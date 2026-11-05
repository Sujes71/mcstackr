import SwiftUI

struct AddServiceView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var image = ""
    @State private var tag = "latest"
    @State private var hostPort = ""
    @State private var containerPort = ""

    @State private var query = ""
    @State private var results: [HubResult] = []
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add service")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    Text("\(state.selectedProfile?.name ?? "—") / \(state.selectedEnvName ?? "—")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                    dismiss()
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Service name")
                    ThemedTextField(placeholder: "postgres", text: $name)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Tag")
                    ThemedTextField(placeholder: "latest", text: $tag)
                }
                .frame(width: 130)
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Image")
                ThemedTextField(placeholder: "postgres", text: $image)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Host port")
                    ThemedTextField(placeholder: "5432", text: $hostPort)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Container port")
                    ThemedTextField(placeholder: "5432", text: $containerPort)
                }
            }

            Divider().overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    FieldLabel(text: "Docker Hub")
                    Spacer()
                    if isSearching {
                        ProgressView().controlSize(.mini).tint(Theme.accent)
                    }
                }

                HStack(spacing: 8) {
                    ThemedTextField(placeholder: "Search images…", text: $query)
                        .onSubmit { search() }
                    ActionTextButton(title: "Search", systemName: "magnifyingglass") {
                        search()
                    }
                }

                if !results.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(results) { result in
                                Button {
                                    apply(result)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: result.official ? "checkmark.seal.fill" : "shippingbox")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(result.official ? Theme.accent : Theme.textDim)
                                            .frame(width: 14)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(result.name)
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .foregroundStyle(Theme.text)
                                            Text(result.description.isEmpty ? "No description" : result.description)
                                                .font(.system(size: 10.5, design: .rounded))
                                                .foregroundStyle(Theme.textMuted)
                                                .lineLimit(2)
                                        }

                                        Spacer()

                                        Text("★ \(result.stars)")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    .padding(9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(Theme.stroke, lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                    .scrollIndicators(.hidden)
                }
            }

            if let localError {
                Text(localError)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                ActionTextButton(title: "Cancel") { dismiss() }
                ActionTextButton(
                    title: isSaving ? "Adding…" : "Add service",
                    systemName: "plus",
                    prominent: true
                ) {
                    Task { await save() }
                }
                .disabled(isSaving || !canSave)
                .opacity(isSaving || !canSave ? 0.5 : 1)
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(Theme.background)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !image.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func apply(_ result: HubResult) {
        image = result.name
        tag = "latest"
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = result.name.split(separator: "/").last.map(String.init) ?? result.name
        }
    }

    private func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        Task {
            results = await state.searchHub(query)
            isSearching = false
        }
    }

    private func save() async {
        localError = nil
        isSaving = true
        defer { isSaving = false }

        let added = await state.addService(
            name: name.trimmingCharacters(in: .whitespaces),
            image: image.trimmingCharacters(in: .whitespaces),
            tag: tag.trimmingCharacters(in: .whitespaces),
            hostPort: hostPort,
            containerPort: containerPort
        )
        if added {
            dismiss()
        } else {
            localError = state.errorMessage ?? "Could not add the service."
            state.errorMessage = nil
        }
    }
}
