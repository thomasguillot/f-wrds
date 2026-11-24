import Foundation
import Testing
import WrdsKit

private let signature = Snippet(triggers: [":sig"], content: "Best, Tom")
private let address = Snippet(triggers: [":addr"], content: "1 Main St.")
private let dotSig = Snippet(triggers: [".sig"], content: "DOT")
private let cursor = Snippet(triggers: [":cur"], content: "Hello $|$world")
private func form(_ name: String, field: String) -> Variable {
    Variable(name: name, kind: .form(fields: [FormField(name: field, label: field, kind: .text(default: ""))]))
}

private let greeting = Snippet(triggers: [":hi"], content: "Hi {{who.name}}",
                               variables: [form("who", field: "name")])
private let twoForms = Snippet(triggers: [":two"], content: "{{first.a}}-{{second.b}}",
                               variables: [form("first", field: "a"), form("second", field: "b")])

private let expandedSignature: [FakeInjector.Call] = [.delete(4), .paste("Best, Tom")]

@Suite("ExpansionEngine", .timeLimit(.minutes(1)))
struct ExpansionEngineTests {

    @Suite("Expanding")
    struct Expanding {
        @Test("A typed trigger is deleted and replaced with its expansion")
        func triggerExpands() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":sig")
            #expect(harness.injector.calls == expandedSignature)
        }

        @Test("Nothing expands before the engine is started")
        func nothingBeforeStart() {
            let harness = EngineHarness(snippets: [signature], start: false)
            harness.type(":sig")
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("A source that fails to start leaves the engine paused")
        func failedStartStaysPaused() {
            let source = FakeKeystrokeSource(startResult: false)
            let injector = FakeInjector()
            let engine = ExpansionEngine(monitor: source, injector: injector)
            engine.updateLibrary(groups: [SnippetGroup(name: "Test", snippets: [signature])], globals: [])
            #expect(!engine.start())
            #expect(engine.isPaused)
            for character in ":sig" { source.onKeyInput?(.character(character), false) }
            engine.waitUntilIdle()
            #expect(injector.calls.isEmpty)
        }

        @Test("Stopping pauses matching and stops the source")
        func stopPausesAndStopsSource() {
            let harness = EngineHarness(snippets: [signature])
            harness.engine.stop()
            harness.type(":sig")
            #expect(harness.source.stopCount == 1)
            #expect(harness.engine.isPaused)
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("A click forgets the half-typed trigger")
        func clickForgetsBuffer() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":si")
            harness.click()
            harness.type("g")
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("Switching apps forgets the half-typed trigger")
        func appSwitchForgetsBuffer() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":si")
            harness.switchApp(to: "com.example.other")
            harness.type("g")
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("A menu expansion deletes nothing and injects the text")
        func menuExpansion() {
            let harness = EngineHarness(snippets: [signature])
            harness.expand(signature)
            #expect(harness.injector.calls == [.delete(0), .paste("Best, Tom")])
        }

        @Test("A cursor marker moves the caret back into the expansion")
        func cursorMarker() {
            let harness = EngineHarness(snippets: [cursor])
            harness.type(":cur")
            #expect(harness.injector.calls == [.delete(4), .paste("Hello world"), .arrowLeft(5)])
        }
    }

    @Suite("Injection mode")
    struct InjectionMode {
        @Test("The default mode is used when the app has no override")
        func defaultMode() {
            let harness = EngineHarness(snippets: [signature],
                                        settings: .with { $0.defaultInjectionMode = .typed })
            harness.type(":sig")
            #expect(harness.injector.calls == [.delete(4), .type("Best, Tom")])
        }

        @Test("A per-app override wins over the default, only in that app")
        func perAppOverride() {
            let terminal = "com.example.terminal"
            let harness = EngineHarness(
                snippets: [signature],
                settings: .with { $0.perAppInjectionOverrides = [terminal: .typed] },
                frontmost: terminal)
            harness.type(":sig")
            harness.reset()
            harness.switchApp(to: EngineHarness.editor)
            harness.type(":sig")
            #expect(harness.injector.calls == [
                .delete(4), .type("Best, Tom"),
                .delete(4), .paste("Best, Tom"),
            ])
        }

        @Test("An explicit app for a picker expansion picks that app's mode")
        func pickerAppMode() {
            let terminal = "com.example.terminal"
            let harness = EngineHarness(
                snippets: [signature],
                settings: .with { $0.perAppInjectionOverrides = [terminal: .typed] })
            harness.expand(signature, inApp: terminal)
            #expect(harness.injector.calls == [.delete(0), .type("Best, Tom")])
        }

        @Test("A form's injection mode comes from the app its trigger was typed in")
        func formUsesOriginApp() async throws {
            let terminal = "com.example.terminal"
            let harness = EngineHarness(
                snippets: [greeting],
                settings: .with { $0.perAppInjectionOverrides = [terminal: .typed] },
                frontmost: terminal)
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            let request = try #require(await requests.next())
            #expect(request.originBundleID == terminal)
            harness.switchApp(to: EngineHarness.editor)
            harness.complete(request, answers: ["who.name": "Ada"])
            #expect(harness.injector.calls == [.delete(3), .type("Hi Ada")])
        }
    }

    @Suite("Pause and panel suspension")
    struct Suspension {
        @Test("Typing while paused does not expand")
        func pausedDropsInput() {
            let harness = EngineHarness(snippets: [signature])
            harness.setPaused(true)
            harness.type(":sig")
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("Resuming does not complete a trigger half-typed before the pause")
        func resumeDoesNotCompleteHalfTrigger() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":si")
            harness.setPaused(true)
            harness.setPaused(false)
            harness.type("g")
            #expect(harness.injector.calls.isEmpty)
            harness.type(":sig")
            #expect(harness.injector.calls == expandedSignature)
        }

        @Test("Typing into a panel does not expand")
        func panelSuspendedDropsInput() {
            let harness = EngineHarness(snippets: [signature])
            harness.setPanelSuspended(true)
            harness.type(":sig")
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("Closing a panel does not complete a trigger half-typed before it opened")
        func panelDoesNotCompleteHalfTrigger() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":si")
            harness.setPanelSuspended(true)
            harness.setPanelSuspended(false)
            harness.type("g")
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("A panel session drops an armed undo")
        func panelClearsUndo() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":sig")
            harness.setPanelSuspended(true)
            harness.setPanelSuspended(false)
            harness.backspace()
            #expect(harness.injector.calls == expandedSignature)
        }

        @Test("A pause drops an armed undo")
        func pauseClearsUndo() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":sig")
            harness.setPaused(true)
            harness.setPaused(false)
            harness.backspace()
            #expect(harness.injector.calls == expandedSignature)
        }

        @Test("The palette can still expand what it was opened to find")
        func panelStillExpandsFromMenu() {
            let harness = EngineHarness(snippets: [signature])
            harness.setPanelSuspended(true)
            harness.expand(signature)
            #expect(harness.injector.calls == [.delete(0), .paste("Best, Tom")])
        }
    }

    @Suite("Forms")
    struct Forms {
        @Test("A form trigger deletes nothing until the answers come back")
        func formWaitsForAnswers() async throws {
            let harness = EngineHarness(snippets: [greeting])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            let request = try #require(await requests.next())
            #expect(request.originBundleID == EngineHarness.editor)
            #expect(request.variable.name == "who")
            #expect(harness.injector.calls.isEmpty)
            harness.complete(request, answers: ["who.name": "Ada"])
            #expect(harness.injector.calls == [.delete(3), .paste("Hi Ada")])
        }

        @Test("Nothing matches while a form is pending")
        func pendingFormBlocksMatching() async throws {
            let harness = EngineHarness(snippets: [greeting, signature])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            _ = try #require(await requests.next())
            harness.type(":sig")
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("A menu expansion is refused while a form is pending")
        func pendingFormBlocksMenuExpansion() async throws {
            let harness = EngineHarness(snippets: [greeting, signature])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            _ = try #require(await requests.next())
            harness.expand(signature)
            harness.expand(signature, inApp: EngineHarness.editor)
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("Answers quoting another flow are ignored")
        func staleCompleteIgnored() async throws {
            let harness = EngineHarness(snippets: [greeting, signature])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            let request = try #require(await requests.next())
            harness.complete(request, answers: ["who.name": "Ada"], flow: UUID())
            #expect(harness.injector.calls.isEmpty)
            harness.type(":sig")
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("A cancel quoting another flow leaves the pending form alone")
        func staleCancelIgnored() async throws {
            let harness = EngineHarness(snippets: [greeting, signature])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            let request = try #require(await requests.next())
            harness.cancel(flow: UUID())
            harness.type(":sig")
            #expect(harness.injector.calls.isEmpty)
            harness.complete(request, answers: ["who.name": "Ada"])
            #expect(harness.injector.calls == [.delete(3), .paste("Hi Ada")])
        }

        @Test("Typing into a form panel forgets a trigger half-typed before it opened")
        func formPanelTypingForgetsBuffer() async throws {
            let harness = EngineHarness(snippets: [greeting, signature])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":si")
            harness.expand(greeting)
            let request = try #require(await requests.next())
            harness.type("x")
            harness.cancel(flow: request.flow)
            harness.type("g")
            #expect(harness.injector.calls.isEmpty)
        }

        @Test("Canceling resumes matching, and the canceled flow cannot be completed")
        func cancelResumesMatching() async throws {
            let harness = EngineHarness(snippets: [greeting, signature])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            let request = try #require(await requests.next())
            harness.cancel(flow: request.flow)
            harness.complete(request, answers: ["who.name": "Ada"])
            #expect(harness.injector.calls.isEmpty)
            harness.type(":sig")
            #expect(harness.injector.calls == expandedSignature)
        }

        @Test("Completing a form resumes matching")
        func completeResumesMatching() async throws {
            let harness = EngineHarness(snippets: [greeting, signature])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            let request = try #require(await requests.next())
            harness.complete(request, answers: ["who.name": "Ada"])
            harness.type(" :sig")
            #expect(harness.injector.calls == [.delete(3), .paste("Hi Ada"), .delete(4), .paste("Best, Tom")])
        }

        @Test("A second form variable keeps the flow, and matching stays paused between them")
        func multipleFormsShareFlow() async throws {
            let harness = EngineHarness(snippets: [twoForms, signature])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":two")
            let first = try #require(await requests.next())
            #expect(first.variable.name == "first")
            harness.complete(first, answers: ["first.a": "x"])
            let second = try #require(await requests.next())
            #expect(second.variable.name == "second")
            #expect(second.flow == first.flow)
            #expect(second.originBundleID == EngineHarness.editor)
            harness.type(":sig")
            #expect(harness.injector.calls.isEmpty)
            harness.complete(second, answers: ["first.a": "x", "second.b": "y"])
            #expect(harness.injector.calls == [.delete(4), .paste("x-y")])
        }

        @Test("A menu expansion with a form starts a flow of its own")
        func menuFormFlow() async throws {
            let harness = EngineHarness(snippets: [greeting])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.expand(greeting)
            let request = try #require(await requests.next())
            #expect(request.match.typedText.isEmpty)
            harness.complete(request, answers: ["who.name": "Ada"])
            #expect(harness.injector.calls == [.delete(0), .paste("Hi Ada")])
        }

        @Test("Two runs of the same trigger get different flows")
        func freshFlowPerRun() async throws {
            let harness = EngineHarness(snippets: [greeting])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            let first = try #require(await requests.next())
            harness.cancel(flow: first.flow)
            harness.type(":hi")
            let second = try #require(await requests.next())
            #expect(first.flow != second.flow)
            harness.complete(first, answers: ["who.name": "Stale"])
            #expect(harness.injector.calls.isEmpty)
        }
    }

    @Suite("Seed")
    struct Seed {
        @Test("A trigger reaching back over the seeded character is discarded")
        func triggerOverSeedDiscarded() {
            let harness = EngineHarness(snippets: [address, dotSig])
            harness.type(":addr")
            harness.type("sig")
            #expect(harness.injector.calls == [.delete(5), .paste("1 Main St.")])
        }

        @Test("The same trigger typed in full after an expansion still fires")
        func triggerTypedInFullFires() {
            let harness = EngineHarness(snippets: [address, dotSig])
            harness.type(":addr")
            harness.type(".sig")
            #expect(harness.injector.calls == [
                .delete(5), .paste("1 Main St."),
                .delete(4), .paste("DOT"),
            ])
        }

        @Test("A word-boundary trigger does not fire mid-word straight after an expansion")
        func seedKeepsWordBoundaryHonest() {
            let word = Snippet(triggers: ["btw"], content: "by the way", wordBoundary: true)
            let harness = EngineHarness(snippets: [signature, word])
            harness.type(":sig")
            harness.type("btw")
            #expect(harness.injector.calls == expandedSignature)
        }
    }

    @Suite("Undo on backspace")
    struct Undo {
        @Test("A backspace straight after an expansion puts the trigger back")
        func backspaceUndoes() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":sig")
            harness.backspace()
            #expect(harness.injector.calls == expandedSignature + [.delete(8), .type(":sig")])
        }

        @Test("A word-boundary trigger does not fire mid-word straight after an undo")
        func undoSeedsMatcher() {
            let word = Snippet(triggers: ["btw"], content: "by the way", wordBoundary: true)
            let harness = EngineHarness(snippets: [signature, word])
            harness.type(":sig")
            harness.backspace()
            harness.type("btw")
            #expect(harness.injector.calls == expandedSignature + [.delete(8), .type(":sig")])
        }

        @Test("Undo is offered once")
        func undoOnlyOnce() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":sig")
            harness.backspace()
            harness.backspace()
            #expect(harness.injector.calls == expandedSignature + [.delete(8), .type(":sig")])
        }

        @Test("Any other keystroke closes the offer", arguments: [KeyInput.character("x"), .reset])
        func otherKeyClosesOffer(input: KeyInput) {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":sig")
            harness.source.onKeyInput?(input, false)
            harness.backspace()
            #expect(harness.injector.calls == expandedSignature)
        }

        @Test("A backspace from another app does not undo, and closes the offer")
        func foreignBackspaceDoesNotUndo() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":sig")
            harness.backspace(fromAnotherApp: true)
            #expect(harness.injector.calls == expandedSignature)
            harness.backspace()
            #expect(harness.injector.calls == expandedSignature)
        }

        @Test("An expansion that moved the caret is not undoable")
        func cursorExpansionNotUndoable() {
            let harness = EngineHarness(snippets: [cursor])
            harness.type(":cur")
            harness.backspace()
            #expect(harness.injector.calls == [.delete(4), .paste("Hello world"), .arrowLeft(5)])
        }

        @Test("A menu expansion is not undoable")
        func menuExpansionNotUndoable() {
            let harness = EngineHarness(snippets: [signature])
            harness.expand(signature)
            harness.backspace()
            #expect(harness.injector.calls == [.delete(0), .paste("Best, Tom")])
        }

        @Test("Undo stays off when the setting is off")
        func undoDisabled() {
            let harness = EngineHarness(snippets: [signature],
                                        settings: .with { $0.undoOnBackspace = false })
            harness.type(":sig")
            harness.backspace()
            #expect(harness.injector.calls == expandedSignature)
        }

        @Test("A click drops an armed undo")
        func clickClearsUndo() {
            let harness = EngineHarness(snippets: [signature])
            harness.type(":sig")
            harness.click()
            harness.backspace()
            #expect(harness.injector.calls == expandedSignature)
        }

        @Test("A form expansion from a typed trigger is undoable")
        func formExpansionUndoable() async throws {
            let harness = EngineHarness(snippets: [greeting])
            var requests = harness.formRequests.makeAsyncIterator()
            harness.type(":hi")
            let request = try #require(await requests.next())
            harness.complete(request, answers: ["who.name": "Ada"])
            harness.backspace()
            #expect(harness.injector.calls == [.delete(3), .paste("Hi Ada"), .delete(5), .type(":hi")])
        }
    }
}
