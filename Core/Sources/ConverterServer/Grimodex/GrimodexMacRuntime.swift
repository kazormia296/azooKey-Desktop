import Core
import Foundation

/// Process-wide owner of the live Grimodex snapshot and consumer handshake.
///
/// ConverterServer should retain `processGlobal()` for its complete lifetime;
/// individual XPC sessions only borrow `snapshotManager` from this runtime.
final class GrimodexMacRuntime: @unchecked Sendable {
    private static let processRuntime = GrimodexMacRuntime()

    let snapshotManager: GrimodexSnapshotManager

    private let watcher: GrimodexDirectoryWatcher
    private let registrar: GrimodexConsumerRegistrar
    private let lifecycleLock = NSLock()
    private var started = false

    static func processGlobal() -> GrimodexMacRuntime {
        processRuntime
    }

    static func isProcessE2E(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["GRIMODEX_PROCESS_E2E"] == "1"
    }

    init(
        rootURL: URL = GrimodexPathResolver.resolve(),
        version: String = GrimodexMacRuntime.defaultVersion,
        watcherDebounceInterval: TimeInterval = 0.1,
        watcherRetryInterval: TimeInterval = 0.1,
        watcherMaxRearmAttempts: Int = 5,
        watcherBeforeReconcile: @escaping @Sendable () throws -> Void = {},
        consumerHeartbeatInterval: TimeInterval = GrimodexConsumerRegistrar.heartbeatInterval
    ) {
        let manager = GrimodexSnapshotManager(
            loader: GrimodexSnapshotLoader(rootURL: rootURL)
        )
        snapshotManager = manager
        watcher = GrimodexDirectoryWatcher(
            rootURL: rootURL,
            debounceInterval: watcherDebounceInterval,
            retryInterval: watcherRetryInterval,
            maxRearmAttempts: watcherMaxRearmAttempts,
            beforeReconcile: watcherBeforeReconcile
        ) {
            let snapshot = manager.reload()
            Self.publishProcessE2ESnapshot(snapshot)
            return snapshot.diagnostic.isRetryable
        }
        registrar = GrimodexConsumerRegistrar(
            rootURL: rootURL,
            version: version,
            heartbeatInterval: consumerHeartbeatInterval
        )
    }

    deinit {
        stop()
    }

    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !started else {
            return
        }

        do {
            try registrar.start()
            try watcher.start()
            started = true
        } catch {
            watcher.stop()
            registrar.stop()
            do {
                try registrar.unregister()
            } catch let unregisterError {
                NSLog(
                    "Failed to remove unusable Grimodex consumer handshake: \(unregisterError)"
                )
            }
            throw error
        }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard started else {
            return
        }
        started = false

        registrar.stop()
        watcher.stop()
    }

    static var defaultVersion: String {
        if let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
           !version.isEmpty {
            return version
        }
        if let tag = PackageMetadata.gitTag, !tag.isEmpty {
            return tag
        }
        if let commit = PackageMetadata.gitCommit, !commit.isEmpty {
            return commit
        }
        return "development"
    }

    private static func publishProcessE2ESnapshot(
        _ snapshot: GrimodexPublishedSnapshot,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard environment["GRIMODEX_PROCESS_E2E"] == "1",
              let path = environment["GRIMODEX_PROCESS_E2E_READY"],
              !path.isEmpty else {
            return
        }
        let payload = snapshot.payload
        let fields = [
            String(snapshot.generation),
            payload?.projectID ?? "",
            payload?.dictionaryEntries.first?.word ?? "",
            payload?.conditions.topic ?? "",
        ].map {
            $0.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        do {
            try Data((fields.joined(separator: "\t") + "\n").utf8).write(
                to: URL(fileURLWithPath: path),
                options: .atomic
            )
        } catch {
            NSLog("Failed to publish Grimodex process E2E snapshot: \(error)")
        }
    }
}
