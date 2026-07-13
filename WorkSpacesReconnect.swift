import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Security

private let keychainService = "codex-amazon-workspaces"
private let retryCooldown: TimeInterval = 60
private let maximumNodes = 600

private enum ScreenState: String, Codable {
    case noWindow = "no-window"
    case activeSession = "active-session"
    case starting = "starting"
    case disconnected = "disconnected"
    case username = "username"
    case password = "password"
    case credentialError = "credential-error"
    case ambiguous = "ambiguous"
    case accessibilityUnavailable = "accessibility-unavailable"

    var isActionable: Bool {
        self == .disconnected || self == .username || self == .password
    }
}

private struct WatcherState: Codable {
    var consecutiveActionableChecks = 0
    var lastAttemptAt: TimeInterval = 0
    var lastAccessibilityPromptAt: TimeInterval?
    var lastObservation = ""
    var lastDiagnosticSummary: String?
    var blockedReason: String?
}

private struct Credentials {
    let username: String
    let password: String
}

private struct WorkSpacesWindow {
    let processIdentifier: pid_t
    let width: Double
    let height: Double

    var isClearlyActive: Bool {
        width > 800 || height > 600
    }
}

private struct AccessibilityNode {
    let element: AXUIElement
    let role: String
    let subrole: String
    let title: String
    let description: String
    let value: String
    let enabled: Bool

    var searchableText: String {
        [title, description, value]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    var isButton: Bool {
        role == kAXButtonRole
    }

    var isUsernameField: Bool {
        role == kAXTextFieldRole && subrole != kAXSecureTextFieldSubrole
    }

    var isPasswordField: Bool {
        role == kAXTextFieldRole && subrole == kAXSecureTextFieldSubrole
            || role == "AXSecureTextField"
    }
}

private struct UISnapshot {
    let state: ScreenState
    let nodes: [AccessibilityNode]
}

private enum WatcherError: Error, CustomStringConvertible {
    case accessibility(String)
    case keychain(OSStatus)
    case invalidCredentialData(String)
    case interaction(String)

    var description: String {
        switch self {
        case .accessibility(let message), .interaction(let message):
            return message
        case .keychain(let status):
            return "Keychain lookup failed with status \(status)"
        case .invalidCredentialData(let message):
            return message
        }
    }
}

private let fileManager = FileManager.default
private let stateDirectory = fileManager.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/WorkSpacesReconnect", isDirectory: true)
private let stateURL = stateDirectory.appendingPathComponent("state.json")

private func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func log(_ message: String) {
    print("\(timestamp()) \(message)")
}

private func normalizedDiagnosticText(_ node: AccessibilityNode) -> String {
    if node.isPasswordField || node.isUsernameField {
        return "<editable field redacted>"
    }

    var text = node.searchableText
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    if text.range(
        of: #"^ws[a-z0-9-]*\+[a-z0-9]+$"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil {
        return "<registration code redacted>"
    }
    if let registrationCode = text.range(
        of: "registration code:",
        options: .caseInsensitive
    ) {
        text = String(text[..<registrationCode.lowerBound]) + "registration code: <redacted>"
    }
    return String(text.prefix(180))
}

private func diagnosticSummary(_ nodes: [AccessibilityNode]) -> String {
    let entries = nodes.compactMap { node -> String? in
        let text = normalizedDiagnosticText(node)
        let isUsefulRole = node.role == kAXWindowRole
            || node.role == kAXButtonRole
            || node.role == kAXStaticTextRole
            || node.role == kAXTextFieldRole
            || node.role == "AXSecureTextField"
        guard isUsefulRole || !text.isEmpty else { return nil }
        return "role=\(node.role) subrole=\(node.subrole) enabled=\(node.enabled) text=\(text.isEmpty ? "<none>" : text)"
    }
    return entries.prefix(40).joined(separator: " | ")
}

private func windowNumber(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
}

private func currentWindows() -> [WorkSpacesWindow] {
    guard let rawWindows = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return []
    }

    return rawWindows.compactMap { window in
        guard
            let owner = window[kCGWindowOwnerName as String] as? String,
            owner.localizedCaseInsensitiveContains("workspaces"),
            windowNumber(window[kCGWindowLayer as String]) == 0,
            let processIdentifier = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: rawBounds),
            bounds.width >= 300,
            bounds.height >= 250
        else {
            return nil
        }

        return WorkSpacesWindow(
            processIdentifier: processIdentifier,
            width: bounds.width,
            height: bounds.height
        )
    }
}

private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
    copyAttribute(element, attribute) as? String ?? ""
}

private func boolAttribute(_ element: AXUIElement, _ attribute: String, default defaultValue: Bool) -> Bool {
    (copyAttribute(element, attribute) as? NSNumber)?.boolValue ?? defaultValue
}

