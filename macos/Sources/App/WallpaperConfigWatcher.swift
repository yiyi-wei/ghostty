import Foundation

/// Watches the small config include written by ghostty-bg after the image is ready.
/// Watching only the image would miss format/path changes, `off`, and `tune`.
@MainActor
final class WallpaperConfigWatcher {
    private struct Stamp: Equatable {
        let fileNumber: NSNumber?
        let modified: Date?
        let size: NSNumber?
    }

    private let url: URL
    private let onChange: @MainActor () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingCheck: DispatchWorkItem?
    private var lastStamp: Stamp?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        self.lastStamp = Self.stamp(at: url)
        // Directory events catch creation, deletion and atomic replacement. The
        // file source catches in-place writes (including ghostty-bg's heredoc).
        self.directorySource = watch(url.deletingLastPathComponent(), events: [.write])
        self.fileSource = watchFile()
    }

    func stop() {
        pendingCheck?.cancel()
        directorySource?.cancel()
        fileSource?.cancel()
        pendingCheck = nil
        directorySource = nil
        fileSource = nil
    }

    private static func stamp(at url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return .init(
            fileNumber: attributes[.systemFileNumber] as? NSNumber,
            modified: attributes[.modificationDate] as? Date,
            size: attributes[.size] as? NSNumber)
    }

    private func watchFile() -> DispatchSourceFileSystemObject? {
        watch(url, events: [.write, .extend, .rename, .delete, .revoke])
    }

    private func watch(_ url: URL, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        pendingCheck?.cancel()
        // Coalesce truncate/write/rename events and let the writer finish the include.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func check() {
        pendingCheck = nil
        let next = Self.stamp(at: url)
        if next?.fileNumber != lastStamp?.fileNumber || (next != nil && fileSource == nil) {
            fileSource?.cancel()
            fileSource = watchFile()
        }
        guard next != lastStamp else { return }
        lastStamp = next
        onChange()
    }
}
