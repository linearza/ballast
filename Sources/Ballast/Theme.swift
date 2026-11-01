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

    static let bg = dynamic("bg", dark: hex(0x0C1F24), light: hex(0xEEF4F4))
    static let bg2 = dynamic("bg2", dark: hex(0x10262C), light: hex(0xF7FAFA))
    static let bg3 = dynamic("bg3", dark: hex(0x173540), light: hex(0xE3EDEE))
    static let line = dynamic("line", dark: hex(0x1F3A42), light: hex(0xD3E0E2))
    static let text = dynamic("text", dark: hex(0xD6E3E5), light: hex(0x1D3A40))
    static let muted = dynamic("muted", dark: hex(0x8BA6AB), light: hex(0x4D666C))
    /// Brass as text: the headline totals.
    static let accent = dynamic("accent", dark: hex(0xD4A849), light: hex(0x7D5200))
    /// Brass as a surface: buttons, toggles, progress.
    static let ctaBg = dynamic("ctaBg", dark: hex(0xD4A849), light: hex(0xDBA43C))
    static let ctaText = dynamic("ctaText", dark: hex(0x1A1204), light: hex(0x1A1204))
    static let ok = dynamic("ok", dark: hex(0x5FBF9A), light: hex(0x0B7A4D))
    static let review = dynamic("review", dark: hex(0xE89A66), light: hex(0xA84A0B))
    static let danger = dynamic("danger", dark: hex(0xE87878), light: hex(0xB42318))
    static let tintOK = dynamic("tintOK", dark: hex(0x5FBF9A, 0.10), light: hex(0x0B7A4D, 0.10))
    static let tintReview = dynamic("tintReview", dark: hex(0xE89A66, 0.11), light: hex(0xA84A0B, 0.10))
    static let tintNeutral = dynamic("tintNeutral", dark: hex(0x8BA6AB, 0.14), light: hex(0x46636A, 0.12))
    static let dangerBg = dynamic("dangerBg", dark: hex(0xE87878, 0.09), light: hex(0xB42318, 0.07))
    static let dangerLine = dynamic("dangerLine", dark: hex(0xE87878, 0.38), light: hex(0xB42318, 0.35))
    /// Sidebar selection: a step up from the sidebar surface.
    static let selection = bg3
    /// Text on a danger-filled button.
    static let onDanger = dynamic("onDanger", dark: hex(0xFDECEB), light: hex(0xFFFFFF))
    /// Solid fill for a destructive commit button (light text on it).
    static let dangerFill = dynamic("dangerFill", dark: hex(0xB8423A), light: hex(0xB42318))

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

/// Metrics shared by the button styles: regular, or compact when the button says `.controlSize(.small)`
/// (inline row actions and the popover). Compact buttons are 24pt tall so neighbours line up.
private struct ButtonMetrics {
    let small: Bool
    var radius: CGFloat { small ? 6 : 7 }
    var hPad: CGFloat { small ? 10 : 12 }
    func font(bold: Bool) -> Font { small ? .callout.weight(.medium) : (bold ? .body.weight(.semibold) : .body) }
    func frame<V: View>(_ v: V) -> some View {
        v.padding(.horizontal, hPad).padding(.vertical, small ? 0 : 4).frame(minHeight: small ? 24 : nil)
    }
}

/// Brass fill with dark text: non-destructive primary actions (Open Ballast, Scan, Continue, Close).
struct BrassButtonStyle: ButtonStyle {
    @SwiftUI.Environment(\.isEnabled) private var isEnabled
    @SwiftUI.Environment(\.controlSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        let m = ButtonMetrics(small: size == .small)
        m.frame(configuration.label.font(m.font(bold: true)).foregroundStyle(Theme.ctaText))
            .background(RoundedRectangle(cornerRadius: m.radius).fill(Theme.ctaBg))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// Red buttons for anything that removes, deletes or moves things off a device.
/// Solid with light text commits the action; `outline` only opens a confirmation or is an inline row action.
struct DangerButtonStyle: ButtonStyle {
    @SwiftUI.Environment(\.isEnabled) private var isEnabled
    @SwiftUI.Environment(\.controlSize) private var size
    var outline = false

    func makeBody(configuration: Configuration) -> some View {
        let m = ButtonMetrics(small: size == .small)
        m.frame(configuration.label.font(outline ? (m.small ? m.font(bold: false) : .callout) : m.font(bold: true))
            .foregroundStyle(outline ? Theme.danger : Theme.onDanger))
            .background(RoundedRectangle(cornerRadius: m.radius).fill(outline ? (configuration.isPressed ? Theme.dangerBg : Color.clear) : Theme.dangerFill))
            .overlay(RoundedRectangle(cornerRadius: m.radius).strokeBorder(outline ? Theme.dangerLine : Color.clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// Quiet bordered button on teal: secondary actions.
struct LineButtonStyle: ButtonStyle {
    @SwiftUI.Environment(\.isEnabled) private var isEnabled
    @SwiftUI.Environment(\.controlSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        let m = ButtonMetrics(small: size == .small)
        m.frame(configuration.label.font(m.font(bold: false)).foregroundStyle(Theme.text))
            .background(RoundedRectangle(cornerRadius: m.radius).fill(configuration.isPressed ? Theme.bg3 : Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: m.radius).strokeBorder(Theme.line))
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

/// SwiftUI's Table draws its column-header strip in system grey; this reaches the underlying NSTableView and
/// paints the strip in the theme colour instead.
struct TableHeaderSkin: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let root = view.window?.contentView else { return }
            Self.skin(in: root)
        }
    }

    private static func skin(in v: NSView) {
        if let table = v as? NSTableView {
            table.backgroundColor = .clear
            if let old = table.headerView, !(old is ThemedHeaderView) {
                let h = ThemedHeaderView(frame: old.frame)
                table.headerView = h
            }
        }
        for s in v.subviews { skin(in: s) }
    }
}

/// Column-header strip drawn entirely from the theme: bg-2 fill, muted text, subtle separators, a `line` hairline below.
/// Replaces the native NSTableHeaderView, whose own material overlay reads lighter and bluer than the teal.
final class ThemedHeaderView: NSTableHeaderView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let table = tableView else { return }
        func resolve(_ c: Color) -> NSColor {
            var out = NSColor(c)
            effectiveAppearance.performAsCurrentDrawingAppearance { out = NSColor(cgColor: NSColor(c).cgColor) ?? out }
            return out
        }
        resolve(Theme.bg2).setFill()
        bounds.fill()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: resolve(Theme.muted),
            .paragraphStyle: para,
        ]
        let line = resolve(Theme.line)
        for i in 0..<table.numberOfColumns {
            let r = headerRect(ofColumn: i)
            let title = table.tableColumns[i].title as NSString
            let size = title.size(withAttributes: attrs)
            title.draw(in: NSRect(x: r.minX + 8, y: r.midY - size.height / 2, width: max(0, r.width - 16), height: size.height), withAttributes: attrs)
            if i < table.numberOfColumns - 1 {
                line.withAlphaComponent(0.7).setFill()
                NSRect(x: r.maxX - 1, y: r.minY + 5, width: 1, height: r.height - 10).fill()
            }
        }
        line.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}
