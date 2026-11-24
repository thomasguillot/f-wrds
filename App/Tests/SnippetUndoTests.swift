import Foundation
import Testing
import WrdsKit

@MainActor
private final class FakeLibrary: SnippetEditingModel {
    var canEditSnippets = true
    var stored: [UUID: Snippet] = [:]
    private(set) var saveCount = 0

    func snippet(id: UUID) -> Snippet? { stored[id] }

    func updateSnippet(_ snippet: Snippet) {
        stored[snippet.id] = snippet
        saveCount += 1
    }
}

/// The snippet editor without its views: a draft, the library it saves to, and the window's undo
/// manager, driven the way `SnippetEditorView` drives `SnippetUndoController`.
@MainActor
private final class EditorHarness {
    let library = FakeLibrary()
    let undoManager = UndoManager()
    let controller: SnippetUndoController
    var draft: Snippet

    init(_ snippet: Snippet = Snippet(triggers: [";a"], label: "Old", content: "Hello"),
         flushingOn flushNames: [Notification.Name] = []) {
        controller = SnippetUndoController(flushingOn: flushNames)
        undoManager.groupsByEvent = false
        library.stored[snippet.id] = snippet
        draft = snippet
        controller.saveDelay = .milliseconds(10)
        open(snippet)
    }

    var stored: Snippet { library.stored[draft.id]! }

    /// What selecting a snippet does: the editor loads it and starts a fresh history.
    func open(_ snippet: Snippet) {
        library.stored[snippet.id] = library.stored[snippet.id] ?? snippet
        draft = library.stored[snippet.id]!
        controller.begin(read: { [unowned self] in draft }, write: { [unowned self] in draft = $0 },
                         model: library, undoManager: undoManager)
    }

    /// An edit committed in the editor: changed, recorded as a step, saved.
    func edit(_ edit: SnippetEdit, _ change: (inout Snippet) -> Void) {
        change(&draft)
        undoManager.beginUndoGrouping()
        controller.record(edit, current: draft)
        undoManager.endUndoGrouping()
        controller.save()
    }

    /// A group is opened only for an edit that can start a step: with `groupsByEvent` off, an empty
    /// group would count as an undo of its own, which the app's event-based groups never produce.
    func type(_ content: String, continuing: Bool) {
        draft.content = content
        if continuing {
            controller.recordTyping(content: content, continuing: true)
            return
        }
        undoManager.beginUndoGrouping()
        controller.recordTyping(content: content, continuing: false)
        undoManager.endUndoGrouping()
    }

    func undo() { undoManager.undo() }
    func redo() { undoManager.redo() }

    /// Waits out the save that follows an undo or redo.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }
}

@Suite("Snippet editor undo", .timeLimit(.minutes(1)))
@MainActor
struct SnippetUndoTests {

    @Test("Undo restores the step's field and saves it")
    func undoRestoresAndSaves() async {
        let editor = EditorHarness()
        editor.edit(.changeLabel) { $0.label = "New" }
        #expect(editor.stored.label == "New")
        #expect(editor.undoManager.undoActionName == "Change Label")

        editor.undo()
        #expect(editor.draft.label == "Old")
        await editor.settle()
        #expect(editor.stored.label == "Old")
    }

    @Test("Undo writes only its own field onto the snippet as stored now")
    func undoIsFieldIsolated() async {
        let editor = EditorHarness()
        editor.edit(.changeLabel) { $0.label = "New" }
        // Switched off in the list, and not yet reported to the editor.
        editor.library.stored[editor.draft.id]?.isEnabled = false

        editor.undo()
        await editor.settle()
        #expect(editor.stored.label == "Old")
        #expect(editor.stored.isEnabled == false)
        #expect(editor.draft.isEnabled == false)
    }

    @Test("Redo puts an undone step back")
    func redoReapplies() async {
        let editor = EditorHarness()
        editor.edit(.changeOption) { $0.wordBoundary = true }
        editor.undo()
        await editor.settle()
        #expect(editor.stored.wordBoundary == false)

        editor.redo()
        await editor.settle()
        #expect(editor.draft.wordBoundary == true)
        #expect(editor.stored.wordBoundary == true)
        #expect(editor.undoManager.canUndo)
    }

