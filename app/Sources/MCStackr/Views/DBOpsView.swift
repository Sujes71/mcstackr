import SwiftUI

// MARK: - DB operations sheet

struct DBOpsView: View {
    @EnvironmentObject private var state: AppState
    let service: ServiceStatus

    @Environment(\.dismiss) private var dismiss

    @State private var info: DBOpsInfo?
    @State private var selectedEnv: String = ""
    @State private var confirm: Confirm?
    @State private var sheetTarget: SheetTarget?
    @State private var errorText: String?

    private enum SheetTarget: Identifiable {
        case syncEnv(DBSyncEnv?)
        case customAction(DBSyncEnv, CustomAction?)
        case params(DBSyncEnv, CustomAction)

        var id: String {
            switch self {
            case .syncEnv(let env):
                return "syncEnv-\(env?.name ?? "__new")"
            case .customAction(let env, let action):
                return "customAction-\(env.name)-\(action?.name ?? "__new")"
            case .params(let env, let action):
                return "params-\(env.name)-\(action.name)"
            }
        }
    }

    private enum Confirm: Identifiable {
        case action(DBAction)
        case customAction(DBSyncEnv, CustomAction, [String: String])
        case deleteCustomAction(DBSyncEnv, CustomAction)

        var id: String {
            switch self {
            case .action(let action): return "action-\(action.id)"
            case .customAction(let env, let action, _): return "custom-\(env.name)-\(action.name)"
            case .deleteCustomAction(let env, let action): return "delete-\(env.name)-\(action.name)"
            }
        }

        var title: String {
            switch self {
            case .action(let action): return "\(action.label)?"
            case .customAction(_, let action, _): return "Run “\(action.name)”?"
            case .deleteCustomAction(_, let action): return "Delete action “\(action.name)”?"
            }
        }

        var confirmTitle: String {
            switch self {
            case .action: return "Run"
            case .customAction: return "Run"
            case .deleteCustomAction: return "Delete"
            }
        }

        var destructive: Bool {
            switch self {
            case .action(let action): return action.destructive == true
            case .customAction: return true
            case .deleteCustomAction: return true
            }
        }

    }

    private var syncEnv: DBSyncEnv? {
        info?.syncEnvs.first { $0.name == selectedEnv }
    }

    /// The operations of this service. They live in the engine, so they keep
    /// running when the sheet is closed.
    private var serviceJobs: [DBJob] {
        state.dbJobs.filter { $0.service == service.name }
    }

