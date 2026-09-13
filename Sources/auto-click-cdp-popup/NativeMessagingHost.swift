import Darwin
import Foundation

enum NativeMessagingError: Error {
    case invalidMessage
    case unexpectedEndOfStream
    case messageTooLarge
    case socketFailure(String)
}

struct NativeMessagingCodec {
    static let maximumMessageSize = 16 * 1024 * 1024

    static func encode(_ object: Any) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [])
        guard body.count <= maximumMessageSize else {
            throw NativeMessagingError.messageTooLarge
        }
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(body)
        return frame
    }

    static func readMessage(from handle: FileHandle) throws -> [String: Any]? {
        guard let header = try readExactly(MemoryLayout<UInt32>.size, from: handle) else {
            return nil
        }
        let byte0 = UInt32(header[header.startIndex])
        let byte1 = UInt32(header[header.startIndex + 1])
        let byte2 = UInt32(header[header.startIndex + 2])
        let byte3 = UInt32(header[header.startIndex + 3])
        let length = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
        guard length <= maximumMessageSize else {
            throw NativeMessagingError.messageTooLarge
        }
        guard let body = try readExactly(Int(length), from: handle) else {
            throw NativeMessagingError.unexpectedEndOfStream
        }
        guard let object = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            throw NativeMessagingError.invalidMessage
        }
        return object
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
        if count == 0 {
            return Data()
        }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                if result.isEmpty {
                    return nil
                }
                throw NativeMessagingError.unexpectedEndOfStream
            }
            result.append(chunk)
        }
        return result
    }
}

final class NativeMessagingHost {
    static let hostName = "com.schroneko.autoclickcdppopup.bridge"
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AutoClickCDPPopup", isDirectory: true)
    static let defaultSocketPath = defaultDirectory.appendingPathComponent("bridge.sock").path

    static var isNativeMessagingInvocation: Bool {
        CommandLine.arguments.count == 1
            && isatty(STDIN_FILENO) == 0
            && isatty(STDOUT_FILENO) == 0
    }

    private let input: FileHandle
    private let output: FileHandle
    private let socketPath: String
    private let outputLock = NSLock()
    private let pendingLock = NSLock()
    private var pendingClients: [String: FileHandle] = [:]
    private var serverFD: Int32 = -1
    private var stopping = false

    init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        socketPath: String = NativeMessagingHost.defaultSocketPath
    ) {
        self.input = input
        self.output = output
        self.socketPath = socketPath
    }

    func run() {
        do {
            try prepareSocket()
        } catch {
            writeError("native messaging socket setup failed: \(error)")
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
        sendNative([
            "type": "hostReady",
            "socketPath": socketPath,
            "pid": ProcessInfo.processInfo.processIdentifier
        ])

        do {
            while let message = try NativeMessagingCodec.readMessage(from: input) {
                handleNativeMessage(message)
            }
        } catch {
            writeError("native messaging read failed: \(error)")
        }
        stop()
    }

    private func prepareSocket() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NativeMessagingError.socketFailure(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathData = Data(socketPath.utf8) + Data([0])
        guard pathData.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw NativeMessagingError.socketFailure("socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathData.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw NativeMessagingError.socketFailure(message)
        }
        guard listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            unlink(socketPath)
            throw NativeMessagingError.socketFailure(message)
        }
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            unlink(socketPath)
            throw NativeMessagingError.socketFailure(message)
        }
        serverFD = fd
    }

    private func acceptLoop() {
        while !stopping {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            if stopping {
                close(clientFD)
                break
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ clientFD: Int32) {
        let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
        do {
            let data = try handle.readToEnd() ?? Data()
            guard let request = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                respond(to: handle, id: nil, ok: false, error: "request must be a JSON object")
                return
            }
            let id = stringValue(request["id"]) ?? UUID().uuidString
            var message = request
            message["type"] = "request"
            message["id"] = id
            if (request["method"] as? String) == "bridge.status" {
                respond(
                    to: handle,
                    id: id,
                    ok: true,
                    result: [
                        "pid": ProcessInfo.processInfo.processIdentifier,
                        "socketPath": socketPath,
                        "nativeMessagingHost": NativeMessagingHost.hostName
                    ]
                )
                return
            }
            pendingLock.lock()
            pendingClients[id] = handle
            pendingLock.unlock()
            sendNative(message)
        } catch {
            respond(to: handle, id: nil, ok: false, error: "invalid request: \(error)")
        }
    }

    private func handleNativeMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else {
            writeError("native messaging message is missing type")
            return
        }
        if type == "log" {
            if let text = message["message"] as? String {
                writeError(text)
            }
            return
        }
        guard type == "response", let id = stringValue(message["id"]) else {
            return
        }
        pendingLock.lock()
        let client = pendingClients.removeValue(forKey: id)
        pendingLock.unlock()
        guard let client else {
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: message, options: [])
            try client.write(contentsOf: data)
            try client.write(contentsOf: Data([10]))
            try client.close()
        } catch {
            writeError("bridge response write failed: \(error)")
            try? client.close()
        }
    }

    private func sendNative(_ message: [String: Any]) {
        outputLock.lock()
        defer { outputLock.unlock() }
        do {
            let data = try NativeMessagingCodec.encode(message)
            try output.write(contentsOf: data)
        } catch {
            writeError("native messaging write failed: \(error)")
        }
    }

    private func respond(to client: FileHandle, id: String?, ok: Bool, result: Any? = nil, error: String? = nil) {
        var response: [String: Any] = [
            "type": "response",
            "ok": ok
        ]
        if let id {
            response["id"] = id
        }
        if let result {
            response["result"] = result
        }
        if let error {
            response["error"] = error
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [])
            try client.write(contentsOf: data)
            try client.write(contentsOf: Data([10]))
            try client.close()
        } catch {
            writeError("bridge error response write failed: \(error)")
            try? client.close()
        }
    }

    private func stop() {
        guard !stopping else {
            return
        }
        stopping = true
        wakeAcceptLoop()
        if serverFD >= 0 {
            shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
        pendingLock.lock()
        let clients = Array(pendingClients.values)
        pendingClients.removeAll()
        pendingLock.unlock()
        for client in clients {
            respond(to: client, id: nil, ok: false, error: "native messaging host stopped")
        }
    }

    private func wakeAcceptLoop() {
        guard serverFD >= 0 else {
            return
        }
        let wakeFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard wakeFD >= 0 else {
            return
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathData = Data(socketPath.utf8) + Data([0])
        guard pathData.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(wakeFD)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathData.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(wakeFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(wakeFD)
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func writeError(_ message: String) {
        let line = (message + "\n").data(using: .utf8) ?? Data()
        try? FileHandle.standardError.write(contentsOf: line)
    }
}

struct NativeMessagingClient {
    static func request(_ object: [String: Any], socketPath: String = NativeMessagingHost.defaultSocketPath) -> Int32 {
        do {
            let fd = try connect(to: socketPath)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([10]))
            shutdown(fd, SHUT_WR)
            let response = try handle.readToEnd() ?? Data()
            if let text = String(data: response, encoding: .utf8) {
                print(text, terminator: "")
            }
            try handle.close()
            return 0
        } catch {
            fputs("bridge request failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NativeMessagingError.socketFailure(String(cString: strerror(errno)))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathData = Data(path.utf8) + Data([0])
        guard pathData.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw NativeMessagingError.socketFailure("socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathData.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw NativeMessagingError.socketFailure(message)
        }
        return fd
    }
}
