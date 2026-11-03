import AppKit
import SwiftUI
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement

// MARK: - Global hotkeys (Carbon: no Accessibility permission needed)

final class HotKeys {
    static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    fileprivate var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(id: UInt32, keyCode: Int, mods: Int, action: @escaping () -> Void) -> Bool {
        install()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(mods), EventHotKeyID(signature: OSType(0x4252_4641), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }
}

// MARK: - Pasting at the cursor

enum Paster {
    /// Electron apps (Claude, Slack) and Chromium only expose text fields to
    /// Accessibility after being asked. Call when recording starts.
    static func prepareFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Chromium browsers ignore the Electron flag and need this one instead.
        if chromium.contains(app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Spaces to add around the insertion so it doesn't glue onto neighbouring words.
    /// Uses Accessibility to read the characters around the cursor; nil when the app doesn't say.
    static func spacing() -> (lead: Bool, trail: Bool)? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        let element = el as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }

        var value: NSString?
        func char(at i: Int) -> Unicode.Scalar? {
            guard i >= 0 else { return nil }
            var r = CFRange(location: i, length: 1)
            if let rangeValue = AXValueCreate(.cfRange, &r) {
                var s: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                              rangeValue, &s) == .success, let str = s as? String, !str.isEmpty {
                    return str.unicodeScalars.first
                }
            }
            if value == nil {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &v) == .success { value = (v as? String) as NSString? }
            }
            guard let ns = value, i < ns.length else { return nil }
            return ns.substring(with: NSRange(location: i, length: 1)).unicodeScalars.first
        }

        let blank = CharacterSet.whitespacesAndNewlines
        let before = char(at: range.location - 1)
        let after = char(at: range.location + range.length)
        let lead = before.map { !blank.contains($0) && !"([{\"'“".unicodeScalars.contains($0) } ?? false
        let trail = after.map { !blank.contains($0) && !".,;:!?)]}\"'”".unicodeScalars.contains($0) } ?? false
        return (lead, trail)
    }

    // MARK: Finding the window's text box when nothing is focused

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func focusedElement() -> AXUIElement? {
        guard let el = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return (el as! AXUIElement)
    }

    /// Text areas, text fields and web contenteditable boxes (Chromium/WebKit report those as
    /// their own editable ancestor).
    private static func isTextInput(_ el: AXUIElement) -> Bool {
        let role = attr(el, kAXRoleAttribute) as? String ?? ""
        if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) {
            // Read-only text (e.g. Finder file-name labels) reports the same roles but can't be set.
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        }
        if role == kAXGroupRole, let root = attr(el, "AXEditableAncestor"), CFGetTypeID(root) == AXUIElementGetTypeID() {
            return CFEqual(root, el)
        }
        return false
    }

    /// Visible editable boxes in a window, skipping toolbars (browser address bars) and search fields.
    private static func textInputs(in window: AXUIElement) -> [(element: AXUIElement, frame: CGRect)] {
        let bounds = frame(window) ?? .infinite
        var out: [(AXUIElement, CGRect)] = []
        var queue = [window], next = 0
        let deadline = Date().addingTimeInterval(0.8) // big web pages: stay responsive
        while next < queue.count, next < 5000, Date() < deadline {
            let el = queue[next]; next += 1
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            // Toolbars hold address bars; lists, tables and outlines hold rename fields (Finder),
            // never a message box.
            if [kAXToolbarRole, kAXMenuBarRole, kAXListRole, kAXTableRole, kAXOutlineRole, kAXBrowserRole, "AXGrid"].contains(role) { continue }
            if isTextInput(el) {
                if attr(el, kAXSubroleAttribute) as? String != kAXSearchFieldSubrole,
                   let f = frame(el), f.width > 20, f.height > 10, bounds.intersects(f) {
                    out.append((el, f))
                }
                continue
            }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return out
    }

    /// When no text box has focus, focuses the bottom-most one in the front window (where chat apps
    /// put the message box) with the cursor at the end. False if there is none.
    private static func focusWindowTextBox() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let w = attr(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              CFGetTypeID(w) == AXUIElementGetTypeID() else { return false }
        let inputs = textInputs(in: w as! AXUIElement)
        guard let best = inputs.max(by: { ($0.frame.maxY, $0.frame.width) < ($1.frame.maxY, $1.frame.width) }) else { return false }
        log("auto-focus: \(inputs.count) text boxes, picked \(attr(best.element, kAXRoleAttribute) as? String ?? "?")")

        AXUIElementSetAttributeValue(best.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(150_000)
        if !(focusedElement().map(isTextInput) ?? false), isInWebContent(best.element) {
            // Some web views ignore AX focus; click the box instead and put the pointer back.
            // Never in native apps, where a click could select or rename things.
            click(CGPoint(x: best.frame.midX, y: best.frame.midY))
            usleep(150_000)
        }
        guard focusedElement().map(isTextInput) ?? false else { return false }
        key(kVK_DownArrow, .maskCommand) // cursor to the end, after any existing text
        usleep(50_000)
        return true
    }

    private static func isInWebContent(_ el: AXUIElement) -> Bool {
        var current: AXUIElement? = el
        for _ in 0..<60 {
            guard let e = current else { return false }
            if attr(e, kAXRoleAttribute) as? String == "AXWebArea" { return true }
            current = attr(e, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        return false
    }

    private static func click(_ point: CGPoint) {
        let back = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if let back { CGWarpMouseCursorPosition(back) }
    }

    private static func key(_ code: Int, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    enum Result { case pasted, noPermission, noTextBox }

    /// Inserts text at the cursor of the focused app via ⌘V, then restores the clipboard. With no
    /// text box focused, it focuses the window's message box first. On failure the text is left
    /// on the clipboard.
    static func paste(_ text: String) -> Result {
        let pb = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return .noPermission
        }
        if !(focusedElement().map(isTextInput) ?? false) {
            // Chromium builds its accessibility tree lazily after prepareFrontmostApp(); retry once.
            if !focusWindowTextBox() {
                usleep(300_000)
                if !focusWindowTextBox() {
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    return .noTextBox
                }
            }
        }
        // Chromium builds its accessibility tree lazily after prepareFrontmostApp(); give it a moment.
        var around = spacing()
        if around == nil { usleep(300_000); around = spacing() }
        let space = around ?? (false, false)
        let insert = (space.lead ? " " : "") + text + (space.trail ? " " : "")

        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(insert, forType: .string)
        // Tells clipboard managers not to record this temporary entry.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = pb.changeCount

        key(kVK_ANSI_V, .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == ours else { return } // user copied something meanwhile
            pb.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, d) in pairs { item.setData(d, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        return .pasted
    }
}

// MARK: - Sounds

enum Sounds {
    static func play(_ name: String) {
        guard Settings.soundsOn else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func error() { play("Basso") }
}

// MARK: - Floating status pill

enum PillState: Equatable {
    case hidden, listening, working
    case message(String, error: Bool)
}

final class PillModel: ObservableObject {
    @Published var state: PillState = .hidden
    @Published var level: Float = 0
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .listening:
                Circle().fill(Color.red).frame(width: 8, height: 8)
                LevelBars(level: model.level)
                Text("Listening…")
            case .working:
                ProgressView().controlSize(.small)
                Text("Translating…")
            case .message(let text, let error):
                Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(error ? Color.yellow : Color.green)
                Text(text).lineLimit(2)
            case .hidden:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

struct LevelBars: View {
    var level: Float
    private let weights: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<weights.count, id: \.self) { i in
                Capsule().fill(Color.white)
                    .frame(width: 3, height: CGFloat(4 + 14 * min(1, level * weights[i] * 1.3)))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

final class Pill {
    let model = PillModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PillView(model: model))
    }

    func show(_ state: PillState, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        model.state = state
        if state == .hidden { panel.orderOut(nil); return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.maxY - panel.frame.height - 6))
        }
        panel.orderFrontRegardless()
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }
}

// MARK: - Settings window

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { log("login item: \(error)") }
    }
}

struct SettingsView: View {
    var onHotkeyChange: () -> Void
    @State private var label = Settings.hotkeyLabel
    @State private var recording = false
    @State private var monitor: Any?
    @State private var silence = Settings.silenceSeconds
    @State private var sounds = Settings.soundsOn
    @State private var model = Settings.model
    @State private var login = LoginItem.enabled
    @State private var key = ""
    @State private var keySaved = Keychain.groqKey != nil

    var body: some View {
        Form {
            Section {
                SecureField("Groq API key", text: $key, prompt: Text(keySaved ? "Saved in Keychain" : "gsk_…"))
                    .onSubmit(saveKey)
                HStack {
                    Link("Get a free key at console.groq.com/keys", destination: URL(string: "https://console.groq.com/keys")!)
                        .font(.caption)
                    Spacer()
                    Button("Save", action: saveKey).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            LabeledContent("Shortcut") {
                Button(recording ? "Press new shortcut…" : label) { recording ? stopRecording() : startRecording() }
                    .frame(minWidth: 160)
            }
            LabeledContent("Stop after silence") {
                HStack {
                    Slider(value: $silence, in: 1.5...10, step: 0.5).frame(width: 160)
                    Text(String(format: "%.1f s", silence)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            .onChange(of: silence) { _, v in Settings.silenceSeconds = v }
            Toggle("Sound cues", isOn: $sounds).onChange(of: sounds) { _, v in Settings.soundsOn = v }
            Toggle("Launch at login", isOn: $login).onChange(of: login) { _, v in LoginItem.set(v) }
            TextField("Translation model", text: $model)
                .onChange(of: model) { _, v in
                    let t = v.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { Settings.model = t }
                }
        }
        .formStyle(.grouped)
        // A grouped Form has no natural height; without one the window collapses to nothing.
        .frame(width: 460, height: 400)
        .onDisappear { stopRecording() }
    }

    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        Keychain.setGroqKey(k)
        key = ""
        keySaved = true
    }

    private func startRecording() {
        recording = true
        HotKeys.shared.unregister(id: 1)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stopRecording(); return nil }
            let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            var mods = 0
            if flags.contains(.command) { mods |= cmdKey }
            if flags.contains(.option) { mods |= optionKey }
            if flags.contains(.control) { mods |= controlKey }
            if flags.contains(.shift) { mods |= shiftKey }
            Settings.hotkeyCode = Int(e.keyCode)
            Settings.hotkeyMods = mods
            Settings.hotkeyLabel = Self.describe(flags: flags, event: e)
            label = Settings.hotkeyLabel
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; onHotkeyChange() }
    }

    static func describe(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        return s + (named[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased())
    }
}

final class SettingsWindow {
    private var window: NSWindow?

    func show(onHotkeyChange: @escaping () -> Void) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(onHotkeyChange: onHotkeyChange)))
            w.title = "Voci Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.center()
            window = w
        }
        // Menu-bar-only apps are never frontmost on their own; force it.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
