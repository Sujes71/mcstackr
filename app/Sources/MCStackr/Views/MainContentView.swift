import AppKit
import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var state: AppState

    @State private var showAddService = false
    @State private var dbOpsService: ServiceStatus?
    @State private var deleteTarget: DeleteTarget?
    @State private var logTarget: LogTarget?
    @State private var editingService: ServiceStatus?
    @State private var showAddPortForward = false
    @State private var editingForward: PortForwardInfo?

    /// Every delete in the app confirms through the same window.
    private enum DeleteTarget: Identifiable {
        case service(ServiceStatus)
        case process(LocalProcessInfo)
        case forward(PortForwardInfo)

        var id: String {
            switch self {
            case .service(let service): return "service-\(service.name)"
            case .process(let process): return "process-\(process.name)"
            case .forward(let forward): return "forward-\(forward.name)"
            }
        }

        var title: String {
            switch self {
            case .service(let service): return "Delete service “\(service.name)”?"
            case .process(let process): return "Delete local process “\(process.name)”?"
            case .forward(let forward): return "Delete port-forward “\(forward.name)”?"
            }
        }

        var message: String {
            switch self {
            case .service(let service):
                return "This removes \(service.name) from the workspace, deletes its container and its named volumes. Stored data is lost."
            case .process(let process):
                return "This stops \(process.name) and removes it from the workspace."
            case .forward(let forward):
                return "This stops the forward and removes it from the workspace."
            }
        }
    }

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
        .sheet(item: $dbOpsService) { service in
            DBOpsView(service: service)
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
        .sheet(item: $deleteTarget) { target in
            ConfirmSheet(
                title: target.title,
                message: target.message,
                confirmTitle: "Delete"
            ) {
                Task { await performDelete(target) }
            }
        }
    }

    private func performDelete(_ target: DeleteTarget) async {
        switch target {
        case .service(let service):
            await state.deleteService(named: service.name)
        case .process(let process):
            await state.deleteLocalProcess(named: process.name)
        case .forward(let forward):
            await state.deletePortForward(named: forward.name)
        }
        deleteTarget = nil
    }

    @ViewBuilder
    private var content: some View {
        if state.selectedProfile == nil {
            NoWorkspaceView()
        } else if state.section == .portForward {
            PortForwardView(
                onAdd: { showAddPortForward = true },
                onEdit: { editingForward = $0 },
                onDelete: { deleteTarget = .forward($0) }
            )
        } else if state.section == .requests {
            RequestOpsView()
        } else {
            dockerContent
        }
    }

    @ViewBuilder
    private var dockerContent: some View {
        if let env = state.dockerEnvironment, env.serviceCount == 0, state.localProcesses.isEmpty {
            EmptyDockerView(onAddService: { showAddService = true })
        } else if state.services.isEmpty && state.dockerDetail == nil {
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
                                onDBOps: { dbOpsService = service },
                                onDelete: { deleteTarget = .service(service) }
                            )
                        }

                        ForEach(state.localProcesses) { process in
                            LocalProcessCard(
                                process: process,
                                isBusy: state.runningAction != nil,
                                onToggle: {
                                    if process.isRunning {
                                        Task { await state.stopLocalProcess(process) }
                                    } else {
                                        Task { await state.startLocalProcess(process) }
                                    }
                                },
                                onDelete: { deleteTarget = .process(process) }
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

    private var hasLive: Bool {
        isDocker
            ? state.hasRunningServices || state.runningLocalProcessCount > 0
            : state.runningForwardCount > 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(state.section.title)
                        .font(Theme.display(28))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    if hasLive {
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

                switch state.section {
                case .docker:
                    dockerActions
                case .portForward:
                    portForwardActions
                case .requests:
                    requestActions
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
        if state.selectedProfile != nil, let env = state.dockerEnvironment {
            let hasItems = env.serviceCount > 0 || !state.localProcesses.isEmpty
            let anythingRunning = state.runningCount + state.runningLocalProcessCount > 0

            if anythingRunning {
                ActionTextButton(title: "Stop all", systemName: "stop.fill") {
                    Task { await state.performEnvAction("stop") }
                }
            } else if hasItems {
                ActionTextButton(title: "Start all", systemName: "play.fill", prominent: true) {
                    Task { await state.performEnvAction("up") }
                }
            }

            if hasItems {
                ActionIconButton(systemName: "plus", tint: Theme.accent, help: "Add service or local process") {
                    showAddService = true
                }
            }
        }
    }

    /// What the add button of the section offers: a request, a folder or an
    /// environment. A request needs a folder, so it only shows when there is
    /// one.
    private var requestMenuItems: [(title: String, systemImage: String, action: () -> Void)] {
        var items: [(title: String, systemImage: String, action: () -> Void)] = []
        if state.requestFolderCount > 0 {
            items.append(("New request…", "list.bullet", { state.pendingSectionAction = .addRequest }))
        }
        items.append(("New folder…", "folder.badge.plus", { state.pendingSectionAction = .addRequestFolder }))
        items.append(("New environment…", "shippingbox", { state.pendingSectionAction = .addRequestEnv }))
        return items
    }

    @ViewBuilder
    private var requestActions: some View {
        if state.selectedProfile != nil {
            ActionMenuButton(
                systemName: "plus",
                tint: Theme.accent,
                help: "Add a request, a folder or an environment",
                items: requestMenuItems
            )
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
            let processes = state.localProcesses.count
            let running = state.runningCount + state.runningLocalProcessCount
            var parts = ["\(total) services"]
            if processes > 0 {
                parts.append("\(processes) processes")
            }
            parts.append("\(running) running")
            let summary = parts.joined(separator: " · ")
            if let description = profile.description, !description.isEmpty {
                return "\(description) · \(summary)"
            }
            return summary
        case .portForward:
            let forwards = state.portForwardCount
            let running = state.runningForwardCount
            if let description = profile.description, !description.isEmpty {
                return "\(description) · \(forwards) port-forwards · \(running) running"
            }
            return "\(forwards) port-forwards · \(running) running"
        case .requests:
            var parts = ["request collections"]
            if let description = profile.description, !description.isEmpty {
                parts.insert(description, at: 0)
            }
            return parts.joined(separator: " · ")
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

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(state: forward.state)

            Image(systemName: "network")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.info)
                .frame(width: 28, height: 28)
                .background(Theme.info.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(forward.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
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
    let onAddService: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text("No services yet")
                .font(Theme.title(18))
                .foregroundStyle(Theme.text)

            Text("Add a compose service or a host command to this workspace.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)

            ActionTextButton(title: "Add service", systemName: "plus", prominent: true, action: onAddService)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Local process row

private struct LocalProcessCard: View {
    let process: LocalProcessInfo
    let isBusy: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 9) {
                StatusDot(state: process.state)
                Text(process.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                TechBadge(text: "PROCESS", color: Theme.textMuted)

                Spacer(minLength: 4)

                if let pid = process.pid {
                    Text("pid \(pid)")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
            }

            Text(process.command)
                .font(Theme.mono)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 8, weight: .bold))
                Text(process.workDir.isEmpty ? "App working directory" : process.workDir)
                    .font(Theme.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.textDim)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()

                ActionIconButton(
                    systemName: process.isRunning ? "stop.fill" : "play.fill",
                    tint: process.isRunning ? Theme.danger : Theme.accent,
                    help: process.isRunning ? "Stop" : "Start"
                ) {
                    onToggle()
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.5 : 1)
            }
        }
        .padding(16)
        .frame(minHeight: 168)
        .cardStyle(highlighted: hovering)
        .contentShape(Rectangle())
        .contextMenu {
            Button(process.isRunning ? "Stop" : "Start") { onToggle() }
            Divider()
            Button("Delete process…", role: .destructive) { onDelete() }
        }
        .onHover { value in
            withAnimation(.easeOut(duration: 0.12)) { hovering = value }
        }
    }
}

// MARK: - Service card

private struct ServiceCard: View {
    @EnvironmentObject private var state: AppState

    let service: ServiceStatus
    let isBusy: Bool
    let onOpen: () -> Void
    let onLogs: () -> Void
    let onDBOps: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var accent: Color {
        if let kind = service.kind { return kindColor(kind) }
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

                if let kind = service.kind {
                    TechBadge(text: kind, color: kindColor(kind))
                }

                Spacer(minLength: 4)

                if service.kind == "DB" {
                    ActionIconButton(
                        systemName: "cylinder.split.1x2",
                        tint: Theme.info,
                        help: "DB operations",
                        action: onDBOps
                    )
                }

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

func kindColor(_ kind: String) -> Color {
    switch kind.uppercased() {
    case "DB": return Theme.info
    case "QUEUE": return Theme.warning
    case "MOCK": return Theme.violet
    case "SEARCH": return Theme.accent
    case "CACHE": return Theme.running
    default: return Theme.textMuted
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
