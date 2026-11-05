import SwiftUI

struct AddServiceView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case choose
        case configure
    }

    private enum Source: String, CaseIterable, Identifiable {
        case catalog
        case search
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .catalog: return "Catalog"
            case .search: return "Docker Hub"
            case .manual: return "Manual"
            }
        }
    }

    @State private var step: Step = .choose
    @State private var source: Source = .catalog

    @State private var query = ""
    @State private var results: [HubResult] = []
    @State private var isSearching = false

    @State private var manualImage = ""
    @State private var manualTag = "latest"

    @State private var name = ""
    @State private var image = ""
    @State private var tag = ""
    @State private var ports: [PortConfig] = []
    @State private var envVars: [EnvVarConfig] = []
    @State private var volumes: [VolumeConfig] = []

    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            if step == .choose {
                chooseStep
            } else {
                configureStep
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 660, height: 680)
        .background(Theme.background)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step == .choose ? "Add service" : "Configure service")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                    if step == .configure, !image.isEmpty {
                        TechBadge(text: image, color: Theme.info)
                    }
                }
                Text(step == .choose
                     ? "Pick an image first. Defaults depend on what you pick."
                     : "\(state.workspaceName) / Docker")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
            }

            Spacer()

            if step == .configure {
                ActionTextButton(title: "Change image", systemName: "chevron.left") {
                    step = .choose
                }
            }

            ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                dismiss()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    // MARK: - Step 1: choose image

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch source {
            case .catalog:
                catalogList
            case .search:
                searchList
            case .manual:
                manualEntry
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var catalogList: some View {
        Group {
            if state.catalog.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                    Text("Loading catalog…")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(state.catalog) { entry in
                            Button {
                                choose(image: entry.image, tag: entry.defaultTag, entry: entry)
                            } label: {
                                catalogRow(entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func catalogRow(_ entry: CatalogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text("\(entry.image):\(entry.defaultTag)")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textDim)
                }
                Text(entry.description)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if !entry.defaultPorts.isEmpty {
                Text(entry.defaultPorts.map { "\($0.host):\($0.container)" }.joined(separator: "  "))
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var searchList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ThemedTextField(placeholder: "Search Docker Hub…", text: $query)
                    .onSubmit { search() }
                ActionTextButton(title: "Search", systemName: "magnifyingglass") {
                    search()
                }
            }

            if isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                    Text("Searching…")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
            }

            if results.isEmpty && !isSearching {
                Text("Search for an image, then pick it to continue.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textDim)
                    .padding(.top, 6)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(results) { result in
                        Button {
                            choose(image: result.name, tag: "latest", entry: nil)
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Image")
                    ThemedTextField(placeholder: "e.g. my-registry/image", text: $manualImage)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Tag")
                    ThemedTextField(placeholder: "latest", text: $manualTag)
                        .frame(width: 150)
                }
            }

            Text("We still prefill ports, env vars and volumes when the image is in the catalog.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textDim)

            ActionTextButton(title: "Continue", systemName: "arrow.right", prominent: true) {
                choose(image: manualImage, tag: manualTag, entry: nil)
            }
            .disabled(manualImage.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(manualImage.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

            Spacer()
        }
    }

    // MARK: - Step 2: configure

    private var configureStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let localError {
                    Text(localError)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ServiceConfigForm(
                    showName: true,
                    nameHint: "Letters, numbers, _, . and - only.",
                    name: $name,
                    image: $image,
                    tag: $tag,
                    ports: $ports,
                    envVars: $envVars,
                    volumes: $volumes
                )
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if step == .configure {
                Text("Defaults come from the curated catalog; everything is editable.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            ActionTextButton(title: "Cancel") { dismiss() }

            if step == .configure {
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
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - Logic

    private var canSave: Bool {
        isValidServiceName(name) && !image.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func choose(image imageName: String, tag tagName: String, entry: CatalogEntry?) {
        localError = nil
        let trimmedImage = imageName.trimmingCharacters(in: .whitespaces)
        guard !trimmedImage.isEmpty else { return }

        image = trimmedImage
        tag = tagName.trimmingCharacters(in: .whitespaces)
        name = defaultServiceName(trimmedImage)

        let defaults = entry ?? state.catalogDefaults(forImage: trimmedImage)
        ports = defaults?.defaultPorts ?? []
        envVars = defaults?.defaultEnv ?? []
        if let target = defaults?.defaultVolumeTarget, !target.isEmpty {
            volumes = [VolumeConfig(source: "", target: target, named: true)]
        } else {
            volumes = []
        }

        step = .configure
    }

    private func defaultServiceName(_ imageName: String) -> String {
        var base = imageName
        if let colon = base.firstIndex(of: ":") {
            base = String(base[base.startIndex..<colon])
        }
        if base.hasPrefix("library/") {
            base.removeFirst("library/".count)
        }
        return base.split(separator: "/").last.map(String.init) ?? base
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

        let cleanPorts = ports.filter {
            !$0.host.trimmingCharacters(in: .whitespaces).isEmpty &&
            !$0.container.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let cleanEnvVars = envVars.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        let cleanVolumes = volumes.filter { !$0.target.trimmingCharacters(in: .whitespaces).isEmpty }

        let added = await state.addService(
            name: name.trimmingCharacters(in: .whitespaces),
            image: image.trimmingCharacters(in: .whitespaces),
            tag: tag.trimmingCharacters(in: .whitespaces),
            ports: cleanPorts,
            envVars: cleanEnvVars,
            volumes: cleanVolumes
        )
        if added {
            dismiss()
        } else {
            localError = state.errorMessage ?? "Could not add the service."
            state.errorMessage = nil
        }
    }
}
