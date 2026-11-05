import SwiftUI

struct NewWorkspaceView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New workspace")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text("A workspace is one project: its Docker stack and its AWS workloads.")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                    dismiss()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Name")
                ThemedTextField(placeholder: "e.g. Globick", text: $name)
                Text("Letters, numbers, _, . and - only.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Description")
                ThemedTextField(placeholder: "Optional short description", text: $description)
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.running)
                Text("Docker and AWS sections are created automatically.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            }

            if let localError {
                Text(localError)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                ActionTextButton(title: "Cancel") { dismiss() }
                ActionTextButton(
                    title: isSaving ? "Creating…" : "Create workspace",
                    systemName: "plus",
                    prominent: true
                ) {
                    Task { await create() }
                }
                .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(Theme.background)
    }

    private func create() async {
        localError = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        let created = await state.createWorkspace(
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespaces)
        )
        if created {
            dismiss()
        } else {
            localError = state.errorMessage ?? "Could not create the workspace."
            state.errorMessage = nil
        }
    }
}
