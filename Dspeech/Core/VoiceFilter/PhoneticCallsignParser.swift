import Foundation

enum PhoneticCallsignParser {
  private static let posixLocale = Locale(identifier: "en_US_POSIX")

  private static let tokenMap: [String: String] = [
    "alpha": "A", "alfa": "A",
    "bravo": "B",
    "charlie": "C",
    "delta": "D",
    "echo": "E",
    "foxtrot": "F", "fox": "F",
    "golf": "G",
    "hotel": "H",
    "india": "I",
    "juliett": "J", "juliet": "J",
    "kilo": "K",
    "lima": "L",
    "mike": "M",
    "november": "N",
    "oscar": "O",
    "papa": "P",
    "quebec": "Q",
    "romeo": "R",
    "sierra": "S",
    "tango": "T",
    "uniform": "U",
    "victor": "V",
    "whiskey": "W", "whisky": "W",
    "xray": "X", "exray": "X",
    "yankee": "Y",
    "zulu": "Z",
    "zero": "0",
    "one": "1", "won": "1",
    "two": "2", "too": "2", "to": "2",
    "three": "3", "tree": "3",
    "four": "4", "fower": "4", "for": "4", "fore": "4",
    "five": "5", "fife": "5",
    "six": "6",
    "seven": "7",
    "eight": "8", "ate": "8",
    "nine": "9", "niner": "9",
  ]

  private static func tokens(from spoken: String, foldDiacritics: Bool) -> [String] {
    let source =
      foldDiacritics
      ? spoken.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: posixLocale
      )
      : spoken.lowercased()
    let rawTokens =
      source
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }

    var tokens: [String] = []
    var index = 0
    while index < rawTokens.count {
      if rawTokens[index] == "x" || rawTokens[index] == "ex",
        index + 1 < rawTokens.count,
        rawTokens[index + 1] == "ray"
      {
        tokens.append(rawTokens[index] + "ray")
        index += 2
      } else {
        tokens.append(rawTokens[index])
        index += 1
      }
    }
    return tokens
  }

  private static func isFrenchLocale(_ localeIdentifier: String?) -> Bool {
    guard let localeIdentifier else { return false }
    let language = localeIdentifier.split { $0 == "-" || $0 == "_" }.first
    return language?.lowercased() == "fr"
  }

  private static func lookupToken(_ token: String, usesFrench: Bool) -> String? {
    tokenMap[token] ?? (usesFrench ? PhoneticAlphabet.frenchDigits[token.uppercased()] : nil)
  }

  private static func mappedToken(
    _ token: String,
    previous: String?,
    next: String?,
    usesFrench: Bool
  ) -> String? {
    if usesFrench, PhoneticAlphabet.frenchIgnoredTokens.contains(token.uppercased()) {
      return ""
    }
    if token == "oh" {
      return previous.flatMap({ lookupToken($0, usesFrench: usesFrench) }) != nil
        || next.flatMap({ lookupToken($0, usesFrench: usesFrench) }) != nil
        ? "0"
        : nil
    }
    return lookupToken(token, usesFrench: usesFrench)
  }

  static func parse(_ spoken: String, localeIdentifier: String? = nil) -> String {
    let usesFrench = isFrenchLocale(localeIdentifier)
    let words = tokens(from: spoken, foldDiacritics: usesFrench)

    var result = ""
    for index in words.indices {
      let previous = index == words.startIndex ? nil : words[words.index(before: index)]
      let next =
        words.index(after: index) == words.endIndex ? nil : words[words.index(after: index)]
      let word = words[index]
      if let mapped = mappedToken(word, previous: previous, next: next, usesFrench: usesFrench) {
        result += mapped
      } else {
        for scalar in word.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result.uppercased()
  }
}
