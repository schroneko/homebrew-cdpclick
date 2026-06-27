import ApplicationServices
import AppKit
import Foundation

struct Options {
    var interval: TimeInterval = 1.0
    var once = false
    var dryRun = false
    var timeout: TimeInterval = 0
    var maxClicks = 0
    var logPath: String?
    var promptForAccessibility = false
    var processes = [
        "Google Chrome",
        "Google Chrome Canary",
        "Chromium",
        "Brave Browser",
        "Arc",
        "Microsoft Edge",
        "osascript",
        "Script Editor"
    ]
}

final class Watcher {
    let options: Options
    let targets = [
        "Chrome DevTools Protocol",
        "Allow remote debugging?",
        "external app wants full control over this Chrome session"
    ]
    let buttons = [
        "Open Chrome DevTools Protocol",
        "Allow",
        "Open",
        "OK",
        "Continue",
        "許可",
        "許可する",
        "開く",
        "続ける"
    ]
    var observers: [pid_t: AXObserver] = [:]
    var observedElements = Set<String>()
    var clickCount = 0
    var startedAt = Date()
    var lastRefresh = Date.distantPast
    var timer: Timer?
    var monitoringStarted = false
    var accessibilityWarningLogged = false
    var accessibilityPromptShown = false
    var lastAccessibilityLog = Date.distantPast
    var recentClicks: [String: Date] = [:]

    init(options: Options) {
        self.options = options
    }

    func run() {
        startMonitoringIfTrusted()

        timer = Timer.scheduledTimer(withTimeInterval: options.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }

        RunLoop.current.run()
    }

    func tick() {
        if options.timeout > 0 && Date().timeIntervalSince(startedAt) >= options.timeout {
            exit(options.once ? 1 : 0)
        }
        startMonitoringIfTrusted()
        guard monitoringStarted else {
            return
        }
        refreshTargets()
    }

