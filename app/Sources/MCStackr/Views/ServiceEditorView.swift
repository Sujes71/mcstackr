import SwiftUI

struct ServiceEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let service: ServiceStatus

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var name = ""
    @State private var image = ""
    @State private var tag = ""
    @State private var ports: [PortConfig] = []
    @State private var envVars: [EnvVarConfig] = []
    @State private var volumes: [VolumeConfig] = []
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let localError {
                            Text(localError)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ServiceConfigForm(
                            showName: false,
                            name: $name,
                            image: $image,
                            tag: $tag,
                            ports: $ports,
                            envVars: $envVars,
                            volumes: $volumes
                        )
                    }
                    .padding(22)
                }
                .scrollIndicators(.hidden)
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 660, height: 680)
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
            Text("This removes \(service.name) from the workspace, deletes its container and its named volumes. Stored data is lost.")
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
                Text("Configure image, ports, environment variables and volumes.")
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
            ActionTextButton(title: "Delete service", systemName: "trash", destructive: true) {
                confirmDelete = true
            }
            .disabled(isSaving)

            if service.isRunning {
                Text("Changes apply on the next restart.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

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

    private func load() async {
        guard let config = await state.serviceConfig(named: service.name) else {
            localError = state.errorMessage ?? "Could not load the service config."
            state.errorMessage = nil
            isLoading = false
            return
        }
        name = config.name
        image = config.image
        tag = config.tag
        ports = config.ports
        envVars = config.envVars
        volumes = config.volumes
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

        let cleanPorts = ports.filter {
            !$0.host.trimmingCharacters(in: .whitespaces).isEmpty &&
            !$0.container.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let cleanEnvVars = envVars.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        let cleanVolumes = volumes.filter { !$0.target.trimmingCharacters(in: .whitespaces).isEmpty }

        let saved = await state.updateService(
            named: service.name,
            image: trimmedImage,
            tag: tag.trimmingCharacters(in: .whitespaces),
            ports: cleanPorts,
            envVars: cleanEnvVars,
            volumes: cleanVolumes
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
