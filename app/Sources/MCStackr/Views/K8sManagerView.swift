import SwiftUI

// MARK: - K8s manager

/// The Kubernetes deployment manager of the app.
///
/// It is the port of the resource manager of the console runtime: a context,
/// a namespace, the deployments of that namespace and the actions of one
/// deployment. The shell of the console runtime is not one of them: an app
/// cannot hand its terminal over to kubectl, so the manager only runs the
/// actions the engine knows.
struct K8sManagerView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// When the manager opens from a port forward, it starts at the
    /// deployments of that namespace instead of asking for a context.
    var initialContext: String? = nil
    var initialNamespace: String? = nil
    /// The deployment the manager opens with. It comes from a port forward:
    /// the service of the forward is the deployment, so the manager lands on
    /// it instead of on the list of the namespace.
    var initialDeployment: String? = nil

    // MARK: Types

    /// The steps of the manager, in the order of the console runtime.
    private enum Step: Int, CaseIterable {
        case context
        case namespace
        case deployments
        case actions
        case scale
    }

    /// The actions of a deployment, in the order of the console runtime.
    private enum DeploymentAction: String, CaseIterable, Identifiable {
        case restart
        case scale
        case logs
        case delete

        var id: String { rawValue }

        /// The help text of the console runtime.
        var title: String {
            switch self {
            case .restart: return "Rollout restart"
            case .scale: return "Scale replicas"
            case .logs: return "View the live logs"
            case .delete: return "Delete the deployment"
            }
        }

        /// The short name of the action, for the badge of the header.
        var badge: String {
            switch self {
            case .restart: return "Restart"
            case .scale: return "Scale"
            case .logs: return "Logs"
            case .delete: return "Delete"
            }
        }

        var icon: String {
            switch self {
            case .restart: return "arrow.clockwise"
            case .scale: return "arrow.up.and.down"
            case .logs: return "text.alignleft"
            case .delete: return "trash"
            }
        }

        var tint: Color {
            switch self {
            case .restart: return Theme.warning
            case .scale: return Theme.info
            case .logs: return Theme.violet
            case .delete: return Theme.danger
            }
        }
    }

    /// The result of an action that finished. It shows itself for a few
    /// seconds, the way the console runtime did.
    private struct Feedback: Identifiable {
        let id = UUID()
        let succeeded: Bool
        let text: String
    }

    /// The deployment whose live logs are open.
    private struct K8sLogsTarget: Identifiable {
        let id = UUID()
        let context: String
        let namespace: String
        let deployment: String
    }

    // MARK: State

    @State private var step: Step
    @State private var contexts: [String] = []
    @State private var namespaces: [String] = []
    @State private var deployments: [K8sDeployment] = []
    @State private var selectedContext: String
    @State private var selectedNamespace: String
    @State private var selectedDeployment: K8sDeployment?
    @State private var kubectlAvailable = true
    @State private var isLoading = false
    @State private var isRunning = false
    @State private var localError: String?
    @State private var feedback: Feedback?
    @State private var replicaText = ""
    @State private var liveLogs: K8sLogsTarget?
    @State private var confirmDelete = false

    // MARK: Init

    init(initialContext: String? = nil, initialNamespace: String? = nil, initialDeployment: String? = nil) {
        self.initialContext = initialContext
        self.initialNamespace = initialNamespace
        self.initialDeployment = initialDeployment

        // With a context and a namespace the manager starts at the
        // deployments of that namespace: it does not ask for either.
        let context = self.initialContext ?? ""
        let namespace = self.initialNamespace ?? ""
        let opensAtDeployments = !context.isEmpty && !namespace.isEmpty
        _selectedContext = State(initialValue: context)
        _selectedNamespace = State(initialValue: namespace)

        // It comes from a port forward: the manager opens on the actions of
        // that deployment, without the list of the namespace in between. The
        // numbers of the deployment arrive with the list.
        if let deployment = self.initialDeployment, !deployment.isEmpty {
            _step = State(initialValue: .actions)
            _selectedDeployment = State(initialValue: K8sDeployment(
                name: deployment,
                desired: 0,
                available: 0,
                updated: 0,
                progressing: false,
                lastRestarted: "",
                age: "",
                strategy: ""
            ))
        } else {
            _step = State(initialValue: opensAtDeployments ? .deployments : .context)
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            content
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 720)
        .frame(minHeight: 420, idealHeight: 560, maxHeight: 680)
        .background(Theme.background)
        .task { await loadContexts() }
        .task(id: pollID) { await pollDeployments() }
        .task(id: feedback?.id) { await expireFeedback() }
        .sheet(isPresented: $confirmDelete) {
            ConfirmSheet(
                title: "Delete “\(selectedDeployment?.name ?? "deployment")”?",
                message: "This deletes the deployment and its pods in \(selectedNamespace).",
                confirmTitle: "Delete"
            ) {
                Task { await runAction(.delete) }
            }
        }
        .sheet(item: $liveLogs) { target in
            K8sLogsSheet(
                context: target.context,
                namespace: target.namespace,
                deployment: target.deployment
            )
            .environmentObject(state)
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(headerTitle)
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    TechBadge(text: badgeText, color: Theme.info)
                }
                Text(headerSubtitle)
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

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerHint)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textDim)

            Spacer()

            footerAction
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var footerAction: some View {
        switch step {
        case .deployments:
            ActionTextButton(title: "Refresh", systemName: "arrow.clockwise") {
                Task { await loadDeployments(showSpinner: false) }
            }
            .disabled(isLoading)
            .opacity(isLoading ? 0.5 : 1)
        case .scale:
            ActionTextButton(
                title: isRunning ? "Scaling…" : "Scale",
                systemName: "checkmark",
                prominent: true
            ) {
                guard let replicas = replicaCount else { return }
                Task { await runAction(.scale, replicas: replicas) }
            }
            .disabled(isRunning || replicaCount == nil)
            .opacity(isRunning || replicaCount == nil ? 0.5 : 1)
        case .context, .namespace, .actions:
            EmptyView()
        }
    }

    // MARK: Content

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
                        selectContext(context)
                    }
                case .namespace:
                    discoveryList(
                        items: namespaces,
                        emptyText: "No namespaces found in “\(selectedContext)”.",
                        isLoading: isLoading
                    ) { namespace in
                        selectNamespace(namespace)
                    }
                case .deployments:
                    deploymentList
                case .actions:
                    actionMenu
                case .scale:
                    scaleStep
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var deploymentList: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLoading && deployments.isEmpty {
                loadingBlock("Querying deployments…")
            } else if deployments.isEmpty {
                emptyBlock("No deployments found in “\(selectedNamespace)”.")
            } else {
                VStack(spacing: 8) {
                    ForEach(deployments) { deployment in
                        Button {
                            selectDeployment(deployment)
                        } label: {
                            deploymentRow(deployment)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // A deletion leaves the menu, so its feedback follows the user
            // back to the list.
            feedbackSection
        }
    }

    private var actionMenu: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let deployment = selectedDeployment {
                FormSection("Deployment") {
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Name", deployment.name)
                        infoRow("Namespace", selectedNamespace)
                        infoRow("Replicas", "\(deployment.available)/\(deployment.desired)")
                        infoRow("Strategy", deployment.strategy.isEmpty ? "—" : deployment.strategy)
                        infoRow("Age", deployment.age.isEmpty ? "—" : deployment.age)
                        infoRow("Last restart", restartLabel(deployment))
                    }
                }
            }

            FormSection("Actions") {
                VStack(spacing: 8) {
                    ForEach(DeploymentAction.allCases) { action in
                        Button {
                            choose(action)
                        } label: {
                            actionRow(action)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunning)
                        .opacity(isRunning ? 0.5 : 1)
                    }
                }
            }

            feedbackSection
        }
    }

    private var scaleStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let deployment = selectedDeployment {
                FormSection("Deployment") {
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Name", deployment.name)
                        infoRow("Namespace", selectedNamespace)
                        infoRow("Replicas", "\(deployment.available)/\(deployment.desired)")
                    }
                }
            }

            FormSection("Replicas") {
                VStack(alignment: .leading, spacing: 8) {
                    ThemedTextField(placeholder: "3", text: $replicaText)
                        .frame(width: 140)
                    Text("The deployment wants \(selectedDeployment?.desired ?? 0) replicas now. Zero scales it down to no pods.")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                    if !replicaText.trimmingCharacters(in: .whitespaces).isEmpty && replicaCount == nil {
                        Text("Enter a number of zero or more.")
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(Theme.danger)
                    }
                }
            }

            feedbackSection
        }
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
            loadingBlock("Querying kubectl…")
        } else if items.isEmpty {
            emptyBlock(emptyText)
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

    private func deploymentRow(_ deployment: K8sDeployment) -> some View {
        HStack(spacing: 12) {
            DeploymentStatusDot(state: deployment.state)
                .help(deployment.state.title)

            Text(deployment.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(deployment.available)/\(deployment.desired)")
                .font(Theme.mono)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 56, alignment: .trailing)

            Text(deployment.age.isEmpty ? "—" : deployment.age)
                .font(Theme.mono)
                .foregroundStyle(Theme.textDim)
                .frame(width: 44, alignment: .trailing)

            Text(restartLabel(deployment))
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textDim)
                .frame(width: 108, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textDim)
        }
        .padding(12)
        .cardStyle()
    }

    private func actionRow(_ action: DeploymentAction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: action.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(action.tint)
                .frame(width: 28, height: 28)
                .background(action.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(action.rawValue)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textDim)
        }
        .padding(12)
        .cardStyle()
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let feedback {
            feedbackLine(feedback)
        }
    }

    private func feedbackLine(_ feedback: Feedback) -> some View {
        HStack(spacing: 8) {
            Image(systemName: feedback.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(feedback.succeeded ? Theme.running : Theme.danger)
            Text(feedback.text)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(feedback.succeeded ? Theme.text : Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (feedback.succeeded ? Theme.running : Theme.danger).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func loadingBlock(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.accent)
            Text(text)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func emptyBlock(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.textDim)
            Text(text)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textDim)
                .frame(width: 100, alignment: .leading)
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

    private var headerTitle: String {
        "Kubernetes"
    }

    private var badgeText: String {
        stepTitle
    }

    private var headerSubtitle: String {
        "\(state.workspaceName) / \(state.portForwardEnvName ?? "Port Forwards") · \(stepSubtitle)"
    }

    private var stepTitle: String {
        switch step {
        case .context: return "Context"
        case .namespace: return "Namespace"
        case .deployments: return "Deployments"
        case .actions: return "Actions"
        case .scale: return "Scale replicas"
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .context: return "Select a Kubernetes context"
        case .namespace: return "Select a namespace"
        case .deployments: return "Select a deployment"
        case .actions: return "Select an action"
        case .scale: return "Choose the number of replicas"
        }
    }

    private var footerHint: String {
        switch step {
        case .context: return "Pick a context from your kubeconfig."
        case .namespace: return "Pick a namespace of the selected context."
        case .deployments: return "The list refreshes every 3 seconds."
        case .actions: return "Pick what to do with the deployment."
        case .scale: return "Zero replicas scales the deployment down to no pods."
        }
    }

    private func restartLabel(_ deployment: K8sDeployment) -> String {
        deployment.lastRestarted.isEmpty ? "never restarted" : "restarted \(deployment.lastRestarted)"
    }

    // MARK: Logic

    /// The number of replicas the scale step asks for. The console runtime
    /// asked no question and scaled to one more than the current count.
    private var replicaCount: Int? {
        let trimmed = replicaText.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    /// The identity of the polling task. It changes with the step and with
    /// the selection, so the task restarts when the list to watch changes.
    private var pollID: String {
        "\(step.rawValue)|\(selectedContext)|\(selectedNamespace)"
    }

    private func goBack() {
        localError = nil
        feedback = nil
        switch step {
        case .context: break
        case .namespace:
            step = .context
            namespaces = []
        case .deployments:
            step = .namespace
            // The manager can open at a namespace it was given: the list of
            // the namespaces is asked again when it is needed.
            if namespaces.isEmpty {
                Task { await loadNamespaces() }
            }
        case .actions:
            step = .deployments
        case .scale:
            step = .actions
        }
    }

    private func selectContext(_ context: String) {
        selectedContext = context
        selectedNamespace = ""
        selectedDeployment = nil
        namespaces = []
        deployments = []
        feedback = nil
        Task { await loadNamespaces() }
    }

    private func selectNamespace(_ namespace: String) {
        selectedNamespace = namespace
        selectedDeployment = nil
        deployments = []
        feedback = nil
        step = .deployments
    }

    private func selectDeployment(_ deployment: K8sDeployment) {
        selectedDeployment = deployment
        feedback = nil
        step = .actions
    }

    private func choose(_ action: DeploymentAction) {
        switch action {
        case .restart:
            Task { await runAction(.restart) }
        case .scale:
            replicaText = String((selectedDeployment?.desired ?? 0) + 1)
            step = .scale
        case .logs:
            openLogs()
        case .delete:
            confirmDelete = true
        }
    }

    /// Runs an action that answers with a message instead of with output.
    private func runAction(_ action: DeploymentAction, replicas: Int? = nil) async {
        guard let deployment = selectedDeployment else { return }
        isRunning = true
        defer { isRunning = false }

        // The output of these actions is the answer of kubectl: the manager
        // shows the label of the action instead of it.
        let (_, error) = await state.runK8sDeploymentAction(
            action.rawValue,
            context: selectedContext,
            namespace: selectedNamespace,
            deployment: deployment.name,
            replicas: replicas
        )
        guard !Task.isCancelled else { return }

        if let error {
            feedback = Feedback(succeeded: false, text: error)
            return
        }

        feedback = Feedback(succeeded: true, text: successText(action, replicas: replicas))

        switch action {
        case .scale:
            // The scale step closes itself: the answer is in the menu.
            step = .actions
        case .delete:
            // The deployment is gone: the list is the only thing left.
            selectedDeployment = nil
            step = .deployments
        case .restart, .logs:
            break
        }
    }

    /// Opens the live logs of the deployment in a window of their own.
    private func openLogs() {
        guard let deployment = selectedDeployment else { return }
        liveLogs = K8sLogsTarget(
            context: selectedContext,
            namespace: selectedNamespace,
            deployment: deployment.name
        )
    }

    private func successText(_ action: DeploymentAction, replicas: Int?) -> String {
        switch action {
        case .restart: return "Restart requested"
        case .scale: return "Scaled to \(replicas ?? 0) replicas"
        case .delete: return "Deployment deleted"
        case .logs: return action.title
        }
    }

    /// The feedback shows itself for a few seconds, the way the console
    /// runtime did.
    private func expireFeedback() async {
        guard feedback != nil else { return }
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } catch {
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            feedback = nil
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
            // The step moves on only when the user is still where the
            // namespaces were asked from.
            if step == .context {
                step = .namespace
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    /// Watches the deployments of the namespace, the way the console runtime
    /// did: it asked the cluster again every three seconds.
    private func pollDeployments() async {
        guard step == .deployments else { return }
        await loadDeployments(showSpinner: true)
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await loadDeployments(showSpinner: false)
        }
    }

    private func loadDeployments(showSpinner: Bool) async {
        if showSpinner { isLoading = true }
        defer { if showSpinner { isLoading = false } }

        let (loaded, error) = await state.k8sDeployments(context: selectedContext, namespace: selectedNamespace)
        guard !Task.isCancelled else { return }

        if let error {
            // The error belongs here: the banner of the app stays behind
            // this window, and the list asks again every three seconds, so
            // it must not take the error of the app away either.
            localError = error
            return
        }

        deployments = loaded ?? []
        localError = nil
        openInitialDeploymentIfAny(loaded ?? [])
    }

    /// Fills the numbers of the deployment the manager came for.
    ///
    /// The manager opened on its actions without waiting for the list, so
    /// the numbers arrive with it. It only fills the one that is on screen:
    /// the user may have picked another deployment meanwhile.
    private func openInitialDeploymentIfAny(_ loaded: [K8sDeployment]) {
        guard let wanted = initialDeployment,
              !wanted.isEmpty,
              selectedDeployment?.name == wanted,
              let match = loaded.first(where: { $0.name == wanted }) else { return }
        selectedDeployment = match
    }
}

// MARK: - Deployment status dot

/// The dot of a deployment.
///
/// It is not the `StatusDot` of the app: that one paints a stopped
/// deployment in red, and the console runtime painted it in grey.
private struct DeploymentStatusDot: View {
    let state: K8sDeploymentState
    var size: CGFloat = 9

    private var color: Color {
        switch state {
        case .running: return Theme.running
        case .progressing: return Theme.warning
        case .failing: return Theme.danger
        case .stopped: return Theme.textDim
        }
    }

    private var glow: CGFloat {
        switch state {
        case .running: return 6
        case .progressing, .failing, .stopped: return 0
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 4)
                    .blur(radius: 2)
            }
            .shadow(color: color.opacity(0.8), radius: glow)
    }
}
