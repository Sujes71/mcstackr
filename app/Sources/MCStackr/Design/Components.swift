import SwiftUI

// MARK: - Card

struct CardStyle: ViewModifier {
    var highlighted: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.035), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(highlighted ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
    }
}

extension View {
    func cardStyle(highlighted: Bool = false) -> some View {
        modifier(CardStyle(highlighted: highlighted))
    }
}

// MARK: - Status dot

struct StatusDot: View {
    let state: String
    var size: CGFloat = 9

    private var color: Color {
        switch state.lowercased() {
        case "running": return Theme.running
        case "restarting", "starting": return Theme.warning
        case "paused": return Theme.info
        case "dead", "exited", "stopped": return Theme.danger
        default: return Theme.textDim
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 4)
                    .blur(radius: 2)
            }
            .shadow(color: color.opacity(0.8), radius: state.lowercased() == "running" ? 6 : 0)
    }
}

// MARK: - Pills and chips

struct StatePill: View {
    let state: String

    private var label: String {
        state.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    private var color: Color {
        switch state.lowercased() {
        case "running": return Theme.running
        case "restarting", "starting", "created": return Theme.warning
        case "paused": return Theme.info
        case "dead", "exited", "stopped": return Theme.danger
        default: return Theme.textDim
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .overlay { Capsule().stroke(color.opacity(0.24), lineWidth: 1) }
    }
}

struct TechBadge: View {
    let text: String
    var color: Color = Theme.info

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(color.opacity(0.22), lineWidth: 1)
            }
    }
}

// MARK: - Buttons

struct ActionIconButton: View {
    let systemName: String
    var tint: Color = Theme.textMuted
    var help: String = ""
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? tint : Theme.textMuted)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Theme.surfaceHover : Theme.field)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(hovering ? tint.opacity(0.35) : Theme.stroke, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct ActionTextButton: View {
    let title: String
    var systemName: String? = nil
    var prominent: Bool = false
    var destructive: Bool = false
    var tint: Color = Theme.accent
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(buttonForeground)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(buttonBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(buttonBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var buttonForeground: Color {
        if prominent { return Theme.accentInk }
        if destructive { return Theme.danger }
        return hovering ? Theme.text : Theme.textMuted
    }

    private var buttonBackground: Color {
        if prominent { return tint }
        if destructive { return Theme.danger.opacity(hovering ? 0.22 : 0.12) }
        return hovering ? Theme.surfaceHover : Theme.field
    }

    private var buttonBorder: Color {
        if prominent { return .clear }
        if destructive { return Theme.danger.opacity(0.45) }
        return hovering ? tint.opacity(0.4) : Theme.stroke
    }
}

// MARK: - Form section

struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(height: 1)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .fixedSize()
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(height: 1)
            }
            content
        }
    }
}

// MARK: - Form field

struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(Theme.textDim)
    }
}

struct ThemedTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.field)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            }
    }
}

struct ThemedSecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.field)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            }
    }
}
