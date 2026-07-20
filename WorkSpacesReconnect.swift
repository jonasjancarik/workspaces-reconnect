import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Security

private let keychainService = "codex-amazon-workspaces"
private let workSpacesBundleIdentifier = "com.amazon.workspaces"
private let workSpacesDesignatedRequirement = """
identifier "com.amazon.workspaces" and anchor apple generic and \
( \
certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or \
( \
certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and \
certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and \
certificate leaf[subject.OU] = "94KV3E626L" \
) \
)
"""
private let retryCooldown: TimeInterval = 60
private let maximumNodes = 600
private let maximumUnicodeUnitsPerEvent = 20

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

private enum InputFieldKind {
    case username
    case password

    func matches(_ node: AccessibilityNode) -> Bool {
        switch self {
        case .username:
            return node.isUsernameField
        case .password:
            return node.isPasswordField
        }
    }
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

private func accessibilityNode(from element: AXUIElement) -> AccessibilityNode {
    AccessibilityNode(
        element: element,
        role: stringAttribute(element, kAXRoleAttribute),
        subrole: stringAttribute(element, kAXSubroleAttribute),
        title: stringAttribute(element, kAXTitleAttribute),
        description: stringAttribute(element, kAXDescriptionAttribute),
        value: stringAttribute(element, kAXValueAttribute),
        enabled: boolAttribute(element, kAXEnabledAttribute, default: true)
    )
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
        result.append(accessibilityNode(from: element))
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

private func classify(_ nodes: [AccessibilityNode], windows: [WorkSpacesWindow]) -> ScreenState {
    let allText = nodes.map(\.searchableText).joined(separator: " ")
    let windowDescriptions = Set(nodes.filter { $0.role == kAXWindowRole }.map { $0.description.lowercased() })

    if allText.contains("starting workspace") || allText.contains("initializing workspace") { return .starting }
    if allText.contains("couldn't verify your sign-in credentials")
        || allText.contains("could not verify your sign-in credentials") { return .credentialError }
    if allText.contains("disconnected")
        && button(nodes, labels: ["reconnect", "connect again"]) != nil { return .disconnected }
    if nodes.contains(where: \.isPasswordField)
        && button(nodes, labels: ["sign in", "connect"]) != nil { return .password }
    if allText.contains("username")
        && nodes.contains(where: \.isUsernameField)
        && button(nodes, labels: ["next"]) != nil { return .username }
    if windowDescriptions.contains("sessionwindow") || windows.contains(where: \.isClearlyActive) {
        return .activeSession
    }
    return .ambiguous
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

    return UISnapshot(state: classify(nodes, windows: windows), nodes: nodes)
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

private func processIdentifierForElement(_ element: AXUIElement) throws -> pid_t {
    var processIdentifier: pid_t = 0
    let result = AXUIElementGetPid(element, &processIdentifier)
    guard result == .success, processIdentifier > 0 else {
        throw WatcherError.accessibility("Could not identify the input field owner; code \(result.rawValue)")
    }
    return processIdentifier
}

private func processHasAuthenticWorkSpacesSignature(_ processIdentifier: pid_t) -> Bool {
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)]
    var code: SecCode?
    guard
        SecCodeCopyGuestWithAttributes(
            nil,
            attributes as CFDictionary,
            SecCSFlags(rawValue: 0),
            &code
        ) == errSecSuccess,
        let code
    else {
        return false
    }

    var requirement: SecRequirement?
    guard
        SecRequirementCreateWithString(
            workSpacesDesignatedRequirement as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess,
        let requirement
    else {
        return false
    }

    return SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement) == errSecSuccess
}

private func inputTargetIsAllowed(
    _ node: AccessibilityNode,
    expectedKind: InputFieldKind,
    ownerProcessIdentifier: pid_t,
    ownerBundleIdentifier: String?,
    signatureIsValid: Bool,
    workSpacesProcessIdentifiers: Set<pid_t>
) -> Bool {
    expectedKind.matches(node)
        && ownerProcessIdentifier > 0
        && ownerBundleIdentifier == workSpacesBundleIdentifier
        && signatureIsValid
        && workSpacesProcessIdentifiers.contains(ownerProcessIdentifier)
}

private func focusedInputTargetIsAllowed(
    _ focusedNode: AccessibilityNode,
    expectedKind: InputFieldKind,
    expectedProcessIdentifier: pid_t,
    focusedProcessIdentifier: pid_t,
    focusedOwnerBundleIdentifier: String?,
    signatureIsValid: Bool,
    workSpacesProcessIdentifiers: Set<pid_t>
) -> Bool {
    focusedProcessIdentifier == expectedProcessIdentifier
        && inputTargetIsAllowed(
            focusedNode,
            expectedKind: expectedKind,
            ownerProcessIdentifier: focusedProcessIdentifier,
            ownerBundleIdentifier: focusedOwnerBundleIdentifier,
            signatureIsValid: signatureIsValid,
            workSpacesProcessIdentifiers: workSpacesProcessIdentifiers
        )
}

private func assertFocusedInputTarget(
    _ node: AccessibilityNode,
    expectedKind: InputFieldKind,
    processIdentifier: pid_t
) throws {
    let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
    let workSpacesProcessIdentifiers = Set(currentWindows().map(\.processIdentifier))
    let signatureIsValid = processHasAuthenticWorkSpacesSignature(processIdentifier)
    guard inputTargetIsAllowed(
        node,
        expectedKind: expectedKind,
        ownerProcessIdentifier: processIdentifier,
        ownerBundleIdentifier: runningApplication?.bundleIdentifier,
        signatureIsValid: signatureIsValid,
        workSpacesProcessIdentifiers: workSpacesProcessIdentifiers
    ) else {
        throw WatcherError.interaction("Input target stopped belonging to the WorkSpaces application")
    }
    let application = AXUIElementCreateApplication(processIdentifier)
    let focusedElement = elementAttribute(application, kAXFocusedUIElementAttribute)
        ?? (boolAttribute(node.element, kAXFocusedAttribute, default: false) ? node.element : nil)
    guard let focusedElement else {
        throw WatcherError.interaction("WorkSpaces did not report a focused input field; refusing to type")
    }
    let focusedProcessIdentifier = try processIdentifierForElement(focusedElement)
    let focusedNode = accessibilityNode(from: focusedElement)
    let focusedApplication = NSRunningApplication(processIdentifier: focusedProcessIdentifier)
    // WebKit can return a fresh AX proxy for the same DOM input, so CFEqual is not stable.
    // Validate the focused field's semantics and signed process ownership instead.
    guard focusedInputTargetIsAllowed(
        focusedNode,
        expectedKind: expectedKind,
        expectedProcessIdentifier: processIdentifier,
        focusedProcessIdentifier: focusedProcessIdentifier,
        focusedOwnerBundleIdentifier: focusedApplication?.bundleIdentifier,
        signatureIsValid: signatureIsValid,
        workSpacesProcessIdentifiers: workSpacesProcessIdentifiers
    ) else {
        throw WatcherError.interaction(
            "WorkSpaces focused element is no longer the expected input field; refusing to type"
        )
    }
}

private func prepareInputTarget(_ node: AccessibilityNode, expectedKind: InputFieldKind) throws -> pid_t {
    let processIdentifier = try processIdentifierForElement(node.element)
    let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
    let workSpacesProcessIdentifiers = Set(currentWindows().map(\.processIdentifier))
    guard inputTargetIsAllowed(
        node,
        expectedKind: expectedKind,
        ownerProcessIdentifier: processIdentifier,
        ownerBundleIdentifier: runningApplication?.bundleIdentifier,
        signatureIsValid: processHasAuthenticWorkSpacesSignature(processIdentifier),
        workSpacesProcessIdentifiers: workSpacesProcessIdentifiers
    ) else {
        throw WatcherError.interaction("Input field was not owned by a recognized WorkSpaces window")
    }

    try focus(node)
    Thread.sleep(forTimeInterval: 0.1)
    try assertFocusedInputTarget(
        node,
        expectedKind: expectedKind,
        processIdentifier: processIdentifier
    )
    return processIdentifier
}

private func postKey(
    keyCode: CGKeyCode,
    flags: CGEventFlags = [],
    to processIdentifier: pid_t
) throws {
    guard let source = CGEventSource(stateID: .privateState) else {
        throw WatcherError.interaction("Could not create a keyboard event source")
    }
    guard
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else {
        throw WatcherError.interaction("Could not create a keyboard event")
    }
    down.flags = flags
    down.postToPid(processIdentifier)
    up.flags = flags
    up.postToPid(processIdentifier)
}

private func unicodeEventChunks(_ text: String) -> [[UniChar]] {
    let units = Array(text.utf16)
    var chunks: [[UniChar]] = []
    var start = 0

    while start < units.count {
        var end = min(start + maximumUnicodeUnitsPerEvent, units.count)
        if end < units.count,
           end > start,
           (0xD800...0xDBFF).contains(units[end - 1]),
           (0xDC00...0xDFFF).contains(units[end]) {
            end -= 1
        }
        chunks.append(Array(units[start..<end]))
        start = end
    }
    return chunks
}

private func postTextChunk(_ characters: [UniChar], to processIdentifier: pid_t) throws {
    guard !characters.isEmpty else { return }
    guard let source = CGEventSource(stateID: .privateState) else {
        throw WatcherError.interaction("Could not create a text event source")
    }
    guard
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    else {
        throw WatcherError.interaction("Could not create a text event")
    }
    characters.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: buffer.baseAddress!)
    }
    down.flags = []
    down.postToPid(processIdentifier)
    up.flags = []
    up.postToPid(processIdentifier)
}