private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func childElements(_ element: AXUIElement) -> [AXUIElement] {
    copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

private func mainWindow(for processIdentifier: pid_t) -> AXUIElement? {
    let application = AXUIElementCreateApplication(processIdentifier)
    if let main = elementAttribute(application, kAXMainWindowAttribute) {
        return main
    }
    if let focused = elementAttribute(application, kAXFocusedWindowAttribute) {
        return focused
    }
    if let windows = copyAttribute(application, kAXWindowsAttribute) as? [AXUIElement] {
        return windows.first
    }
    return childElements(application).first {
        stringAttribute($0, kAXRoleAttribute) == kAXWindowRole
    }
}

private func accessibilityNodes(from root: AXUIElement) -> [AccessibilityNode] {
    var result: [AccessibilityNode] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]

    while !queue.isEmpty && result.count < maximumNodes {
        let (element, depth) = queue.removeFirst()
        result.append(AccessibilityNode(
            element: element,
            role: stringAttribute(element, kAXRoleAttribute),
            subrole: stringAttribute(element, kAXSubroleAttribute),
            title: stringAttribute(element, kAXTitleAttribute),
            description: stringAttribute(element, kAXDescriptionAttribute),
            value: stringAttribute(element, kAXValueAttribute),
            enabled: boolAttribute(element, kAXEnabledAttribute, default: true)
        ))
        if depth < 12 {
            queue.append(contentsOf: childElements(element).map { ($0, depth + 1) })
        }
    }
    return result
}

private func button(_ nodes: [AccessibilityNode], labels: Set<String>) -> AccessibilityNode? {
    nodes.first { node in
        guard node.isButton else { return false }
        let values = [node.title, node.description, node.value]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return !labels.isDisjoint(with: values)
    }
}

private func snapshot() -> UISnapshot {
    let windows = currentWindows()
    guard !windows.isEmpty else {
        return UISnapshot(state: .noWindow, nodes: [])
    }
    guard AXIsProcessTrusted() else {
        let fallback: ScreenState = windows.contains(where: \.isClearlyActive)
            ? .activeSession
            : .accessibilityUnavailable
        return UISnapshot(state: fallback, nodes: [])
    }

    var nodes: [AccessibilityNode] = []
    for processIdentifier in Set(windows.map(\.processIdentifier)) {
        if let root = mainWindow(for: processIdentifier) {
            nodes.append(contentsOf: accessibilityNodes(from: root))
        }
    }

    let allText = nodes.map(\.searchableText).joined(separator: " ")
    let windowDescriptions = Set(nodes.filter { $0.role == kAXWindowRole }.map { $0.description.lowercased() })

    if windowDescriptions.contains("sessionwindow") || windows.contains(where: \.isClearlyActive) {
        return UISnapshot(state: .activeSession, nodes: nodes)
    }
    if allText.contains("starting workspace") || allText.contains("initializing workspace") {
        return UISnapshot(state: .starting, nodes: nodes)
    }
    if allText.contains("couldn't verify your sign-in credentials")
        || allText.contains("could not verify your sign-in credentials") {
        return UISnapshot(state: .credentialError, nodes: nodes)
    }
    if allText.contains("disconnected")
        && button(nodes, labels: ["reconnect", "connect again"]) != nil {
        return UISnapshot(state: .disconnected, nodes: nodes)
    }
    if nodes.contains(where: \.isPasswordField)
        && button(nodes, labels: ["sign in", "connect"]) != nil {
        return UISnapshot(state: .password, nodes: nodes)
    }
    if allText.contains("username")
        && nodes.contains(where: \.isUsernameField)
        && button(nodes, labels: ["next"]) != nil {
        return UISnapshot(state: .username, nodes: nodes)
    }
    return UISnapshot(state: .ambiguous, nodes: nodes)
}

private func loadState() -> WatcherState {
    guard
        let data = try? Data(contentsOf: stateURL),
        let state = try? JSONDecoder().decode(WatcherState.self, from: data)
    else {
        return WatcherState()
    }
    return state
}

private func saveState(_ state: WatcherState) throws {
    try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(state)
    try data.write(to: stateURL, options: .atomic)
}

private func press(_ node: AccessibilityNode) throws {
    guard node.enabled else {
        throw WatcherError.interaction("Expected button was disabled")
    }
    let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
    guard result == .success else {
        throw WatcherError.accessibility("AXPress failed with code \(result.rawValue)")
    }
}

private func focus(_ node: AccessibilityNode) throws {
    let result = AXUIElementSetAttributeValue(
        node.element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    guard result == .success else {
        throw WatcherError.accessibility("Could not focus \(node.role); code \(result.rawValue)")
    }
}

private func postKey(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
}

private func postText(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    let characters = Array(text.utf16)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    characters.withUnsafeBufferPointer { buffer in
        down?.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: buffer.baseAddress!)
    }
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    up?.post(tap: .cghidEventTap)
}

