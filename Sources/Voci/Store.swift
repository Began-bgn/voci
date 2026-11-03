import Foundation
import Carbon.HIToolbox

/// User settings, persisted in UserDefaults.
enum Settings {
    private static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            "hotkeyCode": kVK_Space,
            "hotkeyMods": controlKey | optionKey,
            "hotkeyLabel": "⌃⌥Space",
            "silenceSeconds": 3.0,
            "soundsOn": true,
            "micUID": "",
            "model": "qwen3:14b",
        ])
    }

    static var hotkeyCode: Int { get { d.integer(forKey: "hotkeyCode") } set { d.set(newValue, forKey: "hotkeyCode") } }
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    static var hotkeyMods: Int { get { d.integer(forKey: "hotkeyMods") } set { d.set(newValue, forKey: "hotkeyMods") } }
    static var hotkeyLabel: String { get { d.string(forKey: "hotkeyLabel") ?? "" } set { d.set(newValue, forKey: "hotkeyLabel") } }
    static var silenceSeconds: Double { get { d.double(forKey: "silenceSeconds") } set { d.set(newValue, forKey: "silenceSeconds") } }
    static var soundsOn: Bool { get { d.bool(forKey: "soundsOn") } set { d.set(newValue, forKey: "soundsOn") } }
    /// Empty string means the system default input.
    static var micUID: String { get { d.string(forKey: "micUID") ?? "" } set { d.set(newValue, forKey: "micUID") } }
    static var model: String { get { d.string(forKey: "model") ?? "qwen3:14b" } set { d.set(newValue, forKey: "model") } }

    static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voci", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct HistoryEntry: Codable {
    var date: Date
    var romanian: String
    var english: String?
}

/// Last 20 sessions, stored only on this Mac.
enum History {
    static let limit = 20
    private static var file: URL { Settings.supportDir.appendingPathComponent("history.json") }

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([HistoryEntry].self, from: data)) ?? []
    }

    static func add(_ entry: HistoryEntry) {
        let all = Array(([entry] + load()).prefix(limit))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(all) { try? data.write(to: file, options: .atomic) }
    }
}
