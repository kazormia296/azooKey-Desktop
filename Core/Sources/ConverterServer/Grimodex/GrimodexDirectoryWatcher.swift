import Darwin
import Dispatch
import Foundation

enum GrimodexDirectoryWatcherError: Error, Equatable, Sendable {
    case noExistingAncestor(path: String)
    case openFailed(path: String, errno: Int32)
    case descriptorFailed(path: String, errno: Int32)
    case notDirectory(path: String)
    case pathChanged(path: String)
}

/// Watches the Grimodex snapshot directories without assuming that Grimodex
/// has created them before ConverterServer starts.
///
/// DispatchSource file-system sources follow a vnode, not a pathname.  Each
/// registration therefore records the vnode identity and reconciliation
/// replaces a source when an atomic directory rename puts a new vnode at the
/// same path.
final class GrimodexDirectoryWatcher: @unchecked Sendable {
    private enum Role: Hashable {
        case ancestor
        case root
        case projects
    }

    private struct Registration {
        let token: UUID
        let descriptor: Int32
        let path: String
        let expectedChild: String?
        let device: dev_t
        let inode: ino_t
        let source: DispatchSourceFileSystemObject
    }

    private static var eventMask: DispatchSource.FileSystemEvent {
        [.write, .delete, .rename, .attrib, .extend, .link, .revoke]
    }

    private static var invalidationMask: DispatchSource.FileSystemEvent {
        [.delete, .rename, .revoke]
    }

    private let rootURL: URL
    private let projectsURL: URL
    private let debounceInterval: TimeInterval
    private let retryInterval: TimeInterval
    /// Number of exponential-backoff steps before retries continue at the
    /// capped delay.  Rearming itself never gives up while the runtime lives.
    private let maxRearmBackoffStep: Int
    private let beforeReconcile: @Sendable () throws -> Void
    private let reload: @Sendable () -> Bool
    private let queue = DispatchQueue(
        label: "com.miyakey.grimodex.ime.macos.snapshot-watcher"
    )
    private let healthLock = NSLock()

    private var registrations: [Role: Registration] = [:]
    private var pendingReload: DispatchWorkItem?
    private var pendingRetry: DispatchWorkItem?
    private var pendingRearm: DispatchWorkItem?
    private var started = false
    private var active = false

    var isActive: Bool {
        healthLock.lock()
        defer { healthLock.unlock() }
        return active
    }

    init(
        rootURL: URL,
        debounceInterval: TimeInterval = 0.1,
        retryInterval: TimeInterval = 0.1,
        maxRearmAttempts: Int = 5,
        beforeReconcile: @escaping @Sendable () throws -> Void = {},
        reload: @escaping @Sendable () -> Bool
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.projectsURL = rootURL.standardizedFileURL
            .appendingPathComponent("projects", isDirectory: true)
        self.debounceInterval = max(0, debounceInterval)
        self.retryInterval = max(0, retryInterval)
        self.maxRearmBackoffStep = min(max(1, maxRearmAttempts), 9)
        self.beforeReconcile = beforeReconcile
        self.reload = reload
    }

    func start() throws {
        let result: Result<Void, Error> = queue.sync {
            Result { try startIsolated() }
        }
        try result.get()
    }

    func stop() {
        queue.sync {
            stopIsolated()
        }
    }

    private func startIsolated() throws {
        guard !started else {
            return
        }
        do {
            try reconcileWatches()
            started = true
            setActive(true)
            performReload(allowRetry: true)
        } catch {
            removeAllWatches()
            setActive(false)
            throw error
        }
    }

    private func stopIsolated() {
        guard started || !registrations.isEmpty else {
            return
        }
        started = false
        setActive(false)
        pendingReload?.cancel()
        pendingReload = nil
        pendingRetry?.cancel()
        pendingRetry = nil
        pendingRearm?.cancel()
        pendingRearm = nil
        removeAllWatches()
    }

    private func reconcileWatches() throws {
        try beforeReconcile()
        var transientError: GrimodexDirectoryWatcherError?
        for _ in 0..<2 {
            do {
                try reconcileOnce()
                return
            } catch let error as GrimodexDirectoryWatcherError {
                switch error {
                case .openFailed(_, let number)
                    where number == ENOENT || number == ENOTDIR:
                    transientError = error
                case .descriptorFailed(_, let number)
                    where number == ENOENT || number == ENOTDIR:
                    transientError = error
                case .pathChanged:
                    transientError = error
                default:
                    throw error
                }
            }
        }
        throw transientError
            ?? GrimodexDirectoryWatcherError.noExistingAncestor(path: rootURL.path)
    }

    private func reconcileOnce() throws {
        if isDirectory(rootURL) {
            removeWatch(for: .ancestor)
            try ensureWatch(for: .root, url: rootURL, expectedChild: nil)
            if isDirectory(projectsURL) {
                try ensureWatch(for: .projects, url: projectsURL, expectedChild: nil)
            } else {
                removeWatch(for: .projects)
            }
            return
        }

        removeWatch(for: .root)
        removeWatch(for: .projects)
        guard let (ancestor, expectedChild) = nearestExistingAncestor() else {
            throw GrimodexDirectoryWatcherError.noExistingAncestor(path: rootURL.path)
        }
        try ensureWatch(for: .ancestor, url: ancestor, expectedChild: expectedChild)
    }

