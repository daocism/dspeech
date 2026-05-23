import Foundation

protocol AudioSessionRouting: Sendable {
    var currentRouteSnapshot: RouteSnapshot { get }
    var availableInputSnapshots: [PortSnapshot] { get }
    var routeChanges: AsyncStream<RouteChangeEvent> { get }
    func requestRecordPermission() async -> Bool
    func setPreferredInput(uid: String) throws
}

final class FakeAudioSessionRouting: AudioSessionRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentRoute: RouteSnapshot
    private var _availableInputs: [PortSnapshot]
    private let _permissionGranted: Bool
    private var _preferredInputUIDs: [String] = []
    private var continuation: AsyncStream<RouteChangeEvent>.Continuation?
    let routeChanges: AsyncStream<RouteChangeEvent>

    init(
        currentRoute: RouteSnapshot = RouteSnapshot(),
        availableInputs: [PortSnapshot] = [],
        permissionGranted: Bool = true
    ) {
        self._currentRoute = currentRoute
        self._availableInputs = availableInputs
        self._permissionGranted = permissionGranted
        var localContinuation: AsyncStream<RouteChangeEvent>.Continuation!
        self.routeChanges = AsyncStream<RouteChangeEvent>(
            bufferingPolicy: .unbounded
        ) { continuation in
            localContinuation = continuation
        }
        self.continuation = localContinuation
    }

    var currentRouteSnapshot: RouteSnapshot {
        lock.lock(); defer { lock.unlock() }
        return _currentRoute
    }

    var availableInputSnapshots: [PortSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return _availableInputs
    }

    func requestRecordPermission() async -> Bool {
        _permissionGranted
    }

    func setPreferredInput(uid: String) throws {
        lock.lock(); defer { lock.unlock() }
        _preferredInputUIDs.append(uid)
    }

    func updateRoute(
        _ route: RouteSnapshot,
        availableInputs: [PortSnapshot]? = nil
    ) {
        lock.lock()
        _currentRoute = route
        if let availableInputs { _availableInputs = availableInputs }
        lock.unlock()
    }

    func emit(_ event: RouteChangeEvent) {
        continuation?.yield(event)
    }

    func finish() {
        continuation?.finish()
    }

    var preferredInputCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _preferredInputUIDs
    }
}
