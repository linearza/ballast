import AppKit
import BallastCore
import SwiftUI

/// The site's palette (site/style.css): harbour teal-black in dark, pale teal in light, brass for the waterline.
/// Every colour in the app comes from here; views never carry their own hex.
enum Theme {
    private static func hex(_ v: UInt32, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    private static func dynamic(_ name: String, dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: name) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let bg = dynamic("bg", dark: hex(0x061418), light: hex(0xF2F7F7))
    static let bg2 = dynamic("bg2", dark: hex(0x0A1E24), light: hex(0xFFFFFF))
    static let bg3 = dynamic("bg3", dark: hex(0x10303A), light: hex(0xE4EEF0))
    static let line = dynamic("line", dark: hex(0x1F3F48), light: hex(0xC9D9DC))
    static let text = dynamic("text", dark: hex(0xE9F2F3), light: hex(0x08262D))
    static let muted = dynamic("muted", dark: hex(0x93AEB3), light: hex(0x46636A))
    /// Brass as text: the headline totals.
    static let accent = dynamic("accent", dark: hex(0xE3B04B), light: hex(0x7D5200))
    /// Brass as a surface: buttons, toggles, progress.
    static let ctaBg = dynamic("ctaBg", dark: hex(0xE3B04B), light: hex(0xDBA43C))
    static let ctaText = dynamic("ctaText", dark: hex(0x1A1204), light: hex(0x1A1204))
    static let ok = dynamic("ok", dark: hex(0x4FD19A), light: hex(0x0B7A4D))
    static let review = dynamic("review", dark: hex(0xFF9A5C), light: hex(0xA84A0B))
    static let danger = dynamic("danger", dark: hex(0xFF6B6B), light: hex(0xB42318))
    static let tintOK = dynamic("tintOK", dark: hex(0x4FD19A, 0.12), light: hex(0x0B7A4D, 0.10))
    static let tintReview = dynamic("tintReview", dark: hex(0xFF9A5C, 0.13), light: hex(0xA84A0B, 0.10))
    static let tintNeutral = dynamic("tintNeutral", dark: hex(0x93AEB3, 0.16), light: hex(0x46636A, 0.12))
    static let dangerBg = dynamic("dangerBg", dark: hex(0xFF6B6B, 0.10), light: hex(0xB42318, 0.07))
    static let dangerLine = dynamic("dangerLine", dark: hex(0xFF6B6B, 0.40), light: hex(0xB42318, 0.35))
    /// Sidebar selection: a step up from the sidebar surface.
    static let selection = bg3
    /// Text on a danger-filled button.
    static let onDanger = dynamic("onDanger", dark: hex(0x1A0606), light: hex(0xFFFFFF))

    /// Sizes and paths, like the site's ledger.
    static func mono(_ style: Font.TextStyle = .body) -> Font { .system(style, design: .monospaced) }
}

extension Risk {
    var tagColor: Color {
        switch self {
        case .regenerable: Theme.ok
        case .review: Theme.review
        case .yourData: Theme.danger
        }
    }

    var tagTint: Color {
        switch self {
        case .regenerable: Theme.tintOK
        case .review: Theme.tintReview
        case .yourData: Theme.dangerBg
        }
    }
}

/// A rounded capsule like the site's tags.
struct Tag: View {
    let text: String
    var color: Color = Theme.muted
    var tint: Color = Theme.tintNeutral

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(tint))
    }
}

/// Brass fill with dark text: Remove, Review and remove…, Continue.
struct BrassButtonStyle: ButtonStyle {
    @SwiftUI.Environment(\.isEnabled) private var isEnabled
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(danger ? Theme.onDanger : Theme.ctaText)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(danger ? Theme.danger : Theme.ctaBg))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// Quiet bordered button on teal: secondary actions.
struct LineButtonStyle: ButtonStyle {
    @SwiftUI.Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? Theme.bg3 : Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    /// Teal surface behind a screen, with brass for controls and the site's text colour.
    func ballastSurface(_ surface: Color = Theme.bg) -> some View {
        self.foregroundStyle(Theme.text).tint(Theme.ctaBg).background(surface)
    }

    /// Lists and tables: no system grey behind the rows.
    func ballastList(_ surface: Color = Theme.bg) -> some View {
        self.scrollContentBackground(.hidden).background(surface).tint(Theme.ctaBg)
    }
}

/// A 1pt rule in `line`, in place of the system Divider.
struct Rule: View {
    var body: some View { Theme.line.frame(height: 1) }
}
