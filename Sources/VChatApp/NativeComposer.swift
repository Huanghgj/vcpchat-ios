import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Both send controls dismiss the same editor, only after the chat accepts the draft.
@MainActor final class ComposerKeyboard {
    #if os(iOS)
    fileprivate weak var editor: UITextView?
    #endif

    func dismiss() {
        #if os(iOS)
        editor?.resignFirstResponder()
        #endif
    }
}

/// Native text editing keeps IME composition, selection and the insertion cursor intact.
struct NativeComposer: View {
    @Binding var text: String
    var enterSends: Bool
    var insertNewline: Int
    let keyboard: ComposerKeyboard
    var onSend: () -> Void
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty { Text("发消息").foregroundStyle(.secondary).padding(.top, 10).allowsHitTesting(false) }
            #if os(iOS)
            ComposerEditor(text: $text, enterSends: enterSends, insertNewline: insertNewline, keyboard: keyboard, onSend: onSend)
                .fixedSize(horizontal: false, vertical: true)
            #else
            ComposerEditor(text: $text, enterSends: enterSends, insertNewline: insertNewline, onSend: onSend)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }.frame(minHeight: 40).accessibilityLabel("发消息")
    }
}
#if os(iOS)
/// Some keyboard paths call insertText directly; others ask the editing delegate.
@MainActor private final class ComposerTextView: UITextView {
    var handleReturn: ((UITextView) -> Bool)?
    private(set) var forwardingInsertion = false

    override func insertText(_ text: String) {
        if text == "\n", handleReturn?(self) == true { return }
        forwardingInsertion = true
        defer { forwardingInsertion = false }
        super.insertText(text)
    }
}

private struct ComposerEditor: UIViewRepresentable {
    @Binding var text: String
    var enterSends: Bool; var insertNewline: Int; let keyboard: ComposerKeyboard; var onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.handleReturn = { [weak coordinator = context.coordinator] editor in
            coordinator?.handleReturn(editor) == true
        }
        keyboard.editor = view
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear; view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = "发消息"; view.isScrollEnabled = false
        let toolbar = UIToolbar()
        let hide = UIBarButtonItem(title: "收起键盘", style: .plain, target: view, action: #selector(UIResponder.resignFirstResponder))
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace), hide]
        toolbar.sizeToFit()
        view.inputAccessoryView = toolbar
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text && view.markedTextRange == nil { view.text = text; view.invalidateIntrinsicContentSize() }
        let returnKey: UIReturnKeyType = enterSends ? .send : .default
        if view.returnKeyType != returnKey { view.returnKeyType = returnKey; view.reloadInputViews() }
        if context.coordinator.newline != insertNewline {
            context.coordinator.newline = insertNewline
            context.coordinator.inserting = true; view.insertText("\n"); context.coordinator.inserting = false
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 280), measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let maxHeight: CGFloat = 142
        uiView.isScrollEnabled = measured.height > maxHeight
        return CGSize(width: width, height: min(maxHeight, max(40, measured.height)))
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerEditor; var newline: Int; var inserting = false
        init(_ parent: ComposerEditor) { self.parent = parent; newline = parent.insertNewline }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text; view.invalidateIntrinsicContentSize() }
        func handleReturn(_ view: UITextView) -> Bool {
            guard parent.enterSends, !inserting, view.markedTextRange == nil else { return false }
            if parent.text != view.text { parent.text = view.text }
            parent.onSend()
            return true
        }
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", (view as? ComposerTextView)?.forwardingInsertion != true {
                return !handleReturn(view)
            }
            return true
        }
    }
}
#else
@MainActor private final class ComposerTextView: NSTextView {
    override func setAccessibilityValue(_ accessibilityValue: Any?) { super.setAccessibilityValue(accessibilityValue); didChangeText() }
}
private struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    var enterSends: Bool; var insertNewline: Int; var onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 40)); view.autoresizingMask = [.width]; view.delegate = context.coordinator; view.isRichText = false
        view.font = .systemFont(ofSize: 16); view.textColor = .labelColor; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 0, height: 10); view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("发消息")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 40)); scroll.borderType = .noBorder; scroll.drawsBackground = false; scroll.documentView = view; scroll.hasVerticalScroller = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text && !view.hasMarkedText() { view.string = text }
        if context.coordinator.newline != insertNewline { context.coordinator.newline = insertNewline; view.insertText("\n", replacementRange: view.selectedRange()) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let view = nsView.documentView as? NSTextView, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = max(1, proposal.width ?? 280)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = max(40, ceil(layout.usedRect(for: container).height) + 20)
        return CGSize(width: width, height: min(142, height))
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor; var newline: Int
        init(_ parent: ComposerEditor) { self.parent = parent; newline = parent.insertNewline }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string } }
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) && parent.enterSends && !view.hasMarkedText() && !NSEvent.modifierFlags.contains(.shift) { parent.onSend(); return true }
            return false
        }
    }
}
#endif
