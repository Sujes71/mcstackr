import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    @State private var showNewWorkspace = false
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 18)
                .padding(.top, 44)
                .padding(.bottom, 18)

            workspaceSwitcher
                .padding(.horizontal, 14)
                .padding(.bottom, 18)

            // The sections belong to a workspace: without one there is
            // nothing to navigate to.
            if state.selectedProfile != nil {
                nav
                    .padding(.horizontal, 12)
            }

            if state.profiles.isEmpty {
                emptyWorkspace
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

            Spacer(minLength: 10)

            footer
        }
        .frame(width: 240)
        .background(Theme.sidebar)
        .sheet(isPresented: $showNewWorkspace) {
            NewWorkspaceView()
                .environmentObject(state)
        }
        .sheet(isPresented: $showSettings) {
            WorkspaceSettingsView()
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

    private var workspaceSwitcher: some View {
        Menu {
            ForEach(state.profiles) { profile in
                Button {
                    state.select(profile: profile)
                } label: {
                    if profile.name == state.selectedProfileName {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }

            Divider()

            Button {
                showNewWorkspace = true
            } label: {
                Label("New workspace…", systemImage: "plus")
            }

            Button {
                showSettings = true
            } label: {
                Label("Workspace settings…", systemImage: "slider.horizontal.3")
            }
            .disabled(state.selectedProfile == nil)
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.workspaceName.isEmpty ? "No workspace" : state.workspaceName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("WORKSPACE")
                        .font(.system(size: 7.5, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(Theme.textDim)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var nav: some View {
        VStack(spacing: 3) {
            sectionRow(
                .docker,
                badge: state.runningCount + state.runningLocalProcessCount > 0
                    ? "\(state.runningCount + state.runningLocalProcessCount)"
                    : nil
            )
            sectionRow(
                .portForward,
                badge: state.runningForwardCount > 0 ? "\(state.runningForwardCount)" : nil
            )
            sectionRow(.requests, badge: nil)
            sectionRow(.git, badge: nil)
        }
    }

    private func sectionRow(_ section: AppSection, badge: String?) -> some View {
        let selected = state.section == section
        return Button {
            state.selectSection(section)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.textMuted)
                    .frame(width: 18)

                Text(section.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(selected ? Theme.text : Theme.textMuted)

                Spacer(minLength: 4)

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(selected ? Theme.accentInk : Theme.textDim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(selected ? Theme.accent : Theme.field, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.surface : .clear)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No workspace yet")
                .font(Theme.title(12))
                .foregroundStyle(Theme.textMuted)
            Text("Create one to start defining Docker services.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            ActionTextButton(title: "New workspace", systemName: "plus", prominent: true) {
                showNewWorkspace = true
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
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
