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

    @Published var section: AppSection = .docker {
        didSet {
            guard section == .aws else { return }
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

    /// Everything that is not the Docker environment is exposed under AWS.
    var awsEnvironment: ProfileEnvironment? {
        guard let profile = selectedProfile else { return nil }
        return profile.environments.first { $0.name != "local" }
    }

    var portForwardCount: Int { environmentDetail?.portForwards.count ?? awsEnvironment?.portForwardCount ?? 0 }

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
            }
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
        }
        Task {
            await refreshStatus()
            if section == .aws {
                await refreshEnvironmentDetail()
            }
        }
    }

    func selectSection(_ newSection: AppSection) {
        section = newSection
        if newSection == .aws {
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

    func refreshEnvironmentDetail() async {
        guard let client,
              let profileName = selectedProfileName,
              let env = awsEnvironment else {
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
            try await reloadProfiles()
            await refreshStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addService(name: String, image: String, tag: String, hostPort: String, containerPort: String) async -> Bool {
        guard let client, let profileName = selectedProfileName, let envName = selectedEnvName else { return false }
        var ports: [PortMappingInput] = []
        let host = hostPort.trimmingCharacters(in: .whitespaces)
        let container = containerPort.trimmingCharacters(in: .whitespaces)
        if !host.isEmpty, !container.isEmpty {
            ports = [PortMappingInput(host: host, container: container)]
        }

        do {
            let _: Profile = try await client.post(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/services",
                body: CreateServiceRequest(name: name, image: image, tag: tag, ports: ports)
            )
            try await reloadProfiles()
            await refreshStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
        envVars: [EnvVarConfig]
    ) async -> Bool {
        guard let client, let profileName = selectedProfileName, let envName = selectedEnvName else { return false }
        do {
            let _: Profile = try await client.patch(
                "/api/profiles/\(profileName.pathComponentEncoded)/envs/\(envName.pathComponentEncoded)/services/\(name.pathComponentEncoded)",
                body: UpdateServiceRequest(image: image, tag: tag, ports: ports, envVars: envVars)
            )
            try await reloadProfiles()
            await refreshStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.runningAction == nil, self.selectedProfileName != nil {
                    await self.refreshStatus()
                }
            }
        }
    }
}
