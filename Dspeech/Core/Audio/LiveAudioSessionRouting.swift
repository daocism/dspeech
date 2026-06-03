import Foundation

#if canImport(AVFAudio)
  import AVFAudio
#endif

#if canImport(AVFAudio)
  final class LiveAudioSessionRouting: AudioSessionRouting, @unchecked Sendable {
    private let session: AVAudioSession
    private let continuation: AsyncStream<RouteChangeEvent>.Continuation
    private let _routePreparationStatus: AudioRoutePreparationStatus
    let routeChanges: AsyncStream<RouteChangeEvent>
    private var observer: NSObjectProtocol?

    init(session: AVAudioSession = .sharedInstance()) {
      self.session = session
      // why: until a record-capable category is set, `currentRoute` and
      // `availableInputs` enumerate no microphone, which makes route health read
      // .noInput and disables Start before the engine ever activates capture.
      // Priming the category (without activating — the engine owns activation)
      // lets the OS surface the real input so Start reflects an available mic.
      do {
        try session.setCategory(
          .playAndRecord,
          mode: .measurement,
          options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        self._routePreparationStatus = .ready
      } catch {
        self._routePreparationStatus = .failed(
          .recordCategoryUnavailable(error.localizedDescription)
        )
      }
      var localContinuation: AsyncStream<RouteChangeEvent>.Continuation!
      self.routeChanges = AsyncStream<RouteChangeEvent>(
        bufferingPolicy: .unbounded
      ) { continuation in
        localContinuation = continuation
      }
      self.continuation = localContinuation
      self.observer = NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: session,
        queue: nil
      ) { [continuation = localContinuation!] note in
        let rawReason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let event = LiveAudioSessionRouting.event(forRawReason: rawReason)
        continuation.yield(event)
      }
    }

    deinit {
      if let observer {
        NotificationCenter.default.removeObserver(observer)
      }
      continuation.finish()
    }

    var routePreparationStatus: AudioRoutePreparationStatus {
      _routePreparationStatus
    }

    var currentRouteSnapshot: RouteSnapshot {
      let route = session.currentRoute
      return RouteSnapshot(
        inputs: route.inputs.map(LiveAudioSessionRouting.snapshot(from:)),
        outputs: route.outputs.map(LiveAudioSessionRouting.snapshot(from:))
      )
    }

    var availableInputSnapshots: [PortSnapshot] {
      (session.availableInputs ?? []).map(LiveAudioSessionRouting.snapshot(from:))
    }

    func requestRecordPermission() async -> Bool {
      await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        AVAudioApplication.requestRecordPermission { granted in
          cont.resume(returning: granted)
        }
      }
    }

    func setPreferredInput(uid: String) throws {
      let inputs = session.availableInputs ?? []
      guard let port = inputs.first(where: { $0.uid == uid }) else { return }
      try session.setPreferredInput(port)
    }

    private static func snapshot(from port: AVAudioSessionPortDescription) -> PortSnapshot {
      PortSnapshot(
        portType: AudioPortType(rawValue: port.portType.rawValue),
        portName: port.portName,
        uid: port.uid,
        hasHardwareVoiceProcessing: false
      )
    }

    private static func event(forRawReason raw: UInt) -> RouteChangeEvent {
      guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else {
        return .unknown(Int(raw))
      }
      switch reason {
      case .newDeviceAvailable: return .newDeviceAvailable
      case .oldDeviceUnavailable: return .oldDeviceUnavailable
      case .categoryChange: return .categoryChange
      case .override: return .override
      case .wakeFromSleep: return .wakeFromSleep
      case .noSuitableRouteForCategory: return .noSuitableRouteForCategory
      case .routeConfigurationChange: return .routeConfigurationChange
      case .unknown: return .unknown(Int(raw))
      @unknown default: return .unknown(Int(raw))
      }
    }
  }
#endif
