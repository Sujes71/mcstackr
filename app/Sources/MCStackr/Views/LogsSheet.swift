import AppKit
import SwiftUI

struct LogsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let title: String
    let service: String?

    @State private var lines: [String] = []
    @State private var isLive = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StatusDot(state: isLive ? "running" : "exited", size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text(isLive ? "streaming" : "stream closed")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }

                Spacer()

                ActionIconButton(systemName: "doc.on.doc", tint: Theme.info, help: "Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }

                ActionIconButton(systemName: "xmark", tint: Theme.danger, help: "Close") {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider().overlay(Theme.stroke)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(lines.isEmpty ? "Waiting for logs…" : lines.joined(separator: "\n"))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(lines.isEmpty ? Theme.textDim : Theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
                .onChange(of: lines.count) { _, _ in
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .background(Theme.background)
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(Theme.background)
        .task { await consume() }
    }

    private func consume() async {
        guard let stream = state.logStream(service: service) else {
            lines = ["— no environment selected"]
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
