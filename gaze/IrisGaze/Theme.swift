import SwiftUI

/// Light theme (Julian's keyboard design).
enum Theme {
    static let background = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let cell = Color(red: 0.97, green: 0.97, blue: 0.97)          // #F7F7F7
    static let cellBorder = Color.black.opacity(0.06)
    static let action = Color(red: 0.17, green: 0.17, blue: 0.17)        // #2B2B2B
    static let suggestFill = Color(red: 0.66, green: 0.80, blue: 0.96)   // #A9CBF5
    static let text = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let muted = Color(red: 0.45, green: 0.46, blue: 0.50)
    static let suggest = text
    static let glow = Color(red: 0.16, green: 0.47, blue: 0.96)          // gaze blue
    static let look = Color(red: 0.55, green: 0.30, blue: 0.95)          // calibration purple
    static let panel = Color.white
}