    @Test("A burst of undos saves once, after it stops")
    func burstSavesOnce() async {
        let editor = EditorHarness()
        editor.controller.saveDelay = .milliseconds(150)
        for label in ["One", "Two", "Three"] {
            editor.edit(.changeLabel) { $0.label = label }
        }
        editor.edit(.changeOption) { $0.wordBoundary = true }
        editor.edit(.changeOption) { $0.propagateCase = true }
        editor.edit(.changeEnabled) { $0.isEnabled = false }
        let savesBefore = editor.library.saveCount

        // Like a held ⌘Z: the repeats outlast the save delay, but each lands before the previous
        // one's save would have.
        for _ in 0..<6 {
            editor.undo()
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(editor.library.saveCount == savesBefore)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(editor.library.saveCount == savesBefore + 1)
        #expect(editor.stored == Snippet(id: editor.draft.id, triggers: [";a"], label: "Old",
                                         content: "Hello"))
    }

    @Test("An outside change is taken in and ends the history")
    func outsideChangeEndsHistory() {
        let editor = EditorHarness()
        editor.edit(.changeLabel) { $0.label = "New" }
        editor.draft.content = "Typed, not saved yet"
        var outside = editor.stored
        outside.isEnabled = false
        outside.wordBoundary = true
        editor.library.stored[outside.id] = outside

        editor.controller.storedSnippetChanged(to: outside)
        #expect(!editor.undoManager.canUndo)
        #expect(editor.draft.isEnabled == false)
        #expect(editor.draft.wordBoundary == true)
        #expect(editor.draft.label == "New")
        #expect(editor.draft.content == "Typed, not saved yet")
    }

    @Test("An outside change during the save delay wins over the waiting undo",
          arguments: [true, false])
    func outsideChangeBeatsPendingSave(reported: Bool) async {
        let editor = EditorHarness()
        editor.controller.saveDelay = .milliseconds(150)
        editor.edit(.changeOption) { $0.wordBoundary = true }
        editor.edit(.changeLabel) { $0.label = "New" }
        editor.undo()
        editor.undo()
        // A backup restore lands before the undos are saved.
        editor.library.stored[editor.draft.id]?.label = "Restored"
        if reported { editor.controller.storedSnippetChanged(to: editor.stored) }

        try? await Task.sleep(for: .milliseconds(400))
        #expect(editor.stored.label == "Restored")
        #expect(editor.draft.label == "Restored")
        #expect(editor.stored.wordBoundary == false)
    }

    @Test("Quitting saves an undo still waiting, and content typed but not committed")
    func flushSavesAtOnce() {
        let quit = Notification.Name("SnippetUndoTests.quit")
        let editor = EditorHarness(flushingOn: [quit])
        editor.controller.saveDelay = .seconds(30)
        editor.edit(.changeLabel) { $0.label = "New" }
        editor.undo()
        editor.draft.content = "Typed, not committed"

        NotificationCenter.default.post(name: quit, object: nil)
        #expect(editor.stored.label == "Old")
        #expect(editor.stored.content == "Typed, not committed")
    }

    @Test("A closed editor saves nothing on quit")
    func flushIgnoredAfterEnd() {
        let quit = Notification.Name("SnippetUndoTests.quitAfterEnd")
        let editor = EditorHarness(flushingOn: [quit])
        editor.controller.end()
        editor.draft.content = "Left behind"
        let savesBefore = editor.library.saveCount

        NotificationCenter.default.post(name: quit, object: nil)
        #expect(editor.library.saveCount == savesBefore)
    }

    @Test("The editor's own save is not mistaken for an outside change")
    func ownSaveKeepsHistory() {
        let editor = EditorHarness()
        editor.edit(.changeLabel) { $0.label = "New" }
        editor.controller.storedSnippetChanged(to: editor.stored)
        #expect(editor.undoManager.canUndo)
    }

    @Test("Undo does nothing while editing is off")
    func undoNoOpWhenEditingOff() async {
        let editor = EditorHarness()
        editor.edit(.changeLabel) { $0.label = "New" }
        let savesBefore = editor.library.saveCount
        editor.library.canEditSnippets = false

        editor.undo()
        await editor.settle()
        #expect(editor.draft.label == "New")
        #expect(editor.library.saveCount == savesBefore)
    }

    @Test("Opening another snippet drops the history")
    func switchingSnippetEndsHistory() async {
        let editor = EditorHarness()
        let first = editor.draft
        editor.edit(.changeLabel) { $0.label = "New" }

        editor.open(Snippet(triggers: [";b"], label: "Other"))
        #expect(!editor.undoManager.canUndo)
        editor.undo()
        await editor.settle()
        #expect(editor.library.stored[first.id]?.label == "New")
    }

    @Test("Typing that continues joins one step; a break starts another")
    func typingRuns() {
        let editor = EditorHarness()
        editor.type("Hello w", continuing: false)
        editor.type("Hello wo", continuing: true)
        editor.type("Hello wor", continuing: true)
        editor.type("X Hello wor", continuing: false)
        #expect(editor.undoManager.undoActionName == "Typing")

        editor.undo()
        #expect(editor.draft.content == "Hello wor")
        editor.undo()
        #expect(editor.draft.content == "Hello")
    }

    @Test("Undoing content asks the editor to show the change, other fields don't")
    func contentRestoreIsReported() {
        let editor = EditorHarness()
        var reported = 0
        editor.controller.onContentRestored = { reported += 1 }
        editor.edit(.changeLabel) { $0.label = "New" }
        editor.type("Hello!", continuing: false)

        editor.undo()
        #expect(reported == 1)
        editor.undo()
        #expect(reported == 1)
    }
}

