import CoreServices
import Foundation

/// Surveille des dossiers (récursif) via FSEvents et appelle `onChange` quand quelque chose bouge.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, existing as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
