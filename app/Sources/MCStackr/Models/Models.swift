import Foundation

// MARK: - Profiles

struct Profile: Codable, Identifiable, Hashable {
    let name: String
    let description: String?
    let activeEnv: String
    let environments: [ProfileEnvironment]

    var id: String { name }
}

struct ProfileEnvironment: Codable, Identifiable, Hashable {
    let name: String
    let serviceCount: Int
    let portForwardCount: Int
    let localProcessCount: Int

    var id: String { name }
}

// MARK: - Runtime status

struct ServiceStatus: Codable, Identifiable, Hashable {
    let name: String
    let container: String
    let fullImage: String
    let dbType: String?
    let kind: String?
    let state: String
    let health: String?
    let ports: String?

    var id: String { name }

    var isRunning: Bool { state.lowercased() == "running" }
    var isBusy: Bool {
        let s = state.lowercased()
        return s == "restarting" || s == "starting" || s == "created"
    }
    var isStopped: Bool {
        let s = state.lowercased()
        return s == "exited" || s == "stopped" || s == "dead"
    }
}

struct StatusResponse: Codable {
    let dockerAvailable: Bool
    let error: String?
    let services: [ServiceStatus]
    let refreshedAt: String
}

struct HealthResponse: Codable {
    let status: String
    let version: String
    let dockerAvailable: Bool
    let configPath: String
}

// MARK: - Docker Hub / images

struct HubResult: Codable, Identifiable, Hashable {
    let name: String
    let description: String
    let official: Bool
    let stars: Int
    let pulls: Int

    var id: String { name }
}

struct DockerImage: Codable, Identifiable, Hashable {
    let repository: String
    let tag: String
    let imageID: String
    let size: String

    var id: String { "\(repository):\(tag)" }

    enum CodingKeys: String, CodingKey {
        case repository
        case tag
        case imageID = "id"
        case size
    }
}

// MARK: - Requests

struct CreateProfileRequest: Encodable {
    let name: String
    let description: String
    let environments: [String]
}

struct PortConfig: Codable, Hashable {
    var host: String
    var container: String
}

struct EnvVarConfig: Codable, Hashable {
    var key: String
    var value: String
}

struct VolumeConfig: Codable, Hashable {
    var source: String
    var target: String
    var named: Bool
}

struct ServiceConfig: Codable {
    let name: String
    let image: String
    let tag: String
    let fullImage: String
    let ports: [PortConfig]
    let envVars: [EnvVarConfig]
    let volumes: [VolumeConfig]
}

struct UpdateServiceRequest: Encodable {
    let image: String
    let tag: String
    let ports: [PortConfig]
    let envVars: [EnvVarConfig]
    let volumes: [VolumeConfig]
}

struct HubTag: Decodable, Identifiable, Hashable {
    let name: String

    var id: String { name }
}

struct CatalogEntry: Codable, Identifiable, Hashable {
    let name: String
    let image: String
    let description: String
    let defaultTag: String
    let defaultPorts: [PortConfig]
    let defaultEnv: [EnvVarConfig]
    let defaultVolumeTarget: String

    var id: String { image }
}

struct EnvironmentDetail: Codable {
    let name: String
    let serviceCount: Int
    let portForwards: [PortForwardInfo]
    let localProcesses: [LocalProcessInfo]
}

struct PortForwardInfo: Codable, Identifiable, Hashable {
    let name: String
    let localPort: Int
    let remotePort: Int
    let k8sContext: String
    let k8sNamespace: String
    let k8sService: String
    let state: String
    let error: String?

    var id: String { name }

    var isRunning: Bool { state.lowercased() == "running" }
    var isBusy: Bool { state.lowercased() == "starting" }
}

struct DiscoveredService: Codable, Identifiable, Hashable {
    let name: String
    let remotePort: Int

    var id: String { name }
}

struct PortForwardRuntime: Codable {
    let state: String
    let error: String?
}

struct PortForwardRequest: Codable {
    let name: String
    let localPort: Int
    let remotePort: Int
    let k8sContext: String
    let k8sNamespace: String
    let k8sService: String
}

struct LocalProcessRuntime: Codable {
    let state: String
    let pid: Int?
}

struct LocalProcessRequest: Codable {
    let name: String
    let command: String
    let workDir: String
}

struct LocalProcessInfo: Codable, Identifiable, Hashable {
    let name: String
    let command: String
    let workDir: String
    let state: String
    let pid: Int?

    var id: String { name }
    var isRunning: Bool { state == "running" }
}

// MARK: - DB operations

struct DBOpsInfo: Codable {
    let service: String
    let dbType: String
    let running: Bool
    let syncEnvs: [DBSyncEnv]
}

struct DBSyncEnv: Codable, Identifiable, Hashable {
    let name: String
    let dbType: String
    let host: String
    let port: String
    let user: String
    let database: String
    let authDb: String?
    let toolImage: String
    let actions: [DBAction]
    let customActions: [CustomAction]
    let dumps: [DBDump]

