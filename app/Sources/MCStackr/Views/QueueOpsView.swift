import SwiftUI

// MARK: - Queue operations

struct QueueOpsView: View {
    @EnvironmentObject private var state: AppState
    let service: ServiceStatus

    @Environment(\.dismiss) private var dismiss

    @State private var info: QueueOpsInfo?
    @State private var selectedEnv = ""
    @State private var sheetTarget: SheetTarget?
    @State private var errorText: String?
    /// The last operation, shown in the sheet like the DB operations do.
    @State private var lastRun: QueueRunResult?
    @State private var lastRunLabel: String = ""

    private enum SheetTarget: Identifiable {
        case params(QueueAction, [String])
        case env(QueueEnv?)
        case customAction(QueueEnv, QueueCustom?)

        var id: String {
            switch self {
            case .params(let action, _): return "params-\(action.id)"
            case .env(let env): return "env-\(env?.name ?? "__new")"
            case .customAction(let env, let action): return "custom-\(env.name)-\(action?.name ?? "__new")"
            }
        }
    }

    private var env: QueueEnv? {
        info?.envs.first { $0.name == selectedEnv }
    }

    /// The actions grouped as the original runtime groups them, plus the
    /// custom actions of the environment in use.
    private var groups: [(group: String, actions: [QueueAction])] {
        guard let info else { return [] }
        var order: [String] = []
        var byGroup: [String: [QueueAction]] = [:]
        for action in info.actions {
            if !order.contains(action.group) { order.append(action.group) }
            byGroup[action.group, default: []].append(action)
        }

        // The custom actions of the environment in use go in the last group,
        // the same place they have in the DB operations.
        if let env, !env.isLocal {
            let group = order.last ?? "Custom"
			for custom in env.customActions {
                byGroup[group, default: []].append(QueueAction(
                    id: "custom:\(custom.name)",
                    label: custom.name,
                    group: group,
                    params: custom.command.variablePlaceholders,
                    destructive: false,
                    enabled: true,
                    disabledReason: nil
                ))
            }
        }

        return order.compactMap { group in
            let actions = byGroup[group] ?? []
            return actions.isEmpty ? nil : (group, actions)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            if let info {
                content(info)
            } else {
                loading
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 700)
        .frame(minHeight: 320, maxHeight: 900)
        .background(Theme.background)
        .task { await reload() }
        .sheet(item: $sheetTarget) { target in
            switch target {
            case .params(let action, let names):
                QueueParamsSheet(action: action, names: names) { values in
                    Task { await run(action, values: values) }
                }
            case .env(let existing):
                QueueEnvWizard(serviceName: service.name, existing: existing) { updated in
                    info = updated
                    selectedEnv = updated.envs.first?.name ?? ""
                }
                .environmentObject(state)
            case .customAction(let env, let existing):
                QueueCustomWizard(existing: existing) { draft in
                    Task { await saveCustom(env, draft, existing) }
                }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Queue operations")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    if let info {
                        TechBadge(text: info.queueType, color: Theme.info)
                    }
                }
                Text("\(service.name) · \(state.workspaceName) / Docker")
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
            Text("The commands run inside the queue container.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text("Loading queue operations…")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Body

    private func content(_ info: QueueOpsInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                envPicker(info)

                if !info.running {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Start \(service.name) to run the queue operations.")
                            .font(.system(size: 11, design: .rounded))
                    }
                    .foregroundStyle(Theme.warning)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                ForEach(groups, id: \.group) { group in
                    FormSection(group.group) {
                        ForEach(group.actions) { action in
                            actionRow(action)
                        }

                        if let env, !env.isLocal, group.group == groups.last?.group {
                            addActionRow(env)
                        }
                    }
                }

                if let lastRun {
                    FormSection("Last operation") {
                        lastOperation(lastRun)
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    private func envPicker(_ info: QueueOpsInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("QUEUE ENVIRONMENT")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(Theme.textDim)

                Spacer()

                if let env {
                    Text(env.isLocal ? env.name : "\(env.host):\(env.port)")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }

                ActionIconButton(systemName: "plus", tint: Theme.accent, help: "Add queue environment") {
                    sheetTarget = .env(nil)
                }

                if let env, !env.isLocal {
                    ActionIconButton(systemName: "pencil", tint: Theme.textMuted, help: "Edit queue environment") {
                        sheetTarget = .env(env)
                    }
                }
            }

            if info.envs.count > 1 {
                Picker("Queue environment", selection: $selectedEnv) {
                    ForEach(info.envs) { env in
                        Text(env.name).tag(env.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private func actionRow(_ action: QueueAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: action))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(action.enabled ? tint(for: action) : Theme.textDim)
                .frame(width: 26, height: 26)
                .background(
                    (action.enabled ? tint(for: action) : Theme.textDim).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(action.label)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(action.enabled ? Theme.text : Theme.textDim)
                if !action.enabled, let reason = action.disabledReason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
            }

            Spacer(minLength: 8)

            ActionTextButton(
                title: "Run",
                systemName: "play.fill",
                destructive: action.destructive,
                tint: tint(for: action)
            ) {
                trigger(action)
            }
            .disabled(!action.enabled)
            .opacity(action.enabled ? 1 : 0.4)
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    private func reload() async {
        guard let loaded = await state.fetchQueueOps(service: service.name) else {
            errorText = state.errorMessage
            return
        }
        info = loaded
        if !loaded.envs.contains(where: { $0.name == selectedEnv }) {
            selectedEnv = loaded.envs.first?.name ?? ""
        }
    }

    /// An action with parameters asks for them first.
    private func trigger(_ action: QueueAction) {
        errorText = nil
        let params = action.params ?? []
        guard !params.isEmpty else {
            Task { await run(action, values: [:]) }
            return
        }
        sheetTarget = .params(action, params)
    }

    /// Saves a custom action of the environment in use.
    private func saveCustom(_ env: QueueEnv, _ draft: QueueCustomDraft, _ existing: QueueCustom?) async {
        errorText = nil
        let updated: QueueOpsInfo?
        if let existing {
            updated = await state.updateQueueCustom(
                service: service.name,
                env: env.name,
                action: existing.name,
                draft: draft
            )
        } else {
            updated = await state.addQueueCustom(
                service: service.name,
                env: env.name,
                draft: draft
            )
        }
        guard let updated else {
            errorText = state.errorMessage ?? "Could not save the action."
            return
        }
        info = updated
    }

    private func run(_ action: QueueAction, values: [String: String]) async {
        errorText = nil
        guard let outcome = await state.runQueueOp(
            service: service.name,
            env: env?.isLocal == true ? "" : selectedEnv,
            action: action.id,
            params: values
        ) else {
            errorText = state.errorMessage ?? "Could not run the operation."
            return
        }
        lastRun = outcome
        lastRunLabel = action.label
    }

    /// The last operation: a table when the output is one, the text otherwise.
    /// Same shape as the card of the DB operations.
    private func lastOperation(_ result: QueueRunResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.running)
                Text(lastRunLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.running)
                if let env {
                    TechBadge(text: env.name, color: Theme.info)
                }
                if let stamp = result.finishedAt {
                    Text(operationStamp(stamp))
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }

            if let table = result.table {
                tableView(table)
            } else {
                Text(result.output.isEmpty ? "(no output)" : result.output)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// The destinations of the queue, as a table: the name and the counts.
    private func tableView(_ table: QueueTable) -> some View {
        let shown = ["Name", "Queue Size", "Producer #", "Consumer #", "Enqueue #", "Dequeue #"]
        let indexes = shown.compactMap { name -> Int? in
            table.columns.firstIndex(of: name)
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("QUEUE")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(shown.dropFirst(), id: \.self) { column in
                    Text(column.replacingOccurrences(of: " #", with: "").replacingOccurrences(of: "Queue Size", with: "Size"))
                        .frame(width: 62, alignment: .trailing)
                }
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.textDim)

            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(indexes.first ?? 0 < row.count ? row[indexes.first ?? 0] : "")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(indexes.first ?? 0 < row.count ? row[indexes.first ?? 0] : "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(indexes.dropFirst(), id: \.self) { index in
                        Text(index < row.count ? row[index] : "")
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 62, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// The icon of an operation, the same way the DB operations name theirs.
    private func icon(for action: QueueAction) -> String {
        switch action.id {
        case "kafka-list-topics", "rabbitmq-list-queues", "activemq-list-destinations":
            return "list.bullet.rectangle"
        case "kafka-describe-topic", "kafka-describe-group":
            return "info.circle"
        case "kafka-create-topic", "rabbitmq-create-queue":
            return "plus.circle"
        case "kafka-send-message", "activemq-send-message":
            return "paperplane"
        case "kafka-consume-messages", "activemq-consume-messages":
            return "arrow.down.circle"
        case "kafka-list-groups":
            return "person.2"
        case "activemq-browse-queue":
            return "eye"
        case "rabbitmq-list-exchanges":
            return "arrow.triangle.2.circlepath"
        case "rabbitmq-list-bindings":
            return "link"
        case "rabbitmq-list-connections", "rabbitmq-list-channels", "rabbitmq-list-consumers":
            return "network"
        case "kafka-reset-offset":
            return "arrow.uturn.backward"
        default:
            return action.destructive ? "trash" : "play.circle"
        }
    }

    /// The colour of an operation: the destructive ones in red, the ones
    /// that only read in green and the ones that write in blue.
    private func tint(for action: QueueAction) -> Color {
        if action.destructive { return Theme.danger }
        switch action.id {
        case "kafka-list-topics", "kafka-describe-topic", "kafka-list-groups",
             "kafka-describe-group", "rabbitmq-list-queues", "rabbitmq-list-exchanges",
             "rabbitmq-list-bindings", "rabbitmq-list-connections", "rabbitmq-list-channels",
             "rabbitmq-list-consumers", "activemq-list-destinations", "activemq-browse-queue":
            return Theme.running
        default:
            return Theme.info
        }
    }

    /// The row that adds a custom action, in the same place the DB
    /// operations have it.
    private func addActionRow(_ env: QueueEnv) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            ActionTextButton(title: "Add action", systemName: nil, tint: Theme.textMuted) {
                sheetTarget = .customAction(env, nil)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Parameters sheet

struct QueueParamsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let action: QueueAction
    let names: [String]
    let onRun: ([String: String]) -> Void

    @State private var values: [String: String] = [:]

    private var canRun: Bool {
        names.allSatisfy { !(values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.label)
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("Fill the values this operation needs.")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                }

                Spacer()

                ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                    dismiss()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().overlay(Theme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(names, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: name)
                            ThemedTextField(placeholder: name, text: binding(for: name))
                        }
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Theme.stroke)

            HStack(spacing: 10) {
                Spacer()
                ActionTextButton(title: "Run", systemName: "play.fill", prominent: true) {
                    onRun(values.mapValues { $0.trimmingCharacters(in: .whitespaces) })
                    dismiss()
                }
                .disabled(!canRun)
                .opacity(canRun ? 1 : 0.5)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 380)
        .background(Theme.background)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}

// MARK: - Result sheet

struct QueueResultSheet: View {
    @Environment(\.dismiss) private var dismiss

    let action: QueueAction
    let output: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.label)
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("The output of the operation.")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                }

                Spacer()

                ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                    dismiss()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().overlay(Theme.stroke)

            // The output of a queue is a table: it scrolls sideways so the
            // columns stay in place.
            ScrollView([.horizontal, .vertical]) {
                Text(output.isEmpty ? "(no output)" : output)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
            }
            .scrollIndicators(.visible)

            Divider().overlay(Theme.stroke)

        }
        .frame(width: 660, height: 520)
        .background(Theme.background)
    }
}

// MARK: - Queue environment wizard

struct QueueEnvWizard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let serviceName: String
    let existing: QueueEnv?
    let onSaved: (QueueOpsInfo) -> Void

    @State private var name = ""
    @State private var queueType = ""
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var password = ""
    @State private var bootstrapServers = ""
    @State private var toolImage = ""
    @State private var managementEndpoint = ""
    @State private var vhost = ""
    @State private var brokerUrl = ""
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var localError: String?
    @State private var loaded = false


    private var isEdit: Bool { existing != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            content
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 560, height: 560)
        .background(Theme.background)
        .onAppear(perform: prefill)
        .sheet(isPresented: $confirmDelete) {
            ConfirmSheet(
                title: "Delete queue environment “\(existing?.name ?? "")”?",
                message: "This removes the environment and its values.",
                confirmTitle: "Delete environment"
            ) {
                Task { await deleteEnv() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isEdit ? "Edit queue environment" : "Add queue environment")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.text)
                Text("A remote queue with its own address and credentials.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let localError {
                    Text(localError)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                FormSection("Environment") {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Name")
                        ThemedTextField(placeholder: "dev", text: $name)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Host")
                        ThemedTextField(placeholder: "localhost", text: $host)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Port")
                        ThemedTextField(placeholder: "61616", text: $port)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "User")
                        ThemedTextField(placeholder: "admin", text: $user)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Password")
                        ThemedSecureField(placeholder: "password", text: $password)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Bootstrap servers")
                        ThemedTextField(placeholder: "kafka:9092", text: $bootstrapServers)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Tool image")
                        ThemedTextField(placeholder: "confluentinc/cp-kafka:latest", text: $toolImage)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Management endpoint")
                        ThemedTextField(placeholder: "http://localhost:15672", text: $managementEndpoint)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Virtual host")
                        ThemedTextField(placeholder: "/", text: $vhost)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Broker URL")
                        ThemedTextField(placeholder: "tcp://localhost:61616", text: $brokerUrl)
                    }
                }
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isEdit {
                ActionTextButton(title: "Delete environment", systemName: "trash", destructive: true) {
                    confirmDelete = true
                }
                .disabled(isSaving)
            } else {
                Text("The password is encrypted in ~/.stackr/config.yaml.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            ActionTextButton(
                title: isSaving ? "Saving…" : (isEdit ? "Save" : "Add"),
                systemName: isEdit ? "checkmark" : "plus",
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

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        guard let existing else { return }
        name = existing.name
        queueType = existing.queueType
        host = existing.host
        port = existing.port
        user = existing.user
        toolImage = existing.toolImage
        bootstrapServers = existing.bootstrapServers
        managementEndpoint = existing.managementEndpoint
        vhost = existing.vhost
        brokerUrl = existing.brokerUrl
    }

    private func save() async {
        localError = nil
        isSaving = true
        defer { isSaving = false }

        let draft = QueueEnvDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            queueType: queueType.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: port.trimmingCharacters(in: .whitespaces),
            user: user,
            password: password,
            toolImage: toolImage.trimmingCharacters(in: .whitespaces),
            bootstrapServers: bootstrapServers.trimmingCharacters(in: .whitespaces),
            managementEndpoint: managementEndpoint.trimmingCharacters(in: .whitespaces),
            vhost: vhost.trimmingCharacters(in: .whitespaces),
            brokerUrl: brokerUrl.trimmingCharacters(in: .whitespaces)
        )
        guard let updated = await state.saveQueueEnv(
            service: serviceName,
            originalName: existing?.name,
            draft: draft
        ) else {
            localError = state.errorMessage ?? "Could not save the environment."
            return
        }
        onSaved(updated)
        dismiss()
    }



    private func deleteEnv() async {
        guard let existing else { return }
        localError = nil
        isSaving = true
        defer { isSaving = false }
        guard let updated = await state.deleteQueueEnv(
            service: serviceName,
            name: existing.name
        ) else {
            localError = state.errorMessage ?? "Could not delete the environment."
            return
        }
        onSaved(updated)
        dismiss()
    }
}

// MARK: - Custom action form

struct QueueCustomWizard: View {
    @Environment(\.dismiss) private var dismiss

    let existing: QueueCustom?
    let onSave: (QueueCustomDraft) -> Void

    @State private var name = ""
    @State private var command = ""
    @State private var loaded = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(existing == nil ? "Add action" : "Edit action")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text("The command runs against the queue environment.")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                }

                Spacer()

                ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                    dismiss()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 16) {
                FormSection("Action") {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Name")
                        ThemedTextField(placeholder: "list my queues", text: $name)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Command")
                        TextEditor(text: $command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 120)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Theme.stroke, lineWidth: 1)
                            }
                        Text("Use {qs_host}, {qs_port}, {qs_user}, {qs_type} for the environment, and {service} or {container} for this one.")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(22)

            Divider().overlay(Theme.stroke)

            HStack(spacing: 10) {
                Spacer()

                ActionTextButton(
                    title: existing == nil ? "Add" : "Save",
                    systemName: existing == nil ? "plus" : "checkmark",
                    prominent: true
                ) {
                    onSave(QueueCustomDraft(
                        name: name.trimmingCharacters(in: .whitespaces),
                        command: command.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    dismiss()
                }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 460)
        .background(Theme.background)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        name = existing?.name ?? ""
        command = existing?.command ?? ""
    }
}
