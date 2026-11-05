import SwiftUI

// MARK: - Add local process

struct AddLocalProcessView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var command = ""
    @State private var workDir = ""
    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            content
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 640, height: 520)
        .background(Theme.background)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run a local command")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.text)
                Text("\(state.workspaceName) / \(state.dockerEnvironment?.name ?? "Docker") · Host process, not a container")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                dismiss()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let localError {
                    Text(localError)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                FormSection("Process") {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Name")
                        ThemedTextField(placeholder: "e.g. api", text: $name)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Command")
                        ThemedTextField(placeholder: "npm run dev", text: $command)
                        Text("Runs through sh -c, so pipes, redirects and shell syntax work.")
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Working directory")
                        ThemedTextField(placeholder: "~/Projects/my-app", text: $workDir)
                        Text("Optional. Supports a leading ~. Defaults to the app working directory.")
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                    }
                }

                Text("The process starts and stops with this workspace and keeps running while the app is open.")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("A local process runs on your Mac, not in Docker.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textDim)

            Spacer()

            ActionTextButton(
                title: isSaving ? "Adding…" : "Add process",
                systemName: "plus",
                prominent: true
            ) {
                Task { await save() }
            }
            .disabled(isSaving || !canSave)
            .opacity(isSaving || !canSave ? 0.5 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        localError = nil
        let ok = await state.addLocalProcess(
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            workDir: workDir.trimmingCharacters(in: .whitespaces)
        )
        isSaving = false
        if ok {
            dismiss()
        } else {
            localError = state.errorMessage
        }
    }
}
