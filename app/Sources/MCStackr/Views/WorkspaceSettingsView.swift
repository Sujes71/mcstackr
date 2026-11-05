import SwiftUI

struct WorkspaceSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var description = ""
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var localError: String?

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

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Workspace")
                        HStack(spacing: 9) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Text(state.workspaceName)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Theme.stroke, lineWidth: 1)
                        }
                        Text("Workspace names are limited to 24 characters.")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Description")
                        ThemedTextField(placeholder: "Optional short description", text: $description)
                    }

                    if let profile = state.selectedProfile {
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(text: "Environments")
                            ForEach(profile.environments) { environment in
                                HStack(spacing: 9) {
                                    Image(systemName: environment.name == "local"
                                          ? "shippingbox.fill"
                                          : "arrow.left.arrow.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.textMuted)
                                        .frame(width: 16)
                                    Text(environment.name)
                                        .font(Theme.monoSmall)
                                        .foregroundStyle(Theme.text)
                                    Spacer()
                                    Text("\(environment.serviceCount) services")
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(Theme.textDim)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                        }
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 520, height: 520)
        .background(Theme.background)
        .task {
            description = state.selectedProfile?.description ?? ""
        }
        .confirmationDialog(
            "Delete \(state.workspaceName)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete workspace", role: .destructive) {
                Task { await delete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops its containers and removes its config from ~/.stackr. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Workspace settings")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.text)
                Text("\(state.workspaceName) · shared Stackr config")
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
            ActionTextButton(title: "Delete workspace", systemName: "trash", destructive: true) {
                confirmDelete = true
            }
            .disabled(isSaving)

            Spacer()

            ActionTextButton(
                title: isSaving ? "Saving…" : "Save changes",
                systemName: "checkmark",
                prominent: true
            ) {
                Task { await save() }
            }
            .disabled(isSaving)
            .opacity(isSaving ? 0.5 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func save() async {
        localError = nil
        isSaving = true
        defer { isSaving = false }
        if await state.updateWorkspaceDescription(description.trimmingCharacters(in: .whitespaces)) {
            dismiss()
        } else {
            localError = state.errorMessage ?? "Could not save the workspace."
            state.errorMessage = nil
        }
    }

    private func delete() async {
        isSaving = true
        defer { isSaving = false }
        if await state.deleteWorkspace() {
            dismiss()
        } else {
            localError = state.errorMessage ?? "Could not delete the workspace."
            state.errorMessage = nil
        }
    }
}