private func typeUsername(_ username: String, into field: AccessibilityNode) throws {
    try focus(field)
    Thread.sleep(forTimeInterval: 0.1)
    postKey(keyCode: 0, flags: .maskCommand) // Command-A
    postKey(keyCode: 51) // Delete
    postText(username)
    Thread.sleep(forTimeInterval: 0.2)
}

private func keychainCredentials() throws -> Credentials {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecReturnAttributes as String: true,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
        throw WatcherError.keychain(status)
    }
    guard let item = result as? [String: Any] else {
        throw WatcherError.invalidCredentialData("Keychain returned an unexpected credential record")
    }
    guard
        let username = item[kSecAttrAccount as String] as? String,
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw WatcherError.invalidCredentialData("Keychain credential had no WorkSpaces username")
    }
    guard let data = item[kSecValueData as String] as? Data else {
        throw WatcherError.invalidCredentialData("Keychain credential had no password data")
    }
    guard let password = String(data: data, encoding: .utf8) else {
        throw WatcherError.invalidCredentialData("Keychain password was not valid UTF-8")
    }
    return Credentials(username: username, password: password)
}

private func pastePassword(_ password: String, into field: AccessibilityNode) throws {
    try focus(field)
    Thread.sleep(forTimeInterval: 0.1)
    postKey(keyCode: 0, flags: .maskCommand) // Command-A
    postKey(keyCode: 51) // Delete

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(password, forType: .string) else {
        throw WatcherError.interaction("Could not put the Keychain password on the pasteboard")
    }
    defer { pasteboard.clearContents() }
    postKey(keyCode: 9, flags: .maskCommand) // Command-V
    Thread.sleep(forTimeInterval: 0.25)
}

private func waitForSnapshot(timeout: TimeInterval, matching states: Set<ScreenState>) -> UISnapshot? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let current = snapshot()
        if states.contains(current.state) {
            return current
        }
        Thread.sleep(forTimeInterval: 0.4)
    } while Date() < deadline
    return nil
}

private func submitPassword(from current: UISnapshot, credentials: Credentials) throws -> ScreenState {
    guard let field = current.nodes.first(where: \.isPasswordField) else {
        throw WatcherError.interaction("Confirmed password screen had no secure text field")
    }
    try pastePassword(credentials.password, into: field)

    var refreshed = snapshot()
    var signIn = button(refreshed.nodes, labels: ["sign in", "connect"])
    if signIn?.enabled != true {
        Thread.sleep(forTimeInterval: 0.4)
        refreshed = snapshot()
        signIn = button(refreshed.nodes, labels: ["sign in", "connect"])
    }
    guard let signIn else {
        throw WatcherError.interaction("Password was entered but no Sign in button was available")
    }
    try press(signIn)
    log("submitted WorkSpaces credentials deterministically")

    return waitForSnapshot(
        timeout: 15,
        matching: [.starting, .activeSession, .credentialError]
    )?.state ?? .ambiguous
}

private func performLoginFlow(from initial: UISnapshot) throws -> ScreenState {
    var current = initial

    if current.state == .disconnected {
        guard let reconnect = button(current.nodes, labels: ["reconnect", "connect again"]) else {
            throw WatcherError.interaction("Disconnected screen had no recognized reconnect button")
        }
        try press(reconnect)
        log("pressed WorkSpaces reconnect")
        guard let next = waitForSnapshot(timeout: 12, matching: [.username, .password, .starting, .activeSession]) else {
            return .ambiguous
        }
        current = next
    }

    let credentials: Credentials?
    if current.state == .username || current.state == .password {
        credentials = try keychainCredentials()
    } else {
        credentials = nil
    }

    if current.state == .username {
        guard let credentials else {
            throw WatcherError.invalidCredentialData("WorkSpaces credentials were unavailable")
        }
        guard let field = current.nodes.first(where: \.isUsernameField) else {
            throw WatcherError.interaction("Username screen had no editable text field")
        }
        try typeUsername(credentials.username, into: field)
        let refreshed = snapshot()
        guard let next = button(refreshed.nodes, labels: ["next"]) else {
            throw WatcherError.interaction("Username was entered but no Next button was available")
        }
        try press(next)
        log("submitted WorkSpaces username")
        guard let password = waitForSnapshot(timeout: 12, matching: [.password, .credentialError]) else {
            return .ambiguous
        }
        current = password
    }

    if current.state == .password {
        guard let credentials else {
            throw WatcherError.invalidCredentialData("WorkSpaces credentials were unavailable")
        }
        return try submitPassword(from: current, credentials: credentials)
    }
    return current.state
}