    private func ensureWatch(for role: Role, url: URL, expectedChild: String?) throws {
        let path = url.path
        if let registration = registrations[role],
           registration.path == path,
           registration.expectedChild == expectedChild,
           registrationStillNamesCurrentDirectory(registration) {
            return
        }

        removeWatch(for: role)
        let descriptor = try openDirectory(at: url)
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            let number = errno
            _ = Darwin.close(descriptor)
            throw GrimodexDirectoryWatcherError.descriptorFailed(path: path, errno: number)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(descriptor)
            throw GrimodexDirectoryWatcherError.notDirectory(path: path)
        }

        let token = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: Self.eventMask,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleEvent(for: role, token: token)
        }
        source.setCancelHandler {
            _ = Darwin.close(descriptor)
        }
        let registration = Registration(
            token: token,
            descriptor: descriptor,
            path: path,
            expectedChild: expectedChild,
            device: info.st_dev,
            inode: info.st_ino,
            source: source
        )
        registrations[role] = registration
        source.resume()
        guard registrationStillNamesCurrentDirectory(registration) else {
            removeWatch(for: role)
            throw GrimodexDirectoryWatcherError.pathChanged(path: path)
        }
    }

    private func openDirectory(at url: URL) throws -> Int32 {
        while true {
            let descriptor = url.path.withCString {
                Darwin.open($0, O_EVTONLY | O_CLOEXEC)
            }
            if descriptor >= 0 {
                return descriptor
            }
            if errno == EINTR {
                continue
            }
            throw GrimodexDirectoryWatcherError.openFailed(path: url.path, errno: errno)
        }
    }

    private func registrationStillNamesCurrentDirectory(_ registration: Registration) -> Bool {
        var info = stat()
        let result = registration.path.withCString { path in
            Darwin.lstat(path, &info)
        }
        guard result == 0 else {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_dev == registration.device
            && info.st_ino == registration.inode
    }

    private func removeWatch(for role: Role) {
        registrations.removeValue(forKey: role)?.source.cancel()
    }

    private func removeAllWatches() {
        let current = Array(registrations.values)
        registrations.removeAll()
        for registration in current {
            registration.source.cancel()
        }
    }

    private func nearestExistingAncestor() -> (URL, String)? {
        var current = rootURL
        var missingComponents: [String] = []
        while true {
            if isDirectory(current) {
                guard let expectedChild = missingComponents.first else {
                    return nil
                }
                return (current, expectedChild)
            }
            let component = current.lastPathComponent
            guard !component.isEmpty else {
                return nil
            }
            missingComponents.insert(component, at: 0)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                return nil
            }
            current = parent
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        let result = url.path.withCString { path in
            Darwin.lstat(path, &info)
        }
        return result == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func handleEvent(for role: Role, token: UUID) {
        guard started,
              let registration = registrations[role],
              registration.token == token else {
            return
        }

        let events = registration.source.data
        if !events.isDisjoint(with: Self.invalidationMask) {
            removeWatch(for: role)
        }
        reconcileAfterEvent()
        scheduleReload()
    }

    private func reconcileAfterEvent() {
        pendingRearm?.cancel()
        pendingRearm = nil
        do {
            try reconcileWatches()
            setActive(true)
        } catch {
            setActive(false)
            NSLog("Failed to rearm Grimodex macOS snapshot watches: \(error)")
            scheduleRearm(attempt: 1)
        }
    }

    private func scheduleRearm(attempt: Int) {
        guard started else {
            return
        }
        pendingRearm?.cancel()
        let backoffStep = min(max(1, attempt), maxRearmBackoffStep)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.started else {
                return
            }
            self.pendingRearm = nil
            do {
                try self.reconcileWatches()
                self.setActive(true)
                self.scheduleReload()
            } catch {
                self.setActive(false)
                NSLog("Failed to rearm Grimodex macOS snapshot watches: \(error)")
                self.scheduleRearm(
                    attempt: min(backoffStep + 1, self.maxRearmBackoffStep)
                )
            }
        }
        pendingRearm = item
        let multiplier = Double(1 << (backoffStep - 1))
        queue.asyncAfter(
            deadline: .now() + max(0.05, retryInterval * multiplier),
            execute: item
        )
    }

    private func scheduleReload() {
        pendingRetry?.cancel()
        pendingRetry = nil
        pendingReload?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.started else {
                return
            }
            self.pendingReload = nil
            self.performReload(allowRetry: true)
        }
        pendingReload = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func performReload(allowRetry: Bool) {
        let shouldRetry = reload()
        guard shouldRetry, allowRetry, started else {
            return
        }
        pendingRetry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.started else {
                return
            }
            self.pendingRetry = nil
            self.performReload(allowRetry: false)
        }
        pendingRetry = item
        queue.asyncAfter(deadline: .now() + retryInterval, execute: item)
    }

    private func setActive(_ value: Bool) {
        healthLock.lock()
        active = value
        healthLock.unlock()
    }
}
