import ApplicationServices
import AppKit
import Foundation

struct Options {
    var interval: TimeInterval = 60.0
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

enum CDPMatchPolicy {
    static func canCarryTarget(role: String) -> Bool {
        role == kAXStaticTextRole as String
            || role == kAXHeadingRole as String
            || role == kAXButtonRole as String
    }

    static func canCombineTargetAndButton(role: String, subrole: String) -> Bool {
        role == kAXSheetRole as String
            || role == kAXPopoverRole as String
            || role == kAXButtonRole as String
            || (role == kAXGroupRole as String
                && subrole == kAXApplicationAlertDialogSubrole as String)
    }
}

enum CDPPressPolicy {
    static let burstDelays: [TimeInterval] = [0.075, 0.150, 0.300, 0.650, 0.900]
    static let retryInterval: TimeInterval = 0.500
    static let maximumAttempts = 2

    static func shouldSuppress(attempts: Int, elapsedSinceLastAttempt: TimeInterval) -> Bool {
        attempts >= maximumAttempts
            || attempts > 0 && elapsedSinceLastAttempt < retryInterval
    }
}

enum WatchedProcessKind: Equatable {
    case cdp
    case homebrewGatekeeper
}

struct NotificationRegistrationKey: Hashable {
    let pid: pid_t
    let element: AXUIElement
    let notification: String

    static func == (lhs: NotificationRegistrationKey, rhs: NotificationRegistrationKey) -> Bool {
        lhs.pid == rhs.pid
            && lhs.notification == rhs.notification
            && CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(notification)
        hasher.combine(CFHash(element))
    }
}

struct CDPPromptMatch {
    let container: AXUIElement
    let button: AXUIElement
    let target: String
}

struct CDPSubtreeResult {
    var containsTarget = false
    var target: String?
    var button: AXUIElement?
    var match: CDPPromptMatch?
}

struct RecentButtonPress {
    let button: AXUIElement
    var lastDate: Date
    var attempts: Int
}

final class LocalBurst {
    let pid: pid_t
    let root: AXUIElement?
    var stopped = false

    init(pid: pid_t, root: AXUIElement?) {
        self.pid = pid
        self.root = root
    }
}

enum LocalRootResolution {
    case root(AXUIElement)
    case retryFromApplication
    case ignore
}

final class Watcher {
    let options: Options
    let gatekeeperRule = GatekeeperRule(localizations: GatekeeperLocalizationCatalog.load())
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
    let applicationNotifications = [
        kAXWindowCreatedNotification as String,
        kAXSheetCreatedNotification as String,
        kAXCreatedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String
    ]
    let windowNotifications = [
        kAXSheetCreatedNotification as String,
        kAXCreatedNotification as String
    ]
    let burstDelays = CDPPressPolicy.burstDelays
    let registrationRetryDelays: [TimeInterval] = [0.050, 0.200, 0.750, 1.500]
    let observerRetryDelays: [TimeInterval] = [0.025, 0.075, 0.150, 0.300, 0.600, 0.900]
    var observers: [pid_t: AXObserver] = [:]
    var processKinds: [pid_t: WatchedProcessKind] = [:]
    var runningApplicationsObservation: NSKeyValueObservation?
    var registeredNotifications = Set<NotificationRegistrationKey>()
    var unsupportedNotifications = Set<NotificationRegistrationKey>()
    var pendingNotificationRetries = Set<NotificationRegistrationKey>()
    var reportedNotificationFailures = Set<NotificationRegistrationKey>()
    var pendingObserverRetries = Set<pid_t>()
    var observerRetryAttempts: [pid_t: Int] = [:]
    var localBursts: [LocalBurst] = []
    var clickCount = 0
    var timer: Timer?
    var timeoutTimer: Timer?
    var accessibilityTimer: Timer?
    var monitoringStarted = false
    var accessibilityWarningLogged = false
    var accessibilityPromptShown = false
    var lastAccessibilityLog = Date.distantPast
    var recentButtonPresses: [RecentButtonPress] = []
    var recentGatekeeperAttempts: [String: Date] = [:]

    init(options: Options) {
        self.options = options
    }

    func run() {
        scheduleTimeout()
        observeRunningApplications()
        startMonitoringIfTrusted()
        scheduleWatchdog()
        RunLoop.current.run()
    }

