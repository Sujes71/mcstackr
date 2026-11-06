import AppKit
import SwiftUI

// MARK: - K8s logs

/// The live logs of a deployment.
///
/// The window follows the deployment: the last lines come first and the new
/// ones arrive while the window is open. The task that reads the stream
/// belongs to the view, so closing the window stops it.
struct K8sLogsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let context: String
    let namespace: String
    let deployment: String

    @State private var lines: [String] = []
    @State private var isLive = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            toolbar
            Divider().overlay(Theme.stroke)
            log
        }
        .frame(minWidth: 560, idealWidth: 720, maxWidth: 820)
        .frame(minHeight: 320, idealHeight: 460, maxHeight: 620)
        .background(Theme.background)
        .task { await consume() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(deployment)
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    TechBadge(text: namespace, color: Theme.info)
                }
                Text("\(context) · Live logs")
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

    private var toolbar: some View {
        HStack(spacing: 10) {
            StatusDot(state: isLive ? "running" : "exited", size: 8)
            Text(isLive ? "streaming" : "stream closed")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)

            Spacer()

            ActionIconButton(systemName: "doc.on.doc", tint: Theme.info, help: "Copy all") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
    }

    // MARK: Body

    private var log: some View {
        ZStack {
            LiveLogView(lines: lines)

            if lines.isEmpty {
                Text("Waiting for logs…")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: Stream

    /// Reads the stream of the deployment and keeps the lines of the window.
    ///
    /// The buffer is capped: a deployment that logs a lot does not grow the
    /// window forever. The oldest lines are the ones that go.
    private func consume() async {
        guard let stream = state.k8sDeploymentLogs(
            context: context,
            namespace: namespace,
            deployment: deployment
        ) else {
            lines = ["— the engine is not running"]
            isLive = false
            return
        }
        do {
            for try await line in stream {
                if Task.isCancelled { return }
                lines.append(line)
                if lines.count > 2000 {
                    lines.removeFirst(lines.count - 2000)
                }
            }
        } catch {
            if !Task.isCancelled {
                lines.append("— \(error.localizedDescription)")
            }
        }
        isLive = false
    }
}