private func check() throws {
    let accessibilityTrusted = AXIsProcessTrusted()
    let current = snapshot()
    var state = loadState()

    if !accessibilityTrusted {
        let now = Date().timeIntervalSince1970
        let lastPrompt = state.lastAccessibilityPromptAt ?? 0
        if now - lastPrompt >= 24 * 60 * 60 {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            state.lastAccessibilityPromptAt = now
            log("requested macOS Accessibility permission; next prompt is suppressed for 24 hours")
        }
    }

    if state.lastObservation != current.state.rawValue {
        log("observation=\(current.state.rawValue)")
        state.lastObservation = current.state.rawValue
    }

    let diagnosticStates: Set<ScreenState> = [
        .ambiguous,
        .disconnected,
        .credentialError,
        .accessibilityUnavailable,
    ]
    if diagnosticStates.contains(current.state) {
        let summary = diagnosticSummary(current.nodes)
        if state.lastDiagnosticSummary != summary {
            log("accessibility-snapshot state=\(current.state.rawValue) \(summary.isEmpty ? "nodes=<none>" : summary)")
            state.lastDiagnosticSummary = summary
        }
    } else {
        state.lastDiagnosticSummary = nil
    }

    switch current.state {
    case .activeSession, .starting:
        state.consecutiveActionableChecks = 0
        state.blockedReason = nil
    case .credentialError:
        state.consecutiveActionableChecks = 0
        state.blockedReason = "WorkSpaces rejected the stored credential"
        log("blocked further attempts after a credential error")
    default:
        if current.state.isActionable {
            state.consecutiveActionableChecks += 1
        } else {
            state.consecutiveActionableChecks = 0
        }
    }

    let now = Date().timeIntervalSince1970
    let cooldownElapsed = now - state.lastAttemptAt >= retryCooldown
    let shouldAttempt = current.state.isActionable
        && state.consecutiveActionableChecks >= 2
        && cooldownElapsed
        && state.blockedReason == nil

    if shouldAttempt {
        state.lastAttemptAt = now
        try saveState(state)
        let result = try performLoginFlow(from: current)
        log("deterministic login flow result=\(result.rawValue)")
        if result == .credentialError {
            state.blockedReason = "WorkSpaces rejected the stored credential"
        } else if result == .starting || result == .activeSession {
            state.blockedReason = nil
            state.consecutiveActionableChecks = 0
        }
    }

    try saveState(state)
}

private func diagnose() throws {
    let current = snapshot()
    print("trusted=\(AXIsProcessTrusted())")
    print("classification=\(current.state.rawValue)")
    for node in current.nodes {
        let text = normalizedDiagnosticText(node)
        guard !text.isEmpty else { continue }
        print("role=\(node.role) subrole=\(node.subrole) enabled=\(node.enabled) text=\(text)")
    }
}

private func credentialsCheck() throws {
    _ = try keychainCredentials()
    print("credentials=available")
}

private func requestAccessibility() {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    print("trusted=\(AXIsProcessTrusted())")
}

private func selfTest() throws {
    let active = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXWindowRole, subrole: "",
        title: "Amazon WorkSpaces", description: "SessionWindow", value: "", enabled: true
    )
    precondition(active.searchableText.contains("sessionwindow"))

    let secure = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXTextFieldRole,
        subrole: kAXSecureTextFieldSubrole, title: "", description: "Password", value: "", enabled: true
    )
    precondition(secure.isPasswordField)

    let usernameField = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXTextFieldRole,
        subrole: "", title: "", description: "Username", value: "example-user", enabled: true
    )
    precondition(usernameField.isUsernameField)
    precondition(normalizedDiagnosticText(usernameField) == "<editable field redacted>")

    let registrationCode = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXStaticTextRole,
        subrole: "", title: "", description: "",
        value: "Initializing WorkSpace. Registration code: secret-code", enabled: true
    )
    let redacted = normalizedDiagnosticText(registrationCode)
    precondition(redacted.contains("registration code: <redacted>"))
    precondition(!redacted.contains("secret-code"))

    let bareRegistrationCode = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXStaticTextRole,
        subrole: "", title: "", description: "", value: "wsdub+Y5L9T6", enabled: true
    )
    precondition(normalizedDiagnosticText(bareRegistrationCode) == "<registration code redacted>")
    print("self-test passed")
}

do {
    switch CommandLine.arguments.dropFirst().first ?? "check" {
    case "check":
        try check()
    case "diagnose":
        try diagnose()
    case "credentials-check":
        try credentialsCheck()
    case "request-accessibility":
        requestAccessibility()
    case "self-test":
        try selfTest()
    default:
        fputs("usage: workspaces-reconnect [check|credentials-check|diagnose|request-accessibility|self-test]\n", stderr)
        exit(64)
    }
} catch {
    fputs("\(timestamp()) error: \(error)\n", stderr)
    exit(1)
}
