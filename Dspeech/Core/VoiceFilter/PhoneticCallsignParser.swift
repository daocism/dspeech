import Foundation

enum PhoneticCallsignParser {
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
    "xray": "X", "x-ray": "X", "ex-ray": "X",
    "yankee": "Y",
    "zulu": "Z",
    "zero": "0", "oh": "0",
    "one": "1", "won": "1",
    "two": "2", "too": "2", "to": "2",
    "three": "3", "tree": "3",
    "four": "4", "for": "4", "fore": "4",
    "five": "5", "fife": "5",
    "six": "6",
    "seven": "7",
    "eight": "8", "ate": "8",
    "nine": "9", "niner": "9",
  ]

  static func parse(_ spoken: String) -> String {
    let lowered = spoken.lowercased()
    let words =
      lowered
      .components(separatedBy: CharacterSet(charactersIn: " \t\n\r,.;:!?"))
      .filter { !$0.isEmpty }

    var result = ""
    for word in words {
      if let mapped = tokenMap[word] {
        result += mapped
      } else if let mapped = tokenMap[word.replacingOccurrences(of: "-", with: "")] {
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