    private var runningCount: Int {
        serviceJobs.filter { $0.isRunning }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            if let info {
                body(info)
            } else {
                loading
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 660, height: 680)
        .background(Theme.background)
        .task(id: service.name) {
            await reload(selectFirst: true)
            await adoptJobs()
        }
        .onChange(of: state.dbFinishedCount) { _, _ in
            Task { await reload(selectFirst: false) }
        }
        .sheet(item: $sheetTarget) { target in
            switch target {
            case .syncEnv(let existing):
                SyncEnvWizard(
                    service: service,
                    dbType: info?.dbType ?? "",
                    existing: existing
                ) { updated, savedName in
                    info = updated
                    selectedEnv = savedName
                } onDeleted: { updated in
                    info = updated
                    selectedEnv = updated.syncEnvs.first?.name ?? ""
                }
                .environmentObject(state)
            case .customAction(let env, let existing):
                CustomActionWizard(
                    service: service,
                    syncEnv: env,
                    existing: existing
                ) { updated in
                    info = updated
                } onDeleted: { updated in
                    info = updated
                }
                .environmentObject(state)
            case .params(let env, let action):
                CustomActionParamsView(
                    action: action,
                    params: action.command.customActionParams,
                    context: "\(service.name) · \(env.name)"
                ) { values in
                    runCustom(action, env: env, params: values)
                }
            }
        }
        .sheet(item: $confirm) { target in
            ConfirmSheet(
                title: target.title,
                message: confirmationMessage(for: target),
                confirmTitle: target.confirmTitle,
                destructive: target.destructive
            ) {
                switch target {
                case .action(let action):
                    run(action)
                case .customAction(let env, let action, let params):
                    runCustom(action, env: env, params: params)
                case .deleteCustomAction(let env, let action):
                    deleteCustom(action, env: env)
                }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("DB operations")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    if let info {
                        TechBadge(text: info.dbType, color: Theme.info)
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
            Text("Dumps live under ~/.stackr/<workspace>/<env>/dumps/<service>/<sync env>.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)

        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text("Loading DB operations…")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)
            Text("No sync environments yet")
                .font(Theme.title(17))
                .foregroundStyle(Theme.text)
            Text("Add the connection details of a remote \(info?.dbType ?? "database") to export from it or import into it.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            ActionTextButton(title: "Add sync environment", systemName: "plus", prominent: true) {
                sheetTarget = .syncEnv(nil)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Body

    private func body(_ info: DBOpsInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                targetPicker(info)

                if info.syncEnvs.isEmpty {
                    emptyState
                }

                if !info.running && !info.syncEnvs.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Start \(service.name) to import, truncate or run actions; exports work while it is stopped.")
                            .font(.system(size: 11, design: .rounded))
                    }
                    .foregroundStyle(Theme.warning)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if let env = syncEnv {
                    actionSections(env)
                    dumpsSection(env)
                }

                jobSection

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

    private func targetPicker(_ info: DBOpsInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SYNC ENVIRONMENT")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(Theme.textDim)

                Spacer()

                if let env = syncEnv {
                    Text("\(env.host):\(env.port) · \(env.database)")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }

                ActionIconButton(systemName: "plus", tint: Theme.accent, help: "Add sync environment") {
                    sheetTarget = .syncEnv(nil)
                }

                if let env = syncEnv {
                    ActionIconButton(systemName: "pencil", tint: Theme.textMuted, help: "Edit sync environment") {
                        sheetTarget = .syncEnv(env)
                    }
                }
            }

            if info.syncEnvs.count > 1 {
                Picker("Sync environment", selection: $selectedEnv) {
                    ForEach(info.syncEnvs) { env in
                        Text(env.name).tag(env.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else if let env = info.syncEnvs.first {
                HStack(spacing: 8) {
                    Text(env.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    TechBadge(text: env.dbType, color: Theme.info)
                    Spacer()
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private func actionSections(_ env: DBSyncEnv) -> some View {
        let groups = orderedGroups(env.actions)
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(groups, id: \.self) { group in
                FormSection(group) {
                    ForEach(env.actions.filter { $0.group == group }) { action in
                        actionRow(action)
                    }
                    if group == "Actions" {
                        customActionRows(env)
                    }
                }
            }
        }
    }

    private func actionRow(_ action: DBAction) -> some View {
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
                destructive: action.destructive == true,
                tint: tint(for: action)
            ) {
                trigger(action)
            }
            .disabled(!action.enabled)
            .opacity(!action.enabled ? 0.4 : 1)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func customActionRows(_ env: DBSyncEnv) -> some View {
        ForEach(env.customActions) { action in
            customActionRow(action, env: env)
        }

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

    private func customActionRow(_ action: CustomAction, env: DBSyncEnv) -> some View {
        let enabled = info?.running == true
        return HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Theme.violet : Theme.textDim)
                .frame(width: 26, height: 26)
                .background(
                    (enabled ? Theme.violet : Theme.textDim).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(enabled ? Theme.text : Theme.textDim)
                Text(action.command)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            ActionIconButton(systemName: "play.fill", tint: Theme.violet, help: "Run action") {
                triggerCustom(action, env: env)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)

            ActionIconButton(systemName: "pencil", tint: Theme.textMuted, help: "Edit action") {
                sheetTarget = .customAction(env, action)
            }

            ActionIconButton(systemName: "trash", tint: Theme.danger, help: "Delete action") {
                confirm = .deleteCustomAction(env, action)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var jobSection: some View {
        if !serviceJobs.isEmpty {
            FormSection("Operations") {
                ForEach(serviceJobs.prefix(6)) { job in
                    jobRow(job)
                }
            }
        }
    }

    private func jobRow(_ job: DBJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if job.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                } else {
                    Image(systemName: job.isDone ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(job.isDone ? Theme.running : Theme.danger)
                }
                Text(job.label ?? job.action ?? "Operation")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(job.isDone ? Theme.running : (job.isRunning ? Theme.text : Theme.danger))
                if let syncEnv = job.syncEnv, !syncEnv.isEmpty {
                    TechBadge(text: syncEnv, color: Theme.info)
                }
                Text(operationStamp(job.finishedAt ?? job.startedAt))
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)

                Spacer(minLength: 0)
            }

            if let output = job.output, !output.isEmpty {
                Text(output)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = job.error, !error.isEmpty {
                Text(error)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func dumpsSection(_ env: DBSyncEnv) -> some View {
        FormSection("Dumps") {
            if env.dumps.isEmpty {
                Text("No dumps yet for \(env.name).")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(env.dumps) { dump in
                    HStack(spacing: 10) {
                        Image(systemName: dump.kind == "schema" ? "doc.text" : "tablecells")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(dump.kind == "schema" ? Theme.info : Theme.running)
                            .frame(width: 22)

                        Text(dump.file)
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        TechBadge(text: dump.kind, color: dump.kind == "schema" ? Theme.info : Theme.running)

                        Spacer(minLength: 8)

                        Text(byteLabel(dump.size))
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.textDim)

                        Text(dateLabel(dump.modifiedAt))
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func orderedGroups(_ actions: [DBAction]) -> [String] {
        var seen: [String] = []
        for action in actions where !seen.contains(action.group) {
            seen.append(action.group)
        }
        return seen
    }

    private func icon(for action: DBAction) -> String {
        switch action.id {
        case "export-schema": return "arrow.up.doc"
        case "export-data": return "arrow.up.bin"
        case "import-schema": return "arrow.down.doc"
        case "import-data": return "arrow.down.bin"
        case "truncate": return "trash"
        default: return "play"
        }
    }

    private func tint(for action: DBAction) -> Color {
        if action.destructive == true { return Theme.danger }
        return action.group == "Export" ? Theme.running : Theme.info
    }

    private func trigger(_ action: DBAction) {
        guard let env = syncEnv else { return }
        errorText = nil
        if action.destructive == true {
            confirm = .action(action)
            return
        }
        run(action, env: env)
    }

    private func run(_ action: DBAction, env: DBSyncEnv? = nil) {
        guard let target = env ?? syncEnv else { return }
        errorText = nil
        Task {
            guard await state.runDBOp(
                service: service.name,
                syncEnv: target.name,
                action: action.id,
                label: action.label
            ) != nil else {
                errorText = state.errorMessage ?? "Could not start the operation."
                return
            }
        }
    }

    private func triggerCustom(_ action: CustomAction, env: DBSyncEnv) {
        errorText = nil
        if !action.command.customActionParams.isEmpty {
            sheetTarget = .params(env, action)
            return
        }
        confirm = .customAction(env, action, [:])
    }

    private func runCustom(_ action: CustomAction, env: DBSyncEnv, params: [String: String]) {
        errorText = nil
        Task {
            guard await state.runCustomAction(
                service: service.name,
                syncEnv: env.name,
                name: action.name,
                params: params
            ) != nil else {
                errorText = state.errorMessage ?? "Could not start the action."
                return
            }
        }
    }

    private func deleteCustom(_ action: CustomAction, env: DBSyncEnv) {
        errorText = nil
        Task {
            guard let updated = await state.deleteCustomAction(
                service: service.name,
                syncEnv: env.name,
                name: action.name
            ) else {
                errorText = state.errorMessage ?? "Could not delete the action."
                return
            }
            info = updated
        }
    }

    /// Picks up the operations the engine still remembers for this service.
    private func adoptJobs() async {
        state.adoptDBJobs(await state.fetchDBJobs(service: service.name), service: service.name)
    }

    private func reload(selectFirst: Bool) async {
        guard let loaded = await state.fetchDBOps(service: service.name) else {
            errorText = state.errorMessage
            return
        }
        info = loaded
        if selectFirst || !loaded.syncEnvs.contains(where: { $0.name == selectedEnv }) {
            selectedEnv = loaded.syncEnvs.first?.name ?? ""
        }
    }

    private func confirmationMessage(for confirm: Confirm?) -> String {
        guard let confirm else { return "" }
        switch confirm {
        case .action(let action):
            return actionMessage(for: action)
        case .customAction(let env, let action, _):
            return "This runs “\(action.command)” inside \(service.name) for \(env.name)."
        case .deleteCustomAction(let env, let action):
            return "This removes the action from \(env.name). It does not touch the database."
        }
    }

    private func actionMessage(for action: DBAction) -> String {
        switch action.id {
        case "import-schema":
            return "This drops every schema in \(service.name) and re-applies the latest schema dump."
        case "import-data":
            return "This restores the latest data dump into \(service.name)."
        case "truncate":
            return "This removes all rows from every table in \(service.name)."
        default:
            return ""
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func dateLabel(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { return iso }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}
