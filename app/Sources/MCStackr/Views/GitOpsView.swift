import SwiftUI

// MARK: - Git operations sheet

/// The git view of the workspace: the same two panels and the same operations
/// the original runtime had.
struct GitOpsView: View {
    @EnvironmentObject private var state: AppState

    @State private var selectedPath: String?
    @State private var diffText: String = ""
    @State private var loadingDiff: Bool = false
    @State private var output: String = ""
    @State private var errorText: String?
    @State private var busy: Bool = false
    @State private var sheetTarget: SheetTarget?
    @State private var confirm: Confirm?
    /// The log of a branch asked from the branch sheet.
    @State private var pendingLogBranch: String?

    private enum SheetTarget: Identifiable {
        case commit(amend: Bool)
        case branches
        case log(branch: String?)
        case conflicts

        var id: String {
            switch self {
            case .commit(let amend): return amend ? "amend" : "commit"
            case .branches: return "branches"
            case .log(let branch): return "log-\(branch ?? "current")"
            case .conflicts: return "conflicts"
            }
        }
    }

    /// The operations that destroy something ask first, the same way the
    /// original runtime did.
    private enum Confirm: Identifiable {
        case discard(GitFile)

        var id: String {
            switch self {
            case .discard(let file): return "discard-\(file.id)"
            }
        }

        var title: String {
            switch self {
            case .discard(let file): return "Discard “\(file.path)”?"
            }
        }

        var message: String {
            switch self {
            case .discard:
                return "The changes of the file are lost. It cannot be undone."
            }
        }

