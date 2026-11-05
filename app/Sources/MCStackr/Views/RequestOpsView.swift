import SwiftUI

// MARK: - Request operations

struct RequestOpsView: View {
    @EnvironmentObject private var state: AppState

    @State private var response: RequestsResponse?
    @State private var selectedEnv: String = ""
    @State private var runTarget: RequestDefinition?
    @State private var errorText: String?

    private var env: RequestEnvironment? {
        response?.envs.first { $0.name == selectedEnv }
    }

    /// The requests grouped by the base URL they use, which is what the
    /// folders of the original runtime hold.
    private var groups: [(folder: String, requests: [RequestDefinition])] {
        guard let response else { return [] }
        var order: [String] = []
        for folder in response.folders where !order.contains(folder) {
            order.append(folder)
        }
        for request in response.requests where !order.contains(request.baseUrlName) {
            order.append(request.baseUrlName)
        }
        return order.compactMap { folder in
            let requests = response.requests.filter { $0.baseUrlName == folder }
            return requests.isEmpty ? nil : (folder, requests)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let response, !response.envs.isEmpty {
                    envPicker(response)

                    if let env {
                        variablesSection(env)
                    }

                    ForEach(groups, id: \.folder) { group in
                        FormSection(group.folder) {
                            ForEach(group.requests) { request in
                                requestRow(request)
                            }
                        }
                    }
                } else if response != nil {
                    emptyState
                } else {
                    loading
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
        .task { await reload() }
        .sheet(item: $runTarget) { request in
            if let env {
                RequestRunSheet(request: request, env: env)
                    .environmentObject(state)
            }
        }
    }

    // MARK: Pieces

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text("Loading requests…")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)
            Text("No request environments yet")
                .font(Theme.title(17))
                .foregroundStyle(Theme.text)
            Text("Request environments hold their own base URLs and variables. Add one in the shared Stackr config to start running requests.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func envPicker(_ response: RequestsResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REQUEST ENVIRONMENT")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(Theme.textDim)

            if response.envs.count > 1 {
                Picker("Request environment", selection: $selectedEnv) {
                    ForEach(response.envs) { env in
                        Text(env.name).tag(env.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else if let env = response.envs.first {
                HStack(spacing: 8) {
                    Text(env.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(env.baseUrls.count) base URLs · \(env.variables.count) variables")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private func variablesSection(_ env: RequestEnvironment) -> some View {
        FormSection("Base URLs & Variables") {
            ForEach(env.baseUrls) { base in
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.info)
                        .frame(width: 20)

                    Text(base.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)

                    Spacer(minLength: 8)

                    Text(base.url)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            ForEach(env.variables) { variable in
                HStack(spacing: 10) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.violet)
                        .frame(width: 20)

                    Text(variable.name)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.text)

                    Spacer(minLength: 8)

                    Text(variableLabel(variable))
                        .font(Theme.monoSmall)
                        .foregroundStyle(variable.value.isEmpty ? Theme.textDim : Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// The value of a variable, hidden when it looks like a secret.
    private func variableLabel(_ variable: RequestVariable) -> String {
        if variable.value.isEmpty { return "—" }
        let upper = variable.name.uppercased()
        let secret = ["PASSWORD", "SECRET", "TOKEN", "KEY"].contains { upper.contains($0) }
        return secret ? "••••••••" : variable.value
    }

    private func requestRow(_ request: RequestDefinition) -> some View {
        HStack(spacing: 10) {
            Text(request.method.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(methodTint(request.method))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(methodTint(request.method).opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(request.path)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            ActionTextButton(title: "Run", systemName: "play.fill", tint: Theme.info) {
                runTarget = request
            }
        }
        .padding(.vertical, 2)
    }

    private func methodTint(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return Theme.running
        case "POST": return Theme.info
        case "PUT", "PATCH": return Theme.violet
        case "DELETE": return Theme.danger
        default: return Theme.textMuted
        }
    }

    // MARK: Actions

    private func reload() async {
        guard let loaded = await state.fetchRequests() else {
            errorText = state.errorMessage
            return
        }
        response = loaded
        if !loaded.envs.contains(where: { $0.name == selectedEnv }) {
            selectedEnv = loaded.envs.first?.name ?? ""
        }
    }

}

// MARK: - Run sheet

struct RequestRunSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let request: RequestDefinition
    let env: RequestEnvironment

    @State private var values: [String: String] = [:]
    @State private var result: RequestRunResult?
    @State private var isRunning = false
    @State private var localError: String?
    @State private var loaded = false

    /// The variables the request uses: the ones it declares plus the ones its
    /// text references.
    private var variableNames: [String] {
        var names: [String] = []
        for name in request.variableRefs where !names.contains(name) {
            names.append(name)
        }
        for name in request.placeholders where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    /// The token lives in the environment under its own name.
    private var tokenValue: String {
        values["token"] ?? env.value(for: "_token")
    }

    /// Replaces the variables and {token}, the same way the engine does.
    private func substitute(_ text: String) -> String {
        var result = text
        for name in variableNames {
            result = result.replacingOccurrences(of: "{\(name)}", with: values[name] ?? "")
        }
        return result.replacingOccurrences(of: "{token}", with: tokenValue)
    }

    private var resolvedURL: String {
        let base = env.baseUrls.first { $0.name == request.baseUrlName }?.url ?? ""
        let path = request.path.hasPrefix("/") || request.path.isEmpty ? request.path : "/" + request.path
        return base.replacingOccurrences(of: "/$", with: "", options: .regularExpression) + substitute(path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let localError {
                        Text(localError)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    FormSection("Request") {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: "URL")
                            Text(resolvedURL)
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }

                        if !request.headers.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "Headers")
                                ForEach(request.headers, id: \.key) { header in
                                    HStack(spacing: 6) {
                                        Text(header.key)
                                            .font(Theme.monoSmall)
                                            .foregroundStyle(Theme.info)
                                        Text(substitute(header.value))
                                            .font(Theme.monoSmall)
                                            .foregroundStyle(Theme.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }

                        if !request.body.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "Body")
                                Text(request.body)
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(Theme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                        }
                    }

                    if !variableNames.isEmpty {
                        FormSection("Variables") {
                            ForEach(variableNames, id: \.self) { name in
                                VStack(alignment: .leading, spacing: 6) {
                                    FieldLabel(text: name)
                                    ThemedTextField(placeholder: name, text: binding(for: name))
                                }
                            }
                        }
                    }

                    if let result {
                        FormSection("Response") {
                            HStack(spacing: 8) {
                                Text("\(result.status) \(result.statusText)")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(result.isSuccess ? Theme.running : Theme.danger)
                                Spacer()
                                Text("\(result.durationMs) ms")
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(Theme.textDim)
                            }
                            Text(result.body.isEmpty ? "(empty body)" : result.body)
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 660, height: 640)
        .background(Theme.background)
        .onAppear(perform: prefill)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(request.method.uppercased())
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.info)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.info.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(request.name)
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                Text("\(env.name) · \(request.baseUrlName)")
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
            if let result {
                Text(result.url)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Runs from this Mac against the base URL of the environment.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }

            Spacer()

            ActionTextButton(title: "Cancel", systemName: nil) {
                dismiss()
            }

            ActionTextButton(title: isRunning ? "Running…" : "Run", systemName: "play.fill", prominent: true) {
                run()
            }
            .disabled(isRunning)
            .opacity(isRunning ? 0.5 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        for name in variableNames {
            values[name] = name == "token" ? env.value(for: "_token") : env.value(for: name)
        }
    }

    private func run() {
        localError = nil
        isRunning = true
        Task {
            result = await state.runRequest(
                env: env.name,
                request: request.name,
                variables: values
            )
            if result == nil {
                localError = state.errorMessage ?? "Could not run the request."
            }
            isRunning = false
        }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}

extension RequestDefinition {
    /// The variables referenced in the path, the params, the headers and the
    /// body of the request.
    var placeholders: [String] {
        var found: [String] = []
        var texts = [path, body]
        texts.append(contentsOf: params.map { $0.key + $0.value })
        texts.append(contentsOf: headers.map { $0.key + $0.value })
        for text in texts {
            for name in text.variablePlaceholders where !found.contains(name) {
                found.append(name)
            }
        }
        return found
    }
}

extension String {
    /// The `{name}` references of a string.
    var variablePlaceholders: [String] {
        // The names of the variables can carry dashes, like {activity-ids-list}.
        guard let regex = try? NSRegularExpression(pattern: #"\{([a-zA-Z_][a-zA-Z0-9_-]*)\}"#) else {
            return []
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        var found: [String] = []
        for match in regex.matches(in: self, range: range) {
            guard match.numberOfRanges > 1, let nameRange = Range(match.range(at: 1), in: self) else { continue }
            let name = String(self[nameRange])
            if !found.contains(name) { found.append(name) }
        }
        return found
    }
}
