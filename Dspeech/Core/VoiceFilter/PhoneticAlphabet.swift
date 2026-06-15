import Foundation

// why: the canonical ICAO phonetic alphabet + French radiotelephony digits were hand-copied into
// both CallSign (ATC-transcript matching) and PhoneticCallsignParser (enrollment parse). This is the
// single source of truth for that frozen standard so the two decoders can never drift on it. Each
// decoder keeps its OWN purpose-specific layer on top (CallSign: transcriber-variant decodes + alpha/
// digit splitting + run matching; PhoneticCallsignParser: spoken-homophone tolerance) — those are
// intentionally different and stay with their consumer. Vendored into the ReplayKit/SpeakerEval tools
// by symlink (same bytes the app compiles), alongside the symlinked CallSign.
enum PhoneticAlphabet {
  // Letter/digit -> ICAO spoken word. "9" is the aviation "NINER".
  static let icao: [Character: String] = [
    "A": "ALPHA", "B": "BRAVO", "C": "CHARLIE", "D": "DELTA",
    "E": "ECHO", "F": "FOXTROT", "G": "GOLF", "H": "HOTEL",
    "I": "INDIA", "J": "JULIETT", "K": "KILO", "L": "LIMA",
    "M": "MIKE", "N": "NOVEMBER", "O": "OSCAR", "P": "PAPA",
    "Q": "QUEBEC", "R": "ROMEO", "S": "SIERRA", "T": "TANGO",
    "U": "UNIFORM", "V": "VICTOR", "W": "WHISKEY", "X": "XRAY",
    "Y": "YANKEE", "Z": "ZULU",
    "0": "ZERO", "1": "ONE", "2": "TWO", "3": "THREE", "4": "FOUR",
    "5": "FIVE", "6": "SIX", "7": "SEVEN", "8": "EIGHT", "9": "NINER",
  ]

  // French radiotelephony digit words -> digit. UPPERCASE keys (callers fold/uppercase first).
  static let frenchDigits: [String: String] = [
    "ZERO": "0",
    "UN": "1", "UNITE": "1",
    "DEUX": "2",
    "TROIS": "3",
    "QUATRE": "4",
    "CINQ": "5",
    "SIX": "6",
    "SEPT": "7",
    "HUIT": "8",
    "NEUF": "9",
  ]

  // French decimal/comma fillers that carry no callsign content. UPPERCASE.
  static let frenchIgnoredTokens: Set<String> = ["DECIMALE", "VIRGULE"]
}
