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
    map["ALFA"] = "A"
    map["JULIET"] = "J"
    map["WHISKY"] = "W"
    map["X-RAY"] = "X"
    map["XRAY"] = "X"
    map["NINE"] = "9"
    map["TREE"] = "3"
    map["FIFE"] = "5"
    map["FOWER"] = "4"
    return map
  }()

  private static let posixLocale = Locale(identifier: "en_US_POSIX")
  private static let compactRunSeparators = CharacterSet(charactersIn: "-/")
  private static let frenchPhoneticDecode: [String: String] = [
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
  private static let frenchIgnoredTokens: Set<String> = ["DECIMALE", "VIRGULE"]

  private static func isFrenchLocale(_ localeIdentifier: String?) -> Bool {
    guard let localeIdentifier else { return false }
    let language = localeIdentifier.split { $0 == "-" || $0 == "_" }.first
    return language?.lowercased() == "fr"
  }

  private static func decode(token: String, usesFrench: Bool) -> String? {
    if let mapped = phoneticDecode[token] { return mapped }
    if usesFrench, let mapped = frenchPhoneticDecode[token] { return mapped }
    if !token.isEmpty, token.allSatisfy({ $0.isNumber }) { return token }
    return nil
  }

  private static func decode(
    token: String,
    previous: String?,
    next: String?,
    usesFrench: Bool
  ) -> String? {
    if token == "OH" {
      let previousDecoded = previous.flatMap { decode(token: $0, usesFrench: usesFrench) }
      let nextDecoded = next.flatMap { decode(token: $0, usesFrench: usesFrench) }
      return previousDecoded != nil || nextDecoded != nil ? "0" : nil
    }
    return decode(token: token, usesFrench: usesFrench)
  }

  private static func phoneticWords(in text: String) -> [String] {
    let folded =
      text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: posixLocale)
      .uppercased()
    let rawWords =
      folded
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    var words: [String] = []
    var index = 0
    while index < rawWords.count {
      if rawWords[index] == "X", index + 1 < rawWords.count, rawWords[index + 1] == "RAY" {
        words.append("XRAY")
        index += 2
      } else {
        words.append(rawWords[index])
        index += 1
      }
    }
    return words
  }

  private static func decodedRuns(in text: String, localeIdentifier: String?) -> [String] {
    let usesFrench = isFrenchLocale(localeIdentifier)
    let words = phoneticWords(in: text)
    var runs: [String] = []
    var run = ""
    for index in words.indices {
      let previous = index == words.startIndex ? nil : words[words.index(before: index)]
      let next =
        words.index(after: index) == words.endIndex ? nil : words[words.index(after: index)]
      if usesFrench, frenchIgnoredTokens.contains(words[index]) {
        continue
      }
      if let decoded = Self.decode(
        token: words[index],
        previous: previous,
        next: next,
        usesFrench: usesFrench
      ) {
        run += decoded
      } else {
        if !run.isEmpty { runs.append(run) }
        run = ""
      }
    }
    if !run.isEmpty { runs.append(run) }
    return runs
  }

  private static func compactAlphanumericRuns(in text: String) -> [String] {
    let folded =
      text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: posixLocale)
      .uppercased()
    var runs: [String] = []
    var run = ""
    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        run.unicodeScalars.append(scalar)
      } else if compactRunSeparators.contains(scalar), !run.isEmpty {
        continue
      } else {
        if !run.isEmpty { runs.append(run) }
        run = ""
      }
    }
    if !run.isEmpty { runs.append(run) }
    return runs
  }

  private static func matches(
    _ candidates: Set<String>,
    in text: String,
    localeIdentifier: String?
  ) -> Bool {
    guard !candidates.isEmpty else { return false }
    let compactRuns = compactAlphanumericRuns(in: text)
    if compactRuns.contains(where: { candidates.contains($0) }) {
      return true
    }
    return decodedRuns(in: text, localeIdentifier: localeIdentifier).contains { run in
      candidates.contains { run.contains($0) }
    }
  }

  // why: abbreviated tails ("3AB" for N123AB) must match only a COMPLETE spoken run, never
  // a substring of a longer decoded run — substring matching makes every other aircraft
  // whose callsign merely contains the tail read as "addressed to us".
  private static func matchesExactRun(
    _ candidates: Set<String>,
    in text: String,
    localeIdentifier: String?
  ) -> Bool {
    guard !candidates.isEmpty else { return false }
    if compactAlphanumericRuns(in: text).contains(where: { candidates.contains($0) }) {
      return true
    }
    return decodedRuns(in: text, localeIdentifier: localeIdentifier).contains {
      candidates.contains($0)
    }
  }

  private static func abbreviationCandidates(for normalized: String) -> Set<String> {
    guard let prefix = normalized.first else { return [] }
    let suffix = String(normalized.dropFirst())
    guard suffix.count >= 2 else { return [] }

    var candidates: Set<String> = []
    for length in 2...suffix.count {
      let tail = String(suffix.suffix(length))
      candidates.insert(tail)
      candidates.insert(String(prefix) + tail)
    }
    return candidates
  }

  func matches(in text: String, localeIdentifier: String? = nil) -> Bool {
    guard !normalized.isEmpty else { return false }
    return Self.matches([normalized], in: text, localeIdentifier: localeIdentifier)
  }

  // why: separate display-biased tier (ICAO abbreviated addressing — prefix + at least the
  // last two characters, or the bare tail). The gate uses it to SHOW a possibly-own call;
  // it must never feed a suppression decision, so it stays out of matches(in:).
  func matchesAbbreviated(in text: String, localeIdentifier: String? = nil) -> Bool {
    Self.matchesExactRun(
      Self.abbreviationCandidates(for: normalized),
      in: text,
      localeIdentifier: localeIdentifier
    )
  }
}
