import AppKit
import SwiftUI

/// A text field with keyboard-driven suggestions: Tab accepts the highlighted suggestion,
/// ↑/↓ move the highlight. With no suggestions, Tab moves to the next field as usual.
/// AppKit-backed because SwiftUI text fields don't reliably let an app intercept Tab.
struct SuggestingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let suggestions: [String]
    @Binding var highlighted: Int
    /// Returns the new text for an accepted suggestion.
    let accept: (String) -> String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SuggestingTextField

        init(_ parent: SuggestingTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.highlighted = 0
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let suggestions = parent.suggestions
            guard !suggestions.isEmpty else { return false }
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                let index = min(max(parent.highlighted, 0), suggestions.count - 1)
                let newText = parent.accept(suggestions[index])
                parent.text = newText
                parent.highlighted = 0
                textView.string = newText
                textView.setSelectedRange(NSRange(location: (newText as NSString).length, length: 0))
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.highlighted = (parent.highlighted + 1) % suggestions.count
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.highlighted = (parent.highlighted - 1 + suggestions.count) % suggestions.count
                return true
            default:
                return false
            }
        }
    }
}

/// Clickable suggestion chips under a field; the highlighted one is what Tab accepts.
struct SuggestionChips: View {
    let suggestions: [String]
    let highlighted: Int
    let pick: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                    if index == min(highlighted, suggestions.count - 1) {
                        Button(suggestion) { pick(suggestion) }.buttonStyle(.borderedProminent).controlSize(.small)
                    } else {
                        Button(suggestion) { pick(suggestion) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Text("Tab to add · ↑↓ to choose").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
