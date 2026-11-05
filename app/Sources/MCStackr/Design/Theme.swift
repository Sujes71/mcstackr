import SwiftUI

enum Theme {
    // Base surfaces
    static let background = Color(hex: 0x0A0C0B)
    static let backgroundLift = Color(hex: 0x0F1210)
    static let sidebar = Color(hex: 0x0C0F0D)
    static let surface = Color(hex: 0x141815)
    static let surfaceHover = Color(hex: 0x1A201B)
    static let field = Color(hex: 0x101411)

    // Lines
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.14)

    // Text
    static let text = Color(hex: 0xF3F6F0)
    static let textMuted = Color(hex: 0x8C988D)
    static let textDim = Color(hex: 0x5E6A60)

    // Accents
    static let accent = Color(hex: 0xC9F45B)
    static let accentInk = Color(hex: 0x101403)
    static let danger = Color(hex: 0xFF6B5E)
    static let warning = Color(hex: 0xFFC24B)
    static let info = Color(hex: 0x67D8FF)
    static let violet = Color(hex: 0xB69CFF)
    static let running = Color(hex: 0x6FF3A8)

    // Type
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func label(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .rounded)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Background

struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.background

            RadialGradient(
                colors: [Theme.accent.opacity(0.10), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 620
            )

            RadialGradient(
                colors: [Theme.info.opacity(0.07), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 760
            )

            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.28)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}
