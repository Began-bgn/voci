import AppKit
import AVFoundation
import Carbon.HIToolbox

// MARK: - Controller: hotkey → record → transcribe → translate → paste

@MainActor
final class Controller {
    enum Phase { case idle, listening, working }

    private(set) var phase = Phase.idle { didSet { onPhase?(phase) } }
    var onPhase: ((Phase) -> Void)?

    let pill = Pill()
    private let recorder = Recorder()
    private var job: Task<Void, Never>?
    private var generation = 0

    static let toggleID: UInt32 = 1
    static let escapeID: UInt32 = 2

    init() {
        recorder.onLevel = { [weak self] level in self?.pill.model.level = level }
        recorder.onAutoStop = { [weak self] in
            guard let self, self.phase == .listening else { return }
            self.finish()
        }
    }

    func registerHotkey() {
        let ok = HotKeys.shared.register(id: Self.toggleID, keyCode: Settings.hotkeyCode, mods: Settings.hotkeyMods) { [weak self] in
            self?.toggle()
        }
        if !ok { fail("Shortcut \(Settings.hotkeyLabel) is used by another app — change it in Settings") }
    }

    func toggle() {
        switch phase {
        case .idle: start()
        case .listening: finish()
        case .working: break // ignore repeat presses while translating
        }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { if granted { self.start() } }
            }
            return
        case .authorized: break
        default:
            fail("Microphone access is off — System Settings › Privacy & Security › Microphone")
            return
        }
        Paster.prepareFrontmostApp()
        do { try recorder.start() } catch {
            fail(error.localizedDescription)
            return
        }
        phase = .listening
        log("listening")
        Sounds.start()
        pill.model.level = 0
        pill.show(.listening)
        HotKeys.shared.register(id: Self.escapeID, keyCode: kVK_Escape, mods: 0) { [weak self] in self?.cancel() }
    }

    private func finish() {
        let samples = recorder.stop()
        let speech = recorder.speechDuration
        Sounds.stop()
        log("stopped: \(String(format: "%.1f", Double(samples.count) / Recorder.sampleRate))s audio, \(String(format: "%.1f", speech))s speech")
        guard speech >= 0.5 else { reset(); return } // nothing said: discard silently
        process(samples)
    }

    /// Test hook: runs an audio file through the same path as a recording.
    func inject(file path: String) {
        guard phase == .idle, let samples = try? loadAudio(path) else { log("inject skipped"); return }
        Paster.prepareFrontmostApp()
        process(samples)
    }

    /// The last recording that failed to process, kept so no speech is lost.
    static var failedFile: URL { Settings.supportDir.appendingPathComponent("failed-recording.wav") }
    static var hasFailedRecording: Bool { FileManager.default.fileExists(atPath: failedFile.path) }

    func retryFailed() {
        guard phase == .idle, let samples = try? loadAudio(Self.failedFile.path) else { return }
        log("retry")
        process(samples)
    }

    private func process(_ samples: [Float]) {
        HotKeys.shared.register(id: Self.escapeID, keyCode: kVK_Escape, mods: 0) { [weak self] in self?.cancel() }
        phase = .working
        pill.show(.working)
        generation += 1
        let gen = generation

        job = Task { [weak self] in
            var romanian: String?
            do {
                let ro = try await Groq.transcribe(samples)
                romanian = ro
                guard let self, gen == self.generation else { return }
                log("transcribed \(ro.count) chars")
                guard !ro.isEmpty else { self.reset(); return }

                let english = try await Groq.translateWithFallback(ro)
                guard gen == self.generation else { return }
                History.add(HistoryEntry(date: Date(), romanian: ro, english: english))
                try? FileManager.default.removeItem(at: Self.failedFile)
                let result = Paster.paste(english)
                log("translated \(english.count) chars, pasted=\(result == .pasted)")
                switch result {
                case .pasted: self.reset()
                case .noPermission:
                    self.fail("Allow Voci in System Settings › Privacy & Security › Accessibility. Text copied to clipboard.")
                    self.reset(keepPill: true)
                case .noTextBox:
                    self.fail("No text box in this window — English copied to clipboard")
                    self.reset(keepPill: true)
                }
            } catch {
                guard let self, gen == self.generation else { return }
                try? Groq.wav(samples).write(to: Self.failedFile, options: .atomic)
                if let ro = romanian { History.add(HistoryEntry(date: Date(), romanian: ro, english: nil)) }
                self.fail(error.localizedDescription + " — use “Retry last recording” in the menu")
                self.reset(keepPill: true)
            }
        }
    }

    func cancel() {
        switch phase {
        case .idle: return
        case .listening: recorder.stop()
        case .working: generation += 1; job?.cancel()
        }
        log("cancelled")
        reset()
    }

    private func reset(keepPill: Bool = false) {
        HotKeys.shared.unregister(id: Self.escapeID)
        job = nil
        phase = .idle
        if !keepPill { pill.show(.hidden) }
    }

    func fail(_ message: String) {
        log("error: \(message)")
        Sounds.error()
        pill.show(.message(message, error: true), autoHide: 5)
    }
}