        var confirmTitle: String {
            switch self {
            case .discard: return "Discard"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            if let git {
                content(git)
            } else {
                loading
            }

            if let message = lastMessage {
                Divider().overlay(Theme.stroke)
                HStack(spacing: 8) {
                    Image(systemName: lastMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(lastMessageIsError ? Theme.danger : Theme.running)
                    Text(message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(lastMessageIsError ? Theme.danger : Theme.textMuted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .background(Theme.background)
        .task {
            await reload()
        }
        .sheet(item: $sheetTarget, onDismiss: {
            // The branch sheet asks for the log of a branch: it is opened
            // once the sheet that asked for it is gone.
            if let branch = pendingLogBranch {
                pendingLogBranch = nil
                sheetTarget = .log(branch: branch as String?)
            }
        }) { target in
            switch target {
            case .commit(let amend):
                GitCommitSheet(amend: amend, lastCommit: git?.lastCommit ?? "") { message in
                    await perform(amend ? "amend" : "commit", ["subject": message, "body": ""])
                }
            case .branches:
                GitBranchesSheet(
                    branches: git?.branches ?? [],
                    current: git?.branch ?? ""
                ) { action, branch in
                    await branchAction(action, branch)
                } onOpenLog: { branch in
                    pendingLogBranch = branch.name
                }
            case .log(let branch):
                GitLogSheet(
                    branch: branch ?? "",
                    initialCommits: branch == nil ? (git?.commits ?? []) : [],
                    onCherryPick: { hashes in
                        await perform(
                            "cherry_pick",
                            ["hashes": hashes.joined(separator: ","), "push": "true"]
                        )
                    }
                )
            case .conflicts:
                GitConflictsSheet(
                    conflicts: git?.conflicts ?? [],
                    rebase: git?.rebaseInProgress ?? false,
                    merge: git?.mergeInProgress ?? false
                ) { action, path in
                    await conflictAction(action, path)
                }
            }
        }
        .sheet(item: $confirm) { target in
            ConfirmSheet(
                title: target.title,
                message: target.message,
                confirmTitle: target.confirmTitle
            ) {
                Task {
                    switch target {
                    case .discard(let file):
                        await perform("discard", ["path": file.path])
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var git: GitState? { state.gitState }

    private var header: some View {
        HStack(spacing: 8) {
            if let git {
                if !git.branch.isEmpty {
                    TechBadge(text: git.branch, color: Theme.violet)
                }
                if git.ahead > 0 {
                    TechBadge(text: "↑\(git.ahead)", color: Theme.info)
                }
                if git.behind > 0 {
                    TechBadge(text: "↓\(git.behind)", color: Theme.warning)
                }
                if git.isRepo {
                    Text(git.root)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ git: GitState) -> some View {
        if !git.gitFound {
            emptyState(
                icon: "exclamationmark.triangle",
                title: "Git is not installed",
                message: "The operations need the git command in your PATH."
            )
        } else if !git.isRepo {
            emptyState(
                icon: "folder",
                title: "This directory is not a git repository",
                message: "The operations work on the directory the app was launched from."
            )
        } else if git.files.isEmpty {
            emptyState(
                icon: "checkmark.seal",
                title: "Working tree clean",
                message: "There is nothing to stage, commit or push."
            )
        } else {
            HSplitView {
                fileList(git)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)
                diffPanel
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)
            Text(title)
                .font(Theme.title(17))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text("Loading git operations…")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File list

    private func fileList(_ git: GitState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Files")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("\(git.files.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().overlay(Theme.stroke)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if git.stagedStart > 0 {
                        sectionLabel("Staged")
                        ForEach(git.files.prefix(git.stagedStart)) { file in
                            fileRow(file)
                        }
                    }
                    if git.stagedStart < git.files.count {
                        sectionLabel("Changes")
                        ForEach(git.files.dropFirst(git.stagedStart)) { file in
                            fileRow(file)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Theme.background)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func fileRow(_ file: GitFile) -> some View {
        let selected = selectedPath == file.path
        return HStack(spacing: 8) {
            Text(file.marker)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(markerColor(file))
                .frame(width: 12)

            Text(file.path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(selected ? Theme.text : Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if !file.staged, file.marker != "?" {
                ActionIconButton(
                    systemName: "arrow.uturn.backward",
                    tint: Theme.warning,
                    help: "Discard the changes of the file"
                ) {
                    confirm = .discard(file)
                }
            }

            ActionIconButton(
                systemName: file.staged ? "minus.circle" : "plus.circle",
                tint: file.staged ? Theme.textMuted : Theme.accent,
                help: file.staged ? "Unstage" : "Stage"
            ) {
                Task {
                    await perform(file.staged ? "unstage" : "stage", ["path": file.path])
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(selected ? Theme.surfaceHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            select(file)
        }
    }

    private func markerColor(_ file: GitFile) -> Color {
        switch file.marker {
        case "M", "A": return Theme.textMuted
        case "D": return Theme.danger
        case "C": return Theme.info
        case "U": return Theme.danger
        case "R": return Theme.accent
        default: return Theme.textDim
        }
    }

    // MARK: - Diff panel

    private var diffPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(selectedPath ?? "Diff")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().overlay(Theme.stroke)

            if loadingDiff {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diffText.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.textDim)
                    Text("Select a file to see its diff")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(coloredDiff(diffText))
                        .font(Theme.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        }
        .background(Theme.background)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let git {
                ActionTextButton(
                    title: allStaged(git) ? "Unstage all" : "Stage all",
                    systemName: allStaged(git) ? "minus.circle" : "plus.circle"
                ) {
                    Task { await perform(allStaged(git) ? "unstage_all" : "stage_all", [:]) }
                }

                if git.stagedStart > 0 {
                    ActionTextButton(title: "Commit", systemName: "checkmark.seal", prominent: true) {
                        sheetTarget = .commit(amend: false)
                    }
                }

                if !git.lastCommit.isEmpty, !git.headPushed {
                    ActionTextButton(title: "Amend", systemName: "pencil") {
                        sheetTarget = .commit(amend: true)
                    }
                }

                ActionTextButton(title: "Branches", systemName: "arrow.triangle.branch") {
                    sheetTarget = .branches
                }

                ActionTextButton(title: "Log", systemName: "list.bullet") {
                    sheetTarget = .log(branch: nil)
                }

                if git.hasUnpushed {
                    ActionTextButton(title: "Push", systemName: "arrow.up") {
                        Task { await perform("push", [:]) }
                    }
                } else if git.files.isEmpty {
                    ActionTextButton(title: "Pull", systemName: "arrow.down") {
                        Task { await perform("pull", [:]) }
                    }
                }

                if !git.files.isEmpty {
                    ActionTextButton(title: "Stash", systemName: "tray.and.arrow.down") {
                        Task { await perform("stash", ["message": "wip"]) }
                    }
                } else if git.hasStash {
                    ActionTextButton(title: "Pop", systemName: "tray.and.arrow.up") {
                        Task { await perform("stash_pop", [:]) }
                    }
                }

                if git.rebaseInProgress || git.mergeInProgress || !git.conflicts.isEmpty {
                    ActionTextButton(title: "Conflicts", systemName: "exclamationmark.triangle", tint: Theme.warning) {
                        sheetTarget = .conflicts
                    }
                }
            }

            Spacer()

            if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    /// What the last operation said.
    private var lastMessage: String? {
        if let errorText { return errorText }
        return output.isEmpty ? nil : output
    }

    private var lastMessageIsError: Bool {
        errorText != nil
    }

    private func allStaged(_ git: GitState) -> Bool {
        git.stagedStart > 0 && git.stagedStart >= git.files.count
    }

    // MARK: - Actions

    private func reload() async {
        let previous = selectedPath
        await state.refreshGit()
        guard let next = state.gitState else { return }
        if let previous, next.files.contains(where: { $0.path == previous }) {
            await loadDiff(for: previous)
        } else {
            selectedPath = nil
            diffText = ""
        }
    }

    private func select(_ file: GitFile) {
        selectedPath = file.path
        Task { await loadDiff(for: file.path) }
    }

    private func loadDiff(for path: String) async {
        loadingDiff = true
        let staged = git?.files.first { $0.path == path }?.staged ?? false
        let result = await state.runGitOp(op: "diff", params: ["path": path, "staged": staged ? "true" : "false"])
        diffText = result?.output ?? ""
        loadingDiff = false
    }

    /// Runs one operation and refreshes the state.
    private func perform(_ op: String, _ params: [String: String]) async {
        busy = true
        let result = await state.runGitOp(op: op, params: params)
        busy = false
        if let result {
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("unknown operation") || text.hasPrefix("fatal:") || text.hasPrefix("error:") {
                errorText = text
                output = ""
            } else {
                output = text
                errorText = nil
            }
        }
        await reload()
    }

    private func branchAction(_ action: String, _ branch: GitBranch) async {
        switch action {
        case "checkout":
            await perform("checkout", ["branch": branch.name])
        case "merge":
            await perform("merge", ["source": branch.name])
        case "delete":
            await perform("delete_branch", ["name": branch.name])
        case "create":
            await perform("create_branch", ["name": branch.name])
        default:
            break
        }
    }

    private func conflictAction(_ action: String, _ path: String) async {
        switch action {
        case "ours":
            await perform("resolve_ours", ["path": path])
        case "theirs":
            await perform("resolve_theirs", ["path": path])
        case "rebase_continue":
            await perform("rebase_continue", [:])
        case "rebase_abort":
            await perform("rebase_abort", [:])
        case "merge_continue":
            await perform("merge_continue", [:])
        case "merge_abort":
            await perform("merge_abort", [:])
        default:
            break
        }
    }
}

// MARK: - Commit sheet

struct GitCommitSheet: View {
    let amend: Bool
    let lastCommit: String
    let onCommit: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message: String = ""
    @State private var busy: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(amend ? "Amend commit" : "Commit")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text(amend ? "The last commit is rewritten with this message." : "The staged changes are committed with this message.")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
                Spacer()
                ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                    dismiss()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Message")
                ThemedTextField(placeholder: "What changed?", text: $message)
                if amend, !lastCommit.isEmpty {
                    Text("Last commit: \(lastCommit)")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().overlay(Theme.stroke)

            HStack {
                Spacer()
                ActionTextButton(
                    title: amend ? "Amend" : "Commit",
                    systemName: "checkmark",
                    prominent: true
                ) {
                    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    busy = true
                    Task {
                        await onCommit(text)
                        busy = false
                        dismiss()
                    }
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 300, idealWidth: 440, maxWidth: 520)
        .frame(minHeight: 200, idealHeight: 250, maxHeight: 320)
        .background(Theme.background)
        .onAppear {
            if amend { message = lastCommit }
        }
    }
}

// MARK: - Branches sheet

struct GitBranchesSheet: View {
    let branches: [GitBranch]
    let current: String
    let onAction: (String, GitBranch) async -> Void
    /// The log of a branch is asked to the parent, which opens it once this
    /// sheet is gone.
    let onOpenLog: (GitBranch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: String = ""
    /// The confirmation lives here: a view cannot present two sheets at once.
    @State private var confirm: BranchConfirm?
    /// The new branch form, in line: the sheet cannot open another one.
    @State private var creating = false
    @State private var newName = ""

    private enum BranchConfirm: Identifiable {
        case merge(GitBranch)
        case delete(GitBranch)

        var id: String {
            switch self {
            case .merge(let branch): return "merge-\(branch.name)"
            case .delete(let branch): return "delete-\(branch.name)"
            }
        }

        var title: String {
            switch self {
            case .merge(let branch): return "Merge “\(branch.name)”?"
            case .delete(let branch): return "Delete branch “\(branch.name)”?"
            }
        }

        var message: String {
            switch self {
            case .merge:
                return "The branch is merged into the current one. If both changed the same lines, you will have to solve it."
            case .delete:
                return "The branch is deleted. Its commits are not reachable anymore."
            }
        }

        var confirmTitle: String {
            switch self {
            case .merge: return "Merge"
            case .delete: return "Delete"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Branches")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text("\(branches.count) local branches")
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

            if creating {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Name")
                    ThemedTextField(placeholder: "feature/my-work", text: $newName)
                    Text("The branch starts at the current commit.")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(branches) { branch in
                            branchRow(branch)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Divider().overlay(Theme.stroke)

            HStack(spacing: 10) {
                if creating {
                    ActionTextButton(title: "Back", systemName: "arrow.left") {
                        creating = false
                        newName = ""
                    }
                    ActionTextButton(title: "Create", systemName: "plus", prominent: true) {
                        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        creating = false
                        newName = ""
                        Task { await onAction("create", GitBranch(
                            name: name, current: false, tracking: "", ahead: 0, behind: 0,
                            lastCommit: "", head: ""
                        )) }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    ActionTextButton(title: "New branch", systemName: "plus") {
                        creating = true
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 380, idealWidth: 500, maxWidth: 580)
        .frame(minHeight: 200, idealHeight: creating ? 240 : 320, maxHeight: 460)
        .background(Theme.background)
        .sheet(item: $confirm) { target in
            ConfirmSheet(
                title: target.title,
                message: target.message,
                confirmTitle: target.confirmTitle
            ) {
                Task {
                    switch target {
                    case .merge(let branch):
                        await onAction("merge", branch)
                    case .delete(let branch):
                        await onAction("delete", branch)
                    }
                }
            }
        }
    }

    /// A branch that is already at the same commit has nothing to merge, the
    /// same way the original runtime understood it.
    private func canMerge(_ branch: GitBranch) -> Bool {
        guard let current = branches.first(where: { $0.current }) else { return true }
        guard !branch.head.isEmpty, !current.head.isEmpty else { return true }
        return branch.head != current.head
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        let isSelected = selected == branch.name
        return HStack(spacing: 10) {
            // The circle at the left switches to the branch.
            Button {
                guard !branch.current else { return }
                Task { await onAction("checkout", branch) }
            } label: {
                Image(systemName: branch.current ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(branch.current ? Theme.accent : Theme.textDim)
            }
            .buttonStyle(.plain)
            .help("Switch to this branch")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(branch.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                    if branch.ahead > 0 {
                        Text("↑\(branch.ahead)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.info)
                    }
                    if branch.behind > 0 {
                        Text("↓\(branch.behind)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.warning)
                    }
                }
                if !branch.tracking.isEmpty {
                    Text("→ \(branch.tracking)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
                if !branch.lastCommit.isEmpty {
                    Text(branch.lastCommit)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // The log is offered for every branch: checking out one does not
            // take the log away.
            ActionIconButton(systemName: "list.bullet", tint: Theme.textMuted, help: "The log of the branch") {
                onOpenLog(branch)
                dismiss()
            }

            if !branch.current {
                ActionIconButton(
                    systemName: "arrow.left.arrow.right",
                    tint: canMerge(branch) ? Theme.info : Theme.textDim,
                    help: canMerge(branch) ? "Merge into the current branch" : "The branch is already at the same commit"
                ) {
                    guard canMerge(branch) else { return }
                    confirm = .merge(branch)
                }
                ActionIconButton(systemName: "trash", tint: Theme.danger, help: "Delete the branch") {
                    confirm = .delete(branch)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.surfaceHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = branch.name }
    }
}

// MARK: - Log sheet

/// The commit log of the current branch or of another one, with the live
/// filter and the cherry-pick of the original runtime.
struct GitLogSheet: View {
    /// Empty means the current branch.
    let branch: String
    let initialCommits: [GitCommit]
    let onCherryPick: ([String]) async -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    /// The detail lives here: a view cannot present two sheets at once.
    @State private var detail: GitCommit?
    @State private var commits: [GitCommit] = []
    @State private var pool: [GitCommit] = []
    @State private var search: String = ""
    /// The commits marked to cherry-pick.
    @State private var marked: Set<String> = []
    @State private var busy: Bool = false

    /// The cherry-pick is only offered in the log of another branch, like in
    /// the original runtime.
    private var canCherryPick: Bool { !branch.isEmpty }

    /// The commits the filter leaves, like the original runtime: the hash,
    /// the author or the message.
    private var visible: [GitCommit] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return commits }
        var matched: [GitCommit] = []
        for commit in pool {
            if commit.hash.lowercased().contains(query)
                || commit.author.lowercased().contains(query)
                || commit.message.lowercased().contains(query) {
                matched.append(commit)
                if matched.count >= 50 { break }
            }
        }
        return matched
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            searchField
            Divider().overlay(Theme.stroke)

            if visible.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: search.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.textDim)
                    Text(search.isEmpty ? "No commits" : "No matching commits")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { commit in
                            commitRow(commit)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(minWidth: 420, idealWidth: 540, maxWidth: 620)
        .frame(minHeight: 240, idealHeight: 340, maxHeight: 520)
        .background(Theme.background)
        .sheet(item: $detail) { commit in
            GitCommitDetailSheet(commit: commit)
        }
        .task {
            if branch.isEmpty {
                commits = initialCommits
                pool = initialCommits
            } else {
                await load(n: 30)
            }
            // The filter works over a bigger pool, like the original runtime.
            await loadPool()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Commit log")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    if !branch.isEmpty {
                        TechBadge(text: branch, color: Theme.violet)
                    }
                }
                Text(subtitle)
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
    }

    private var subtitle: String {
        let total = search.isEmpty ? commits.count : visible.count
        let filtered = search.isEmpty ? "" : " (filtered)"
        return "\(total) commits\(filtered)"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            ThemedTextField(placeholder: "Search by hash, author or message", text: $search)
            ActionIconButton(systemName: "xmark.circle.fill", tint: Theme.textMuted, help: "Clear the search") {
                search = ""
            }
            .opacity(search.isEmpty ? 0.35 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        HStack(spacing: 10) {
            if canCherryPick {
                Button {
                    toggle(commit.hash)
                } label: {
                    Image(systemName: marked.contains(commit.hash) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(marked.contains(commit.hash) ? Theme.violet : Theme.textDim)
                }
                .buttonStyle(.plain)
                .help("Mark the commit to cherry-pick")
            }

            Text(commit.hash)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.violet)

            Text(highlighted(commit.message))
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.text)
                .lineLimit(1)

            Text("\(commit.author) · \(commit.date)")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { detail = commit }
    }

    /// The matched text is highlighted, like in the original runtime.
    private func highlighted(_ text: String) -> AttributedString {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        let lower = text.lowercased()
        let needle = query.lowercased()
        var searchStart = lower.startIndex
        while let found = lower.range(of: needle, range: searchStart..<lower.endIndex) {
            if let attributed = Range(found, in: result) {
                result[attributed].foregroundColor = Theme.running
                result[attributed].font = .system(size: 11.5, weight: .bold, design: .rounded)
            }
            searchStart = found.upperBound
            if searchStart >= lower.endIndex { break }
        }
        return result
    }

    private func toggle(_ hash: String) {
        if marked.contains(hash) {
            marked.remove(hash)
        } else {
            marked.insert(hash)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if canCherryPick {
                ActionTextButton(
                    title: marked.isEmpty ? "Cherry-pick" : "Cherry-pick \(marked.count)",
                    systemName: "arrow.triangle.branch",
                    prominent: !marked.isEmpty
                ) {
                    applyCherryPick()
                }
                .disabled(marked.isEmpty || busy)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    /// The search works over a bigger pool, like the original runtime.
    private func loadPool() async {
        await load(n: 200)
    }

    /// Loads the commits of the branch. The empty branch is the current one.
    private func load(n: Int) async {
        let result = await state.runGitOp(
            op: "log_branch",
            params: ["branch": branch, "n": "\(n)"]
        )
        let lines = (result?.output ?? "").split(separator: "\n").map(String.init)
        var loaded: [GitCommit] = []
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count == 4 else { continue }
            loaded.append(GitCommit(
                hash: parts[0], author: parts[1], date: parts[2], message: parts[3]
            ))
        }
        if !loaded.isEmpty {
            commits = loaded
            pool = loaded
        }
    }

    /// The marked commits are applied in the order they appear in the log.
    private func applyCherryPick() {
        let hashes = visible.filter { marked.contains($0.hash) }.map(\.hash)
        guard !hashes.isEmpty else { return }
        busy = true
        Task {
            await onCherryPick(hashes)
            busy = false
            marked.removeAll()
        }
    }
}

// MARK: - Commit detail sheet

struct GitCommitDetailSheet: View {
    let commit: GitCommit

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    @State private var files: [String] = []
    @State private var diff: String = ""
    @State private var selectedFile: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(commit.hash)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.violet)
                    Text(commit.message)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Text("\(commit.author) · \(commit.date)")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                    dismiss()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().overlay(Theme.stroke)

            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("FILES")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(files, id: \.self) { file in
                                Text(file)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(selectedFile == file ? Theme.accent : Theme.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                    .onTapGesture { Task { await select(file) } }
                            }
                        }
                    }
                }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)

                ScrollView([.vertical, .horizontal]) {
                    Text(coloredDiff(diff))
                        .font(Theme.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 760, maxWidth: 880)
        .frame(minHeight: 280, idealHeight: 420, maxHeight: 560)
        .background(Theme.background)
        .task {
            let result = await state.runGitOp(op: "commit_files", params: ["hash": commit.hash])
            files = (result?.output ?? "").split(separator: "\n").map(String.init)
            if let first = files.first {
                await select(first)
            }
        }
    }

    private func select(_ file: String) async {
        selectedFile = file
        let result = await state.runGitOp(op: "diff_commit_file", params: ["hash": commit.hash, "path": file])
        diff = result?.output ?? ""
    }
}

// MARK: - Conflicts sheet

struct GitConflictsSheet: View {
    let conflicts: [String]
    let rebase: Bool
    let merge: Bool
    let onAction: (String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    /// The confirmation lives here: a view cannot present two sheets at once.
    @State private var confirmAbort = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conflicts")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text(rebase ? "A rebase is waiting for an answer." : "A merge is waiting for an answer.")
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
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(conflicts, id: \.self) { file in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning)
                            Text(file)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            ActionTextButton(title: "Ours", systemName: "arrow.left") {
                                Task { await onAction("ours", file) }
                            }
                            ActionTextButton(title: "Theirs", systemName: "arrow.right") {
                                Task { await onAction("theirs", file) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                    }
                }
                .padding(.vertical, 6)
            }

            Divider().overlay(Theme.stroke)

            HStack(spacing: 10) {
                if rebase {
                    ActionTextButton(title: "Continue rebase", systemName: "arrow.triangle.branch", prominent: true) {
                        Task { await onAction("rebase_continue", "") }
                    }
                    ActionTextButton(title: "Abort rebase", systemName: "xmark", destructive: true) {
                        confirmAbort = true
                    }
                }
                if merge {
                    ActionTextButton(title: "Continue merge", systemName: "checkmark", prominent: true) {
                        Task { await onAction("merge_continue", "") }
                    }
                    ActionTextButton(title: "Abort merge", systemName: "xmark", destructive: true) {
                        Task { await onAction("merge_abort", "") }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 380, idealWidth: 520, maxWidth: 600)
        .frame(minHeight: 220, idealHeight: 320, maxHeight: 460)
        .background(Theme.background)
        .sheet(isPresented: $confirmAbort) {
            ConfirmSheet(
                title: "Abort the rebase?",
                message: "The rebase is aborted and the repository goes back to where it was.",
                confirmTitle: "Abort"
            ) {
                Task { await onAction("rebase_abort", "") }
            }
        }
    }
}

// MARK: - Diff colors

/// The colors of a unified diff, the same way the original runtime showed them:
/// the added lines in green, the removed ones in red, the hunks in cyan.
func coloredDiff(_ raw: String) -> AttributedString {
    var out = AttributedString()
    if raw.isEmpty { return out }
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = String(line)
        var piece = AttributedString(text + "\n")
        if text.hasPrefix("+++") || text.hasPrefix("---") {
            piece.foregroundColor = Theme.textMuted
        } else if text.hasPrefix("@@") {
            piece.foregroundColor = Theme.info
        } else if text.hasPrefix("+") {
            piece.foregroundColor = Theme.running
        } else if text.hasPrefix("-") {
            piece.foregroundColor = Theme.danger
        } else {
            piece.foregroundColor = Theme.text
        }
        out += piece
    }
    return out
}
