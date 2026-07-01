import Foundation

enum ApplicationSupportDirectoryError: Error, Equatable {
  case unavailable
}

/// Single fail-fast resolution of the user-domain Application Support directory.
///
/// Replaces the scattered `FileManager.default.urls(for: .applicationSupportDirectory, ...).first!`
/// force-unwraps and the ad-hoc guarded throws across Core. Throwing callers propagate the typed
/// error to their subsystem boundary; the non-throwing default sites (installer/storage inits whose
/// default arguments cannot throw) use ``directoryOrTrap()``.
enum ApplicationSupport {
  static func directory(fileManager: FileManager = .default) throws -> URL {
    guard
      let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      throw ApplicationSupportDirectoryError.unavailable
    }
    return url
  }

  // why: the handful of non-throwing default sites (init default-argument resolution) can't throw.
  // Application Support is guaranteed on iOS, so a nil result is a never-path — trap fast with a
  // descriptive message instead of the old anonymous `.first!` "unexpectedly found nil".
  static func directoryOrTrap(fileManager: FileManager = .default) -> URL {
    do {
      return try directory(fileManager: fileManager)
    } catch {
      preconditionFailure("Application Support directory unavailable: \(error)")
    }
  }
}
