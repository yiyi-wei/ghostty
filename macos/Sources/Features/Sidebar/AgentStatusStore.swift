import Foundation
import Combine

/// Reads agent state that pi (via the `pi-term-status` extension) publishes per terminal.
///
/// Contract, one file per controlling tty:
///   ~/.local/state/pi-term-status/<tty basename>.json   e.g. ttys003.json
///   { "status": "working" | "waiting" | "done", "ts": <unix ms>, "pid": <pi pid> }
///
/// The tty is the join key because Ghostty already exposes it per surface
/// (`Ghostty.Surface.ttyName`) and pi can read its own controlling terminal, so neither
/// side needs a new identifier plumbed through the Zig core. pi writes atomically
/// (tmp + rename) and deletes the file on shutdown; a stale file whose pid is gone is ignored.
final class AgentStatusStore: ObservableObject {
    static let shared = AgentStatusStore()

    struct Entry: Equatable {
        let status: AgentStatus
        let changedAt: Date
    }

    /// Keyed by tty basename (`ttys003`).
    @Published private(set) var entries: [String: Entry] = [:]

    let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/pi-term-status", isDirectory: true)

    private var dirSource: DispatchSourceFileSystemObject?
    private var timer: Timer?

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watchDirectory()
        // Directory events cover create/rename/delete; the timer catches a pi that died
        // without cleaning up (pid check) and any event the vnode watch coalesced away.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    static func key(forTTY tty: String?) -> String? {
        guard let tty, !tty.isEmpty else { return nil }
        return (tty as NSString).lastPathComponent
    }

    private func watchDirectory() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    private func reload() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        var next: [String: Entry] = [:]
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = obj["status"] as? String,
                  let status = AgentStatus(wire: raw)
            else { continue }
            if let pid = obj["pid"] as? Int, pid > 0, kill(pid_t(pid), 0) != 0, errno == ESRCH {
                continue
            }
            let ms = (obj["ts"] as? Double) ?? 0
            next[String(name.dropLast(5))] = Entry(status: status, changedAt: Date(timeIntervalSince1970: ms / 1000))
        }
        if next != entries { entries = next }
    }
}

extension AgentStatus {
    init?(wire: String) {
        switch wire {
        case "working": self = .working
        case "waiting": self = .waiting
        case "done": self = .done
        default: return nil
        }
    }
}
