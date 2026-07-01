import Foundation

protocol AudioSessionRouting: Sendable {
  var routePreparationStatus: AudioRoutePreparationStatus { get }
  var currentRouteSnapshot: RouteSnapshot { get }
  var availableInputSnapshots: [PortSnapshot] { get }
  func routeChangeEvents() -> AsyncStream<RouteChangeEvent>
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
      return String(localized: "Couldn’t prepare the audio input for recording: \(reason)")
    }
  }
}
