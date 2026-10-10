import Foundation
import CoreServices

/// Watches Claude Code's session transcripts (`~/.claude/projects/**/*.jsonl`).
/// Every API response appends a line there, so a change means "usage just happened".
/// The stream is rooted at `~/.claude` so it also works when `projects/` is created later.
final class SessionLogWatcher {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static func isSessionLog(_ path: String) -> Bool {
        path.hasSuffix(".jsonl") && path.contains("/projects/")
    }

    private let directory: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "jp.ymzkmct.Claudemeter.SessionLogWatcher")
    private var stream: FSEventStreamRef?

    init(directory: URL = SessionLogWatcher.defaultDirectory, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    deinit { stop() }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info, numEvents > 0 else { return }
            let watcher = Unmanaged<SessionLogWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            if paths.contains(where: SessionLogWatcher.isSessionLog) {
                watcher.onChange()
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