    var id: String { name }
}

struct CustomAction: Codable, Identifiable, Hashable {
    let name: String
    let command: String

    var id: String { name }
}

struct CustomActionDraft: Encodable {
    let name: String
    let command: String
}

struct CustomActionRunRequest: Encodable {
    let syncEnv: String
    let params: [String: String]
}

struct DBAction: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let group: String
    let enabled: Bool
    let disabledReason: String?
    let destructive: Bool?
}

struct DBDump: Codable, Identifiable, Hashable {
    let file: String
    let kind: String
    let size: Int64
    let modifiedAt: String

    var id: String { file }
}

struct DBJob: Codable, Identifiable {
    let id: String
    let state: String
    let output: String?
    let error: String?
    let startedAt: String
    let finishedAt: String?

    // Context of the operation. The engine keeps the jobs after the sheet
    // that started them is closed, so the app can show them again.
    var service: String? = nil
    var syncEnv: String? = nil
    var action: String? = nil
    var label: String? = nil
    // Where the job was started. The app keeps them so a job can still be
    // followed after the user changes workspace.
    var profile: String? = nil
    var env: String? = nil

    var isRunning: Bool { state == "running" }
    var isDone: Bool { state == "done" }
    var isFailure: Bool { state == "error" }
}

/// The standard stamp of an operation: date and time, in the same format
/// everywhere it appears.
func operationStamp(_ iso: String) -> String {
    guard !iso.isEmpty else { return "" }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    guard let date = parser.date(from: iso) else { return "" }
    let formatter = DateFormatter()
    formatter.dateFormat = "dd/MM HH:mm"
    return formatter.string(from: date)
}

/// A finished operation, surfaced as a notice while the user works elsewhere.
struct DBJobNotice: Identifiable, Equatable {
    let id: String
    let service: String
    let label: String
    let syncEnv: String
    let succeeded: Bool
    let detail: String
    /// When the operation finished, so the notice can show the date.
    let finishedAt: String

    var title: String {
        succeeded ? "\(label) finished" : "\(label) failed"
    }
}

struct DBJobRequest: Codable {
    let syncEnv: String
}

/// Payload for creating or updating a sync environment. A nil password keeps
/// the stored one on update; an empty string clears it.
struct SyncEnvDraft: Encodable {
    var name: String
    var host: String
    var port: String
    var user: String
    var password: String?
    var database: String
    var authDb: String
    var toolImage: String
}

enum AppSection: String, CaseIterable, Identifiable {
    case docker
    case portForward
    case requests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .docker: return "Docker"
        case .portForward: return "Port Forwards"
        case .requests: return "Requests"
        }
    }

    var systemImage: String {
        switch self {
        case .docker: return "shippingbox.fill"
        case .portForward: return "arrow.left.arrow.right"
        case .requests: return "list.bullet.rectangle"
        }
    }
}

struct UpdateProfileRequest: Encodable {
    let description: String
}

struct CreateServiceRequest: Encodable {
    let name: String
    let image: String
    let tag: String
    let ports: [PortConfig]
    let envVars: [EnvVarConfig]
    let volumes: [VolumeConfig]
}

// MARK: - Engine errors

struct APIErrorBody: Codable {
    let error: String
}


// MARK: - Request operations

struct RequestBaseURL: Codable, Identifiable, Hashable {
    let name: String
    let url: String

    var id: String { name }
}

struct RequestVariable: Codable, Identifiable, Hashable {
    let name: String
    var value: String

    var id: String { name }
}

/// A request environment: its own base URLs and variables.
struct RequestEnvironment: Codable, Identifiable, Hashable {
    let name: String
    let baseUrls: [RequestBaseURL]
    var variables: [RequestVariable]

    var id: String { name }

    func value(for name: String) -> String {
        variables.first { $0.name == name }?.value ?? ""
    }
}

struct RequestKV: Codable, Hashable {
    let key: String
    let value: String
}

struct RequestDefinition: Codable, Identifiable, Hashable {
    let name: String
    let method: String
    let baseUrlName: String
    let path: String
    let isLogin: Bool
    let tokenPath: String
    let headers: [RequestKV]
    let params: [RequestKV]
    let body: String
    let variableRefs: [String]

    var id: String { name }
}

struct RequestsResponse: Codable {
    let envs: [RequestEnvironment]
    let folders: [String]
    let requests: [RequestDefinition]
}

struct RequestRunPayload: Encodable {
    let env: String
    let request: String
    let variables: [String: String]
}

struct RequestRunResult: Codable {
    let status: Int
    let statusText: String
    let body: String
    let durationMs: Int
    let token: String?
    let url: String

    var isSuccess: Bool { (200..<300).contains(status) }
}
