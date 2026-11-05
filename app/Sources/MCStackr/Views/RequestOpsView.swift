import SwiftUI

// MARK: - Request operations

struct RequestOpsView: View {
    @EnvironmentObject private var state: AppState

    @State private var response: RequestsResponse?
    @State private var selectedEnv: String = ""
    @State private var sheetTarget: SheetTarget?
    @State private var errorText: String?
    /// The folders the user has collapsed.
    @State private var collapsed: Set<String> = []

    private enum SheetTarget: Identifiable {
        case folder(folder: String?, url: String)
        case request(folder: String, request: RequestDefinition?)
        case params(request: RequestDefinition, names: [String])
        case run(RequestDefinition)
        case newEnv

        var id: String {
            switch self {
            case .folder(let folder, _): return "folder-\(folder ?? "__new")"
            case .request(let folder, let request): return "request-\(folder)-\(request?.name ?? "__new")"
            case .params(let request, _): return "params-\(request.name)"
            case .run(let request): return "run-\(request.name)"
            case .newEnv: return "newEnv"
            }
        }
    }

    private var env: RequestEnvironment? {
        response?.envs.first { $0.name == selectedEnv }
    }

    private var folders: [String] {
        guard let response else { return [] }
        var order: [String] = []
        for folder in response.folders where !order.contains(folder) {
            order.append(folder)
        }
        for request in response.requests where !order.contains(request.baseUrlName) {
            order.append(request.baseUrlName)
        }
        return order
    }

