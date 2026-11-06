import SwiftUI

// MARK: - Add port-forward (discovery driven)

struct AddPortForwardView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        case context
        case namespace
        case service
        case port
    }

    @State private var step: Step = .context
    @State private var kubectlAvailable = true
    @State private var contexts: [String] = []
    @State private var namespaces: [String] = []
    @State private var services: [DiscoveredService] = []
    @State private var selectedContext = ""
    @State private var selectedNamespace = ""
    @State private var selectedService: DiscoveredService?
    @State private var localPort = ""
    @State private var isLoading = false
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
        .frame(minWidth: 460, idealWidth: 580, maxWidth: 640)
        .frame(minHeight: 380, idealHeight: 520, maxHeight: 620)
        .background(Theme.background)
        .task { await loadContexts() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Add port-forward")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    TechBadge(text: stepTitle, color: Theme.info)
                }
                Text("\(state.workspaceName) / \(state.portForwardEnvName ?? "Port Forwards") · \(stepSubtitle)")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            if step != .context {
                ActionIconButton(systemName: "chevron.left", tint: Theme.textMuted, help: "Back") {
                    goBack()
                }
            }

            ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                dismiss()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !kubectlAvailable {
                    banner("kubectl was not found in PATH. Install kubectl and reopen this sheet.", color: Theme.danger)
                }

                if let localError {
                    banner(localError, color: Theme.danger)
                }

                switch step {
                case .context:
                    discoveryList(
                        items: contexts,
                        emptyText: "No Kubernetes contexts found.",
                        isLoading: isLoading
                    ) { context in
                        selectedContext = context
                        selectedNamespace = ""
                        selectedService = nil
                        Task { await loadNamespaces() }
                    }
                case .namespace:
                    discoveryList(
                        items: namespaces,
                        emptyText: "No namespaces found in “\(selectedContext)”.",
                        isLoading: isLoading
                    ) { namespace in
                        selectedNamespace = namespace
                        selectedService = nil
                        Task { await loadServices() }
                    }
                case .service:
                    discoveryList(
                        items: services.map(\.name),
                        emptyText: "No services with ports in “\(selectedNamespace)”.",
                        isLoading: isLoading
                    ) { name in
                        guard let service = services.first(where: { $0.name == name }) else { return }
                        selectedService = service
                        localPort = String(state.nextFreeLocalPort())
                        step = .port
                    }
                case .port:
                    portStep
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var portStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let service = selectedService {
                FormSection("Target") {
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Context", selectedContext)
                        infoRow("Namespace", selectedNamespace)
                        infoRow("Service", service.name)
                        infoRow("Remote port", String(service.remotePort))
                    }
                }
            }

            FormSection("Local port") {
                VStack(alignment: .leading, spacing: 8) {
                    ThemedTextField(placeholder: "8080", text: $localPort)
                        .frame(width: 180)
                    Text("The forward is reachable at localhost:<port>. Choose a free local port.")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(step == .port
                 ? "kubectl port-forward runs until you stop it."
                 : "Pick from your kubeconfig, then a namespace and a service.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textDim)

            Spacer()

            if step == .port {
                ActionTextButton(
                    title: isSaving ? "Adding…" : "Add port-forward",
                    systemName: "plus",
                    prominent: true
                ) {
                    Task { await save() }
                }
                .disabled(isSaving || !canSave)
                .opacity(isSaving || !canSave ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Pieces

    @ViewBuilder
    private func discoveryList(
        items: [String],
        emptyText: String,
        isLoading: Bool,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("Querying kubectl…")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.textDim)
                Text(emptyText)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            VStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button { onSelect(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textDim)
                            Text(item)
                                .font(Theme.mono)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(12)
                        .cardStyle()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textDim)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(Theme.mono)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Copy

    private var stepTitle: String {
        switch step {
        case .context: return "Context"
        case .namespace: return "Namespace"
        case .service: return "Service"
        case .port: return "Local port"
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .context: return "Select a Kubernetes context"
        case .namespace: return "Select a namespace"
        case .service: return "Select a service"
        case .port: return "Choose the local port"
        }
    }

    private var canSave: Bool {
        guard let port = Int(localPort.trimmingCharacters(in: .whitespaces)) else { return false }
        guard (1...65535).contains(port) else { return false }
        return !isPortUsed(port)
    }

    // MARK: Logic

    private func isPortUsed(_ port: Int) -> Bool {
        (state.environmentDetail?.portForwards ?? []).contains { $0.localPort == port }
    }

    private func goBack() {
        localError = nil
        switch step {
        case .context: break
        case .namespace: step = .context
        case .service: step = .namespace
        case .port: step = .service
        }
    }

    private func loadContexts() async {
        isLoading = true
        defer { isLoading = false }
        kubectlAvailable = await state.k8sAvailable()
        guard kubectlAvailable else { return }
        do {
            contexts = try await state.k8sContexts()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func loadNamespaces() async {
        isLoading = true
        localError = nil
        defer { isLoading = false }
        do {
            namespaces = try await state.k8sNamespaces(context: selectedContext)
            step = .namespace
        } catch {
            localError = error.localizedDescription
        }
    }

    private func loadServices() async {
        isLoading = true
        localError = nil
        defer { isLoading = false }
        do {
            services = try await state.k8sServices(context: selectedContext, namespace: selectedNamespace)
            step = .service
        } catch {
            localError = error.localizedDescription
        }
    }

    private func save() async {
        guard let service = selectedService,
              let port = Int(localPort.trimmingCharacters(in: .whitespaces)) else { return }
        localError = nil

        if isPortUsed(port) {
            localError = "Local port \(port) is already used by another port-forward."
            return
        }
        if (state.environmentDetail?.portForwards ?? []).contains(where: { $0.name == service.name }) {
            localError = "A port-forward named “\(service.name)” already exists."
            return
        }

        isSaving = true
        defer { isSaving = false }

        let added = await state.addPortForward(
            name: service.name,
            localPort: port,
            remotePort: service.remotePort,
            context: selectedContext,
            namespace: selectedNamespace,
            service: service.name
        )
        if added {
            dismiss()
        } else {
            localError = state.errorMessage
            state.errorMessage = nil
        }
    }
}

// MARK: - Kubernetes section

/// The Kubernetes section of the app.
///
/// It is organised by environment: the environment in use is at the top and
/// the port forwards of that environment are below it. A new environment
/// starts empty, so the way to add a port-forward belongs to the section.
struct PortForwardView: View {
    @EnvironmentObject private var state: AppState
    let onAdd: () -> Void
    let onEdit: (PortForwardInfo) -> Void
    let onDelete: (PortForwardInfo) -> Void
    let onOpenK8s: (PortForwardInfo) -> Void

    /// The environment in use.
    private var environmentName: String { state.portForwardEnvironment?.name ?? "" }

    /// The removal of the environment in use asks first.
    @State private var confirmDeleteEnvironment = false
    @State private var isDeleting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.k8sEnvironments.isEmpty {
                    K8sEnvironmentsEmptyView()
                } else {
                    HStack(spacing: 10) {
                        envSelector

                        // The environment in use can be removed, like every
                        // other thing the app deletes.
                        ActionIconButton(
                            systemName: "trash",
                            tint: Theme.danger,
                            help: "Remove the Kubernetes environment"
                        ) {
                            confirmDeleteEnvironment = true
                        }
                        .disabled(environmentName.isEmpty || isDeleting)
                        .opacity(environmentName.isEmpty ? 0.35 : 1)
                    }

                    if environmentName.isEmpty {
                        K8sNoEnvironmentSelectedView()
                    } else if let detail = state.environmentDetail {
                        if detail.portForwards.isEmpty {
                            PortForwardEmptyView(onAdd: onAdd)
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
                                        onOpenK8s: { onOpenK8s(forward) },
                                        onDelete: { onDelete(forward) }
                                    )
                                }
                            }

                            addForwardRow
                        }
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
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            Task { await state.refreshEnvironmentDetail() }
        }
        .sheet(isPresented: $confirmDeleteEnvironment) {
            ConfirmSheet(
                title: "Remove “\(environmentName)”?",
                message: "The environment and the port forwards it holds are removed. The workspace keeps the rest.",
                confirmTitle: "Remove"
            ) {
                Task { await deleteEnvironment() }
            }
        }
    }

    /// Removes the environment in use.
    private func deleteEnvironment() async {
        let name = environmentName
        guard !name.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        if await state.deleteK8sEnvironment(name: name) {
            confirmDeleteEnvironment = false
        }
    }

    // MARK: Pieces

    /// The Kubernetes environment in use. It is the context of everything
    /// below it: the same look as the request environment selector and the
    /// same width, so changing the environment moves nothing.
    private var envSelector: some View {
        Menu {
            ForEach(state.k8sEnvironments) { env in
                Button {
                    state.selectK8sEnvironment(env.name)
                } label: {
                    if env.name == environmentName {
                        Label(env.name, systemImage: "checkmark")
                    } else {
                        Text(env.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.violet.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "square.stack.3d.down.forward")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.violet)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(environmentName.isEmpty ? "No environment" : environmentName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("KUBERNETES ENVIRONMENT")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textDim)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            // The same width whatever the name is, so changing the
            // environment does not move anything.
            .frame(width: 240, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .padding(.bottom, 6)
    }

    /// Adding a port-forward belongs to the environment, so the affordance
    /// sits with the forwards of the environment in use.
    private var addForwardRow: some View {
        ActionTextButton(title: "Add port-forward", systemName: "plus") {
            onAdd()
        }
    }
}

/// The workspace has no Kubernetes environment yet. The header creates them.
private struct K8sEnvironmentsEmptyView: View {    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.down.forward")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text("No Kubernetes environment")
                .font(Theme.title(18))
                .foregroundStyle(Theme.text)

            Text("Use the + button of the header to create one. It starts empty and holds the port forwards.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

/// The workspace has environments, but none of them is in use: the app does
/// not choose one for the user.
private struct K8sNoEnvironmentSelectedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.down.forward")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text("No environment in use")
                .font(Theme.title(18))
                .foregroundStyle(Theme.text)

            Text("Pick one of the environments of the workspace above. The port forwards of the one in use are shown here.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

/// The environment in use has no port forwards yet.
private struct PortForwardEmptyView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)

            Text("No port forwards yet")
                .font(Theme.title(18))
                .foregroundStyle(Theme.text)

            Text("Discover a Kubernetes service and forward one of its ports to localhost.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            ActionTextButton(title: "Add port-forward", systemName: "plus", prominent: true) {
                onAdd()
            }
            .padding(.top, 4)
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
    let onOpenK8s: () -> Void
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
                    LogBlock(
                        lines: error.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                        maxLines: 2,
                        messageColor: Theme.danger
                    )
                }
            }

            Spacer(minLength: 8)

            Text("\(forward.localPort) → \(forward.remotePort)")
                .font(Theme.mono)
                .foregroundStyle(Theme.textMuted)

            // The deployments of the namespace of the forward live one level
            // down, next to the button that runs the forward.
            ActionIconButton(
                systemName: "square.stack.3d.down.forward",
                tint: Theme.violet,
                help: "Open the Kubernetes operations of the namespace"
            ) {
                onOpenK8s()
            }

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
            Button("Kubernetes operations…") { onOpenK8s() }
            Divider()
            Button("Delete port-forward…", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Add Kubernetes environment

/// The window that creates a Kubernetes environment. The environment starts
/// empty: the port forwards are added inside it, from the section.
struct AddK8sEnvironmentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// The characters the engine accepts in the name of an environment.
    private static let allowedNameCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

    @State private var name = ""
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
        .frame(width: 460, height: 320)
        .background(Theme.background)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add environment")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.text)
                Text("\(state.workspaceName) · a Kubernetes environment holds the port forwards.")
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
        VStack(alignment: .leading, spacing: 16) {
            if let localError {
                banner(localError, color: Theme.danger)
            }

            FormSection("Environment") {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Name")
                    ThemedTextField(placeholder: "staging", text: $name)
                    Text("Letters, numbers, _, . and -.")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                    if !name.isEmpty && !nameIsValid {
                        Text("The name accepts only letters, numbers, _, . and -.")
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("The environment starts empty.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textDim)

            Spacer()

            ActionTextButton(
                title: isSaving ? "Creating…" : "Create",
                systemName: "plus",
                prominent: true
            ) {
                Task { await save() }
            }
            .disabled(isSaving || !nameIsValid)
            .opacity(isSaving || !nameIsValid ? 0.5 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Pieces

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: State

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The engine refuses an empty name and any name with a character that
    /// is not a letter, a number, `_`, `.` or `-`.
    private var nameIsValid: Bool {
        guard !trimmedName.isEmpty else { return false }
        return trimmedName.allSatisfy { Self.allowedNameCharacters.contains($0) }
    }

    // MARK: Logic

    private func save() async {
        localError = nil
        isSaving = true
        defer { isSaving = false }

        let created = await state.createK8sEnvironment(name: trimmedName)
        if created {
            dismiss()
        } else {
            // The engine refused it: the window stays open and shows why.
            localError = state.errorMessage ?? "Could not create the environment."
            state.errorMessage = nil
        }
    }
}

// MARK: - Edit port-forward

struct PortForwardEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let forward: PortForwardInfo

    @State private var localPort = ""
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

                    FormSection("Target") {
                        VStack(alignment: .leading, spacing: 10) {
                            infoRow("Context", forward.k8sContext)
                            infoRow("Namespace", forward.k8sNamespace)
                            infoRow("Service", forward.k8sService)
                            infoRow("Remote port", String(forward.remotePort))
                            infoRow("State", forward.state)
                        }
                    }

                    FormSection("Local port") {
                        VStack(alignment: .leading, spacing: 8) {
                            ThemedTextField(placeholder: "8080", text: $localPort)
                                .frame(width: 180)
                            Text(forward.isRunning
                                 ? "Saving restarts the forward with the new local port."
                                 : "The forward is reachable at localhost:<port>.")
                                .font(.system(size: 10.5, design: .rounded))
                                .foregroundStyle(Theme.textDim)
                        }
                    }

                    if let error = forward.error, !error.isEmpty {
                        FormSection("Last error") {
                            LogBlock(
                                lines: error.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                                messageColor: Theme.danger
                            )
                        }
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(minWidth: 460, idealWidth: 560, maxWidth: 640)
        .frame(minHeight: 320, idealHeight: 460, maxHeight: 560)
        .background(Theme.background)
        .onAppear { localPort = String(forward.localPort) }
        .sheet(isPresented: $confirmDelete) {
            ConfirmSheet(
                title: "Delete \(forward.name)?",
                message: "This stops the forward and removes it from \(state.workspaceName).",
                confirmTitle: "Delete"
            ) {
                Task { await delete() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(forward.name)
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    StatusDot(state: forward.state)
                }
                Text("\(forward.localPort) → \(forward.remotePort) · \(forward.k8sContext) / \(forward.k8sNamespace)/\(forward.k8sService)")
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
            ActionTextButton(title: "Delete port-forward", systemName: "trash", destructive: true) {
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
            .disabled(isSaving || !canSave)
            .opacity(isSaving || !canSave ? 0.5 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var canSave: Bool {
        guard let port = Int(localPort.trimmingCharacters(in: .whitespaces)) else { return false }
        guard (1...65535).contains(port) else { return false }
        return !isPortUsedByAnother(port)
    }

    private func isPortUsedByAnother(_ port: Int) -> Bool {
        (state.environmentDetail?.portForwards ?? []).contains {
            $0.name != forward.name && $0.localPort == port
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textDim)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(Theme.mono)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
        }
    }

    private func save() async {
        guard let port = Int(localPort.trimmingCharacters(in: .whitespaces)) else { return }
        localError = nil

        if isPortUsedByAnother(port) {
            localError = "Local port \(port) is already used by another port-forward."
            return
        }
        if port == forward.localPort {
            dismiss()
            return
        }

        isSaving = true
        defer { isSaving = false }

        let saved = await state.updatePortForward(named: forward.name, localPort: port)
        if saved {
            dismiss()
        } else {
            localError = state.errorMessage
            state.errorMessage = nil
        }
    }

    private func delete() async {
        isSaving = true
        defer { isSaving = false }
        let deleted = await state.deletePortForward(named: forward.name)
        if deleted {
            dismiss()
        } else {
            localError = state.errorMessage
            state.errorMessage = nil
        }
    }
}
