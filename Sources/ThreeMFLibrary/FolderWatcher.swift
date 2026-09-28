import CoreServices
import Foundation

/// Watches whole folder trees (FSEvents) and calls `onChange` on the main queue when anything inside changes.
public final class FolderWatcher {
    private final class Handler {
        let callback: () -> Void
        init(_ callback: @escaping () -> Void) { self.callback = callback }
    }

    private var stream: FSEventStreamRef?

    public init?(paths: [String], latency: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        guard !paths.isEmpty else { return nil }
        let handler = Unmanaged.passRetained(Handler(onChange))
        var context = FSEventStreamContext(version: 0,
                                           info: handler.toOpaque(),
                                           retain: nil,
                                           release: { info in
                                               guard let info else { return }
                                               Unmanaged<Handler>.fromOpaque(info).release()
                                           },
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().callback()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else {
            handler.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
