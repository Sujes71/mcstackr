import AppKit
import SwiftUI

/// Editor for a JSON request body.
///
/// Valid JSON is formatted as soon as it is pasted or the editor loses focus.
/// The body stays plain text when it is not valid JSON, so a body that is
/// still being written is never modified.
struct JSONBodyEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = JSONTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(Theme.text)
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? JSONTextView else { return }

        if textView.string != text {
            let location = min(textView.selectedRange().location, (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        textView.textColor = NSColor(Theme.text)
        textView.insertionPointColor = NSColor(Theme.accent)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
        }
    }
}

private final class JSONTextView: NSTextView {
    override func paste(_ sender: Any?) {
        super.paste(sender)
        formatJSONIfNeeded()
    }

    override func resignFirstResponder() -> Bool {
        formatJSONIfNeeded()
        return super.resignFirstResponder()
    }

    private func formatJSONIfNeeded() {
        guard let formatted = JSONBody.format(string), formatted != string else { return }

        let location = selectedRange().location
        string = formatted
        let length = (formatted as NSString).length
        setSelectedRange(NSRange(location: min(location, length), length: 0))
        didChangeText()
    }
}

private enum JSONBody {
    static func format(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return nil
        }
        return prettyPrint(trimmed)
    }

    /// Formats the body without reordering its keys.
    ///
    /// `JSONSerialization` is used only to validate the body: writing it back
    /// would not preserve the order of the keys the user wrote.
    private static func prettyPrint(_ source: String) -> String? {
        var result = ""
        var stack: [Frame] = []
        var inString = false
        var escaping = false
        var sawToken = false

        for character in source {
            if inString {
                result.append(character)
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                    sawToken = true
                    markValue(in: &stack)
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
                result.append(character)
            case "{", "[":
                markValue(in: &stack)
                result.append(character)
                stack.append(Frame())
                result.append("\n")
                result.append(String(repeating: "  ", count: stack.count))
            case "}", "]":
                guard !stack.isEmpty else { return nil }
                let frame = stack.removeLast()
                if frame.hasValue {
                    result.append("\n")
                    result.append(String(repeating: "  ", count: stack.count))
                } else {
                    while let last = result.last, last.isWhitespace {
                        result.removeLast()
                    }
                }
                result.append(character)
                sawToken = true
                markValue(in: &stack)
            case ",":
                result.append(character)
                result.append("\n")
                result.append(String(repeating: "  ", count: stack.count))
            case ":":
                result.append(": ")
            case " ", "\n", "\t", "\r":
                continue
            default:
                result.append(character)
                sawToken = true
                markValue(in: &stack)
            }
        }

        guard !inString, stack.isEmpty, sawToken else { return nil }
        return result
    }

    private static func markValue(in stack: inout [Frame]) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].hasValue = true
    }

    private struct Frame {
        var hasValue = false
    }
}
