import SwiftUI
import UIKit
import RemoteCore

struct KeyboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var reset = 0
    var body: some View {
        NavigationStack {
            VStack(alignment:.leading,spacing:14) {
                Text("Typing into the focused field on your PC").font(.subheadline).foregroundStyle(.secondary)
                RemoteEditor(reset:reset,onEdit:{ edit in edit.commands.forEach { model.input($0) } },onKey:{ model.input(.key($0)) })
                    .frame(height:54).padding(.horizontal,10).background(.quaternary,in:RoundedRectangle(cornerRadius:14))
                    .accessibilityLabel("Type on PC").accessibilityIdentifier("remoteEditor")
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:8) {
                        shortcut("Esc","escape"); shortcut("Tab","tab")
                        shortcut("Copy","c",modifiers:["ctrl"]); shortcut("Paste","v",modifiers:["ctrl"])
                        shortcut("Undo","z",modifiers:["ctrl"]); shortcut("Select all","a",modifiers:["ctrl"])
                    }
                }
                ScrollView(.horizontal,showsIndicators:false) { HStack(spacing:8) {
                    ForEach([("arrow.left","left"),("arrow.up","up"),("arrow.down","down"),("arrow.right","right"),("delete.left","backspace"),("return","enter")],id:\.1) { item in
                        Button { model.input(.key(item.1)); reset += 1 } label: { Image(systemName:item.0).frame(width:44,height:42).background(.quaternary,in:RoundedRectangle(cornerRadius:10)) }
                            .accessibilityLabel(item.1).buttonStyle(.plain)
                    }
                } }
                Spacer(minLength:0)
            }.padding(20).navigationTitle("Keyboard").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium,.large]).presentationDragIndicator(.visible).onDisappear { model.release() }
    }
    private func shortcut(_ title: String,_ key: String,modifiers: [String] = []) -> some View {
        Button(title) { model.input(.key(key,modifiers:modifiers)); reset += 1 }.font(.subheadline.weight(.medium)).buttonStyle(.bordered)
    }
}

private final class RemoteTextView: UITextView {
    var emptyBackspace: (()->Void)?
    override func deleteBackward() { if text.isEmpty && markedTextRange == nil { emptyBackspace?() } else { super.deleteBackward() } }
}
private struct RemoteEditor: UIViewRepresentable {
    let reset: Int
    let onEdit: (TypingEdit)->Void
    let onKey: (String)->Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> RemoteTextView {
        let v = RemoteTextView(); v.delegate = context.coordinator; v.font = .preferredFont(forTextStyle:.body); v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear; v.autocorrectionType = .no; v.autocapitalizationType = .none; v.smartDashesType = .no; v.smartQuotesType = .no; v.smartInsertDeleteType = .no
        v.accessibilityIdentifier = "remoteEditor"; v.accessibilityLabel = "Type on PC"
        v.emptyBackspace = { context.coordinator.parent.onKey("backspace") }
        DispatchQueue.main.async { v.becomeFirstResponder() }; return v
    }
    func updateUIView(_ view: RemoteTextView,context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastReset != reset { context.coordinator.lastReset = reset; view.text = ""; context.coordinator.committed = "" }
    }
    final class Coordinator: NSObject,UITextViewDelegate {
        var parent: RemoteEditor
        var committed = ""
        var lastReset: Int
        init(_ parent: RemoteEditor) { self.parent = parent; lastReset = parent.reset }
        func textView(_ textView: UITextView,shouldChangeTextIn range: NSRange,replacementText text: String) -> Bool {
            if text == "\n" && textView.markedTextRange == nil { parent.onKey("enter"); textView.text = ""; committed = ""; return false }
            return true
        }
        func textViewDidChange(_ textView: UITextView) {
            // Marked text is an IME composition, not a committed keystroke.
            guard textView.markedTextRange == nil else { return }
            let current = textView.text ?? ""
            parent.onEdit(.between(committed,current)); committed = current
            if current.count > 128 { let tail = String(current.suffix(64)); textView.text = tail; committed = tail }
        }
    }
}
