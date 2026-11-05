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
        .frame(width: 640, height: 620)
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
                            Text(error)
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 640, height: 560)
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