private func replaceText(
    _ text: String,
    in field: AccessibilityNode,
    expectedKind: InputFieldKind
) throws {
    let processIdentifier = try prepareInputTarget(field, expectedKind: expectedKind)
    try postKey(keyCode: 0, flags: .maskCommand, to: processIdentifier) // Command-A
    try assertFocusedInputTarget(
        field,
        expectedKind: expectedKind,
        processIdentifier: processIdentifier
    )
    try postKey(keyCode: 51, to: processIdentifier) // Delete
    try assertFocusedInputTarget(
        field,
        expectedKind: expectedKind,
        processIdentifier: processIdentifier
    )
    for chunk in unicodeEventChunks(text) {
        try assertFocusedInputTarget(
            field,
            expectedKind: expectedKind,
            processIdentifier: processIdentifier
        )
        try postTextChunk(chunk, to: processIdentifier)
    }
    Thread.sleep(forTimeInterval: 0.2)
    try assertFocusedInputTarget(
        field,
        expectedKind: expectedKind,
        processIdentifier: processIdentifier
    )

    let resultingValue = stringAttribute(field.element, kAXValueAttribute)
    switch expectedKind {
    case .username:
        guard resultingValue == text else {
            throw WatcherError.interaction("WorkSpaces username field did not accept the targeted input")
        }
    case .password:
        // Secure fields expose only a masked value, and mask-length semantics vary by framework.
        // Target, focus, and nonempty checks are portable; WorkSpaces validates the credential.
        guard !resultingValue.isEmpty else {
            throw WatcherError.interaction("WorkSpaces password field did not accept the targeted input")
        }
    }
}

