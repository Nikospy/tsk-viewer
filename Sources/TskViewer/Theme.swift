import AppKit
import SwiftUI
import TskCore

/// "Grafit" palette and iA Writer Mono type, chosen by the user from prototype A (Terminal).
enum Theme {
    /// Marks the user's replies, in notes and in the composer.
    static var replyMarker: String { L("reply ›", pl: "odp ›") }
    static let panel = Color(hex: 0x1B1A18)
    static let side = Color(hex: 0x171614)
    static let raised = Color(hex: 0x23211E)
    static let line = Color(hex: 0x2E2B27)
    static let text = Color(hex: 0xECE7DF)
    static let dim = Color(hex: 0xABA397)
    static let faint = Color(hex: 0x878075)
    static let accent = Color(hex: 0xE8B062)
    static let accentHover = Color(hex: 0xF2C07E)
    static let accentText = Color(hex: 0x1B1408)
    static let selection = Color(hex: 0xE8B062).opacity(0.13)
    static let ask = Color(hex: 0xF0A35E)
    static let review = Color(hex: 0x8DB4F0)
    static let ok = Color(hex: 0x7FBF6A)
    static let okHover = Color(hex: 0x94D27F)
    static let okText = Color(hex: 0x0F1D0A)
    static let danger = Color(hex: 0xE5786D)
    static let hover = Color.white.opacity(0.045)
    static let code = Color.white.opacity(0.07)

    /// The font the user runs in iTerm2; falls back to the system monospace when it is not installed.
    private static let hasMono = NSFont(name: "iAWriterMonoV-Regular", size: 13) != nil

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasMono ? .custom("iA Writer Mono V", size: size).weight(weight)
            : .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension TskStatus {
    var tint: Color {
        switch self {
        case .blocked: Theme.ask
        case .review: Theme.review
        case .done: Theme.ok
        default: Theme.faint
        }
    }

    var glyph: String {
        switch self {
        case .blocked: "?"
        case .review: "✓"
        case .started: "…"
        case .ready: "→"
        case .done: "✓"
        default: "·"
        }
    }

    var terminalLabel: String {
        switch self {
        case .open: L("open", pl: "otwarte")
        case .ready: L("ready to work", pl: "gotowe do pracy")
        case .started: L("in progress", pl: "w trakcie")
        case .blocked: L("waiting for a reply", pl: "czeka na odpowiedź")
        case .review: L("to accept", pl: "do akceptacji")
        case .done: L("done", pl: "zrobione")
        case .unknown(let value): value
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

// MARK: - Button styles (every control answers hover)

struct SolidButtonStyle: ButtonStyle {
    let fill: Color
    let hoverFill: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        Solid(configuration: configuration, fill: fill, hoverFill: hoverFill, foreground: foreground)
    }

    private struct Solid: View {
        let configuration: Configuration
        let fill: Color
        let hoverFill: Color
        let foreground: Color
        @State private var hovered = false

        var body: some View {
            let lifted = hovered && !configuration.isPressed
            configuration.label
                .font(Theme.mono(13, .bold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 16)
                .frame(minWidth: 112, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? hoverFill : fill))
                .shadow(color: fill.opacity(lifted ? 0.35 : 0), radius: 7, y: 3)
                .offset(y: lifted ? -1 : 0)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.15), value: hovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

struct GhostButtonStyle: ButtonStyle {
    var active = false
    /// When set, hover and active paint the button in this color instead of plain text.
    var accent: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        Ghost(configuration: configuration, active: active, accent: accent)
    }

    private struct Ghost: View {
        let configuration: Configuration
        let active: Bool
        let accent: Color?
        @State private var hovered = false

        var body: some View {
            let lit = active || hovered
            configuration.label
                .font(Theme.mono(12))
                .foregroundStyle(lit ? accent ?? Theme.text : Theme.faint)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(lit ? accent?.opacity(0.14) ?? Theme.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(lit ? accent?.opacity(0.5) ?? .clear : .clear, lineWidth: 1))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}