    func scheduleTimeout() {
        if options.timeout > 0 {
            let timeoutTimer = Timer(timeInterval: options.timeout, repeats: false) { [weak self] _ in
                guard let self else {
                    return
                }
                exit(self.options.once ? 1 : 0)
            }
            timeoutTimer.tolerance = min(0.100, options.timeout * 0.05)
            RunLoop.current.add(timeoutTimer, forMode: .default)
            self.timeoutTimer = timeoutTimer
        }
    }

    func observeRunningApplications() {
        let workspace = NSWorkspace.shared
        runningApplicationsObservation = workspace.observe(
            \.runningApplications,
            options: [.new]
        ) { [weak self] workspace, change in
            let applications = change.newValue ?? workspace.runningApplications
            DispatchQueue.main.async {
                self?.runningApplicationsChanged(applications)
            }
        }
    }

    func runningApplicationsChanged(_ applications: [NSRunningApplication]) {
        startMonitoringIfTrusted()
        guard monitoringStarted else {
            return
        }
        refreshTargets(applications: applications)
    }

    func scheduleWatchdog() {
        let interval = max(0.100, options.interval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        timer.tolerance = min(5.0, max(0.010, interval * 0.1))
        RunLoop.current.add(timer, forMode: .default)
        self.timer = timer
    }

    func watchdogTick() {
        startMonitoringIfTrusted()
        guard monitoringStarted else {
            return
        }
        refreshTargets(applications: NSWorkspace.shared.runningApplications)
        scanAllTargets()
    }

    func startMonitoringIfTrusted() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermissionOnce()
            scheduleAccessibilityCheck()
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
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        monitoringStarted = true
        log("started: watching Chrome CDP prompts and Homebrew Gatekeeper confirmations")
        refreshTargets(applications: NSWorkspace.shared.runningApplications)
    }

    func scheduleAccessibilityCheck() {
        guard accessibilityTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.startMonitoringIfTrusted()
        }
        timer.tolerance = 1.0
        RunLoop.current.add(timer, forMode: .default)
        accessibilityTimer = timer
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

    func refreshTargets(applications: [NSRunningApplication]) {
        var currentKinds: [pid_t: WatchedProcessKind] = [:]
        for app in applications {
            let pid = app.processIdentifier
            if isGatekeeperAgent(app) {
                currentKinds[pid] = .homebrewGatekeeper
                continue
            }
            guard let name = app.localizedName else {
                continue
            }
            guard options.processes.contains(name) else {
                continue
            }
            currentKinds[pid] = .cdp
        }

        let trackedPIDs = Set(processKinds.keys).union(observers.keys)
        let stalePIDs = trackedPIDs.filter { currentKinds[$0] == nil }
        for pid in stalePIDs {
            removeTarget(pid: pid)
        }
        processKinds = currentKinds
        for pid in currentKinds.keys {
            observe(pid: pid)
        }
    }

    func removeTarget(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        registeredNotifications = Set(registeredNotifications.filter { $0.pid != pid })
        unsupportedNotifications = Set(unsupportedNotifications.filter { $0.pid != pid })
        pendingNotificationRetries = Set(pendingNotificationRetries.filter { $0.pid != pid })
        reportedNotificationFailures = Set(reportedNotificationFailures.filter { $0.pid != pid })
        pendingObserverRetries.remove(pid)
        observerRetryAttempts.removeValue(forKey: pid)
        for burst in localBursts where burst.pid == pid {
            burst.stopped = true
        }
        localBursts.removeAll { $0.pid == pid }
    }

