import SwiftUI

// MARK: - Mock operations

struct MockOpsView: View {
    @EnvironmentObject private var state: AppState
    let service: ServiceStatus

    @Environment(\.dismiss) private var dismiss

    @State private var info: MockOpsInfo?
    @State private var sheetTarget: SheetTarget?
    @State private var errorText: String?
    /// The last operation, shown in the sheet like the DB operations do.
    @State private var lastRun: MockRunResult?
    @State private var lastRunLabel: String = ""

    private enum SheetTarget: Identifiable {
        case params(MockAction)

        var id: String {
            switch self {
            case .params(let action): return "params-\(action.id)"
            }
        }
    }

    /// The actions grouped as the original runtime groups them.
    private var groups: [(group: String, actions: [MockAction])] {
        guard let info else { return [] }
        var order: [String] = []
        var byGroup: [String: [MockAction]] = [:]
        for action in info.actions {
            if !order.contains(action.group) { order.append(action.group) }
            byGroup[action.group, default: []].append(action)
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
        .frame(width: 660, height: 680)
        .background(Theme.background)
        .task { await reload() }
        .sheet(item: $sheetTarget) { target in
            switch target {
            case .params(let action):
                MockParamsSheet(action: action) { values in
                    Task { await run(action, values: values) }
                }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Mock operations")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    if let info {
                        TechBadge(text: info.port, color: Theme.info)
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
            Text("The calls go to the mock server of the service.")
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
            Text("Loading mock operations…")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Body

    private func content(_ info: MockOpsInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !info.running {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Start \(service.name) to use the mock server.")
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

    private func actionRow(_ action: MockAction) -> some View {
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

    /// The icon of an operation.
    private func icon(for action: MockAction) -> String {
        switch action.id {
        case "create-expectation": return "plus.rectangle.on.rectangle"
        case "import-expectation": return "square.and.arrow.down"
        case "list-expectations": return "list.bullet.rectangle"
        case "reset-all": return "trash"
        case "verify-request": return "checkmark.shield"
        case "retrieve-requests": return "arrow.down.doc"
        default: return action.destructive ? "trash" : "play.circle"
        }
    }

    /// The colour of an operation: the destructive ones in red, the ones that
    /// only read in green and the ones that write in blue.
    private func tint(for action: MockAction) -> Color {
        if action.destructive { return Theme.danger }
        switch action.id {
        case "list-expectations", "retrieve-requests":
            return Theme.running
        default:
            return Theme.info
        }
    }

    /// The last operation, with the same shape as the card of the DB
    /// operations.
    private func lastOperation(_ result: MockRunResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.running)
                Text(lastRunLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.running)
                if let stamp = result.finishedAt {
                    Text(operationStamp(stamp))
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }

            if !result.output.isEmpty {
                Text(result.output)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Actions

    private func reload() async {
        guard let loaded = await state.fetchMockOps(service: service.name) else {
            errorText = state.errorMessage
            return
        }
        info = loaded
    }

    /// An operation with parameters asks for them first.
    private func trigger(_ action: MockAction) {
        errorText = nil
        let params = action.params ?? []
        guard !params.isEmpty else {
            Task { await run(action, values: [:]) }
            return
        }
        sheetTarget = .params(action)
    }

    private func run(_ action: MockAction, values: [String: String]) async {
        errorText = nil
        guard let outcome = await state.runMockOp(
            service: service.name,
            action: action.id,
            params: values
        ) else {
            errorText = state.errorMessage ?? "Could not run the operation."
            return
        }
        lastRun = outcome
        lastRunLabel = action.label
    }
}

// MARK: - Parameters sheet

struct MockParamsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let action: MockAction
    let onRun: ([String: String]) -> Void

    @State private var values: [String: String] = [:]
    @State private var loaded = false

    /// The methods of the original runtime.
    private let methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

    /// Only the parameters the operation cannot run without block it.
    private var canRun: Bool {
        (action.required ?? []).allSatisfy { !(values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
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
                    ForEach(action.params ?? [], id: \.self) { name in
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: name)
                            if name == "method" {
                                Picker("Method", selection: binding(for: name)) {
                                    ForEach(methods, id: \.self) { method in
                                        Text(method).tag(method)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            } else if name == "body" {
                                // The body of an expectation can be long.
                                TextEditor(text: binding(for: name))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .frame(minHeight: 220)
                                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(Theme.stroke, lineWidth: 1)
                                    }
                            } else {
                                ThemedTextField(placeholder: name, text: binding(for: name))
                            }
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
        .frame(width: 620, height: 560)
        .background(Theme.background)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        for (name, value) in action.defaults ?? [:] {
            values[name] = value
        }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}
