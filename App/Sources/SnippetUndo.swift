import AppKit
import Foundation
import WrdsKit

/// What the snippet editor's undo needs from the library: `AppModel`, or a stand-in in tests.
@MainActor
protocol SnippetEditingModel: AnyObject {
    var canEditSnippets: Bool { get }
    func snippet(id: UUID) -> Snippet?
    func updateSnippet(_ snippet: Snippet)
}

/// The parts of a snippet one undo step can put back.
///
/// A step restores only the fields its edit touched, so undoing one change never reverts another
/// made in the meantime (a label still being typed, say, while an option is undone).
enum SnippetField: CaseIterable, Sendable {
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
/// the pane whichever control has focus, and keeps working after focus moves on. Also the one place
/// the editor's draft is saved, and kept in step with the stored snippet.
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
/// Saving writes only the fields the draft has changed onto the snippet as it is stored now, so an
/// edit made elsewhere (the list's on/off switch, a backup restore) is never overwritten by a draft
/// that predates it. When such an outside change lands, the draft takes it in for every field not
/// being edited here, and the history ends: its steps were recorded against a snippet that no longer
/// exists, and undoing one could quietly revert the outside change.
///
/// History also ends when another snippet is selected or the editor closes, so ⌘Z can never change
/// a snippet you can't see.
///
/// The draft is also saved straight away when the app quits or its window stops being key: SwiftUI
/// runs no `onDisappear` on quit, and an undo still waiting on `saveDelay`, or content typed but not
/// yet committed, would otherwise be lost.
@MainActor
final class SnippetUndoController {
    private weak var undoManager: UndoManager?
    private weak var model: (any SnippetEditingModel)?
    /// Called just before an undo or redo changes the content, so the editor can show where.
    var onContentRestored: (() -> Void)?
    /// How long undos must pause before the result is saved.
    var saveDelay: Duration = .milliseconds(400)
    /// The editor's draft, read and written through the editor itself. A `Binding` kept from when
    /// the editor appeared can hand back a value from before the latest edit when read mid-update.
    private var readDraft: (() -> Snippet)?
    private var writeDraft: ((Snippet) -> Void)?
    /// The draft as of the last recorded step: what the next step will restore.
    private var baseline = Snippet()
    /// The stored snippet as of the last load, save or absorbed outside change. A draft field that
    /// differs from it is a local edit.
    private var lastStored: Snippet?
    private var isTypingRunOpen = false
    private var pendingSave: Task<Void, Never>?
    private var isEditing = false
    private var flushObservers: [NSObjectProtocol] = []

    init(flushingOn names: [Notification.Name] = [NSApplication.willTerminateNotification,
                                                  NSWindow.didResignKeyNotification]) {
        flushObservers = names.map { name in
            // No queue, so the save runs before the notification returns: on quit there is no later.
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    isolated deinit {
        flushObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func begin(read: @escaping () -> Snippet, write: @escaping (Snippet) -> Void,
               model: any SnippetEditingModel, undoManager: UndoManager?) {
        end()
        readDraft = read
        writeDraft = write
        baseline = read()
        lastStored = model.snippet(id: baseline.id)
        self.model = model
        self.undoManager = undoManager
        isEditing = true
    }

    func end() {
        pendingSave?.cancel()
        pendingSave = nil
        undoManager?.removeAllActions(withTarget: self)
        isTypingRunOpen = false
        isEditing = false
    }

    private func flush() {
        guard isEditing else { return }
        save()
    }

    /// SwiftUI can hand the editor its undo manager after it appears, or a different one later.
    func adopt(_ newManager: UndoManager?) {
        guard newManager !== undoManager else { return }
        undoManager?.removeAllActions(withTarget: self)
        undoManager = newManager
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

    /// Writes the draft's local edits onto the stored snippet, and nothing else.
    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let model, model.canEditSnippets, let id = readDraft?().id,
              let current = model.snippet(id: id) else { return }
        // An outside change SwiftUI hasn't reported yet is taken in first, or it would become the
        // reference and the draft's older value would look like a local edit.
        storedSnippetChanged(to: current)
        guard let snippet = readDraft?() else { return }
        var stored = current
        let reference = lastStored ?? current
        for field in SnippetField.allCases where field.differs(between: reference, and: snippet) {
            field.copy(from: snippet, to: &stored)
        }
        if stored != current { model.updateSnippet(stored) }
        lastStored = model.snippet(id: id)
    }

    /// The stored snippet changed. Anything other than this editor's own save is an outside change.
    ///
    /// The outside change wins every field it set, local edits included, so a save still waiting
    /// can only write fields nobody else has touched since.
    func storedSnippetChanged(to stored: Snippet?) {
        guard let stored, let draft = readDraft?(), stored.id == draft.id, stored != lastStored
        else { return }
        let reference = lastStored ?? stored
        var merged = draft
        for field in SnippetField.allCases
        where field.differs(between: reference, and: stored)
            || !field.differs(between: reference, and: merged) {
            field.copy(from: stored, to: &merged)
            field.copy(from: stored, to: &baseline)
        }
        merged.unmapped = stored.unmapped
        lastStored = stored
        undoManager?.removeAllActions(withTarget: self)
        isTypingRunOpen = false
        if merged != draft { writeDraft?(merged) }
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
        guard model?.canEditSnippets == true, let current = readDraft?() else { return }
        register(restoring: current, fields: fields, name: name)
        var updated = current
        for field in fields {
            field.copy(from: values, to: &updated)
            field.copy(from: values, to: &baseline)
        }
        isTypingRunOpen = false
        if updated.content != current.content { onContentRestored?() }
        writeDraft?(updated)
        scheduleSave()
    }

    /// Saved once things settle rather than per undo: holding ⌘Z repeats it many times a second,
    /// and one undo can be several steps the undo manager grouped together. Closing the editor or
    /// selecting another snippet saves straight away, so nothing waits on this.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            guard let delay = self?.saveDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
}

/// Whether each edit continues the one before it: a character typed where the last one left the
/// caret, or another ⌫ or ⌦ from there. A paste, typing over a selection or an edit after the caret
/// moved starts a new undo step, as it does in `NSTextView`.
struct TypingRun {
    private enum Kind { case insertion, deletion }
    /// Captured before the change, because by `textDidChange` the text view no longer says what
    /// changed.
    private var pending: (range: NSRange, length: Int)?
    private var last: (kind: Kind, caret: Int)?

    mutating func willChange(_ range: NSRange, replacementLength: Int) {
        pending = (range, replacementLength)
    }

    mutating func didChange(caret: Int) -> Bool {
        defer { pending = nil }
        guard let pending else {
            last = nil
            return false
        }
        let kind: Kind? = switch (pending.range.length, pending.length) {
        case (0, 1): .insertion
        case (_, 0): .deletion
        default: nil
        }
        var continuing = false
        if let kind, let last, last.kind == kind {
            continuing = kind == .insertion
                ? pending.range.location == last.caret
                : NSMaxRange(pending.range) == last.caret || pending.range.location == last.caret
        }
        last = kind.map { ($0, caret) }
        return continuing
    }

    mutating func reset() {
        last = nil
    }
}
