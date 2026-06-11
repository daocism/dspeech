import Foundation

#if canImport(AVFAudio)
  import AVFAudio
#endif

#if canImport(AVFAudio)
  final class LiveAudioSessionRouting: AudioSessionRouting, @unchecked Sendable {
    private let session: AVAudioSession
    private let lock = NSLock()
    private var _routePreparationStatus: AudioRoutePreparationStatus
    private var routeContinuations: [UUID: AsyncStream<RouteChangeEvent>.Continuation] = [:]
    private var observers: [NSObjectProtocol] = []

    init(session: AVAudioSession = .sharedInstance()) {
      self.session = session
      // why: until a record-capable category is set, `currentRoute` and
      // `availableInputs` enumerate no microphone, which makes route health read
      // .noInput and disables Start before the engine ever activates capture.
      // Priming the category (without activating — the engine owns activation)
      // lets the OS surface the real input so Start reflects an available mic.
      self._routePreparationStatus = Self.prepareRecordCategory(session)
      self.observers = [
        NotificationCenter.default.addObserver(
          forName: AVAudioSession.routeChangeNotification,
          object: session,
          queue: nil
        ) { [weak self] note in
          let rawReason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
          let event = LiveAudioSessionRouting.event(forRawReason: rawReason)
          self?.yield(event)
        },
        NotificationCenter.default.addObserver(
          forName: AVAudioSession.interruptionNotification,
          object: session,
          queue: nil
        ) { [weak self] note in
          let event = LiveAudioSessionRouting.event(forInterruptionUserInfo: note.userInfo)
          self?.yield(event)
        },
        NotificationCenter.default.addObserver(
          forName: AVAudioSession.mediaServicesWereResetNotification,
          object: session,
          queue: nil
        ) { [weak self] _ in
          self?.refreshRoutePreparationStatus()
          self?.yield(.mediaServicesWereReset)
        },
      ]
    }

    deinit {
      for observer in observers {
        NotificationCenter.default.removeObserver(observer)
      }
      finishRouteContinuations()
    }

    var routePreparationStatus: AudioRoutePreparationStatus {
      lock.lock()
      defer { lock.unlock() }
      return _routePreparationStatus
    }

    private func refreshRoutePreparationStatus() {
      let status = Self.prepareRecordCategory(session)
      lock.lock()
      _routePreparationStatus = status
      lock.unlock()
    }

    static func configureRecordCategory(
      _ session: AVAudioSession
    ) throws {
      try session.setCategory(
        .playAndRecord,
        mode: .measurement,
        options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
      )
    }

    private static func prepareRecordCategory(
      _ session: AVAudioSession
    ) -> AudioRoutePreparationStatus {
      do {
        try configureRecordCategory(session)
        return .ready
      } catch {
        return .failed(.recordCategoryUnavailable(error.localizedDescription))
      }
    }

    func routeChangeEvents() -> AsyncStream<RouteChangeEvent> {
      let id = UUID()
      return AsyncStream<RouteChangeEvent>(bufferingPolicy: .unbounded) { continuation in
        lock.lock()
        routeContinuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
          guard let self else { return }
          lock.lock()
          routeContinuations[id] = nil
          lock.unlock()
        }
      }
    }

    private func yield(_ event: RouteChangeEvent) {
      lock.lock()
      let continuations = Array(routeContinuations.values)
      lock.unlock()
      for continuation in continuations {
        continuation.yield(event)
      }
    }

    private func finishRouteContinuations() {
      lock.lock()
      let continuations = Array(routeContinuations.values)
      routeContinuations.removeAll()
      lock.unlock()
      for continuation in continuations {
        continuation.finish()
      }
    }

    static func event(
      forInterruptionUserInfo userInfo: [AnyHashable: Any]?
    ) -> RouteChangeEvent {
      let rawType = unsignedValue(userInfo?[AVAudioSessionInterruptionTypeKey]) ?? 0
      guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
        return .unknown(Int(rawType))
      }
      switch type {
      case .began:
        return .interruptionBegan
      case .ended:
        let rawOptions = unsignedValue(userInfo?[AVAudioSessionInterruptionOptionKey]) ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        return .interruptionEnded(shouldResume: options.contains(.shouldResume))
      @unknown default:
        return .unknown(Int(rawType))
      }
    }

    private static func unsignedValue(_ raw: Any?) -> UInt? {
      if let value = raw as? UInt { return value }
      if let value = raw as? NSNumber { return value.uintValue }
      if let value = raw as? Int { return UInt(exactly: value) }
      return nil
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
