import SwiftUI

struct ServiceEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let service: ServiceStatus

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var image = ""
    @State private var tag = ""
    @State private var ports: [PortConfig] = []
    @State private var envVars: [EnvVarConfig] = []
    @State private var revealSecrets = false
    @State private var confirmDelete = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 640, height: 660)
        .background(Theme.background)
        .task { await load() }
        .confirmationDialog(
            "Delete \(service.name)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete service", role: .destructive) {
                Task { await delete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(service.name) from the workspace config. Running containers and volumes are not deleted.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(service.name)
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let db = service.dbType {
                        TechBadge(text: db, color: dbColor(db))
                    }
                }
                Text("Configure image, ports and environment variables.")
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

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let localError {
                    Text(localError)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("IMAGE") {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: "Image")
                            ThemedTextField(placeholder: "e.g. postgres", text: $image)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: "Tag")
                            ThemedTextField(placeholder: "e.g. 16-alpine", text: $tag)
                                .frame(width: 170)
                        }
                    }

                    if let db = service.dbType, db.lowercased().contains("postgres") || db.lowercased().contains("mysql") || db.lowercased().contains("mariadb") || db.lowercased().contains("mongo") {
                        Text("Database credentials are defined as environment variables below.")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                    }
                }

                section("PORTS") {
                    VStack(spacing: 8) {
                        ForEach($ports.indices, id: \.self) { index in
                            HStack(spacing: 10) {
                                ThemedTextField(placeholder: "Host", text: $ports[index].host)
                                    .frame(width: 130)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.textDim)
                                ThemedTextField(placeholder: "Container", text: $ports[index].container)
                                    .frame(width: 130)
                                Spacer()
                                ActionIconButton(systemName: "minus.circle", tint: Theme.danger, help: "Remove port") {
                                    ports.remove(at: index)
                                }
                            }
                        }

                        ActionTextButton(title: "Add port", systemName: "plus") {
                            ports.append(PortConfig(host: "", container: ""))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                section("ENVIRONMENT VARIABLES") {
                    HStack {
                        Text("Values are stored in ~/.stackr/config.yaml")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                        Spacer()
                        Button {
                            revealSecrets.toggle()
                        } label: {
                            Text(revealSecrets ? "Hide secrets" : "Reveal secrets")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.info)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(spacing: 8) {
                        ForEach($envVars.indices, id: \.self) { index in
                            HStack(spacing: 10) {
                                ThemedTextField(placeholder: "KEY", text: $envVars[index].key)
                                    .frame(width: 210)
                                if isSecretKey(envVars[index].key), !revealSecrets {
                                    ThemedSecureField(placeholder: "value", text: $envVars[index].value)
                                } else {
                                    ThemedTextField(placeholder: "value", text: $envVars[index].value)
                                }
                                ActionIconButton(systemName: "minus.circle", tint: Theme.danger, help: "Remove variable") {
                                    envVars.remove(at: index)
                                }
                            }
                        }

                        ActionTextButton(title: "Add variable", systemName: "plus") {
                            envVars.append(EnvVarConfig(key: "", value: ""))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ActionTextButton(title: "Delete", systemName: "trash", tint: Theme.danger) {
                confirmDelete = true
            }
            .disabled(isSaving)

            if service.isRunning {
                Text("Changes apply on the next restart.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            ActionTextButton(title: "Cancel") { dismiss() }
            ActionTextButton(
                title: isSaving ? "Saving…" : "Save changes",
                systemName: "checkmark",
                prominent: true
            ) {
                Task { await save() }
            }
            .disabled(isSaving || image.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(isSaving || image.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(Theme.textDim)
            content()
        }
    }

    private func isSecretKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return ["PASSWORD", "SECRET", "TOKEN", "API_KEY", "PRIVATE"].contains { upper.contains($0) }
    }

    private func load() async {
        guard let config = await state.serviceConfig(named: service.name) else {
            localError = state.errorMessage ?? "Could not load the service config."
            state.errorMessage = nil
            isLoading = false
            return
        }
        image = config.image
        tag = config.tag
        ports = config.ports
        envVars = config.envVars
        isLoading = false
    }

    private func save() async {
        localError = nil
        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        guard !trimmedImage.isEmpty else {
            localError = "Image is required."
            return
        }

        isSaving = true
        defer { isSaving = false }

        let cleanedPorts = ports.filter {
            !$0.host.trimmingCharacters(in: .whitespaces).isEmpty &&
            !$0.container.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let cleanedEnvVars = envVars.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }

        let saved = await state.updateService(
            named: service.name,
            image: trimmedImage,
            tag: tag.trimmingCharacters(in: .whitespaces),
            ports: cleanedPorts,
            envVars: cleanedEnvVars
        )
        if saved {
            dismiss()
        } else {
            localError = state.errorMessage ?? "Could not save the service."
            state.errorMessage = nil
        }
    }

    private func delete() async {
        isSaving = true
        defer { isSaving = false }
        if await state.deleteService(named: service.name) {
            dismiss()
        } else {
            localError = state.errorMessage ?? "Could not delete the service."
            state.errorMessage = nil
        }
    }
}
