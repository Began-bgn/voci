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
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// True when the character before the cursor is not whitespace. Unknown → false.
    static func needsLeadingSpace() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        let element = el as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range), range.location > 0 else { return false }

        var before: String?
        var prev = CFRange(location: range.location - 1, length: 1)
        if let prevValue = AXValueCreate(.cfRange, &prev) {
            var s: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          prevValue, &s) == .success {
                before = s as? String
            }
        }
        if before == nil {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &v) == .success, let str = v as? String {
                let ns = str as NSString
                if range.location <= ns.length { before = ns.substring(with: NSRange(location: range.location - 1, length: 1)) }
            }
        }
        guard let ch = before?.unicodeScalars.first else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(ch)
    }

    /// Inserts text at the cursor of the focused app via ⌘V, then restores the clipboard.
    /// Returns false (and leaves the text on the clipboard) without Accessibility permission.
    static func paste(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return false
        }
        let insert = (needsLeadingSpace() ? " " : "") + text

        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(insert, forType: .string)
        // Tells clipboard managers not to record this temporary entry.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

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
        return true
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
        catch { NSLog("Voci login item: \(error)") }
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

    var body: some View {
        Form {
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
        .frame(width: 420)
        .onDisappear { stopRecording() }
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
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
