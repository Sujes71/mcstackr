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
    @Published private(set) var dockerDetail: EnvironmentDetail?
    @Published private(set) var catalog: [CatalogEntry] = []

    @Published var section: AppSection = .docker {
        didSet {
            guard section == .portForward else { return }
            Task { await refreshEnvironmentDetail() }
        }
    }

    private var client: EngineClient?
    private var pollTask: Task<Void, Never>?
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

    /// Every environment that is not `local` is a port-forward (Kubernetes) environment.
    var portForwardEnvironment: ProfileEnvironment? {
        guard let profile = selectedProfile else { return nil }
        return profile.environments.first { $0.name != "local" }
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
                    environments: ["local", "dev"]
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

    func runDBOp(service: String, syncEnv: String, action: String) async -> DBJob? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            return try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/dbops/\(action)",
                body: DBJobRequest(syncEnv: syncEnv)
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func fetchDBJob(service: String, id: String) async -> DBJob? {
        guard let client, let profileName = selectedProfileName, let env = dockerEnvironment else { return nil }
        do {
            return try await client.get(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/dbops/jobs/\(id)"
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
            return try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(env.name.pathComponentEncoded)/services/\(service.pathComponentEncoded)/dbops/custom/\(name.pathComponentEncoded)",
                body: CustomActionRunRequest(syncEnv: syncEnv, params: params)
            )
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
