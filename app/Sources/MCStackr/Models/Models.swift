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

    var id: String { name }
}

struct LocalProcessInfo: Codable, Identifiable, Hashable {
    let name: String
    let command: String
    let workDir: String

    var id: String { name }
}

enum AppSection: String, CaseIterable, Identifiable {
    case docker
    case aws

    var id: String { rawValue }

    var title: String {
        switch self {
        case .docker: return "Docker"
        case .aws: return "AWS"
        }
    }

    var systemImage: String {
        switch self {
        case .docker: return "shippingbox.fill"
        case .aws: return "cloud.fill"
        }
    }
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
