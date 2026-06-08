import Foundation

struct CallSign: Equatable, Hashable, Sendable, Codable {
  let raw: String
  let normalized: String
  let phoneticTokens: [String]

  init?(raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = Self.normalize(trimmed)
    guard !normalized.isEmpty else { return nil }
    self.raw = trimmed
    self.normalized = normalized
    self.phoneticTokens = Self.expandPhonetics(normalized)
  }

  static func normalize(_ text: String) -> String {
    text.uppercased().unicodeScalars.reduce(into: "") { acc, scalar in
      if CharacterSet.alphanumerics.contains(scalar) {
        acc.unicodeScalars.append(scalar)
      }
    }
  }

  private static let icaoAlphabet: [Character: String] = [
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

  private static func expandPhonetics(_ normalized: String) -> [String] {
    normalized.compactMap { icaoAlphabet[$0] }
  }

  // why: reverse of icaoAlphabet (phonetic word -> its letter/digit) plus the everyday English
  // digit words the recognizer actually emits. The on-device recognizer runs with addsPunctuation,
  // so it renders spoken digits as numerals ("123"), not as "ONE TWO THREE" or the ICAO "NINER".
  private static let phoneticDecode: [String: String] = {
    var map: [String: String] = [:]
    for (character, word) in icaoAlphabet {
      map[word] = String(character)
    }
    map["NINE"] = "9"
    return map
  }()

  private static func decode(token: String) -> String? {
    if let mapped = phoneticDecode[token] { return mapped }
    if !token.isEmpty, token.allSatisfy({ $0.isNumber }) { return token }
    return nil
  }

  func matches(in text: String) -> Bool {
    guard !normalized.isEmpty else { return false }
    let upper = text.uppercased()
    // fast path: the compact alphanumeric form appears verbatim ("N123AB", "N-123-AB").
    if Self.normalize(upper).contains(normalized) {
      return true
    }
    // why: the recognizer renders a spoken callsign as a MIX of phonetic words and numerals —
    // "November 123 Alpha Bravo" for N123AB — so decode each token back to its letter/digit and
    // test the compact callsign against each contiguous decodable RUN. A non-decodable word
    // (airline name, instruction) breaks the run, so unrelated text can't bridge two fragments
    // into a false match, and a wrong-order spelling still fails (the prior ordered-window
    // behavior is preserved by run-local containment).
    let words =
      upper
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    var run = ""
    for word in words {
      if let decoded = Self.decode(token: word) {
        run += decoded
        if run.contains(normalized) { return true }
      } else {
        run = ""
      }
    }
    return false
  }
}
