import SwiftUI

/// Notice for a finished DB operation. It shows up in the main window while
/// the user works elsewhere, so an operation that outlived its sheet is never
/// silently lost.
struct DBNoticeBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let notice = state.dbNotice {
            noticeCard(notice)
        }
    }

    private func noticeCard(_ notice: DBJobNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(notice.succeeded ? Theme.running : Theme.danger)

                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)

                    HStack(spacing: 6) {
                        Text(notice.service)
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.textMuted)
                        if !notice.syncEnv.isEmpty {
                            Text("·")
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.textDim)
                            Text(notice.syncEnv)
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }

                    if !notice.detail.isEmpty {
                        Text(notice.detail)
                            .font(Theme.monoSmall)
                            .foregroundStyle(notice.succeeded ? Theme.textDim : Theme.danger)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    state.dismissDBNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke((notice.succeeded ? Theme.running : Theme.danger).opacity(0.45), lineWidth: 1)
            }
            .padding(.top, 12)
            .padding(.horizontal, 18)
            .frame(maxWidth: 520)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: notice.id) {
                // A success can be read at a glance; an error needs more time.
                let seconds: UInt64 = notice.succeeded ? 8 : 16
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if state.dbNotice?.id == notice.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        state.dismissDBNotice()
                    }
                }
            }
    }
}