    private func requests(in folder: String) -> [RequestDefinition] {
        response?.requests.filter { $0.baseUrlName == folder } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let response, !response.envs.isEmpty {
                    envRow(response)

                    ForEach(folders, id: \.self) { folder in
                        folderTree(folder)
                    }

                    addFolderRow
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
        .onChange(of: state.pendingSectionAction) { _, action in
            guard action == .addRequestEnv else { return }
            state.pendingSectionAction = nil
            sheetTarget = .newEnv
        }
        .sheet(item: $sheetTarget) { target in
            switch target {
            case .folder(let folder, let url):
                BaseURLWizard(
                    existingName: folder,
                    existingURL: url,
                    env: selectedEnv,
                    onSaved: { updated in response = updated },
                    onDeleted: { updated in response = updated }
                )
                .environmentObject(state)
            case .request(let folder, let request):
                RequestWizard(
                    folders: folders,
                    selectedFolder: folder,
                    env: selectedEnv,
                    existing: request,
                    onSaved: { updated in response = updated },
                    onDeleted: { updated in response = updated }
                )
                .environmentObject(state)
            case .params(let request, let names):
                if let env {
                    RequestVarsSheet(request: request, env: env, names: names) { values in
                        sheetTarget = .run(request)
                        Task { await run(request, env: env, values: values) }
                    }
                    .environmentObject(state)
                }
            case .run(let request):
                if let env {
                    RequestRunSheet(request: request, env: env)
                        .environmentObject(state)
                }
            case .newEnv:
                RequestEnvWizard { updated in
                    response = updated
                    if let first = updated.envs.first { selectedEnv = first.name }
                }
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
            Text("A request environment holds the base URLs and the variables of a set of requests.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            ActionTextButton(title: "Add environment", systemName: "plus", prominent: true) {
                sheetTarget = .newEnv
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// The environment in use. It is the root of the tree: its folders hang
    /// from it.
    private func envRow(_ payload: RequestsResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("REQUEST ENVIRONMENT")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(Theme.textDim)

                Spacer()

                if let env, env.name != "local" {
                    ActionIconButton(systemName: "trash", tint: Theme.danger, help: "Remove request environment") {
                        Task {
                            if let updated = await state.deleteRequestEnv(name: env.name) {
                                response = updated
                                selectedEnv = updated.envs.first?.name ?? ""
                            } else {
                                errorText = state.errorMessage
                            }
                        }
                    }
                }
            }

            if payload.envs.count > 1 {
                Picker("Request environment", selection: $selectedEnv) {
                    ForEach(payload.envs) { env in
                        Text(env.name).tag(env.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else if let env = payload.envs.first {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(env.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    /// Adding a folder belongs to the folder level, so the affordance sits
    /// with the folders instead of next to the environment.
    private var addFolderRow: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: 14, height: 14)

            Image(systemName: "folder.badge.plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textDim)
                .frame(width: 18)

            Button {
                sheetTarget = .folder(folder: nil, url: "")
            } label: {
                Text("Add folder")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .help("Add a folder to this environment")

            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    /// A folder: its name sits next to it, and it holds the requests that
    /// use it. It can be folded and unfolded.
    private func folderTree(_ folder: String) -> some View {
        let url = env?.baseUrls.first { $0.name == folder }?.url ?? ""
        let items = requests(in: folder)
        let isCollapsed = collapsed.contains(folder)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if isCollapsed {
                        collapsed.remove(folder)
                    } else {
                        collapsed.insert(folder)
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand" : "Collapse")

                Image(systemName: "folder.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.info)
                    .frame(width: 18)

                Text(folder)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)

                if !url.isEmpty {
                    Text(url)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                ActionIconButton(systemName: "plus", tint: Theme.accent, help: "Add request to \(folder)") {
                    sheetTarget = .request(folder: folder, request: nil)
                }

                ActionIconButton(systemName: "pencil", tint: Theme.textMuted, help: "Edit folder") {
                    sheetTarget = .folder(folder: folder, url: url)
                }

                ActionIconButton(systemName: "trash", tint: Theme.danger, help: "Delete folder") {
                    Task {
                        if let updated = await state.deleteFolder(name: folder) {
                            response = updated
                        } else {
                            errorText = state.errorMessage
                        }
                    }
                }
            }
            .padding(.vertical, 2)

            if !isCollapsed {
                ForEach(items) { request in
                    requestRow(request)
                }
                if items.isEmpty {
                    Text("No requests in this folder.")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                        .padding(.leading, 40)
                }
            }
        }
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
                HStack(spacing: 6) {
                    Text(request.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    if request.isLogin {
                        Image(systemName: hasToken ? "lock.open" : "lock")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(hasToken ? Theme.running : Theme.warning)
                            .help(hasToken ? "The token is available" : "No token yet: run the login request first")
                    }
                }
                Text(request.path)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            ActionIconButton(systemName: "play.fill", tint: Theme.info, help: "Run request") {
                trigger(request)
            }

            ActionIconButton(systemName: "pencil", tint: Theme.textMuted, help: "Edit request") {
                sheetTarget = .request(folder: request.baseUrlName, request: request)
            }

            ActionIconButton(systemName: "trash", tint: Theme.danger, help: "Delete request") {
                Task {
                    if let updated = await state.deleteRequest(name: request.name) {
                        response = updated
                    } else {
                        errorText = state.errorMessage
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 40)
    }

    private var hasToken: Bool {
        guard let env else { return false }
        return !env.value(for: "_token").isEmpty
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

    /// The variables the request uses, the ones the environment already has a
    /// value for are not asked again. The token is never asked: it comes from
    /// the login request.
    private func trigger(_ request: RequestDefinition) {
        guard let env else { return }
        let missing = request.missingVariables(in: env)
        if missing.isEmpty {
            sheetTarget = .run(request)
            Task { await run(request, env: env, values: [:]) }
        } else {
            sheetTarget = .params(request: request, names: missing)
        }
    }

    private func run(_ request: RequestDefinition, env: RequestEnvironment, values: [String: String]) async {
        errorText = nil
        guard await state.runRequest(env: env.name, request: request.name, variables: values) != nil else {
            errorText = state.errorMessage ?? "Could not run the request."
            return
        }
        await reload()
    }
}

// MARK: - Folder (base URL) wizard

struct BaseURLWizard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let existingName: String?
    let existingURL: String
    let env: String
    let onSaved: (RequestsResponse) -> Void
    let onDeleted: (RequestsResponse) -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var localError: String?
    @State private var loaded = false

    private var isEdit: Bool { existingName != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            content
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 520, height: 380)
        .background(Theme.background)
        .onAppear(perform: prefill)
        .confirmationDialog(
            "Delete folder “\(existingName ?? "")”?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteFolder() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The requests that use it are removed too.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isEdit ? "Edit folder" : "Add folder")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.text)
                Text("A folder groups the requests that use the same base URL.")
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

                FormSection("Folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Name")
                        ThemedTextField(placeholder: "supplier_url, client_url…", text: $name)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "URL")
                        ThemedTextField(placeholder: "http://localhost:8086", text: $url)
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
                ActionTextButton(title: "Delete folder", systemName: "trash", destructive: true) {
                    confirmDelete = true
                }
                .disabled(isSaving)
            } else {
                Text("The folder is added to every request environment.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            ActionTextButton(title: "Cancel", systemName: nil) {
                dismiss()
            }

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
        name = existingName ?? ""
        url = existingURL
    }

    private func save() async {
        localError = nil
        isSaving = true
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        let updated: RequestsResponse?
        if let existingName {
            updated = await state.updateFolder(name: trimmedName, originalName: existingName, url: trimmedURL, env: env)
        } else {
            updated = await state.addFolder(name: trimmedName, url: trimmedURL, env: env)
        }
        guard let updated else {
            localError = state.errorMessage ?? "Could not save the folder."
            return
        }
        onSaved(updated)
        dismiss()
    }

    private func deleteFolder() async {
        guard let existingName else { return }
        localError = nil
        isSaving = true
        defer { isSaving = false }
        guard let updated = await state.deleteFolder(name: existingName) else {
            localError = state.errorMessage ?? "Could not delete the folder."
            return
        }
        onDeleted(updated)
        dismiss()
    }
}

// MARK: - Request wizard

struct RequestWizard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let folders: [String]
    let selectedFolder: String
    let env: String
    let existing: RequestDefinition?
    let onSaved: (RequestsResponse) -> Void
    let onDeleted: (RequestsResponse) -> Void

    @State private var name = ""
    @State private var method = "GET"
    @State private var baseURL = ""
    @State private var path = ""
    @State private var isLogin = false
    @State private var tokenPath = ""
    @State private var headers: [KVEntry] = []
    @State private var params: [KVEntry] = []
    @State private var bodyText = ""
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var localError: String?
    @State private var loaded = false

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    private var isEdit: Bool { existing != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !method.isEmpty &&
        !baseURL.isEmpty &&
        !path.trimmingCharacters(in: .whitespaces).isEmpty &&
        (!isLogin || !tokenPath.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    private var showsBody: Bool {
        ["POST", "PUT", "PATCH"].contains(method)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            content
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 700, height: 680)
        .background(Theme.background)
        .onAppear(perform: prefill)
        .confirmationDialog(
            "Delete request “\(existing?.name ?? "")”?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteRequest() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isEdit ? "Edit request" : "New request")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.text)
                Text(isEdit ? (existing?.baseUrlName ?? "") : "In \(selectedFolder)")
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

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let localError {
                    Text(localError)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                FormSection("Request") {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Name")
                        ThemedTextField(placeholder: "import all activities", text: $name)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Method")
                        Picker("Method", selection: $method) {
                            ForEach(Self.methods, id: \.self) { method in
                                Text(method).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Base URL")
                        Picker("Base URL", selection: $baseURL) {
                            ForEach(folders, id: \.self) { folder in
                                Text(folder).tag(folder)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Path")
                        ThemedTextField(placeholder: "/api/v1/users/{id}", text: $path)
                    }

                    HStack(spacing: 10) {
                        Toggle("Login request", isOn: $isLogin)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                    }

                    if isLogin {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: "Token path")
                            ThemedTextField(placeholder: "data.token", text: $tokenPath)
                            Text("Where the token is read from the JSON response, for example data.token.")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                FormSection("Headers") {
                    KVEditor(entries: $headers, keyPlaceholder: "Content-Type", valuePlaceholder: "application/json")
                }

                FormSection("Params") {
                    KVEditor(entries: $params, keyPlaceholder: "immediate", valuePlaceholder: "{inmediate}")
                }

                if showsBody {
                    FormSection("Body") {
                        TextEditor(text: $bodyText)
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
                ActionTextButton(title: "Delete request", systemName: "trash", destructive: true) {
                    confirmDelete = true
                }
                .disabled(isSaving)
            } else {
                Text("Use {variable} anywhere: it is asked when the request runs.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }

            Spacer()

            ActionTextButton(title: "Cancel", systemName: nil) {
                dismiss()
            }

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
        if let existing {
            name = existing.name
            method = existing.method
            baseURL = existing.baseUrlName
            path = existing.path
            isLogin = existing.isLogin
            tokenPath = existing.tokenPath
            headers = existing.headers.map { KVEntry(key: $0.key, value: $0.value) }
            params = existing.params.map { KVEntry(key: $0.key, value: $0.value) }
            bodyText = existing.body
        } else {
            baseURL = selectedFolder
            method = "GET"
        }
    }

    private func save() async {
        localError = nil
        isSaving = true
        defer { isSaving = false }

        let draft = RequestDraft(
            env: env,
            name: name.trimmingCharacters(in: .whitespaces),
            method: method,
            baseUrlName: baseURL,
            path: path.trimmingCharacters(in: .whitespaces),
            isLogin: isLogin,
            tokenPath: tokenPath.trimmingCharacters(in: .whitespaces),
            headers: headers.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.map { RequestKV(key: $0.key, value: $0.value) },
            params: params.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.map { RequestKV(key: $0.key, value: $0.value) },
            body: bodyText
        )
        let updated: RequestsResponse?
        if let existing {
            updated = await state.updateRequest(draft, originalName: existing.name)
        } else {
            updated = await state.addRequest(draft)
        }
        guard let updated else {
            localError = state.errorMessage ?? "Could not save the request."
            return
        }
        onSaved(updated)
        dismiss()
    }

    private func deleteRequest() async {
        guard let existing else { return }
        localError = nil
        isSaving = true
        defer { isSaving = false }
        guard let updated = await state.deleteRequest(name: existing.name) else {
            localError = state.errorMessage ?? "Could not delete the request."
            return
        }
        onDeleted(updated)
        dismiss()
    }
}

// MARK: - Key/value editor

struct KVEntry: Identifiable, Hashable {
    var id = UUID()
    var key: String
    var value: String
}

struct KVEditor: View {
    @Binding var entries: [KVEntry]
    let keyPlaceholder: String
    let valuePlaceholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($entries) { $entry in
                HStack(spacing: 8) {
                    ThemedTextField(placeholder: keyPlaceholder, text: $entry.key)
                    Text("=")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                    ThemedTextField(placeholder: valuePlaceholder, text: $entry.value)
                    ActionIconButton(systemName: "minus.circle", tint: Theme.danger, help: "Remove") {
                        entries.removeAll { $0.id == entry.id }
                    }
                }
            }

            ActionTextButton(title: "Add", systemName: "plus") {
                entries.append(KVEntry(key: "", value: ""))
            }
        }
    }
}

// MARK: - Request environment wizard

struct RequestEnvWizard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let onSaved: (RequestsResponse) -> Void

    @State private var name = ""
    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add environment")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text("A request environment has its own base URLs and variables.")
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
                if let localError {
                    Text(localError)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.danger)
                }
                FormSection("Environment") {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Name")
                        ThemedTextField(placeholder: "dev", text: $name)
                    }
                }
            }
            .padding(22)

            Divider().overlay(Theme.stroke)

            HStack(spacing: 10) {
                Spacer()
                ActionTextButton(title: "Cancel", systemName: nil) { dismiss() }
                ActionTextButton(title: isSaving ? "Saving…" : "Add", systemName: "plus", prominent: true) {
                    Task { await save() }
                }
                .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 320)
        .background(Theme.background)
    }

    private func save() async {
        localError = nil
        isSaving = true
        defer { isSaving = false }
        guard let updated = await state.addRequestEnv(name: name.trimmingCharacters(in: .whitespaces)) else {
            localError = state.errorMessage ?? "Could not add the environment."
            return
        }
        onSaved(updated)
        dismiss()
    }
}

// MARK: - Variables prompt

struct RequestVarsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: RequestDefinition
    let env: RequestEnvironment
    let names: [String]
    let onRun: ([String: String]) -> Void

    @State private var values: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.name)
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text("These values are used for this run and saved in the environment.")
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
                ActionTextButton(title: "Cancel", systemName: nil) { dismiss() }
                ActionTextButton(title: "Run", systemName: "play.fill", prominent: true) {
                    onRun(values.mapValues { $0.trimmingCharacters(in: .whitespaces) })
                    dismiss()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 420)
        .background(Theme.background)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        for name in names {
            values[name] = env.value(for: name)
        }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
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
    /// text references. The token is never one of them.
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

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        for name in variableNames {
            values[name] = env.value(for: name)
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
    /// body of the request. The token is not one of them: it comes from the
    /// login request.
    var placeholders: [String] {
        var found: [String] = []
        var texts = [path, body]
        texts.append(contentsOf: params.map { $0.key + $0.value })
        texts.append(contentsOf: headers.map { $0.key + $0.value })
        for text in texts {
            for name in text.variablePlaceholders where name != "token" && !found.contains(name) {
                found.append(name)
            }
        }
        return found
    }

    /// The variables the request needs, with the ones that have no value in
    /// the environment.
    func missingVariables(in env: RequestEnvironment) -> [String] {
        var names: [String] = []
        for name in variableRefs where !names.contains(name) {
            names.append(name)
        }
        for name in placeholders where !names.contains(name) {
            names.append(name)
        }
        return names.filter { env.value(for: $0).isEmpty }
    }
}

extension String {
    /// The `{name}` references of a string.
    var variablePlaceholders: [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{([\w-]+)\}"#) else {
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