private func typeUsername(_ username: String, into field: AccessibilityNode) throws {
    try replaceText(username, in: field, expectedKind: .username)
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

private func typePassword(_ password: String, into field: AccessibilityNode) throws {
    try replaceText(password, in: field, expectedKind: .password)
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
    try typePassword(credentials.password, into: field)

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
        guard let next = waitForSnapshot(timeout: 12, matching: [.username, .password, .starting, .credentialError]) else {
            return snapshot().state
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
    var parsedRequirement: SecRequirement?
    precondition(SecRequirementCreateWithString(
        workSpacesDesignatedRequirement as CFString,
        SecCSFlags(rawValue: 0),
        &parsedRequirement
    ) == errSecSuccess)
    precondition(parsedRequirement != nil)

    let active = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXWindowRole, subrole: "",
        title: "Amazon WorkSpaces", description: "SessionWindow", value: "", enabled: true
    )
    precondition(active.searchableText.contains("sessionwindow"))
    precondition(classify([active], windows: []) == .activeSession)
    let disconnected = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXStaticTextRole, subrole: "",
        title: "Disconnected", description: "", value: "", enabled: true
    )
    let reconnect = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXButtonRole, subrole: "",
        title: "Reconnect", description: "", value: "", enabled: true
    )
    let largeWindow = WorkSpacesWindow(processIdentifier: 42, width: 1_600, height: 1_200)
    precondition(classify([disconnected, reconnect], windows: [largeWindow]) == .disconnected)

    let secure = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXTextFieldRole,
        subrole: kAXSecureTextFieldSubrole, title: "", description: "Password", value: "", enabled: true
    )
    precondition(secure.isPasswordField)
    precondition(InputFieldKind.password.matches(secure))
    precondition(inputTargetIsAllowed(
        secure,
        expectedKind: .password,
        ownerProcessIdentifier: 42,
        ownerBundleIdentifier: workSpacesBundleIdentifier,
        signatureIsValid: true,
        workSpacesProcessIdentifiers: [42]
    ))
    precondition(!inputTargetIsAllowed(
        secure,
        expectedKind: .password,
        ownerProcessIdentifier: 7,
        ownerBundleIdentifier: workSpacesBundleIdentifier,
        signatureIsValid: true,
        workSpacesProcessIdentifiers: [42]
    ))
    precondition(!inputTargetIsAllowed(
        secure,
        expectedKind: .password,
        ownerProcessIdentifier: 42,
        ownerBundleIdentifier: "example.fake-workspaces",
        signatureIsValid: true,
        workSpacesProcessIdentifiers: [42]
    ))
    precondition(!inputTargetIsAllowed(
        secure,
        expectedKind: .password,
        ownerProcessIdentifier: 42,
        ownerBundleIdentifier: workSpacesBundleIdentifier,
        signatureIsValid: false,
        workSpacesProcessIdentifiers: [42]
    ))

    let secureProxy = AccessibilityNode(
        element: AXUIElementCreateApplication(42), role: kAXTextFieldRole,
        subrole: kAXSecureTextFieldSubrole, title: "", description: "Password", value: "", enabled: true
    )
    precondition(focusedInputTargetIsAllowed(
        secureProxy,
        expectedKind: .password,
        expectedProcessIdentifier: 42,
        focusedProcessIdentifier: 42,
        focusedOwnerBundleIdentifier: workSpacesBundleIdentifier,
        signatureIsValid: true,
        workSpacesProcessIdentifiers: [42]
    ))
    precondition(!focusedInputTargetIsAllowed(
        secureProxy,
        expectedKind: .password,
        expectedProcessIdentifier: 42,
        focusedProcessIdentifier: 7,
        focusedOwnerBundleIdentifier: workSpacesBundleIdentifier,
        signatureIsValid: true,
        workSpacesProcessIdentifiers: [7]
    ))

    let usernameField = AccessibilityNode(
        element: AXUIElementCreateSystemWide(), role: kAXTextFieldRole,
        subrole: "", title: "", description: "Username", value: "example-user", enabled: true
    )
    precondition(usernameField.isUsernameField)
    precondition(InputFieldKind.username.matches(usernameField))
    precondition(!InputFieldKind.password.matches(usernameField))
    precondition(normalizedDiagnosticText(usernameField) == "<editable field redacted>")
    precondition(!focusedInputTargetIsAllowed(
        usernameField,
        expectedKind: .password,
        expectedProcessIdentifier: 42,
        focusedProcessIdentifier: 42,
        focusedOwnerBundleIdentifier: workSpacesBundleIdentifier,
        signatureIsValid: true,
        workSpacesProcessIdentifiers: [42]
    ))

    let longText = String(repeating: "a", count: maximumUnicodeUnitsPerEvent + 1)
    let longTextChunks = unicodeEventChunks(longText)
    precondition(longTextChunks.map(\.count) == [maximumUnicodeUnitsPerEvent, 1])
    precondition(longTextChunks.flatMap { $0 } == Array(longText.utf16))

    let surrogateBoundaryText = String(repeating: "a", count: maximumUnicodeUnitsPerEvent - 1)
        + "😀z"
    let surrogateBoundaryChunks = unicodeEventChunks(surrogateBoundaryText)
    precondition(surrogateBoundaryChunks.map(\.count) == [maximumUnicodeUnitsPerEvent - 1, 3])
    precondition(surrogateBoundaryChunks.flatMap { $0 } == Array(surrogateBoundaryText.utf16))
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