    func observe(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var createdObserver = false

        if observers[pid] == nil {
            var observer: AXObserver?
            let result = AXObserverCreate(pid, axCallback, &observer)
            guard result == .success, let observer else {
                scheduleObserverRetry(pid: pid)
                return
            }
            pendingObserverRetries.remove(pid)
            observerRetryAttempts.removeValue(forKey: pid)
            observers[pid] = observer
            createdObserver = true
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        guard let observer = observers[pid] else {
            return
        }
        for notification in applicationNotifications {
            addNotification(
                observer: observer,
                element: appElement,
                notification: notification,
                refcon: refcon,
                pid: pid,
                retryIndex: 0
            )
        }
        observeWindows(pid: pid, observer: observer, refcon: refcon)
        if createdObserver {
            scheduleLocalBurst(pid: pid, root: nil)
        }
    }

    func scheduleObserverRetry(pid: pid_t) {
        guard processKinds[pid] != nil,
              observers[pid] == nil,
              !pendingObserverRetries.contains(pid) else {
            return
        }
        let attempt = observerRetryAttempts[pid, default: 0]
        guard attempt < observerRetryDelays.count else {
            log("error: [ax] observer creation remained busy \(pid)")
            return
        }
        observerRetryAttempts[pid] = attempt + 1
        pendingObserverRetries.insert(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + observerRetryDelays[attempt]) { [weak self] in
            guard let self,
                  self.pendingObserverRetries.remove(pid) != nil,
                  self.processKinds[pid] != nil,
                  self.observers[pid] == nil else {
                return
            }
            self.observe(pid: pid)
        }
    }

    func observeWindows(
        pid: pid_t,
        observer: AXObserver? = nil,
        refcon: UnsafeMutableRawPointer? = nil
    ) {
        guard let observer = observer ?? observers[pid] else {
            return
        }
        let resolvedRefcon = refcon
            ?? UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let appElement = AXUIElementCreateApplication(pid)
        for window in children(of: appElement, attribute: kAXWindowsAttribute as String) {
            for notification in windowNotifications {
                addNotification(
                    observer: observer,
                    element: window,
                    notification: notification,
                    refcon: resolvedRefcon,
                    pid: pid,
                    retryIndex: 0
                )
            }
        }
    }

    func addNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: String,
        refcon: UnsafeMutableRawPointer,
        pid: pid_t,
        retryIndex: Int
    ) {
        let key = NotificationRegistrationKey(
            pid: pid,
            element: element,
            notification: notification
        )
        guard !registeredNotifications.contains(key),
              !unsupportedNotifications.contains(key),
              !pendingNotificationRetries.contains(key) else {
            return
        }
        let result = AXObserverAddNotification(
            observer,
            element,
            notification as CFString,
            refcon
        )
        switch result {
        case .success, .notificationAlreadyRegistered:
            registeredNotifications.insert(key)
            reportedNotificationFailures.remove(key)
        case .notificationUnsupported:
            unsupportedNotifications.insert(key)
        case .cannotComplete:
            guard retryIndex < registrationRetryDelays.count else {
                if reportedNotificationFailures.insert(key).inserted {
                    log("error: [ax] notification registration remained busy \(pid) / \(notification)")
                }
                return
            }
            pendingNotificationRetries.insert(key)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + registrationRetryDelays[retryIndex]
            ) { [weak self, observer, element] in
                guard let self,
                      self.pendingNotificationRetries.remove(key) != nil,
                      self.processKinds[pid] != nil,
                      let currentObserver = self.observers[pid],
                      CFEqual(currentObserver, observer) else {
                    return
                }
                self.addNotification(
                    observer: observer,
                    element: element,
                    notification: notification,
                    refcon: refcon,
                    pid: pid,
                    retryIndex: retryIndex + 1
                )
            }
        default:
            if reportedNotificationFailures.insert(key).inserted {
                log("error: [ax] notification registration failed \(result.rawValue) / \(pid) / \(notification)")
            }
        }
    }

    func handle(element: AXUIElement, notification: String) {
        guard applicationNotifications.contains(notification) else {
            return
        }
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success, processKinds[pid] != nil else {
            return
        }
        switch localBurstRoot(for: element, pid: pid) {
        case let .root(root):
            scheduleLocalBurst(pid: pid, root: root)
        case .retryFromApplication:
            scheduleLocalBurst(pid: pid, root: nil)
        case .ignore:
            break
        }
        observeWindows(pid: pid)
    }

    func localBurstRoot(for element: AXUIElement, pid: pid_t) -> LocalRootResolution {
        var current = element
        for _ in 0..<24 {
            let role = stringAttribute(current, kAXRoleAttribute as String)
            if role.isEmpty {
                return .retryFromApplication
            }
            if role == "AXWebArea" {
                return .ignore
            }
            if role == kAXWindowRole as String {
                return .root(current)
            }
            if role == kAXApplicationRole as String {
                let appElement = AXUIElementCreateApplication(pid)
                guard let focusedWindow = elementAttribute(
                    appElement,
                    attribute: kAXFocusedWindowAttribute as String
                ) else {
                    return .retryFromApplication
                }
                return .root(focusedWindow)
            }
            guard let parent = elementAttribute(
                current,
                attribute: kAXParentAttribute as String
            ) else {
                return .retryFromApplication
            }
            current = parent
        }
        return .retryFromApplication
    }

    func scheduleCurrentWindowBursts(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        for window in children(of: appElement, attribute: kAXWindowsAttribute as String) {
            scheduleLocalBurst(pid: pid, root: window)
        }
    }

