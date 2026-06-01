import Foundation

// why: `SFSpeechAudioBufferRecognitionRequest.contextualStrings` biases the on-device
// language model toward domain vocabulary it would otherwise under-weight. ATC speech
// is dense with ICAO phonetics, fixed phraseology, and aviation numbers; seeding them
// improves callsign and instruction recognition — especially in code-mixed non-English
// ATC where the surrounding language differs but the phraseology stays ICAO-standard.
// Local-only: contextual strings never leave the device and do not affect privacy mode.
enum ATCContextualVocabulary {
  static let icaoAlphabet = [
    "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India",
    "Juliett", "Kilo", "Lima", "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo",
    "Sierra", "Tango", "Uniform", "Victor", "Whiskey", "X-ray", "Yankee", "Zulu",
  ]

  static let phraseology = [
    "cleared for takeoff", "cleared to land", "line up and wait", "hold short",
    "taxi to holding point", "contact tower", "contact ground", "contact approach",
    "contact departure", "go around", "wind check", "QNH", "flight level", "squawk",
    "descend", "climb", "maintain", "heading", "runway", "wilco", "roger", "affirm",
    "negative", "standby", "readback correct", "report established", "cleared ILS",
    "vacate", "expedite", "traffic", "say again", "niner", "decimal",
  ]

  // why: a caller-supplied aircraft callsign is the single highest-value contextual
  // hint (a proper noun the general LM has never seen); appended when known.
  static func strings(callSign: String? = nil) -> [String] {
    var result = icaoAlphabet + phraseology
    if let callSign, !callSign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      result.append(callSign)
    }
    return result
  }
}
