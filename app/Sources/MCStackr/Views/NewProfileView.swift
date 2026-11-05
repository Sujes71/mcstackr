import SwiftUI

struct NewProfileView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var environments = "local"
    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New profile")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text("A profile groups environments, services and operations for one product.")
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

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Environments")
                ThemedTextField(placeholder: "local, dev, staging", text: $environments)
                Text("Comma separated. Up to 5. Defaults to local.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
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
                    title: isSaving ? "Creating…" : "Create profile",
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
        let envs = parsedEnvironments()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        let created = await state.createProfile(
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespaces),
            environments: envs
        )
        if created {
            dismiss()
        } else {
            localError = state.errorMessage ?? "Could not create the profile."
            state.errorMessage = nil
        }
    }

    private func parsedEnvironments() -> [String] {
        var seen = Set<String>()
        let parsed = environments
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return parsed.isEmpty ? ["local"] : parsed
    }
}
