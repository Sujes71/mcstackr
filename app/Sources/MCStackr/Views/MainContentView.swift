import AppKit
import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var state: AppState

    @State private var showAddService = false
    @State private var logTarget: LogTarget?
    @State private var editingService: ServiceStatus?
    @State private var pendingDelete: ServiceStatus?
    @State private var showAddPortForward = false
    @State private var editingForward: PortForwardInfo?
    @State private var pendingDeleteForward: PortForwardInfo?

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(showAddService: $showAddService, showAddPortForward: $showAddPortForward)
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
        .sheet(item: $editingService) { service in
            ServiceEditorView(service: service)
                .environmentObject(state)
        }
        .sheet(isPresented: $showAddPortForward) {
            AddPortForwardView()
                .environmentObject(state)
        }
        .sheet(item: $editingForward) { forward in
            PortForwardEditorView(forward: forward)
                .environmentObject(state)
        }
        .confirmationDialog(
            pendingDeleteForward.map { "Delete \($0.name)?" } ?? "Delete port-forward?",
            isPresented: Binding(
                get: { pendingDeleteForward != nil },
                set: { if !$0 { pendingDeleteForward = nil } }
            ),
            presenting: pendingDeleteForward
        ) { forward in
            Button("Delete port-forward", role: .destructive) {
                Task { await state.deletePortForward(named: forward.name) }
                pendingDeleteForward = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteForward = nil }
        } message: { forward in
            Text("This stops the forward and removes it from \(state.workspaceName).")
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
                Task { await state.deleteService(named: service.name) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { service in
            Text("This removes \(service.name) from the workspace, deletes its container and its named volumes. Stored data is lost.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.selectedProfile == nil {
            NoWorkspaceView()
        } else if state.section == .portForward {
            PortForwardView(
                onAdd: { showAddPortForward = true },
                onEdit: { editingForward = $0 },
                onDelete: { pendingDeleteForward = $0 }
            )
        } else {
            dockerContent
        }
    }

    @ViewBuilder
    private var dockerContent: some View {
        if let env = state.dockerEnvironment, env.serviceCount == 0 {
            EmptyDockerView(onAdd: { showAddService = true })
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
                        columns: [GridItem(.adaptive(minimum: 320), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(state.services) { service in
                            ServiceCard(
                                service: service,
                                isBusy: state.runningAction != nil,
                                onOpen: { editingService = service },
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
    @Binding var showAddPortForward: Bool

    private var isDocker: Bool { state.section == .docker }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(state.section.title)
                        .font(Theme.display(28))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    if isDocker, state.hasRunningServices {
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
                    .lineLimit(1)
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

                if isDocker {
                    dockerActions
                } else {
                    portForwardActions
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(state.runningAction != nil)
            .opacity(state.runningAction != nil ? 0.55 : 1)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var dockerActions: some View {
        if state.selectedProfile != nil, let env = state.dockerEnvironment, env.serviceCount > 0 {
            if state.runningCount > 0 {
                ActionTextButton(title: "Restart all", systemName: "arrow.triangle.2.circlepath") {
                    Task { await state.performEnvAction("restart") }
                }
                ActionTextButton(title: "Stop all", systemName: "stop.fill") {
                    Task { await state.performEnvAction("stop") }
                }
            } else {
                ActionTextButton(title: "Start all", systemName: "play.fill", prominent: true) {
                    Task { await state.performEnvAction("up") }
                }
            }

            ActionIconButton(systemName: "plus", tint: Theme.accent, help: "Add service") {
                showAddService = true
            }
        } else if state.selectedProfile != nil {
            ActionTextButton(title: "Add service", systemName: "plus", prominent: true) {
                showAddService = true
            }
        }
    }

    @ViewBuilder
    private var portForwardActions: some View {
        if state.selectedProfile != nil, state.portForwardEnvironment != nil {
            let forwards = state.environmentDetail?.portForwards ?? []
            if !forwards.isEmpty {
                if forwards.contains(where: \.isRunning) || forwards.contains(where: \.isBusy) {
                    ActionTextButton(title: "Stop all", systemName: "stop.fill") {
                        Task { await state.stopAllPortForwards() }
                    }
                } else {
                    ActionTextButton(title: "Start all", systemName: "play.fill", prominent: true) {
                        Task { await state.startAllPortForwards() }
                    }
                }
            }

            ActionIconButton(systemName: "plus", tint: Theme.accent, help: "Add port-forward") {
                showAddPortForward = true
            }
        }
    }

    private var subtitle: String {
        guard let profile = state.selectedProfile else {
            return "Create a workspace to start defining your stack."
        }

        switch state.section {
        case .docker:
            let total = profile.environments.reduce(0) { $0 + $1.serviceCount }
            if let description = profile.description, !description.isEmpty {
                return "\(description) · \(total) services · \(state.runningCount) running"
            }
            return "\(total) services · \(state.runningCount) running"
        case .portForward:
            let forwards = state.portForwardCount
            if let description = profile.description, !description.isEmpty {
                return "\(description) · \(forwards) port-forwards"
            }
            return "\(forwards) port-forwards · Kubernetes and cloud workloads"
        }
    }
}

// MARK: - Port forwards

private struct PortForwardView: View {
    @EnvironmentObject private var state: AppState
    let onAdd: () -> Void
    let onEdit: (PortForwardInfo) -> Void
    let onDelete: (PortForwardInfo) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let detail = state.environmentDetail {
                    if detail.portForwards.isEmpty {
                        PortForwardEmptyView(environment: detail.name, onAdd: onAdd)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PORT-FORWARDS")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .tracking(1.1)
                                .foregroundStyle(Theme.textDim)

                            ForEach(detail.portForwards) { forward in
                                PortForwardRow(
                                    forward: forward,
                                    isBusy: state.runningAction != nil,
                                    onToggle: {
                                        if forward.isRunning || forward.isBusy {
                                            Task { await state.stopPortForward(forward) }
                                        } else {
                                            Task { await state.startPortForward(forward) }
                                        }
                                    },
                                    onOpen: { onEdit(forward) },
                                    onDelete: { onDelete(forward) }
                                )
                            }
                        }
                    }

                    if !detail.localProcesses.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("LOCAL PROCESSES")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .tracking(1.1)
                                .foregroundStyle(Theme.textDim)
                                .padding(.top, 6)

                            ForEach(detail.localProcesses) { process in
                                LocalProcessRow(process: process)
                            }
                        }
                    }
                } else if state.portForwardEnvironment == nil {
                    PortForwardEmptyView(environment: nil, onAdd: nil)
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.accent)
                        Text("Loading port-forward environment…")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            Task { await state.refreshEnvironmentDetail() }
        }
    }
}

private struct PortForwardEmptyView: View {
    let environment: String?
    let onAdd: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text(environment == nil ? "No port-forward environment" : "No port forwards yet")
                .font(Theme.title(18))
                .foregroundStyle(Theme.text)

            Text(environment == nil
                 ? "This workspace has no environment besides Docker."
                 : "Discover a Kubernetes service and forward one of its ports to localhost.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            if let onAdd {
                ActionTextButton(title: "Add port-forward", systemName: "plus", prominent: true) {
                    onAdd()
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

private struct PortForwardRow: View {
    let forward: PortForwardInfo
    let isBusy: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var stateColor: Color {
        switch forward.state.lowercased() {
        case "running": return Theme.running
        case "starting": return Theme.warning
        case "failed": return Theme.danger
        default: return Theme.textDim
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(state: forward.state)

            Image(systemName: "network")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.info)
                .frame(width: 28, height: 28)
                .background(Theme.info.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(forward.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text(forward.state.uppercased())
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(stateColor)
                }
                Text("\(forward.k8sContext) · \(forward.k8sNamespace)/\(forward.k8sService)")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                if let error = forward.error, !error.isEmpty {
                    Text(error)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text("\(forward.localPort) → \(forward.remotePort)")
                .font(Theme.mono)
                .foregroundStyle(Theme.textMuted)

            ActionIconButton(
                systemName: forward.isRunning || forward.isBusy ? "stop.fill" : "play.fill",
                tint: forward.isRunning || forward.isBusy ? Theme.warning : Theme.running,
                help: forward.isRunning || forward.isBusy ? "Stop" : "Start"
            ) {
                onToggle()
            }
            .disabled(isBusy)
        }
        .padding(13)
        .cardStyle()
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .contextMenu {
            Button(forward.isRunning || forward.isBusy ? "Stop" : "Start") { onToggle() }
            Button("Edit local port…") { onOpen() }
            Divider()
            Button("Delete port-forward…", role: .destructive) { onDelete() }
        }
    }
}

private struct LocalProcessRow: View {
    let process: LocalProcessInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.violet)
                .frame(width: 28, height: 28)
                .background(Theme.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(process.command)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(13)
        .cardStyle()
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

private struct NoWorkspaceView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text("No workspace yet")
                .font(Theme.title(18))
                .foregroundStyle(Theme.text)

            Text("Use the workspace menu in the sidebar to create one.\nWorkspaces share the same ~/.stackr config as the CLI.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct EmptyDockerView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text("No services yet")
                .font(Theme.title(18))
                .foregroundStyle(Theme.text)

            Text("Add a service to this workspace to start building the Docker stack.")
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
    let onOpen: () -> Void
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

                ActionIconButton(systemName: "text.alignleft", tint: accent, help: "View logs", action: onLogs)
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
                        ActionIconButton(systemName: "arrow.clockwise", tint: Theme.warning, help: "Restart") {
                            Task { await state.performServiceAction("restart", service: service) }
                        }
                        ActionIconButton(systemName: "stop.fill", tint: Theme.danger, help: "Stop") {
                            Task { await state.performServiceAction("stop", service: service) }
                        }
                    } else {
                        ActionIconButton(systemName: "play.fill", tint: Theme.accent, help: "Start") {
                            Task { await state.performServiceAction("up", service: service) }
                        }
                    }

                    ActionIconButton(systemName: "slider.horizontal.3", tint: Theme.textMuted, help: "Configure", action: onOpen)
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.5 : 1)
            }
        }
        .padding(16)
        .frame(minHeight: 168)
        .cardStyle(highlighted: hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("View logs", action: onLogs)
            Button("Configure…", action: onOpen)
            Divider()
            Button("Delete service…", role: .destructive, action: onDelete)
        }
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