    func scheduleLocalBurst(pid: pid_t, root: AXUIElement?) {
        guard !localBursts.contains(where: {
            guard $0.pid == pid, !$0.stopped else {
                return false
            }
            switch ($0.root, root) {
            case (nil, nil):
                return true
            case let (existing?, candidate?):
                return CFEqual(existing, candidate)
            default:
                return false
            }
        }) else {
            return
        }
        let burst = LocalBurst(pid: pid, root: root)
        localBursts.append(burst)
        for (index, delay) in burstDelays.enumerated() {
            let isLast = index == burstDelays.indices.last
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, burst] in
                self?.runLocalBurst(burst, isLast: isLast)
            }
        }
    }

    func runLocalBurst(_ burst: LocalBurst, isLast: Bool) {
        guard !burst.stopped else {
            return
        }
        guard processKinds[burst.pid] != nil else {
            stopLocalBurst(burst)
            return
        }
        var result: String?
        switch processKinds[burst.pid] {
        case .cdp:
            if let root = burst.root,
               !isInvalid(element: root, expectedPID: burst.pid) {
                result = clickPrompt(
                    in: root,
                    context: label(of: root)
                )
            } else {
                result = scanCDPWindows(pid: burst.pid)
            }
        case .homebrewGatekeeper:
            if let app = NSRunningApplication(processIdentifier: burst.pid) {
                result = scanHomebrewGatekeeper(app: app)
            }
        case nil:
            break
        }
        if let result {
            handleClickResult(result)
            if options.dryRun {
                stopLocalBurst(burst)
                return
            }
            if isLast, result.hasPrefix("clicked:") {
                let pid = burst.pid
                let root = burst.root
                stopLocalBurst(burst)
                scheduleLocalBurst(pid: pid, root: root)
                return
            }
        }
        if isLast {
            stopLocalBurst(burst)
        }
    }

    func scanCDPWindows(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        for window in children(of: appElement, attribute: kAXWindowsAttribute as String) {
            if let result = clickPrompt(in: window, context: label(of: window)) {
                return result
            }
        }
        return nil
    }

    func stopLocalBurst(_ burst: LocalBurst) {
        burst.stopped = true
        localBursts.removeAll { $0 === burst }
    }

    func isInvalid(element: AXUIElement, expectedPID: pid_t) -> Bool {
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        if pidResult == .invalidUIElement || pidResult == .invalidUIElementObserver {
            return true
        }
        if pidResult == .success, pid != expectedPID {
            return true
        }
        var value: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        )
        return roleResult == .invalidUIElement
    }

    func scanAllTargets() {
        scanTargets()
    }

    func scanTargets() {
        for app in NSWorkspace.shared.runningApplications {
            if isGatekeeperAgent(app) {
                if let result = scanHomebrewGatekeeper(app: app) {
                    handleClickResult(result)
                    return
                }
                continue
            }
            guard let name = app.localizedName else {
                continue
            }
            guard options.processes.contains(name) else {
                continue
            }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            for window in children(of: appElement, attribute: kAXWindowsAttribute as String) {
                if let result = clickPrompt(in: window, context: "\(name) / \(label(of: window))") {
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

    func matchedTarget(in element: AXUIElement) -> String? {
        let role = stringAttribute(element, kAXRoleAttribute as String)
        guard CDPMatchPolicy.canCarryTarget(role: role) else {
            return nil
        }
        let values = [
            stringAttribute(element, kAXTitleAttribute as String),
            stringAttribute(element, kAXDescriptionAttribute as String),
            stringAttribute(element, kAXValueAttribute as String),
            stringAttribute(element, kAXHelpAttribute as String)
        ]
        let currentText = values.joined(separator: " ")
        return targets.first(where: {
            currentText.localizedCaseInsensitiveContains($0)
        })
    }

    func canCombineCDPTargetAndButton(in element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as String)
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        return CDPMatchPolicy.canCombineTargetAndButton(role: role, subrole: subrole)
    }

    func isAllowedCDPButton(_ element: AXUIElement) -> Bool {
        guard stringAttribute(element, kAXRoleAttribute as String) == kAXButtonRole as String else {
            return false
        }
        let buttonLabel = label(of: element)
        return buttons.contains(buttonLabel)
            || buttonLabel.localizedCaseInsensitiveContains("Chrome DevTools Protocol")
    }

    func findCDPPrompt(in element: AXUIElement, depth: Int) -> CDPSubtreeResult {
        guard depth <= 24 else {
            return CDPSubtreeResult()
        }
        guard stringAttribute(element, kAXRoleAttribute as String) != "AXWebArea" else {
            return CDPSubtreeResult()
        }

        var result = CDPSubtreeResult()
        if let target = matchedTarget(in: element) {
            result.containsTarget = true
            result.target = target
        }
        if isAllowedCDPButton(element) {
            result.button = element
        }

        for child in children(of: element, attribute: kAXChildrenAttribute as String) {
            let childResult = findCDPPrompt(in: child, depth: depth + 1)
            if let match = childResult.match {
                return CDPSubtreeResult(match: match)
            }
            if !result.containsTarget, childResult.containsTarget {
                result.containsTarget = true
                result.target = childResult.target
            }
            if result.button == nil {
                result.button = childResult.button
            }
        }

        if canCombineCDPTargetAndButton(in: element),
           result.containsTarget,
           let target = result.target,
           let button = result.button {
            result.match = CDPPromptMatch(
                container: element,
                button: button,
                target: target
            )
        }
        return result
    }

    func clickPrompt(in element: AXUIElement, context: String) -> String? {
        guard let match = findCDPPrompt(in: element, depth: 0).match else {
            return nil
        }
        guard !wasSuccessfullyPressed(match.button) else {
            return nil
        }
        let buttonLabel = label(of: match.button)
        let containerLabel = label(of: match.container)
        let matchedContext = containerLabel.isEmpty ? context : containerLabel
        let resolvedContext = matchedContext.isEmpty ? match.target : matchedContext
        if options.dryRun {
            return "match: [cdp] \(resolvedContext) / \(buttonLabel)"
        }
        recordPressAttempt(match.button)
        let result = AXUIElementPerformAction(match.button, kAXPressAction as CFString)
        if result == .success {
            return "clicked: [cdp] \(resolvedContext) / \(buttonLabel)"
        }
        return "error: [cdp] press failed \(result.rawValue) / \(resolvedContext) / \(buttonLabel)"
    }

    func wasSuccessfullyPressed(_ button: AXUIElement) -> Bool {
        let now = Date()
        recentButtonPresses.removeAll {
            now.timeIntervalSince($0.lastDate) >= 300
                || isInvalidElement($0.button)
        }
        guard let press = recentButtonPresses.first(where: {
            CFEqual($0.button, button)
        }) else {
            return false
        }
        return CDPPressPolicy.shouldSuppress(
            attempts: press.attempts,
            elapsedSinceLastAttempt: now.timeIntervalSince(press.lastDate)
        )
    }

    func recordPressAttempt(_ button: AXUIElement) {
        let now = Date()
        if let index = recentButtonPresses.firstIndex(where: {
            CFEqual($0.button, button)
        }) {
            recentButtonPresses[index].lastDate = now
            recentButtonPresses[index].attempts += 1
            return
        }
        recentButtonPresses.append(RecentButtonPress(
            button: button,
            lastDate: now,
            attempts: 1
        ))
    }

    func isInvalidElement(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        )
        return result == .invalidUIElement || result == .invalidUIElementObserver
    }

    func scanHomebrewGatekeeper(app: NSRunningApplication) -> String? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for window in children(of: appElement, attribute: kAXWindowsAttribute as String) {
            if let result = clickHomebrewGatekeeper(
                window: window,
                app: app
            ) {
                return result
            }
        }
        return nil
    }

    func clickHomebrewGatekeeper(
        window: AXUIElement,
        app: NSRunningApplication
    ) -> String? {
        let staticTexts = elements(
            in: window,
            role: kAXStaticTextRole as String,
            depth: 0
        )
        .map(staticText(of:))
        .filter { !$0.isEmpty }
        let buttons = elements(
            in: window,
            role: kAXButtonRole as String,
            depth: 0
        )
        let modalEvidence = gatekeeperModalEvidence(window: window)
        let buttonResult = gatekeeperButtonEvidence(
            window: window,
            buttons: buttons
        )
        let snapshot = GatekeeperDialogSnapshot(
            bundleIdentifier: app.bundleIdentifier,
            bundlePath: app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path,
            staticTexts: staticTexts,
            modalEvidence: modalEvidence,
            buttonEvidence: buttonResult.evidence
        )
        guard let match = gatekeeperRule.match(snapshot) else {
            return nil
        }

        let button: AXUIElement?
        if match.usesButtonFallback {
            let matches = buttons.filter {
                stringAttribute($0, kAXRoleAttribute as String) == kAXButtonRole as String
                    && GatekeeperRule.normalized(label(of: $0))
                        == GatekeeperRule.normalized(match.buttonLabel)
            }
            button = matches.count == 1 ? matches[0] : nil
        } else {
            button = buttonResult.defaultButton
        }
        guard let button else {
            return nil
        }

        let signature = staticTexts
            .map(GatekeeperRule.normalized)
            .sorted()
            .joined(separator: "\u{1f}")
        let key = "\(match.locale):\(signature):\(match.buttonLabel)"
        guard canAttemptGatekeeper(key: key) else {
            return nil
        }
        let headlineTemplate = gatekeeperRule.localizations.first(where: {
            $0.locale == match.locale
        })?.headlineTemplate
        let context = headlineTemplate.flatMap { template in
            staticTexts.first(where: {
                GatekeeperRule.matches(template: template, text: $0)
            })
        } ?? GatekeeperRule.bundleIdentifier
        if options.dryRun {
            return "match: [homebrew-gatekeeper] \(context) / \(match.buttonLabel)"
        }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if result == .success {
            recordSuccessfulGatekeeperAttempt(key: key)
            return "clicked: [homebrew-gatekeeper] \(context) / \(match.buttonLabel)"
        }
        return "error: [homebrew-gatekeeper] press failed \(result.rawValue) / \(context) / \(match.buttonLabel)"
    }

    func gatekeeperModalEvidence(window: AXUIElement) -> GatekeeperModalEvidence {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window,
            kAXModalAttribute as CFString,
            &value
        )
        if result == .success {
            guard let isModal = value as? Bool else {
                return .unavailable
            }
            return isModal ? .modal : .notModal
        }
        if result == .attributeUnsupported {
            let subrole = stringAttribute(window, kAXSubroleAttribute as String)
            let dialogSubroles = [
                kAXDialogSubrole as String,
                kAXSystemDialogSubrole as String
            ]
            return dialogSubroles.contains(subrole) ? .dialogSubroleFallback : .unavailable
        }
        return .unavailable
    }

    func gatekeeperButtonEvidence(
        window: AXUIElement,
        buttons: [AXUIElement]
    ) -> (evidence: GatekeeperButtonEvidence, defaultButton: AXUIElement?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window,
            kAXDefaultButtonAttribute as CFString,
            &value
        )
        if result == .success, let value,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement
            return (
                .defaultButton(
                    GatekeeperButtonSnapshot(
                        role: stringAttribute(element, kAXRoleAttribute as String),
                        label: label(of: element)
                    )
                ),
                element
            )
        }
        if result == .attributeUnsupported {
            let snapshots = buttons.map {
                GatekeeperButtonSnapshot(
                    role: stringAttribute($0, kAXRoleAttribute as String),
                    label: label(of: $0)
                )
            }
            return (.defaultButtonUnsupported(snapshots), nil)
        }
        return (.unavailable, nil)
    }

    func elements(
        in element: AXUIElement,
        role: String,
        depth: Int
    ) -> [AXUIElement] {
        if depth > 20 {
            return []
        }
        var matches: [AXUIElement] = []
        if stringAttribute(element, kAXRoleAttribute as String) == role {
            matches.append(element)
        }
        for child in children(of: element, attribute: kAXChildrenAttribute as String) {
            matches.append(contentsOf: elements(
                in: child,
                role: role,
                depth: depth + 1
            ))
        }
        return matches
    }

    func isGatekeeperAgent(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier == GatekeeperRule.bundleIdentifier,
              let bundlePath = app.bundleURL?
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path else {
            return false
        }
        return bundlePath == GatekeeperRule.bundlePath
    }

    func canAttemptGatekeeper(key: String) -> Bool {
        let now = Date()
        recentGatekeeperAttempts = recentGatekeeperAttempts.filter {
            now.timeIntervalSince($0.value) < 30
        }
        if let previous = recentGatekeeperAttempts[key],
           now.timeIntervalSince(previous) < 30 {
            return false
        }
        return true
    }

    func recordSuccessfulGatekeeperAttempt(key: String) {
        let now = Date()
        recentGatekeeperAttempts = recentGatekeeperAttempts.filter {
            now.timeIntervalSince($0.value) < 30
        }
        recentGatekeeperAttempts[key] = now
    }

    func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    func elementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
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

    func staticText(of element: AXUIElement) -> String {
        let value = stringAttribute(element, kAXValueAttribute as String)
        return value.isEmpty ? label(of: element) : value
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
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else {
        return
    }
    let watcher = Unmanaged<Watcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handle(element: element, notification: notification as String)
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
