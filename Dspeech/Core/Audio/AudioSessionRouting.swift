import Foundation

protocol AudioSessionRouting: Sendable {
  var routePreparationStatus: AudioRoutePreparationStatus { get }
  var currentRouteSnapshot: RouteSnapshot { get }
  var availableInputSnapshots: [PortSnapshot] { get }
  var routeChanges: AsyncStream<RouteChangeEvent> { get }
  func requestRecordPermission() async -> Bool
  func setPreferredInput(uid: String) throws
}

enum AudioRoutePreparationStatus: Equatable, Sendable {
  case ready
  case failed(AudioRoutePreparationFailure)

  var failure: AudioRoutePreparationFailure? {
    if case .failed(let failure) = self { return failure }
    return nil
  }
}

enum AudioRoutePreparationFailure: Equatable, Sendable {
  case recordCategoryUnavailable(String)

  var userFacingMessage: String {
    switch self {
    case .recordCategoryUnavailable(let reason):
      return "Не удалось подготовить аудиовход для записи: \(reason)"
    }
  }
}

enum FakeAudioSessionRoutingError: Error, Equatable {
  case rejectedPreferredInput(String)
}

final class FakeAudioSessionRouting: AudioSessionRouting, @unchecked Sendable {
  private let lock = NSLock()
  private var _routePreparationStatus: AudioRoutePreparationStatus
  private var _currentRoute: RouteSnapshot
  private var _availableInputs: [PortSnapshot]
  private let _permissionGranted: Bool
  private let _rejectedPreferredInputUIDs: Set<String>
  private var _preferredInputUIDs: [String] = []
  private var continuation: AsyncStream<RouteChangeEvent>.Continuation?
  let routeChanges: AsyncStream<RouteChangeEvent>

  init(
    routePreparationStatus: AudioRoutePreparationStatus = .ready,
    currentRoute: RouteSnapshot = RouteSnapshot(),
    availableInputs: [PortSnapshot] = [],
    permissionGranted: Bool = true,
    rejectedPreferredInputUIDs: Set<String> = []
  ) {
    self._routePreparationStatus = routePreparationStatus
    self._currentRoute = currentRoute
    self._availableInputs = availableInputs
    self._permissionGranted = permissionGranted
    self._rejectedPreferredInputUIDs = rejectedPreferredInputUIDs
    var localContinuation: AsyncStream<RouteChangeEvent>.Continuation!
    self.routeChanges = AsyncStream<RouteChangeEvent>(
      bufferingPolicy: .unbounded
    ) { continuation in
      localContinuation = continuation
    }
    self.continuation = localContinuation
  }

  var routePreparationStatus: AudioRoutePreparationStatus {
    lock.lock()
    defer { lock.unlock() }
    return _routePreparationStatus
  }

  var currentRouteSnapshot: RouteSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return _currentRoute
  }

  var availableInputSnapshots: [PortSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return _availableInputs
  }

  func requestRecordPermission() async -> Bool {
    _permissionGranted
  }

  func setPreferredInput(uid: String) throws {
    lock.lock()
    defer { lock.unlock() }
    _preferredInputUIDs.append(uid)
    if _rejectedPreferredInputUIDs.contains(uid) {
      throw FakeAudioSessionRoutingError.rejectedPreferredInput(uid)
    }
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

  func updateRoutePreparationStatus(_ status: AudioRoutePreparationStatus) {
    lock.lock()
    _routePreparationStatus = status
    lock.unlock()
  }

  func emit(_ event: RouteChangeEvent) {
    continuation?.yield(event)
  }

  func finish() {
    continuation?.finish()
  }

  var preferredInputCalls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _preferredInputUIDs
  }
}
