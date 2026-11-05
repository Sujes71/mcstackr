import SwiftUI

// MARK: - Add / edit sync environment

struct SyncEnvWizard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let service: ServiceStatus
    let dbType: String
    let existing: DBSyncEnv?
    let onSaved: (DBOpsInfo, String) -> Void
    let onDeleted: (DBOpsInfo) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var password = ""
    @State private var database = ""
    @State private var authDb = ""
    @State private var toolImage = ""
    @State private var passwordDirty = false
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var localError: String?
    @State private var loaded = false

    private var isEdit: Bool { existing != nil }
    private var isMongo: Bool { dbType == "mongo" }

    private var defaultPort: String {
        switch dbType {
        case "mongo": return "27017"
        case "mysql": return "3306"
        case "mssql": return "1433"
        default: return "5432"
        }
    }

    private var defaultToolImage: String {
        switch dbType {
        case "postgres": return "postgres:17"
        case "mongo": return "mongo:7.0"
        case "mysql": return "mysql:9.0"
        case "mssql": return "mcr.microsoft.com/mssql-tools:latest"
        default: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            content
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 640, height: 640)
        .background(Theme.background)
        .onAppear(perform: prefill)
        .sheet(isPresented: $confirmDelete) {
            ConfirmSheet(
                title: "Delete sync environment “\(existing?.name ?? "")”?",
                message: "This removes it from the config. Its dumps stay on disk.",
                confirmTitle: "Delete environment"
            ) {
                Task { await deleteEnv() }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(isEdit ? "Edit sync environment" : "Add sync environment")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    TechBadge(text: dbType, color: Theme.info)
                }
                Text("\(service.name) · \(state.workspaceName) / Docker")
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
                ActionTextButton(title: "Delete sync environment", systemName: "trash", destructive: true) {
                    confirmDelete = true
                }
                .disabled(isSaving)
            } else {
                Text("The password is encrypted in ~/.stackr/config.yaml.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            ActionTextButton(title: "Cancel", systemName: nil) {
                dismiss()
            }

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

                FormSection("Identity") {
                    field("Name", placeholder: "staging, prod, dev…", text: $name)
                }

                FormSection("Connection") {
                    field("Host", placeholder: "db.example.com", text: $host)
                    HStack(spacing: 12) {
                        field("Port", placeholder: defaultPort, text: $port, width: 110)
                        field("Database", placeholder: "database", text: $database)
                    }
                    field("User", placeholder: "username", text: $user)
                    passwordField
                }

                FormSection("Options") {
                    if isMongo {
                        field("Auth database", placeholder: "admin (auth db)", text: $authDb)
                    }
                    field("Tool image", placeholder: defaultToolImage, text: $toolImage)
                    Text("The tool image runs the dump and restore commands; leave it empty to use the default for \(dbType).")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>, width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            if let width {
                ThemedTextField(placeholder: placeholder, text: text)
                    .frame(width: width)
            } else {
                ThemedTextField(placeholder: placeholder, text: text)
            }
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Password")
            ThemedSecureField(placeholder: isEdit && !passwordDirty ? "unchanged" : "password (optional)", text: $password)
                .onChange(of: password) { _, _ in passwordDirty = true }
            if isEdit && passwordDirty && password.isEmpty {
                Text("Saving now clears the stored password.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    // MARK: State

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && !database.trimmingCharacters(in: .whitespaces).isEmpty
            && validPort
    }

    private var validPort: Bool {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        guard let value = Int(trimmed) else { return false }
        return (1...65535).contains(value)
    }

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            name = existing.name
            host = existing.host
            port = existing.port
            database = existing.database
            user = existing.user
            authDb = existing.authDb ?? ""
            toolImage = existing.toolImage == defaultToolImage ? "" : existing.toolImage
        } else {
            port = defaultPort
            toolImage = service.fullImage
        }
    }

    private func deleteEnv() async {
        guard let existing else { return }
        localError = nil
        isSaving = true
        defer { isSaving = false }
        guard let info = await state.deleteSyncEnv(service: service.name, name: existing.name) else {
            localError = state.errorMessage ?? "Could not delete the sync environment."
            return
        }
        onDeleted(info)
        dismiss()
    }

    private func save() async {
        localError = nil
        isSaving = true
        defer { isSaving = false }

        var draft = SyncEnvDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: port.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            password: nil,
            database: database.trimmingCharacters(in: .whitespaces),
            authDb: authDb.trimmingCharacters(in: .whitespaces),
            toolImage: toolImage.trimmingCharacters(in: .whitespaces)
        )
        if !isEdit || passwordDirty {
            draft.password = password
        }

        guard let info = await state.saveSyncEnv(
            service: service.name,
            originalName: existing?.name,
            draft: draft
        ) else {
            localError = state.errorMessage ?? "Could not save the sync environment."
            return
        }
        onSaved(info, draft.name)
        dismiss()
    }
}