// MARK: - Menu bar

final class MenuAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private let settings = SettingsWindow()
    private var status: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(.idle)
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        controller.onPhase = { [weak self] in self?.setIcon($0) }
        controller.registerHotkey()
        // Same as pressing the shortcut; lets Shortcuts or scripts (and tests) drive Voci.
        DistributedNotificationCenter.default().addObserver(forName: .init("app.voci.toggle"), object: nil, queue: .main) { [weak self] _ in
            log("toggle notification")
            MainActor.assumeIsolated { self?.controller.toggle() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("app.voci.retry"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.retryFailed() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("app.voci.settings"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.show { self?.controller.registerHotkey() } }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("app.voci.inject"), object: nil, queue: .main) { [weak self] note in
            guard let path = note.object as? String else { return }
            log("inject notification")
            MainActor.assumeIsolated { self?.controller.inject(file: path) }
        }

        if Keychain.groqKey == nil {
            settings.show { [weak self] in self?.controller.registerHotkey() }
        }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            LoginItem.set(true)
        }
    }

    private func setIcon(_ phase: Controller.Phase) {
        let name: String
        switch phase {
        case .idle: name = "waveform"
        case .listening: name = "mic.fill"
        case .working: name = "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Voci")
        image?.isTemplate = true
        status.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Voci — press \(Settings.hotkeyLabel) to talk", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        if Controller.hasFailedRecording {
            menu.addItem(MenuAction("Retry last recording") { [weak self] in self?.controller.retryFailed() })
        }

        let history = NSMenu()
        let entries = History.load()
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            history.addItem(empty)
        }
        for e in entries {
            let text = e.english ?? e.romanian
            let short = text.count > 60 ? String(text.prefix(60)) + "…" : text
            let item = NSMenuItem(title: (e.english == nil ? "⚠︎ " : "") + short, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if let en = e.english { sub.addItem(MenuAction("Copy English") { Self.copy(en) }) }
            sub.addItem(MenuAction("Copy Romanian") { Self.copy(e.romanian) })
            item.submenu = sub
            history.addItem(item)
        }
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = history
        menu.addItem(historyItem)

        let mics = NSMenu()
        mics.addItem(MenuAction("System Default", checked: Settings.micUID.isEmpty) { Settings.micUID = "" })
        mics.addItem(.separator())
        for d in AudioDevices.inputs() {
            mics.addItem(MenuAction(d.name, checked: Settings.micUID == d.uid) { Settings.micUID = d.uid })
        }
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = mics
        menu.addItem(micItem)

        menu.addItem(MenuAction("Sound Cues", checked: Settings.soundsOn) { Settings.soundsOn.toggle() })
        menu.addItem(MenuAction("Settings…", key: ",") { [weak self] in
            self?.settings.show { self?.controller.registerHotkey() }
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction("Quit Voci", key: "q") { NSApp.terminate(nil) })
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Command-line test modes

/// Reads any audio file as 16 kHz mono Float samples.
func loadAudio(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFormat = file.processingFormat
    let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recorder.sampleRate, channels: 1, interleaved: false)!
    guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)),
          let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return [] }
    try file.read(into: input)
    let cap = AVAudioFrameCount(Double(input.frameLength) * Recorder.sampleRate / inFormat.sampleRate) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return [] }
    var fed = false
    converter.convert(to: out, error: nil) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return input
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

func runCLI(_ args: [String]) async -> Int32 {
    func arg(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let model = arg("--model") ?? Settings.model
    do {
        if let text = arg("--translate") {
            let t0 = Date()
            print(try await Groq.translate(text, model: model))
            FileHandle.standardError.write("[\(String(format: "%.2f", Date().timeIntervalSince(t0)))s]\n".data(using: .utf8)!)
        } else if let path = arg("--transcribe") ?? arg("--pipeline") {
            let samples = try loadAudio(path)
            let t0 = Date()
            let ro = try await Groq.transcribe(samples)
            let t1 = Date()
            print("RO: \(ro)")
            var timing = String(format: "[stt %.2fs for %.1fs audio", t1.timeIntervalSince(t0), Double(samples.count) / Recorder.sampleRate)
            if args.contains("--pipeline"), !ro.isEmpty {
                print("EN: \(try await Groq.translate(ro, model: model))")
                timing += String(format: ", translate %.2fs", Date().timeIntervalSince(t1))
            }
            FileHandle.standardError.write((timing + "]\n").data(using: .utf8)!)
        } else if args.contains("--models") {
            print(try await Groq.models().joined(separator: "\n"))
        } else {
            print("usage: Voci [--transcribe file | --pipeline file | --translate text | --models] [--model name]")
            return 2
        }
        return 0
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        return 1
    }
}

// MARK: - Entry point

Settings.register()
let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.contains(where: { $0.hasPrefix("--") }) {
    let sem = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached { code = await runCLI(cliArgs); sem.signal() }
    sem.wait()
    exit(code)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
