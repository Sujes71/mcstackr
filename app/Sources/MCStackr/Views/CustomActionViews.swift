import SwiftUI

// MARK: - Custom action helpers

extension String {
    /// Placeholders that the engine fills without asking the user.
    static let customActionAutoVars: Set<String> = [
        "host", "user", "password", "database", "db", "env",
        "local_user", "local_pass", "local_db",
        "se_db", "se_user", "se_password",
    ]

    /// User-provided placeholders in a custom action command, in order of
    /// first appearance and without duplicates.
    var customActionParams: [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{([a-zA-Z_][a-zA-Z0-9_]*)\}"#) else {
            return []
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        var seen: Set<String> = []
        var params: [String] = []
        for match in regex.matches(in: self, range: range) {
            guard match.numberOfRanges > 1, let nameRange = Range(match.range(at: 1), in: self) else { continue }
            let name = String(self[nameRange])
            guard !Self.customActionAutoVars.contains(name), !seen.contains(name) else { continue }
            seen.insert(name)
            params.append(name)
        }
        return params
    }
}

// MARK: - Add / edit custom action

struct CustomActionWizard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let service: ServiceStatus
    let syncEnv: DBSyncEnv
    let existing: CustomAction?
    let onSaved: (DBOpsInfo) -> Void
    let onDeleted: (DBOpsInfo) -> Void

    @State private var name = ""
    @State private var command = ""
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var localError: String?
    @State private var loaded = false

    private var isEdit: Bool { existing != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            content
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(minWidth: 480, idealWidth: 600, maxWidth: 680)
        .frame(minHeight: 340, idealHeight: 480, maxHeight: 560)
        .background(Theme.background)
        .onAppear(perform: prefill)
        .sheet(isPresented: $confirmDelete) {
            ConfirmSheet(
                title: "Delete action “\(existing?.name ?? "")”?",
                message: "This removes the action from the sync environment. It does not touch the database.",
                confirmTitle: "Delete"
            ) {
                Task { await deleteAction() }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(isEdit ? "Edit action" : "Add action")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    TechBadge(text: syncEnv.name, color: Theme.info)
                }
                Text("\(service.name) · runs inside the container")
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

    private var footer: some View {
        HStack(spacing: 10) {
            if isEdit {
                ActionTextButton(title: "Delete action", systemName: "trash", destructive: true) {
                    confirmDelete = true
                }
                .disabled(isSaving)
            } else {
                Text("The command runs with sh inside the service container.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            ActionTextButton(
                title: isSaving ? "Saving…" : (isEdit ? "Save" : "Add"),
                systemName: isEdit ? "checkmark" : "plus",
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

    // MARK: Body

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let localError {
                    Text(localError)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                FormSection("Action") {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Name")
                        ThemedTextField(placeholder: "reset tables, seed users…", text: $name)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Command")
                        commandEditor
                        Text("Raw SQL is wrapped in the matching client. Prefix with sh, psql, mysql, mongo or sqlcmd to run it verbatim.")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                FormSection("Variables") {
                    Text("{host} {user} {password} {database} {env} {local_user} {local_pass} {local_db} {se_db} {se_user} {se_password}")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Any other {name} is asked for right before the action runs.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    private var commandEditor: some View {
        TextEditor(text: $command)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.text)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 150)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            }
    }

    // MARK: Actions

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            name = existing.name
            command = existing.command
        }
    }

    private func save() async {
        localError = nil
        isSaving = true
        defer { isSaving = false }

        let draft = CustomActionDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let info = await state.saveCustomAction(
            service: service.name,
            syncEnv: syncEnv.name,
            originalName: existing?.name,
            draft: draft
        ) else {
            localError = state.errorMessage ?? "Could not save the action."
            return
        }
        onSaved(info)
        dismiss()
    }

    private func deleteAction() async {
        guard let existing else { return }
        localError = nil
        isSaving = true
        defer { isSaving = false }
        guard let info = await state.deleteCustomAction(
            service: service.name,
            syncEnv: syncEnv.name,
            name: existing.name
        ) else {
            localError = state.errorMessage ?? "Could not delete the action."
            return
        }
        onDeleted(info)
        dismiss()
    }
}

// MARK: - Parameters prompt

struct CustomActionParamsView: View {
    let action: CustomAction
    let params: [String]
    let context: String
    let onRun: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    private var canRun: Bool {
        params.allSatisfy { !(values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run \(action.name)")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text("Fill the variables, then run it inside \(context).")
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

            Divider().overlay(Theme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(params, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: name)
                            ThemedTextField(placeholder: name, text: binding(for: name))
                        }
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Theme.stroke)

            HStack(spacing: 10) {
                Text(action.command)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ActionTextButton(title: "Run", systemName: "play.fill", prominent: true) {
                    onRun(values.mapValues { $0.trimmingCharacters(in: .whitespaces) })
                    dismiss()
                }
                .disabled(!canRun)
                .opacity(canRun ? 1 : 0.5)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 380, idealWidth: 480, maxWidth: 520)
        .frame(minHeight: 260, idealHeight: 340, maxHeight: 420)
        .background(Theme.background)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}
