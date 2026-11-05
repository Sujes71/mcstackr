import SwiftUI

/// The app's standard confirmation window.
///
/// Every destructive action confirms here instead of with the system
/// `confirmationDialog`, so the confirmation looks like every other window in
/// the app: same header, same close affordance, same footer buttons.
struct ConfirmSheet: View {
    let title: String
    let message: String
    var confirmTitle: String = "Delete"
    var destructive: Bool = true
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            content
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(minWidth: 300, idealWidth: 460, maxWidth: 520)
        .frame(minHeight: 210, idealHeight: 240)
        .background(Theme.background)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(destructive ? Theme.danger : Theme.info)
                .frame(width: 30, height: 30)
                .background(
                    (destructive ? Theme.danger : Theme.info).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.display(21))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                dismiss()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var content: some View {
        Text(message)
            .font(.system(size: 12.5, design: .rounded))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ActionTextButton(
                title: confirmTitle,
                systemName: destructive ? "trash" : "checkmark",
                prominent: !destructive,
                destructive: destructive
            ) {
                onConfirm()
                dismiss()
            }

            Spacer()

            ActionTextButton(title: "Cancel", systemName: nil) {
                dismiss()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}
