import SwiftUI

// MARK: - DB operations sheet

struct DBOpsView: View {
    @EnvironmentObject private var state: AppState
    let service: ServiceStatus

    @Environment(\.dismiss) private var dismiss

    @State private var info: DBOpsInfo?
    @State private var selectedEnv: String = ""
    @State private var job: DBJob?
    @State private var jobLabel: String = ""
    @State private var pendingAction: DBAction?
    @State private var errorText: String?

    private var syncEnv: DBSyncEnv? {
        info?.syncEnvs.first { $0.name == selectedEnv }
    }

    private var isBusy: Bool {
        job?.isRunning == true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            if let info {
                if info.syncEnvs.isEmpty {
                    emptyState
                } else {
                    body(info)
                }
            } else {
                loading
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 660, height: 680)
        .background(Theme.background)
        .task { await reload(selectFirst: true) }
        .confirmationDialog(
            pendingAction?.label ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.label, role: .destructive) {
                    pendingAction = nil
                    run(action)
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            }
        } message: {
            Text(confirmationMessage(for: pendingAction))
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

            Spacer()

            ActionTextButton(title: "Done", systemName: "checkmark") {
                dismiss()
            }
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
            Text("No sync environments")
                .font(Theme.title(17))
                .foregroundStyle(Theme.text)
            Text("Add sync_envs to this service in ~/.stackr/config.yaml to export from or import into a remote database.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Body

    private func body(_ info: DBOpsInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                targetPicker(info)

                if !info.running {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Start \(service.name) to import or truncate; exports work while it is stopped.")
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

            if action.destructive == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .help("Destructive")
            }

            ActionTextButton(
                title: "Run",
                systemName: "play.fill",
                destructive: action.destructive == true,
                tint: tint(for: action)
            ) {
                trigger(action)
            }
            .disabled(!action.enabled || isBusy)
            .opacity(!action.enabled || isBusy ? 0.4 : 1)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var jobSection: some View {
        if let job {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if job.isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.accent)
                    } else {
                        Image(systemName: job.state == "done" ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(job.state == "done" ? Theme.running : Theme.danger)
                    }
                    Text(job.isRunning ? "Running \(jobLabel)…" : (job.state == "done" ? "\(jobLabel) finished" : "\(jobLabel) failed"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(job.state == "done" ? Theme.running : (job.isRunning ? Theme.text : Theme.danger))
                    Spacer()
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
            pendingAction = action
            return
        }
        run(action, env: env)
    }

    private func run(_ action: DBAction, env: DBSyncEnv? = nil) {
        guard let target = env ?? syncEnv else { return }
        errorText = nil
        jobLabel = action.label
        job = DBJob(
            id: "",
            state: "running",
            output: nil,
            error: nil,
            startedAt: "",
            finishedAt: nil
        )
        Task { await start(action, env: target) }
    }

    private func start(_ action: DBAction, env: DBSyncEnv) async {
        guard let started = await state.runDBOp(service: service.name, syncEnv: env.name, action: action.id) else {
            errorText = state.errorMessage ?? "Could not start the operation."
            job = nil
            return
        }
        job = started
        await poll(started.id, env: env)
    }

    private func poll(_ id: String, env: DBSyncEnv) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let latest = await state.fetchDBJob(service: service.name, id: id) else { continue }
            job = latest
            if !latest.isRunning {
                await reload(selectFirst: false)
                return
            }
        }
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

    private func confirmationMessage(for action: DBAction?) -> String {
        switch action?.id {
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
