import Foundation
import Testing

@testable import Dspeech

struct AudioLevelTests {
  @Test func silenceIsZero() {
    #expect(AudioLevel.normalized(rms: 0) == 0)
  }

  @Test func belowFloorIsZero() {
    // ~-60 dB is below the -50 dB floor
    #expect(AudioLevel.normalized(rms: 0.001) == 0)
  }

  @Test func fullScaleIsOne() {
    #expect(AudioLevel.normalized(rms: 1.0) == 1)
  }

  @Test func midRangeIsBetweenZeroAndOne() {
    // -25 dB ≈ 0.056 linear → mid of a -50 dB floor
    let level = AudioLevel.normalized(rms: 0.0562)
    #expect(level > 0.4 && level < 0.6)
  }

  @Test func clampsNonFiniteToZero() {
    #expect(AudioLevel.normalized(rms: .nan) == 0)
    #expect(AudioLevel.normalized(rms: .infinity) == 0)
  }
}
