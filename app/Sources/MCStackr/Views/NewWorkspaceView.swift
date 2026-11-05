import SwiftUI

struct NewWorkspaceView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var localError: String?

    private let workspaceNameLimit = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let localError {
                        Text(localError)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    FormSection("Workspace") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                FieldLabel(text: "Name")
                                Spacer()
                                Text("\(name.count)/\(workspaceNameLimit)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(name.count >= workspaceNameLimit ? Theme.danger : Theme.textDim)
                            }
                            ThemedTextField(placeholder: "e.g. Globick", text: $name)
                                .onChange(of: name) { _, value in
                                    if value.count > workspaceNameLimit {
                                        name = String(value.prefix(workspaceNameLimit))
                                    }
                                }
                            Text("Letters, numbers, _, . and - only. Max \(workspaceNameLimit) characters.")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textDim)
                        }
                    }

                    FormSection("Details") {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: "Description")
                            ThemedTextField(placeholder: "Optional short description", text: $description)
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.running)
                        Text("Docker and Port Forwards sections are created automatically.")
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
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 560)
        .background(Theme.background)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New workspace")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.text)
                Text("A workspace is one project: its Docker stack and its port-forward environment.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
            }

            Spacer()

            ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                dismiss()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
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
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
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
