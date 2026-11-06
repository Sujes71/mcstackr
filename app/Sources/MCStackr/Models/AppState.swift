import Foundation
import SwiftUI

enum BootPhase: Equatable {
    case idle
    case starting
    case ready
    case failed(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var bootPhase: BootPhase = .idle
    @Published private(set) var profiles: [Profile] = []
    @Published var selectedProfileName: String?
    @Published var selectedEnvName: String?
    @Published private(set) var status: StatusResponse?
    @Published private(set) var dockerAvailable = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var runningAction: String?
    @Published var errorMessage: String?
    @Published private(set) var engineVersion = ""
    @Published private(set) var configPath = ""
    @Published private(set) var environmentDetail: EnvironmentDetail?
    /// The state of the repository. It lives here so the refresh of the header
    /// reloads it, the same way it reloads the rest.
    @Published private(set) var gitState: GitState?
    @Published private(set) var dockerDetail: EnvironmentDetail?
    @Published private(set) var catalog: [CatalogEntry] = []

    @Published var section: AppSection = .docker
    /// The Kubernetes environment in use. It is one of the environments of
    /// the workspace that are not the docker one.
    @Published var selectedK8sEnvName: String = ""
    /// An action the header asked the current section to run.
    @Published var pendingSectionAction: SectionAction?
    /// The requests that are running right now, with the task that follows
    /// them. It survives the window being closed and opened again.
    @Published private(set) var runningRequests: Set<String> = []
    private var requestTasks: [String: Task<Void, Never>] = [:]
    /// The windows of the requests that were closed while the request was
    /// still running. Only those runs are reported with a notice.
    private var closedRequestWindows: Set<String> = []

    /// The request environment in use and the ones available. The selector
    /// lives in the header, so both belong to the app state.
    @Published var selectedRequestEnv: String = ""
    @Published private(set) var requestEnvs: [RequestEnvironment] = []

    func setRequestEnvs(_ envs: [RequestEnvironment]) {
        requestEnvs = envs
        if !envs.contains(where: { $0.name == selectedRequestEnv }) {
            selectedRequestEnv = envs.first?.name ?? ""
        }
    }

    /// The environment in use, with its current variables.
    func requestEnv(_ name: String) -> RequestEnvironment? {
        requestEnvs.first { $0.name == name }
    }

    /// Keeps a variable the user wrote, so the window shows the last value
    /// even before the collection is refreshed.
    func setRequestVariable(env: String, name: String, value: String) {
        guard let index = requestEnvs.firstIndex(where: { $0.name == env }) else { return }
        if let variable = requestEnvs[index].variables.first(where: { $0.name == name }) {
            requestEnvs[index].variables[variableIndex(name, in: index)].value = value
        } else {
            requestEnvs[index].variables.append(RequestVariable(name: name, value: value))
        }
    }

    private func variableIndex(_ name: String, in envIndex: Int) -> Int {
        requestEnvs[envIndex].variables.firstIndex { $0.name == name } ?? 0
    }
    /// Bumped on every refresh, so the views reload what they show.
    @Published private(set) var refreshToken = 0
    /// DB operations started from the app. They live in the engine, so they
    /// keep running when the sheet is closed and the user works elsewhere.
    @Published private(set) var dbJobs: [DBJob] = []
    /// The last finished operation. Only one notice is shown at a time: the
    /// next one replaces it. The full history lives in the DB operations
    /// sheet, which lists every operation of the service.
    @Published private(set) var dbNotice: DBJobNotice?
    /// Bumped every time an operation finishes, so open sheets can refresh.
    @Published private(set) var dbFinishedCount = 0 {
        didSet {
            guard section == .portForward else { return }
            Task { await refreshEnvironmentDetail() }
        }
    }

    private var client: EngineClient?
    private var pollTask: Task<Void, Never>?
    private var dbPoller: Task<Void, Never>?
    private var didBootstrap = false

    // MARK: - Derived state

    var selectedProfile: Profile? {
        guard let selectedProfileName else { return nil }
        return profiles.first { $0.name == selectedProfileName }
    }

    /// The workspace is the Stackr profile: one project, two sections.
    var workspaceName: String { selectedProfile?.name ?? "" }

    /// Docker services always live in the environment named `local`.
    var dockerEnvironment: ProfileEnvironment? {
        guard let profile = selectedProfile else { return nil }
        return profile.environments.first { $0.name == "local" }
            ?? profile.environments.first { $0.serviceCount > 0 }
            ?? profile.environments.first
    }

    /// The environments of the workspace that are not the docker one: the
    /// Kubernetes ones. A new one starts empty, and the port forwards are
    /// added inside it.
    var k8sEnvironments: [ProfileEnvironment] {
        guard let profile = selectedProfile else { return [] }
        return profile.environments.filter { $0.name != "local" }
    }

    /// The Kubernetes environment in use: the one the user picked, or the
    /// first one when there is none picked yet.
    var portForwardEnvironment: ProfileEnvironment? {
        let environments = k8sEnvironments
        if let picked = environments.first(where: { $0.name == selectedK8sEnvName }) {
            return picked
        }
        return environments.first
    }

    var portForwardCount: Int { environmentDetail?.portForwards.count ?? portForwardEnvironment?.portForwardCount ?? 0 }

    var runningForwardCount: Int {
        (environmentDetail?.portForwards ?? []).filter(\.isRunning).count
    }

    var localProcesses: [LocalProcessInfo] { dockerDetail?.localProcesses ?? [] }

    var runningLocalProcessCount: Int { localProcesses.filter(\.isRunning).count }

    var services: [ServiceStatus] {
        status?.services ?? []
    }

    var hasRunningServices: Bool {
        services.contains { $0.isRunning }
    }

    var runningCount: Int {
        services.filter(\.isRunning).count
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        bootPhase = .starting

        do {
            let client = try await EngineRuntime.shared.start()
            self.client = client

            let health: HealthResponse = try await client.get("/api/health")
            engineVersion = health.version
            configPath = health.configPath
            dockerAvailable = health.dockerAvailable

            try await reloadProfiles()
            selectInitialProfile()
            if selectedProfile != nil {
                await refreshStatus()
                await refreshDockerDetail()
            }
            catalog = (try? await client.get("/api/hub/catalog")) ?? []
            bootPhase = .ready
            startPolling()
        } catch {
            bootPhase = .failed(error.localizedDescription)
        }
    }

    func retryBootstrap() async {
        EngineRuntime.shared.stop()
        client = nil
        pollTask?.cancel()
        didBootstrap = false
        await bootstrap()
    }

    // MARK: - Selection

    func select(profile: Profile) {
        let changed = selectedProfileName != profile.name
        selectedProfileName = profile.name
        let env = profile.environments.first { $0.name == "local" }
            ?? profile.environments.first { $0.serviceCount > 0 }
            ?? profile.environments.first
        selectedEnvName = env?.name
        reconcileK8sEnvironment(profile)
        if changed {
            status = nil
            environmentDetail = nil
            dockerDetail = nil
        }
        Task {
            await refreshStatus()
            await refreshDockerDetail()
            if section == .portForward {
                await refreshEnvironmentDetail()
            }
        }
    }

    /// Picks another Kubernetes environment and loads what it holds.
    func selectK8sEnvironment(_ name: String) {
        guard name != selectedK8sEnvName else { return }
        selectedK8sEnvName = name
        environmentDetail = nil
        Task { await refreshEnvironmentDetail() }
    }

    /// Creates a Kubernetes environment. It starts empty: the port forwards
    /// are added inside it.
    func createK8sEnvironment(name: String) async -> Bool {
        guard let client, let profileName = selectedProfileName else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let _: Profile = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs",
                body: CreateEnvironmentRequest(name: trimmed)
            )
            try await reloadProfiles()
            selectedK8sEnvName = trimmed
            await refreshEnvironmentDetail()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Keeps the picked Kubernetes environment when it still exists.
    private func reconcileK8sEnvironment(_ profile: Profile) {
        let environments = profile.environments.filter { $0.name != "local" }
        if !environments.contains(where: { $0.name == selectedK8sEnvName }) {
            selectedK8sEnvName = environments.first?.name ?? ""
        }
    }

    func selectSection(_ newSection: AppSection) {
        section = newSection
        if newSection == .portForward {
            Task { await refreshEnvironmentDetail() }
        }
    }

    // MARK: - Refresh

    func refreshAll() async {
        await refreshHealth()
        do {
            try await reloadProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshStatus()
        await refreshDockerDetail()
        await refreshEnvironmentDetail()
        await refreshGit()
        refreshToken += 1
    }

    /// Reloads the state of the repository. A failure here is not an error of
    /// the app: the section simply has nothing to show.
    func refreshGit() async {
        guard let client, let profileName = selectedProfileName else { return }
        gitState = try? await client.get(
            "/api/profiles/\(profileName.pathComponentEncoded)/gitops"
        )
    }

    func refreshHealth() async {
        guard let client else { return }
        if let health: HealthResponse = try? await client.get("/api/health") {
            dockerAvailable = health.dockerAvailable
            engineVersion = health.version
        }
    }

    func refreshStatus() async {
        guard let client,
              !isRefreshing,
              let profileName = selectedProfileName,
              let envName = selectedEnvName else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let response: StatusResponse = try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/status"
            )
            // Ignore a response that arrived after the user switched selection.
            if selectedProfileName == profileName, selectedEnvName == envName {
                status = response
                dockerAvailable = response.dockerAvailable
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshDockerDetail() async {
        guard let client,
              let profileName = selectedProfileName,
              let env = dockerEnvironment else {
            dockerDetail = nil
            return
        }
        do {
            let detail: EnvironmentDetail = try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)"
            )
            if selectedProfileName == profileName {
                dockerDetail = detail
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshEnvironmentDetail() async {
        guard let client,
              let profileName = selectedProfileName,
              let env = portForwardEnvironment else {
            environmentDetail = nil
            return
        }
        do {
            let detail: EnvironmentDetail = try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)"
            )
            if selectedProfileName == profileName {
                environmentDetail = detail
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadProfiles() async throws {
        guard let client else { return }
        let loaded: [Profile] = try await client.get("/api/profiles")
        profiles = loaded
        reconcileSelection()
    }

    private func selectInitialProfile() {
        guard selectedProfile == nil, let first = profiles.first else { return }
        select(profile: first)
    }

    private func reconcileSelection() {
        guard let selectedProfileName,
              let profile = profiles.first(where: { $0.name == selectedProfileName }) else {
            if let first = profiles.first {
                select(profile: first)
            } else {
                self.selectedProfileName = nil
                self.selectedEnvName = nil
                status = nil
            }
            return
        }

        if !profile.environments.contains(where: { $0.name == selectedEnvName }) {
            let env = profile.environments.first { $0.name == "local" }
                ?? profile.environments.first { $0.serviceCount > 0 }
                ?? profile.environments.first
            self.selectedEnvName = env?.name
            status = nil
        }

        reconcileK8sEnvironment(profile)
    }

    // MARK: - Actions

    func performEnvAction(_ action: String) async {
        guard let client, let profileName = selectedProfileName, let envName = selectedEnvName else { return }
        await run(action: "\(action) all") {
            try await client.postVoid(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/actions/\(action)"
            )
        }
    }

    func performServiceAction(_ action: String, service: ServiceStatus) async {
        guard let client, let profileName = selectedProfileName, let envName = selectedEnvName else { return }
        await run(action: "\(action) \(service.name)") {
            try await client.postVoid(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/services/\(service.name.pathComponentEncoded)/actions/\(action)"
            )
        }
    }

    func deleteService(named name: String) async -> Bool {
        guard let client, let profileName = selectedProfileName, let envName = selectedEnvName else { return false }
        var success = false
        await run(action: "delete \(name)") {
            let _: Profile = try await client.delete(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/services/\(name.pathComponentEncoded)"
            )
            try await self.reloadProfiles()
            success = true
        }
        return success
    }

    // MARK: - Port forwards

    var portForwardEnvName: String? { portForwardEnvironment?.name }

    func k8sAvailable() async -> Bool {
        guard let client else { return false }
        struct Response: Decodable { let available: Bool }
        let response: Response? = try? await client.get("/api/k8s/status")
        return response?.available ?? false
    }

    func k8sContexts() async throws -> [String] {
        guard let client else { return [] }
        return try await client.get("/api/k8s/contexts")
    }

    func k8sNamespaces(context: String) async throws -> [String] {
        guard let client else { return [] }
        return try await client.get(
            "/api/k8s/namespaces",
            query: [URLQueryItem(name: "context", value: context)]
        )
    }

    func k8sServices(context: String, namespace: String) async throws -> [DiscoveredService] {
        guard let client else { return [] }
        return try await client.get(
            "/api/k8s/services",
            query: [
                URLQueryItem(name: "context", value: context),
                URLQueryItem(name: "namespace", value: namespace),
            ]
        )
    }

    /// The deployments of a namespace, for the manager.
    ///
    /// The error comes back to the caller instead of the global error
    /// banner: the manager is a window, and the banner of the app would stay
    /// behind it. The manager also asks for the list every few seconds, and
    /// it must not take the error of the app away.
    func k8sDeployments(context: String, namespace: String) async -> (deployments: [K8sDeployment]?, error: String?) {
        guard let client else { return (nil, "The engine is not running.") }
        do {
            let deployments: [K8sDeployment] = try await client.get(
                "/api/k8s/deployments",
                query: [
                    URLQueryItem(name: "context", value: context),
                    URLQueryItem(name: "namespace", value: namespace),
                ]
            )
            return (deployments, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Runs one action of the manager over a deployment.
    ///
    /// The error comes back to the caller instead of the global error
    /// banner: the manager is a window, and the banner of the app would stay
    /// behind it.
    func runK8sDeploymentAction(
        _ action: String,
        context: String,
        namespace: String,
        deployment: String,
        replicas: Int? = nil
    ) async -> (output: String?, error: String?) {
        guard let client else { return (nil, "The engine is not running.") }
        var query = [
            URLQueryItem(name: "context", value: context),
            URLQueryItem(name: "namespace", value: namespace),
            URLQueryItem(name: "deployment", value: deployment),
        ]
        if let replicas {
            query.append(URLQueryItem(name: "replicas", value: "\(replicas)"))
        }
        do {
            let result: K8sActionResult = try await client.post(
                "/api/k8s/deployments/\(action)",
                query: query
            )
            return (result.output, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// The live logs of a deployment.
    ///
    /// The stream follows the deployment: the last lines come first and the
    /// new ones arrive while the window is open.
    func k8sDeploymentLogs(
        context: String,
        namespace: String,
        deployment: String,
        lines: Int = 100
    ) -> AsyncThrowingStream<String, Error>? {
        guard let client, selectedProfileName != nil else { return nil }
        return client.stream(
            "/api/k8s/deployments/\(deployment.pathComponentEncoded)/logs",
            query: [
                URLQueryItem(name: "context", value: context),
                URLQueryItem(name: "namespace", value: namespace),
                URLQueryItem(name: "lines", value: "\(lines)"),
            ]
        )
    }

    /// First local port from 8080 that no configured forward already uses.
    func nextFreeLocalPort() -> Int {
        let used = Set((environmentDetail?.portForwards ?? []).map(\.localPort))
        var port = 8080
        while used.contains(port) { port += 1 }
        return port
    }

    func addPortForward(
        name: String,
        localPort: Int,
        remotePort: Int,
        context: String,
        namespace: String,
        service: String
    ) async -> Bool {
        guard let client, let profileName = selectedProfileName, let env = portForwardEnvironment else { return false }
        var success = false
        await runPortForward(action: "add \(name)") {
            let detail: EnvironmentDetail = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/port-forwards",
                body: PortForwardRequest(
                    name: name,
                    localPort: localPort,
                    remotePort: remotePort,
                    k8sContext: context,
                    k8sNamespace: namespace,
                    k8sService: service
                )
            )
            self.environmentDetail = detail
            success = true
        }
        return success
    }

    func updatePortForward(named name: String, localPort: Int) async -> Bool {
        guard let client, let profileName = selectedProfileName, let env = portForwardEnvironment else { return false }
        guard let existing = environmentDetail?.portForwards.first(where: { $0.name == name }) else { return false }
        var success = false
        await runPortForward(action: "update \(name)") {
            let detail: EnvironmentDetail = try await client.patch(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/port-forwards/\(name.pathComponentEncoded)",
                body: PortForwardRequest(
                    name: existing.name,
                    localPort: localPort,
                    remotePort: existing.remotePort,
                    k8sContext: existing.k8sContext,
                    k8sNamespace: existing.k8sNamespace,
                    k8sService: existing.k8sService
                )
            )
            self.environmentDetail = detail
            success = true
        }
        return success
    }

    func deletePortForward(named name: String) async -> Bool {
        guard let client, let profileName = selectedProfileName, let env = portForwardEnvironment else { return false }
        var success = false
        await runPortForward(action: "delete \(name)") {
            try await client.deleteVoid(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/port-forwards/\(name.pathComponentEncoded)"
            )
            success = true
        }
        return success
    }

    func startPortForward(_ forward: PortForwardInfo) async {
        guard let client, let profileName = selectedProfileName, let env = portForwardEnvironment else { return }
        await runPortForward(action: "start \(forward.name)") {
            let _: PortForwardRuntime = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/port-forwards/\(forward.name.pathComponentEncoded)/actions/start"
            )
        }
    }

    func stopPortForward(_ forward: PortForwardInfo) async {
        guard let client, let profileName = selectedProfileName, let env = portForwardEnvironment else { return }
        await runPortForward(action: "stop \(forward.name)") {
            let _: PortForwardRuntime = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/port-forwards/\(forward.name.pathComponentEncoded)/actions/stop"
            )
        }
    }

    func startAllPortForwards() async {
        await performPortForwardsAction("start")
    }

    func stopAllPortForwards() async {
        await performPortForwardsAction("stop")
    }

    private func performPortForwardsAction(_ action: String) async {
        guard let client, let profileName = selectedProfileName, let env = portForwardEnvironment else { return }
        await runPortForward(action: "\(action) all port-forwards") {
            let detail: EnvironmentDetail = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/port-forwards/actions/\(action)"
            )
            self.environmentDetail = detail
        }
    }

    private func runPortForward(action: String, operation: @escaping () async throws -> Void) async {
        guard runningAction == nil else { return }
        runningAction = action
        defer { runningAction = nil }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshEnvironmentDetail()
        try? await reloadProfiles()
    }

    func createWorkspace(name: String, description: String) async -> Bool {
        guard let client else { return false }
        do {
            let profile: Profile = try await client.post(
                "/api/profiles",
                body: CreateProfileRequest(
                    name: name,
                    description: description,
                    // Only the docker environment: the Kubernetes ones are
                    // created from the section, and they start empty.
                    environments: ["local"]
                )
            )
            try await reloadProfiles()
            if let created = profiles.first(where: { $0.name == profile.name }) {
                select(profile: created)
            }
            await refreshStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateWorkspaceDescription(_ description: String) async -> Bool {
        guard let client, let profileName = selectedProfileName else { return false }
        do {
            let _: Profile = try await client.patch(
                "/api/profiles/\(profileName.pathComponentEncoded)",
                body: UpdateProfileRequest(description: description)
            )
            try await reloadProfiles()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteWorkspace() async -> Bool {
        guard let client, let profileName = selectedProfileName else { return false }
        runningAction = "delete workspace"
        defer { runningAction = nil }
        do {
            try await client.deleteVoid("/api/profiles/\(profileName.pathComponentEncoded)")
            selectedProfileName = nil
            selectedEnvName = nil
            status = nil
            environmentDetail = nil
            dockerDetail = nil
            try await reloadProfiles()
            await refreshStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addService(
        name: String,
        image: String,
        tag: String,
        ports: [PortConfig],
        envVars: [EnvVarConfig],
        volumes: [VolumeConfig]
    ) async -> Bool {
        guard let client, let profileName = selectedProfileName, let envName = selectedEnvName else { return false }

        do {
            let _: Profile = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/services",
                body: CreateServiceRequest(
                    name: name,
                    image: image,
                    tag: tag,
                    ports: ports,
                    envVars: envVars,
                    volumes: volumes
                )
            )
            try await reloadProfiles()
            await refreshStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Defaults for a known image, from the curated catalog. Accepts a full
    /// reference (`postgres:16`, `library/redis`) or a bare image name.
    func catalogDefaults(forImage image: String) -> CatalogEntry? {
        var base = image.trimmingCharacters(in: .whitespaces)
        if let colon = base.firstIndex(of: ":") {
            base = String(base[base.startIndex..<colon])
        }
        if base.hasPrefix("library/") {
            base.removeFirst("library/".count)
        }
        return catalog.first { $0.image == base }
    }

    func serviceConfig(named name: String) async -> ServiceConfig? {
        guard let client, let profileName = selectedProfileName, let envName = selectedEnvName else { return nil }
        do {
            return try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/services/\(name.pathComponentEncoded)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateService(
        named name: String,
        image: String,
        tag: String,
        ports: [PortConfig],
        envVars: [EnvVarConfig],
        volumes: [VolumeConfig]
    ) async -> Bool {
        guard let client, let profileName = selectedProfileName, let envName = selectedEnvName else { return false }
        do {
            let _: Profile = try await client.patch(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/services/\(name.pathComponentEncoded)",
                body: UpdateServiceRequest(
                    image: image,
                    tag: tag,
                    ports: ports,
                    envVars: envVars,
                    volumes: volumes
                )
            )
            try await reloadProfiles()
            await refreshStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func fetchTags(for image: String, limit: Int = 20) async -> [String] {
        guard let client, !image.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do {
            let tags: [HubTag] = try await client.get(
                "/api/hub/tags",
                query: [
                    URLQueryItem(name: "image", value: image),
                    URLQueryItem(name: "limit", value: String(limit)),
                ]
            )
            return tags.map(\.name)
        } catch {
            return []
        }
    }

    func searchHub(_ query: String) async -> [HubResult] {
        guard let client, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do {
            return try await client.get(
                "/api/hub/search",
                query: [URLQueryItem(name: "q", value: query)]
            )
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func launchDocker() async {
        guard let client else { return }
        await run(action: "starting Docker") {
            try await client.postVoid("/api/docker/launch")
            await self.refreshHealth()
        }
    }

    // MARK: - Logs

    func logStream(service: String?) -> AsyncThrowingStream<String, Error>? {
        guard let client, let profileName = selectedProfileName, let envName = selectedEnvName else {
            return nil
        }
        var query = [URLQueryItem(name: "follow", value: "true")]
        if let service, !service.isEmpty {
            query.append(URLQueryItem(name: "service", value: service))
        }
        return client.stream(
            "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/logs",
            query: query
        )
    }

    // MARK: - Internals

    private func run(action: String, operation: @escaping () async throws -> Void) async {
        guard runningAction == nil else { return }
        runningAction = action
        defer { runningAction = nil }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshHealth()
        await refreshStatus()
        await refreshDockerDetail()
    }

    // MARK: - Local processes

    func addLocalProcess(name: String, command: String, workDir: String) async -> Bool {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return false }
        var success = false
        await run(action: "add \(name)") {
            let detail: EnvironmentDetail = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/local-processes",
                body: LocalProcessRequest(name: name, command: command, workDir: workDir)
            )
            self.dockerDetail = detail
            success = true
        }
        return success
    }

    // MARK: - Request operations

    func addFolder(name: String, url: String, env: String) async -> RequestsResponse? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/requests/folders",
                body: FolderDraft(name: name, url: url, env: env)
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateFolder(name: String, originalName: String, url: String, env: String) async -> RequestsResponse? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.patch(
                "/api/profiles/\(profileName.pathComponentEncoded)/requests/folders/\(originalName.pathComponentEncoded)",
                body: FolderDraft(name: name, url: url, env: env)
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteFolder(name: String) async -> RequestsResponse? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.delete(
                "/api/profiles/\(profileName.pathComponentEncoded)/requests/folders/\(name.pathComponentEncoded)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func addRequest(_ draft: RequestDraft) async -> RequestsResponse? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/requests/items",
                body: draft
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateRequest(_ draft: RequestDraft, originalName: String) async -> RequestsResponse? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.patch(
                "/api/profiles/\(profileName.pathComponentEncoded)/requests/items/\(originalName.pathComponentEncoded)",
                body: draft
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteRequest(name: String) async -> RequestsResponse? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.delete(
                "/api/profiles/\(profileName.pathComponentEncoded)/requests/items/\(name.pathComponentEncoded)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func addRequestEnv(name: String) async -> RequestsResponse? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/requests/envs",
                body: RequestEnvDraft(name: name)
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteRequestEnv(name: String) async -> RequestsResponse? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.delete(
                "/api/profiles/\(profileName.pathComponentEncoded)/requests/envs/\(name.pathComponentEncoded)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }


    func fetchRequests() async -> RequestsResponse? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.get("/api/profiles/\(profileName.pathComponentEncoded)/requests")
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Runs a request of a request environment. The values of the variables
    /// are the ones the user confirmed in the prompt.
    /// Runs a request of a request environment. The values of the variables
    /// are the ones the user confirmed. The error is returned instead of
    /// being left in the global error banner: a request that fails is
    /// reported with a notice, the same way an operation is.
    /// Runs a request and keeps it in the list of running ones until it
    /// finishes or it is cancelled.
    func runRequestTracked(
        env: String,
        request: RequestDefinition,
        variables: [String: String]
    ) async -> (result: RequestRunResult?, error: String?) {
        let key = requestRunKey(env: env, request: request.name)
        guard !runningRequests.contains(key) else {
            return (nil, "The request is already running.")
        }

        runningRequests.insert(key)
        let outcome = await withTaskCancellationHandler {
            await runRequest(env: env, request: request.name, variables: variables)
        } onCancel: {
            Task { await self.cancelRequestOnEngine(env: env, request: request.name) }
        }
        runningRequests.remove(key)
        requestTasks.removeValue(forKey: key)
        return outcome
    }

    /// Marks that the window of a request was closed while it was running.
    func markRequestWindowClosed(env: String, request: String) {
        closedRequestWindows.insert(requestRunKey(env: env, request: request))
    }

    /// Clears the mark of a closed window: it belongs to one run only.
    func clearRequestWindowClosed(env: String, request: String) {
        closedRequestWindows.remove(requestRunKey(env: env, request: request))
    }

    /// Whether the result of a request has to be reported with a notice: it
    /// does when the window was closed while the request was running.
    func shouldReportRequest(env: String, request: String) -> Bool {
        closedRequestWindows.contains(requestRunKey(env: env, request: request))
    }

    /// Whether a request is running right now.
    func isRequestRunning(_ request: RequestDefinition, env: String) -> Bool {
        runningRequests.contains(requestRunKey(env: env, request: request.name))
    }

    /// Stops a request that is running.
    func cancelRequest(_ request: RequestDefinition, env: String) async {
        let key = requestRunKey(env: env, request: request.name)
        requestTasks[key]?.cancel()
        requestTasks.removeValue(forKey: key)
        runningRequests.remove(key)
        await cancelRequestOnEngine(env: env, request: request.name)
    }

    /// Asks the engine to stop the run.
    func cancelRequestOnEngine(env: String, request: String) async {
        guard let client, let profileName = selectedProfileName else { return }
        _ = try? await client.deleteVoid(
            "/api/profiles/\(profileName.pathComponentEncoded)/requests/run",
            body: RequestRunPayload(env: env, request: request, variables: [:])
        )
    }

    /// The key that identifies a request of the collection.
    func requestRunKey(env: String, request: String) -> String {
        "\(env)/\(request)"
    }

    func runRequest(env: String, request: String, variables: [String: String]) async -> (result: RequestRunResult?, error: String?) {
        guard let client, let profileName = selectedProfileName else {
            return (nil, "The engine is not running.")
        }
        do {
            let result: RequestRunResult = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/requests/run",
                body: RequestRunPayload(env: env, request: request, variables: variables)
            )
            return (result, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Reports the result of a request with a notice, the same way the
    /// operations report theirs.
    func reportRequest(
        _ request: RequestDefinition,
        env: RequestEnvironment,
        result: RequestRunResult?,
        error: String?
    ) {
        let succeeded = result?.isSuccess == true
        dbNotice = DBJobNotice(
            id: "request-\(request.name)-\(Date().timeIntervalSince1970)",
            service: request.baseUrlName,
            label: request.name,
            syncEnv: env.name,
            succeeded: succeeded,
            detail: succeeded ? (result?.body ?? "") : (error ?? "The request failed."),
            finishedAt: isoNow()
        )
    }

    /// The current time in the format the engine uses.
    func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Mock operations

    func fetchMockOps(service: String) async -> MockOpsInfo? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            return try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/mockops"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func runMockOp(service: String, action: String, params: [String: String]) async -> MockRunResult? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            return try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/mockops/run",
                body: MockRunPayload(action: action, params: params)
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Git operations

    /// The state of the repository the app was launched from.
    func fetchGitState() async -> GitState? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/gitops"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Runs one git operation and returns its output.
    func runGitOp(op: String, params: [String: String] = [:]) async -> GitOpResult? {
        guard let client, let profileName = selectedProfileName else { return nil }
        do {
            return try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/gitops/run",
                body: GitOpPayload(op: op, params: params)
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Reports the result of a git operation with the notice every operation
    /// of the app uses, so the git section shows it the same way the rest of
    /// the app does. The notice lives five seconds, like the message of the
    /// console runtime.
    func reportGitOperation(op: String, detail: String, succeeded: Bool) {
        let root = gitState?.root ?? ""
        let repository = root.split(separator: "/").last.map(String.init) ?? "Git"
        dbNotice = DBJobNotice(
            id: "git-\(op)-\(Date().timeIntervalSince1970)",
            service: repository,
            label: gitOperationLabel(op),
            syncEnv: gitState?.branch ?? "",
            succeeded: succeeded,
            detail: detail,
            finishedAt: isoNow(),
            seconds: 5
        )
    }

    /// The name of a git operation, as the notice shows it.
    private func gitOperationLabel(_ op: String) -> String {
        switch op {
        case "stage": return "Stage"
        case "stage_all": return "Stage all"
        case "unstage": return "Unstage"
        case "unstage_all": return "Unstage all"
        case "commit": return "Commit"
        case "amend": return "Amend"
        case "discard": return "Discard"
        case "checkout": return "Checkout"
        case "create_branch": return "Create branch"
        case "delete_branch": return "Delete branch"
        case "merge", "merge_continue": return "Merge"
        case "merge_abort": return "Abort merge"
        case "push": return "Push"
        case "pull": return "Pull"
        case "stash": return "Stash"
        case "stash_pop": return "Stash pop"
        case "cherry_pick": return "Cherry-pick"
        case "resolve_ours", "resolve_theirs": return "Resolve"
        case "rebase_continue": return "Rebase"
        case "rebase_abort": return "Abort rebase"
        default: return op
        }
    }

    // MARK: - Queue operations

    func fetchQueueOps(service: String) async -> QueueOpsInfo? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            return try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/queueops"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func runQueueOp(service: String, env: String, action: String, params: [String: String]) async -> QueueRunResult? {
        guard let client, let profileName = selectedProfileName, let dockerEnv = dockerEnvironment else { return nil }
        do {
            return try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(dockerEnv.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/queueops/run",
                body: QueueRunPayload(env: env, action: action, params: params)
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func saveQueueEnv(service: String, originalName: String?, draft: QueueEnvDraft) async -> QueueOpsInfo? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        let base = "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/queueops/sync-envs"
        do {
            if let originalName {
                return try await client.patch("\(base)/\(originalName.pathComponentEncoded)", body: draft)
            }
            return try await client.post(base, body: draft)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteQueueEnv(service: String, name: String) async -> QueueOpsInfo? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            return try await client.delete(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/queueops/sync-envs/\(name.pathComponentEncoded)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func addQueueCustom(service: String, env: String, draft: QueueCustomDraft) async -> QueueOpsInfo? {
        guard let client, let profileName = selectedProfileName, let dockerEnv = dockerEnvironment else { return nil }
        do {
            return try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(dockerEnv.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/queueops/sync-envs/\(env.pathComponentEncoded)/actions",
                body: draft
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateQueueCustom(service: String, env: String, action: String, draft: QueueCustomDraft) async -> QueueOpsInfo? {
        guard let client, let profileName = selectedProfileName, let dockerEnv = dockerEnvironment else { return nil }
        do {
            return try await client.patch(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(dockerEnv.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/queueops/sync-envs/\(env.pathComponentEncoded)/actions/\(action.pathComponentEncoded)",
                body: draft
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteQueueCustom(service: String, env: String, action: String) async -> QueueOpsInfo? {
        guard let client, let profileName = selectedProfileName, let dockerEnv = dockerEnvironment else { return nil }
        do {
            return try await client.delete(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(dockerEnv.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/queueops/sync-envs/\(env.pathComponentEncoded)/actions/\(action.pathComponentEncoded)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - DB operations

    func fetchDBOps(service: String) async -> DBOpsInfo? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            return try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/dbops"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Starts a DB operation and keeps track of it until it finishes.
    func runDBOp(service: String, syncEnv: String, action: String, label: String? = nil) async -> DBJob? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            let job: DBJob = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/dbops/\(action)",
                body: DBJobRequest(syncEnv: syncEnv)
            )
            track(job, service: service, syncEnv: syncEnv, label: label)
            return job
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// The jobs the engine keeps for a service, newest first.
    func fetchDBJobs(service: String) async -> [DBJob] {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return [] }
        let jobs: [DBJob] = (try? await client.get(
            "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/dbops/jobs"
        )) ?? []
        return jobs
    }

    /// Registers a job and makes sure something polls it.
    private func track(_ job: DBJob, service: String, syncEnv: String, label: String?) {
        var tracked = job
        tracked.service = job.service ?? service
        tracked.syncEnv = job.syncEnv ?? syncEnv
        if tracked.label == nil || tracked.label?.isEmpty == true {
            tracked.label = label ?? job.action ?? "Operation"
        }
        tracked.profile = tracked.profile ?? selectedProfileName
        tracked.env = tracked.env ?? dockerEnvironment?.name
        dbJobs.removeAll { $0.id == tracked.id }
        dbJobs.insert(tracked, at: 0)
        ensureDBPoller()
    }

    /// Adopts the jobs the engine still remembers for a service, so a sheet
    /// opened later shows the operations that already ran.
    func adoptDBJobs(_ jobs: [DBJob], service: String) {
        for job in jobs {
            var adopted = job
            adopted.service = adopted.service ?? service
            adopted.profile = adopted.profile ?? selectedProfileName
            adopted.env = adopted.env ?? dockerEnvironment?.name
            if let index = dbJobs.firstIndex(where: { $0.id == adopted.id }) {
                dbJobs[index] = adopted
            } else {
                dbJobs.append(adopted)
            }
        }
        dbJobs.sort { $0.startedAt > $1.startedAt }
        if dbJobs.contains(where: { $0.isRunning }) {
            ensureDBPoller()
        }
    }

    /// Polls every running job until they finish. The jobs live in the
    /// engine, so this keeps working across sheets and workspace changes.
    private func ensureDBPoller() {
        guard dbPoller == nil else { return }
        dbPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self else { return }
                await self.pollDBJobs()
                if !self.dbJobs.contains(where: { $0.isRunning }) {
                    self.dbPoller = nil
                    return
                }
            }
        }
    }

    private func pollDBJobs() async {
        for index in dbJobs.indices where dbJobs[index].isRunning {
            let current = dbJobs[index]
            guard let service = current.service, !current.id.isEmpty else { continue }
            let id = current.id
            guard let latest = await fetchDBJob(profile: current.profile, env: current.env, service: service, id: id) else { continue }
            dbJobs[index] = latest
            if !latest.isRunning {
                dbFinishedCount += 1
                dbNotice = DBJobNotice(
                    id: latest.id,
                    service: service,
                    label: latest.label ?? "Operation",
                    syncEnv: latest.syncEnv ?? "",
                    succeeded: latest.isDone,
                    detail: latest.error ?? latest.output ?? "",
                    finishedAt: latest.finishedAt ?? latest.startedAt
                )
            }
        }
    }

    func dismissDBNotice() {
        dbNotice = nil
    }

    func fetchDBJob(profile: String?, env: String?, service: String, id: String) async -> DBJob? {
        guard let client else { return nil }
        let profileName = profile ?? selectedProfileName
        guard let profileName, let envName = env ?? dockerEnvironment?.name else { return nil }
        do {
            return try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/services/\(service.pathComponentEncoded)/dbops/jobs/\(id.pathComponentEncoded)"
            )
        } catch {
            return nil
        }
    }

    func saveSyncEnv(service: String, originalName: String?, draft: SyncEnvDraft) async -> DBOpsInfo? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        let base = "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/sync-envs"
        do {
            if let originalName {
                return try await client.patch("\(base)/\(originalName.pathComponentEncoded)", body: draft)
            }
            return try await client.post(base, body: draft)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func saveCustomAction(
        service: String,
        syncEnv: String,
        originalName: String?,
        draft: CustomActionDraft
    ) async -> DBOpsInfo? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        let base = "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/sync-envs/\(syncEnv.pathComponentEncoded)/custom-actions"
        do {
            if let originalName {
                return try await client.patch("\(base)/\(originalName.pathComponentEncoded)", body: draft)
            }
            return try await client.post(base, body: draft)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteCustomAction(service: String, syncEnv: String, name: String) async -> DBOpsInfo? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            return try await client.delete(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/sync-envs/\(syncEnv.pathComponentEncoded)/custom-actions/\(name.pathComponentEncoded)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func runCustomAction(
        service: String,
        syncEnv: String,
        name: String,
        params: [String: String]
    ) async -> DBJob? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            let job: DBJob = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/dbops/custom/\(name.pathComponentEncoded)",
                body: CustomActionRunRequest(syncEnv: syncEnv, params: params)
            )
            track(job, service: service, syncEnv: syncEnv, label: name)
            return job
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteSyncEnv(service: String, name: String) async -> DBOpsInfo? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            return try await client.delete(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/sync-envs/\(name.pathComponentEncoded)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteLocalProcess(named name: String) async -> Bool {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return false }
        var success = false
        await run(action: "delete \(name)") {
            try await client.deleteVoid(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/local-processes/\(name.pathComponentEncoded)"
            )
            success = true
        }
        return success
    }

    func startLocalProcess(_ process: LocalProcessInfo) async {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return }
        await run(action: "start \(process.name)") {
            let _: LocalProcessRuntime = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/local-processes/\(process.name.pathComponentEncoded)/actions/start"
            )
        }
    }

    func stopLocalProcess(_ process: LocalProcessInfo) async {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return }
        await run(action: "stop \(process.name)") {
            let _: LocalProcessRuntime = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/local-processes/\(process.name.pathComponentEncoded)/actions/stop"
            )
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.runningAction == nil, self.selectedProfileName != nil {
                    await self.refreshStatus()
                    if self.section == .portForward {
                        await self.refreshEnvironmentDetail()
                    } else {
                        await self.refreshDockerDetail()
                    }
                }
            }
        }
    }
}
