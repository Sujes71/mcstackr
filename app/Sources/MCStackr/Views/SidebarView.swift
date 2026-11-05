import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var showNewProfile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 18)
                .padding(.top, 44)
                .padding(.bottom, 22)

            HStack {
                Text("PROFILES")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Button {
                    showNewProfile = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22, height: 22)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("New profile")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(state.profiles) { profile in
                        SidebarProfileRow(
                            profile: profile,
                            isSelected: state.selectedProfileName == profile.name
                        )
                        .onTapGesture {
                            state.select(profile: profile)
                        }

                        if state.selectedProfileName == profile.name {
                            environmentList(for: profile)
                        }
                    }

                    if state.profiles.isEmpty {
                        emptyProfiles
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 10)

            footer
        }
        .frame(width: 272)
        .background(Theme.sidebar)
        .sheet(isPresented: $showNewProfile) {
            NewProfileView()
                .environmentObject(state)
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.info],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 12)
                Text("M")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.accentInk)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("MCSTACKR")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(Theme.text)
                Text("ENVIRONMENT CONTROL")
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    private func environmentList(for profile: Profile) -> some View {
        VStack(spacing: 2) {
            ForEach(profile.environments) { env in
                SidebarEnvRow(
                    env: env,
                    isSelected: state.selectedEnvName == env.name
                )
                .onTapGesture {
                    state.select(profile: profile, env: env)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var emptyProfiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No profiles yet")
                .font(Theme.title(12))
                .foregroundStyle(Theme.textMuted)
            Text("A profile groups the environments, services and operations for one product.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .padding(.top, 6)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)

            HStack(spacing: 9) {
                StatusDot(state: state.dockerAvailable ? "running" : "exited", size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.dockerAvailable ? "Docker online" : "Docker offline")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(state.dockerAvailable ? Theme.text : Theme.textMuted)
                    Text("engine v\(state.engineVersion.isEmpty ? "—" : state.engineVersion)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                if !state.dockerAvailable {
                    Button {
                        Task { await state.launchDocker() }
                    } label: {
                        Text("Start")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .background(Theme.backgroundLift)
    }
}

// MARK: - Rows

private struct SidebarProfileRow: View {
    let profile: Profile
    let isSelected: Bool

    @State private var hovering = false

    private var initials: String {
        let letters = profile.name.prefix(2)
        return letters.uppercased()
    }

    private var serviceCount: Int {
        profile.environments.reduce(0) { $0 + $1.serviceCount }
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.16) : Theme.field)
                .frame(width: 30, height: 30)
                .overlay {
                    Text(initials)
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textMuted)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textMuted)
                    .lineLimit(1)
                Text("\(profile.environments.count) envs · \(serviceCount) services")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 4)

            Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textDim)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.surface : (hovering ? Theme.surfaceHover.opacity(0.55) : .clear))
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct SidebarEnvRow: View {
    let env: ProfileEnvironment
    let isSelected: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(isSelected ? Theme.accent : Theme.strokeStrong)
                .frame(width: 2, height: 16)
                .clipShape(Capsule())

            Text(env.name)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isSelected ? Theme.text : Theme.textMuted)

            if env.serviceCount > 0 {
                Text("\(env.serviceCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Theme.accentInk : Theme.textDim)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(isSelected ? Theme.accent : Theme.field, in: Capsule())
            }

            Spacer()
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering && !isSelected ? Theme.surfaceHover.opacity(0.5) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
