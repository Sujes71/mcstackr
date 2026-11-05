import AppKit
import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var state: AppState

    @State private var showAddService = false
    @State private var logTarget: LogTarget?
    @State private var pendingDelete: ServiceStatus?

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(showAddService: $showAddService)
            Divider().overlay(Theme.stroke)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 34)
        .sheet(isPresented: $showAddService) {
            AddServiceView()
                .environmentObject(state)
        }
        .sheet(item: $logTarget) { target in
            LogsSheet(title: target.title, service: target.service)
                .environmentObject(state)
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.name)?" } ?? "Delete service?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { service in
            Button("Delete service", role: .destructive) {
                Task { await state.deleteService(service) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { service in
            Text("This removes \(service.name) from the profile config. It does not delete running containers or volumes.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.selectedProfile == nil {
            NoProfileView()
        } else if let env = state.selectedEnvironment, env.serviceCount == 0 {
            EmptyEnvironmentView(
                envName: env.name,
                onAdd: { showAddService = true }
            )
        } else if state.services.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
                Text("Loading services…")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    if !state.dockerAvailable {
                        DockerOfflineBanner()
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(state.services) { service in
                            ServiceCard(
                                service: service,
                                isBusy: state.runningAction != nil,
                                onLogs: {
                                    logTarget = LogTarget(
                                        title: "\(service.name) · logs",
                                        service: service.name
                                    )
                                },
                                onDelete: { pendingDelete = service }
                            )
                        }
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct LogTarget: Identifiable {
    let id = UUID()
    let title: String
    let service: String?
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showAddService: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(state.selectedProfile?.name ?? "Stackr")
                            .font(Theme.display(28))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)

                        if state.hasRunningServices {
                            Text("LIVE")
                                .font(.system(size: 8.5, weight: .black, design: .rounded))
                                .tracking(1.2)
                                .foregroundStyle(Theme.accentInk)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                        }
                    }

                    Text(subtitle)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    ActionIconButton(
                        systemName: "arrow.clockwise",
                        tint: Theme.info,
                        help: "Refresh"
                    ) {
                        Task { await state.refreshAll() }
                    }
                    .disabled(state.isRefreshing)

                    if let env = state.selectedEnvironment, env.serviceCount > 0 {
                        ActionTextButton(
                            title: "Start all",
                            systemName: "play.fill",
                            prominent: true
                        ) {
                            Task { await state.performEnvAction("up") }
                        }

                        ActionTextButton(title: "Restart", systemName: "arrow.triangle.2.circlepath") {
                            Task { await state.performEnvAction("restart") }
                        }

                        ActionTextButton(title: "Stop", systemName: "stop.fill") {
                            Task { await state.performEnvAction("down") }
                        }

                        ActionTextButton(title: "Service", systemName: "plus") {
                            showAddService = true
                        }
                    } else if state.selectedProfile != nil {
                        ActionTextButton(title: "Add service", systemName: "plus", prominent: true) {
                            showAddService = true
                        }
                    }
                }
                .disabled(state.runningAction != nil)
                .opacity(state.runningAction != nil ? 0.55 : 1)
            }

            if let profile = state.selectedProfile, profile.environments.count > 0 {
                EnvironmentChips(profile: profile)
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
    }

    private var subtitle: String {
        guard let profile = state.selectedProfile else {
            return "Create your first profile to group environments, services and operations."
        }
        if let description = profile.description, !description.isEmpty {
            return description
        }
        let total = profile.environments.reduce(0) { $0 + $1.serviceCount }
        return "\(profile.environments.count) environments · \(total) services · \(state.runningCount) running"
    }
}

private struct EnvironmentChips: View {
    @EnvironmentObject private var state: AppState
    let profile: Profile

    var body: some View {
        HStack(spacing: 7) {
            ForEach(profile.environments) { env in
                let selected = state.selectedEnvName == env.name
                Button {
                    state.select(profile: profile, env: env)
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(selected ? Theme.accent : Theme.textDim)
                            .frame(width: 5, height: 5)
                        Text(env.name)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        if env.serviceCount > 0 {
                            Text("\(env.serviceCount)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(selected ? Theme.accentInk : Theme.textDim)
                        }
                    }
                    .foregroundStyle(selected ? Theme.accentInk : Theme.textMuted)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(selected ? Theme.accent : Theme.field)
                    )
                    .overlay {
                        if !selected {
                            Capsule().stroke(Theme.stroke, lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Banners and empty states

private struct DockerOfflineBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Docker is not running")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(state.status?.error ?? "Start the Docker daemon to manage containers.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            ActionTextButton(title: "Start Docker", systemName: "power", tint: Theme.warning) {
                Task { await state.launchDocker() }
            }
        }
        .padding(14)
        .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.warning.opacity(0.25), lineWidth: 1)
        }
    }
}

private struct NoProfileView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text("No profiles yet")
                .font(Theme.title(18))
                .foregroundStyle(Theme.text)

            Text("Use the + button in the sidebar to create a profile.\nProfiles share the same ~/.stackr config as the CLI.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct EmptyEnvironmentView: View {
    let envName: String
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text("\(envName) is empty")
                .font(Theme.title(18))
                .foregroundStyle(Theme.text)

            Text("Add a service to this environment to start building the stack.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)

            ActionTextButton(title: "Add service", systemName: "plus", prominent: true, action: onAdd)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Service card

private struct ServiceCard: View {
    @EnvironmentObject private var state: AppState

    let service: ServiceStatus
    let isBusy: Bool
    let onLogs: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var accent: Color {
        if let db = service.dbType { return dbColor(db) }
        return Theme.info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 9) {
                StatusDot(state: service.state)
                Text(service.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                if let db = service.dbType {
                    TechBadge(text: db, color: dbColor(db))
                }

                Spacer(minLength: 4)

                Menu {
                    Button("View logs", action: onLogs)
                    Button("Copy image") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(service.fullImage, forType: .string)
                    }
                    Divider()
                    Button("Delete service", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Text(service.fullImage)
                .font(Theme.mono)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            if !(service.ports ?? "").isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(service.ports ?? "")
                        .font(Theme.monoSmall)
                }
                .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                StatePill(state: service.state)

                if let health = service.health, !health.isEmpty {
                    TechBadge(text: health, color: health == "healthy" ? Theme.running : Theme.warning)
                }

                Spacer()

                HStack(spacing: 6) {
                    if service.isRunning {
                        ActionIconButton(systemName: "stop.fill", tint: Theme.danger, help: "Stop") {
                            Task { await state.performServiceAction("stop", service: service) }
                        }
                        ActionIconButton(systemName: "arrow.clockwise", tint: Theme.warning, help: "Restart") {
                            Task { await state.performServiceAction("restart", service: service) }
                        }
                    } else {
                        ActionIconButton(systemName: "play.fill", tint: Theme.accent, help: "Start") {
                            Task { await state.performServiceAction("up", service: service) }
                        }
                    }

                    ActionIconButton(systemName: "text.alignleft", tint: accent, help: "Logs", action: onLogs)
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.5 : 1)
            }
        }
        .padding(16)
        .frame(minHeight: 168)
        .cardStyle(highlighted: hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: onLogs)
        .onHover { value in
            withAnimation(.easeOut(duration: 0.12)) { hovering = value }
        }
    }
}

func dbColor(_ dbType: String) -> Color {
    switch dbType.lowercased() {
    case "postgres": return Theme.info
    case "mysql", "mariadb": return Theme.warning
    case "mongo": return Theme.running
    case "mssql": return Theme.violet
    case "oracle": return Theme.danger
    default: return Theme.info
    }
}