@Suite("Typing runs")
struct TypingRunTests {
    private func edit(_ run: inout TypingRun, at location: Int, replacing length: Int = 0,
                      with inserted: Int, caretAfter: Int) -> Bool {
        run.willChange(NSRange(location: location, length: length), replacementLength: inserted)
        return run.didChange(caret: caretAfter)
    }

    @Test("Characters typed one after another continue")
    func typingContinues() {
        var run = TypingRun()
        #expect(!edit(&run, at: 0, with: 1, caretAfter: 1))
        #expect(edit(&run, at: 1, with: 1, caretAfter: 2))
        #expect(edit(&run, at: 2, with: 1, caretAfter: 3))
    }

    @Test("Backspaces in a row continue, and so do forward deletes")
    func deletionContinues() {
        var run = TypingRun()
        #expect(!edit(&run, at: 4, replacing: 1, with: 0, caretAfter: 4))
        #expect(edit(&run, at: 3, replacing: 1, with: 0, caretAfter: 3))
        #expect(edit(&run, at: 3, replacing: 1, with: 0, caretAfter: 3))
    }

    @Test("Moving the caret, pasting, typing over a selection or switching to deleting breaks the run")
    func breaks() {
        var run = TypingRun()
        _ = edit(&run, at: 0, with: 1, caretAfter: 1)
        #expect(!edit(&run, at: 5, with: 1, caretAfter: 6))
        #expect(!edit(&run, at: 6, with: 4, caretAfter: 10))
        _ = edit(&run, at: 10, with: 1, caretAfter: 11)
        #expect(!edit(&run, at: 11, replacing: 2, with: 1, caretAfter: 12))
        _ = edit(&run, at: 12, with: 1, caretAfter: 13)
        #expect(!edit(&run, at: 12, replacing: 1, with: 0, caretAfter: 12))
    }

    @Test("A reset breaks the run")
    func resetBreaks() {
        var run = TypingRun()
        _ = edit(&run, at: 0, with: 1, caretAfter: 1)
        run.reset()
        #expect(!edit(&run, at: 1, with: 1, caretAfter: 2))
    }
}

@Suite("Content offsets")
struct ContentOffsetTests {
    @Test("The end of a change is just past what differs", arguments: [
        ("Hello world", "Hello brave world", 12),
        ("Hello brave world", "Hello world", 6),
        ("abc", "abcdef", 6),
        ("same", "same", 4),
        ("{{date1}} on", "{{when}} on", 6),
    ])
    func endOfChange(old: String, new: String, expected: Int) {
        #expect(TokenSerialiser.endOfChange(from: old, to: new) == expected)
    }

    @Test("An offset before a change stays, one after it moves by the change's length")
    func carryAroundChange() {
        let old = "#@!% {{date1}}typing"
        let new = "#@!% {{when}}typing"
        #expect(TokenSerialiser.carry(3, from: old, to: new) == 3)
        #expect(TokenSerialiser.carry(14, from: old, to: new) == 13)
        #expect(TokenSerialiser.carry(20, from: old, to: new) == 19)
    }

    @Test("An offset inside a change lands at its end")
    func carryInsideChange() {
        #expect(TokenSerialiser.carry(9, from: "#@!% {{date1}}x", to: "#@!% {{when}}x") == 11)
    }
}
