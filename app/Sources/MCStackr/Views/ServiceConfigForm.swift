import SwiftUI

struct ServiceConfigForm: View {
    var showName: Bool = true
    var nameHint: String? = nil

    @Binding var name: String
    @Binding var image: String
    @Binding var tag: String
    @Binding var ports: [PortConfig]
    @Binding var envVars: [EnvVarConfig]
    @Binding var volumes: [VolumeConfig]

    @State private var revealSecrets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showName {
                FormSection("Service") {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Name")
                        ThemedTextField(placeholder: "postgres", text: $name)
                        if let nameHint {
                            Text(nameHint)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                }
            }

            FormSection("Image") {
                HStack(alignment: .center, spacing: 12) {
                    ThemedTextField(placeholder: "image, e.g. postgres", text: $image)
                    ThemedTextField(placeholder: "tag, e.g. 16-alpine", text: $tag)
                        .frame(width: 170)
                }

                if let db = detectedDatabase {
                    Text("\(db) defaults are prefilled below. Edit anything you need.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
            }

            FormSection("Ports") {
                VStack(spacing: 8) {
                    ForEach($ports.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            ThemedTextField(placeholder: "Host", text: $ports[index].host)
                                .frame(width: 130)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textDim)
                            ThemedTextField(placeholder: "Container", text: $ports[index].container)
                                .frame(width: 130)
                            Spacer()
                            ActionIconButton(systemName: "minus.circle", tint: Theme.danger, help: "Remove port") {
                                ports.remove(at: index)
                            }
                        }
                    }

                    ActionTextButton(title: "Add port", systemName: "plus") {
                        ports.append(PortConfig(host: "", container: ""))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            FormSection("Environment Variables") {
                HStack {
                    Text("Values are stored in ~/.stackr/config.yaml")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Button {
                        revealSecrets.toggle()
                    } label: {
                        Text(revealSecrets ? "Hide secrets" : "Reveal secrets")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.info)
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 8) {
                    ForEach($envVars.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            ThemedTextField(placeholder: "KEY", text: $envVars[index].key)
                                .frame(width: 210)
                            if isSecretKey(envVars[index].key), !revealSecrets {
                                ThemedSecureField(placeholder: "value", text: $envVars[index].value)
                            } else {
                                ThemedTextField(placeholder: "value", text: $envVars[index].value)
                            }
                            ActionIconButton(systemName: "minus.circle", tint: Theme.danger, help: "Remove variable") {
                                envVars.remove(at: index)
                            }
                        }
                    }

                    ActionTextButton(title: "Add variable", systemName: "plus") {
                        envVars.append(EnvVarConfig(key: "", value: ""))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            FormSection("Volumes") {
                VStack(spacing: 8) {
                    ForEach($volumes.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            ThemedTextField(
                                placeholder: "source (empty = named volume)",
                                text: $volumes[index].source
                            )
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textDim)
                            ThemedTextField(placeholder: "/container/path", text: $volumes[index].target)
                            Toggle("Named", isOn: $volumes[index].named)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textMuted)
                            // A service keeps at least one volume: the data of
                            // a database lives in it.
                            if volumes.count > 1 {
                                ActionIconButton(systemName: "minus.circle", tint: Theme.danger, help: "Remove volume") {
                                    volumes.remove(at: index)
                                }
                            }
                        }
                    }

                    ActionTextButton(title: "Add volume", systemName: "plus") {
                        volumes.append(VolumeConfig(source: "", target: "", named: true))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var detectedDatabase: String? {
        let base = image.lowercased()
        if base.contains("postgres") { return "PostgreSQL" }
        if base.contains("mysql") || base.contains("mariadb") { return "MySQL" }
        if base.contains("mongo") { return "MongoDB" }
        if base.contains("redis") { return "Redis" }
        if base.contains("rabbitmq") { return "RabbitMQ" }
        if base.contains("kafka") { return "Kafka" }
        if base.contains("elasticsearch") { return "Elasticsearch" }
        if base.contains("minio") { return "MinIO" }
        if base.contains("activemq") { return "ActiveMQ" }
        return nil
    }

    private func isSecretKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return ["PASSWORD", "SECRET", "TOKEN", "API_KEY", "PRIVATE"].contains { upper.contains($0) }
    }
}

/// The database kinds that keep their data in a volume. They always need at
/// least one, so the last volume cannot be removed.
func serviceNeedsVolume(_ image: String) -> Bool {
    let base = image.lowercased()
    let kinds = [
        "postgres", "postgis", "cockroach",
        "mysql", "mariadb",
        "mongo",
        "oracle",
        "mssql", "sqlserver", "azuresql",
    ]
    return kinds.contains { base.contains($0) }
}

func isValidServiceName(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
    return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
}
