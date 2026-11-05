import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            AppBackground()

            switch state.bootPhase {
            case .ready:
                HStack(spacing: 0) {
                    SidebarView()
                    Rectangle()
                        .fill(Theme.stroke)
                        .frame(width: 1)
                    MainContentView()
                }
            case .failed(let message):
                BootView(message: message, isFailure: true)
            default:
                BootView(message: nil, isFailure: false)
            }

            if let running = state.runningAction {
                VStack {
                    Spacer()
                    RunningPill(text: running)
                        .padding(.bottom, 22)
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
        .preferredColorScheme(.dark)
        .task { await state.bootstrap() }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                ErrorBanner()
                DBNoticeBanner()
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.dbNotice?.id)
    }
}

// MARK: - Boot

private struct BootView: View {
    @EnvironmentObject private var state: AppState
    let message: String?
    let isFailure: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.info],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 92, height: 92)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 30)

                Text("M")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.accentInk)
            }

            VStack(spacing: 8) {
                Text("MCSTACKR")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .tracking(6)
                    .foregroundStyle(Theme.text)

                Text(isFailure ? "ENGINE FAILED" : "STARTING LOCAL ENGINE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(isFailure ? Theme.danger : Theme.textDim)
            }

            if let message {
                Text(message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                ActionTextButton(title: "Try again", systemName: "arrow.clockwise", prominent: true) {
                    Task { await state.retryBootstrap() }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .scaleEffect(0.9)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RunningPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accentInk)
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(Theme.accentInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.accent, in: Capsule())
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

// MARK: - Error banner

private struct ErrorBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let message = state.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(3)
                Spacer(minLength: 8)
                Button {
                    state.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.danger.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.danger.opacity(0.4), lineWidth: 1)
            }
            .padding(.top, 12)
            .padding(.horizontal, 18)
            .frame(maxWidth: 720)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
