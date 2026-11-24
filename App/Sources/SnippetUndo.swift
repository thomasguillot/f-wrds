import Foundation
import SwiftUI
import WrdsKit

/// The parts of a snippet one undo step can put back.
///
/// A step restores only the fields its edit touched, so undoing one change never reverts another
/// made in the meantime (a label still being typed, say, while an option is undone).
enum SnippetField: Sendable {
    case triggers, label, content, variables, wordBoundary, propagateCase, uppercaseStyle, isEnabled

    /// Copies this field from `source` into `target`. Triggers and the regex travel together: switching
    /// trigger type moves one into the other, and undoing that has to move both back.
    func copy(from source: Snippet, to target: inout Snippet) {
        switch self {
        case .triggers:
            target.triggers = source.triggers
            target.regexTrigger = source.regexTrigger
        case .label: target.label = source.label
        case .content: target.content = source.content
        case .variables: target.variables = source.variables
        case .wordBoundary: target.wordBoundary = source.wordBoundary
        case .propagateCase: target.propagateCase = source.propagateCase
        case .uppercaseStyle: target.uppercaseStyle = source.uppercaseStyle
        case .isEnabled: target.isEnabled = source.isEnabled
        }
    }

    func differs(between first: Snippet, and second: Snippet) -> Bool {
        var merged = first
        copy(from: second, to: &merged)
        return merged != first
    }
}

/// One thing a person can do in the snippet editor, as Edit ▸ Undo names it.
enum SnippetEdit {
    case addTrigger, removeTrigger, changeTriggerType, changeRegex, changeLabel
    case typing, insertVariable, removeVariable, changeVariable
    case changeOption
    case changeEnabled

    var fields: [SnippetField] {
        switch self {
        case .addTrigger, .removeTrigger, .changeTriggerType, .changeRegex: return [.triggers]
        case .changeLabel: return [.label]
        case .typing: return [.content]
        case .insertVariable, .changeVariable: return [.variables, .content]
        case .removeVariable: return [.variables]
        case .changeOption: return [.wordBoundary, .propagateCase, .uppercaseStyle]
        case .changeEnabled: return [.isEnabled]
        }
    }

    func actionName(for snippet: Snippet) -> String {
        switch self {
        case .addTrigger: return String(localized: "Add Trigger")
        case .removeTrigger: return String(localized: "Remove Trigger")
        case .changeTriggerType: return String(localized: "Change Trigger Type")
        case .changeRegex: return String(localized: "Change Regular Expression")
        case .changeLabel: return String(localized: "Change Label")
        case .typing: return String(localized: "Typing")
        case .insertVariable: return String(localized: "Insert Variable")
        case .removeVariable: return String(localized: "Remove Variable")
        case .changeVariable: return String(localized: "Change Variable")
        case .changeOption: return String(localized: "Change Option")
        case .changeEnabled:
            return snippet.isEnabled
                ? String(localized: "Enable Snippet") : String(localized: "Disable Snippet")
        }
    }
}

/// Edit ▸ Undo for the snippet editor, on the window's undo manager, so ⌘Z reaches every edit in
/// the pane whichever control has focus, and keeps working after focus moves on.
///
/// Steps are model values rather than text-view operations, which is what lets content history
/// survive the chip editor rebuilding its text storage: a record in the text view's own character
/// ranges would be invalid after every rebuild.
///
/// A step is recorded when an edit is committed (a toggle flipped, a trigger added, a text field
/// left). Inside a focused text field AppKit's typing undo still runs first, and the field editor
/// drops it when editing ends. The content editor has no field editor, so its typing is recorded
/// here, in runs.
///
/// History belongs to the snippet on screen: selecting another snippet, or closing the editor,
/// drops every step, so ⌘Z can never change a snippet you can't see.
@MainActor
final class SnippetUndoController {
    private weak var undoManager: UndoManager?
    private weak var model: AppModel?
    private var draft: Binding<Snippet>?
    /// The draft as of the last recorded step: what the next step will restore.
    private var baseline = Snippet()
    private var isTypingRunOpen = false
    private var isCommitScheduled = false

    func begin(editing draft: Binding<Snippet>, baseline: Snippet, model: AppModel,
               undoManager: UndoManager?) {
        end()
        self.draft = draft
        self.baseline = baseline
        self.model = model
        self.undoManager = undoManager
    }

    func end() {
        undoManager?.removeAllActions(withTarget: self)
        isTypingRunOpen = false
    }

    /// Registers `edit` if `current` differs from the last recorded state in the fields it covers.
    func record(_ edit: SnippetEdit, current: Snippet) {
        let changed = edit.fields.filter { $0.differs(between: baseline, and: current) }
        guard !changed.isEmpty else { return }
        isTypingRunOpen = false
        register(restoring: baseline, fields: changed, name: edit.actionName(for: current))
        for field in changed { field.copy(from: current, to: &baseline) }
    }

    /// Typing in the content editor. `continuing` says the edit carries on from the previous one,
    /// so it joins that step rather than starting a new one.
    func recordTyping(content: String, continuing: Bool) {
        guard content != baseline.content else { return }
        if !(continuing && isTypingRunOpen) {
            register(restoring: baseline, fields: [.content],
                     name: SnippetEdit.typing.actionName(for: baseline))
            isTypingRunOpen = true
        }
        baseline.content = content
    }

    func breakTyping() {
        isTypingRunOpen = false
    }

    private func register(restoring values: Snippet, fields: [SnippetField], name: String) {
        guard let undoManager, model?.canEditSnippets == true else { return }
        undoManager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.restore(values, fields: fields, name: name)
            }
        }
        undoManager.setActionName(name)
    }

    /// Runs for both undo and redo: whichever it is, registering the current values first is what
    /// gives the undo manager the opposite step.
    private func restore(_ values: Snippet, fields: [SnippetField], name: String) {
        guard let draft else { return }
        let current = draft.wrappedValue
        register(restoring: current, fields: fields, name: name)
        var updated = current
        for field in fields {
            field.copy(from: values, to: &updated)
            field.copy(from: values, to: &baseline)
        }
        isTypingRunOpen = false
        draft.wrappedValue = updated
        scheduleCommit()
    }

    /// One save per undo, however many steps the undo manager grouped into it: inserting a variable
    /// is a content step and a variables step, and saving after each would write the store twice.
    private func scheduleCommit() {
        guard !isCommitScheduled else { return }
        isCommitScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            isCommitScheduled = false
            commit()
        }
    }

    private func commit() {
        guard let model, model.canEditSnippets, let snippet = draft?.wrappedValue,
              let original = model.snippet(id: snippet.id), original != snippet else { return }
        model.updateSnippet(snippet)
    }
}
