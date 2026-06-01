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

  func matches(in text: String) -> Bool {
    let upper = text.uppercased()
    let alnum = Self.normalize(upper)
    if !normalized.isEmpty && alnum.contains(normalized) {
      return true
    }
    let words =
      upper
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    guard !phoneticTokens.isEmpty else { return false }
    if words.count >= phoneticTokens.count {
      let n = phoneticTokens.count
      for start in 0...(words.count - n) {
        var ok = true
        for i in 0..<n where words[start + i] != phoneticTokens[i] {
          ok = false
          break
        }
        if ok { return true }
      }
    }
    let joined = words.joined()
    let compact = phoneticTokens.joined()
    return !compact.isEmpty && joined.contains(compact)
  }
}
