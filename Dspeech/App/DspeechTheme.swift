import SwiftUI

// why: single source of truth for the cockpit's semantic tints, surface colours, corner radii,
// and the mandatory-chip insets/opacities. Every value here is a tint that is already hardcoded
// across the App layer today — centralising them lets the iOS 26 Liquid Glass pass restyle in one
// place instead of chasing per-view literals. The semantic tints alias system colours for now so
// migration is pixel-identical; the glass phase can repoint them to brand colours without touching
// call sites. The app accent asset (Assets.xcassets/AccentColor) encodes the same systemCyan.
enum DspeechTheme {
  static let accent = Color.cyan
  static let warning = Color.orange
  static let danger = Color.red
  static let success = Color.green
  static let filtered = Color.yellow

  static let backgroundTop = Color.black
  static let backgroundBottom = Color(red: 0.03, green: 0.06, blue: 0.10)
  static let cardFill = Color(red: 0.07, green: 0.08, blue: 0.10)

  static let chipFillOpacity = 0.16
  static let chipStrokeOpacity = 0.45

  static let cardCornerRadius: CGFloat = 18
  static let bannerCornerRadius: CGFloat = 12
  static let bubbleCornerRadius: CGFloat = 16

  static let chipHorizontalPadding: CGFloat = 7
  static let chipVerticalPadding: CGFloat = 3
}