    func startMonitoringIfTrusted() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermissionOnce()
            if !accessibilityWarningLogged || Date().timeIntervalSince(lastAccessibilityLog) >= 60 {
                accessibilityWarningLogged = true
                lastAccessibilityLog = Date()
                log("waiting: Accessibility permission is required")
            }
            return
        }
        guard !monitoringStarted else {
            return
        }
        monitoringStarted = true
        log("started: watching Chrome remote debugging prompts")
        refreshTargets()
        scanAllTargets()
    }

    func requestAccessibilityPermissionOnce() {
        guard options.promptForAccessibility, !accessibilityPromptShown else {
            return
        }
        accessibilityPromptShown = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let promptOptions = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOptions)
    }

    func refreshTargets() {
        let now = Date()
        if now.timeIntervalSince(lastRefresh) < 0.8 {
            return
        }
        lastRefresh = now

        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName else {
                continue
            }
            guard options.processes.contains(name) else {
                continue
            }
            let pid = app.processIdentifier
            observe(pid: pid)
        }
    }

    func observe(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        if observers[pid] == nil {
            var observer: AXObserver?
            let result = AXObserverCreate(pid, axCallback, &observer)
            guard result == .success, let observer else {
                return
            }
            observers[pid] = observer
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            addNotification(observer: observer, element: appElement, notification: kAXWindowCreatedNotification as String, refcon: refcon)
            addNotification(observer: observer, element: appElement, notification: kAXSheetCreatedNotification as String, refcon: refcon)
            addNotification(observer: observer, element: appElement, notification: kAXCreatedNotification as String, refcon: refcon)
        }

        observeWindows(pid: pid, appElement: appElement, refcon: refcon)
    }

    func observeWindows(pid: pid_t, appElement: AXUIElement, refcon: UnsafeMutableRawPointer) {
        guard let observer = observers[pid] else {
            return
        }
        for window in children(of: appElement, attribute: kAXWindowsAttribute as String) {
            let key = "\(pid):\(CFHash(window))"
            guard !observedElements.contains(key) else {
                continue
            }
            observedElements.insert(key)
            addNotification(observer: observer, element: window, notification: kAXSheetCreatedNotification as String, refcon: refcon)
            addNotification(observer: observer, element: window, notification: kAXCreatedNotification as String, refcon: refcon)
        }
    }

    func addNotification(observer: AXObserver, element: AXUIElement, notification: String, refcon: UnsafeMutableRawPointer) {
        _ = AXObserverAddNotification(observer, element, notification as CFString, refcon)
    }

    func handle(element: AXUIElement) {
        refreshTargets()
        if let result = clickPrompt(in: element, depth: 0, context: label(of: element)) {
            handleClickResult(result)
            return
        }
        scanAllTargets()
    }

    func scanAllTargets() {
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName else {
                continue
            }
            guard options.processes.contains(name) else {
                continue
            }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            for window in children(of: appElement, attribute: kAXWindowsAttribute as String) {
                if let result = clickPrompt(in: window, depth: 0, context: "\(name) / \(label(of: window))") {
                    handleClickResult(result)
                    return
                }
            }
        }
    }

    func handleClickResult(_ result: String) {
        log(result)
        if result.hasPrefix("clicked:") {
            clickCount += 1
        }
        if options.once {
            exit(0)
        }
        if options.maxClicks > 0 && clickCount >= options.maxClicks {
            exit(0)
        }
    }

    func containsTarget(element: AXUIElement, depth: Int) -> Bool {
        if depth > 8 {
            return false
        }
        if elementMatchesTarget(element) {
            return true
        }
        for child in children(of: element, attribute: kAXChildrenAttribute as String) {
            if containsTarget(element: child, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    func clickPrompt(in element: AXUIElement, depth: Int, context: String) -> String? {
        if depth > 8 {
            return nil
        }
        for child in children(of: element, attribute: kAXChildrenAttribute as String) {
            let childContext = label(of: child)
            if let result = clickPrompt(in: child, depth: depth + 1, context: childContext.isEmpty ? context : childContext) {
                return result
            }
        }
        guard elementMatchesTarget(element) else {
            return nil
        }
        return clickButton(in: element, depth: 0, context: context)
    }

    func elementMatchesTarget(_ element: AXUIElement) -> Bool {
        let currentText = text(of: element)
        return targets.contains(where: { currentText.localizedCaseInsensitiveContains($0) })
    }

    func clickButton(in element: AXUIElement, depth: Int, context: String) -> String? {
        if depth > 8 {
            return nil
        }
        if stringAttribute(element, kAXRoleAttribute as String) == kAXButtonRole as String {
            let buttonLabel = label(of: element)
            if buttons.contains(buttonLabel) || buttonLabel.localizedCaseInsensitiveContains("Chrome DevTools Protocol") {
                let clickKey = "\(context) / \(buttonLabel)"
                guard shouldClick(key: clickKey) else {
                    return nil
                }
                if options.dryRun {
                    return "match: \(context) / \(buttonLabel)"
                }
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result == .success {
                    return "clicked: \(context) / \(buttonLabel)"
                }
                return "error: press failed \(result.rawValue) / \(context) / \(buttonLabel)"
            }
        }
        for child in children(of: element, attribute: kAXChildrenAttribute as String) {
            if let result = clickButton(in: child, depth: depth + 1, context: context) {
                return result
            }
        }
        return nil
    }

    func shouldClick(key: String) -> Bool {
        let now = Date()
        recentClicks = recentClicks.filter { now.timeIntervalSince($0.value) < 5 }
        if let previous = recentClicks[key], now.timeIntervalSince(previous) < 2 {
            return false
        }
        recentClicks[key] = now
        return true
    }

    func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return ""
        }
        if let string = value as? String {
            return string
        }
        return "\(value)"
    }

    func text(of element: AXUIElement) -> String {
        [
            stringAttribute(element, kAXRoleAttribute as String),
            stringAttribute(element, kAXTitleAttribute as String),
            stringAttribute(element, kAXDescriptionAttribute as String),
            stringAttribute(element, kAXValueAttribute as String),
            stringAttribute(element, kAXHelpAttribute as String)
        ].joined(separator: " ")
    }

    func label(of element: AXUIElement) -> String {
        let values = [
            stringAttribute(element, kAXTitleAttribute as String),
            stringAttribute(element, kAXDescriptionAttribute as String),
            stringAttribute(element, kAXValueAttribute as String),
            stringAttribute(element, kAXHelpAttribute as String)
        ]
        return values.first(where: { !$0.isEmpty && $0 != "missing value" }) ?? ""
    }

    func log(_ message: String) {
        let line = "[\(isoTimestamp())] \(message)"
        if let logPath = options.logPath {
            let url = URL(fileURLWithPath: NSString(string: logPath).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = (line + "\n").data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }
        print(line)
        fflush(stdout)
    }

    func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

let axCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else {
        return
    }
    let watcher = Unmanaged<Watcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handle(element: element)
}

func usage() {
    print("Usage: auto-click-cdp-popup [--once] [--dry-run] [--interval seconds] [--timeout seconds] [--max-clicks count] [--process name] [--log path] [--prompt-for-accessibility]")
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--once":
            options.once = true
        case "--dry-run":
            options.dryRun = true
        case "--interval":
            guard let value = args.first, let interval = TimeInterval(value) else {
                usage()
                exit(2)
            }
            args.removeFirst()
            options.interval = interval
        case "--timeout":
            guard let value = args.first, let timeout = TimeInterval(value) else {
                usage()
                exit(2)
            }
            args.removeFirst()
            options.timeout = timeout
        case "--max-clicks":
            guard let value = args.first, let maxClicks = Int(value) else {
                usage()
                exit(2)
            }
            args.removeFirst()
            options.maxClicks = maxClicks
        case "--process":
            guard let value = args.first else {
                usage()
                exit(2)
            }
            args.removeFirst()
            options.processes.append(value)
        case "--log":
            guard let value = args.first else {
                usage()
                exit(2)
            }
            args.removeFirst()
            options.logPath = value
        case "--prompt-for-accessibility":
            options.promptForAccessibility = true
        case "-h", "--help":
            usage()
            exit(0)
        default:
            print("Unknown option: \(arg)")
            usage()
            exit(2)
        }
    }
    return options
}

Watcher(options: parseOptions()).run()
