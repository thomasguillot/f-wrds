import AppKit
import CoreGraphics
import Foundation

/// Puts an expansion into whatever app the user is typing in, and takes back the trigger they typed.
///
/// ## Everything it posts is marked as its own
///
/// The app is watching every keystroke on the machine at the same time as it is synthesising some,
/// so the two have to be told apart or an expansion feeds itself: the injected characters would go
/// back into `TriggerMatcher`'s buffer, and a snippet whose replacement contains a trigger would
/// expand forever. The mark is `injectionSourceUserData`, and it is applied twice over — once on the
/// shared `CGEventSource`, which every event created from it inherits, and again on each event
/// directly. The second is belt and braces: the source field is what the system propagates, but it
/// costs one call to guarantee the field is set on the event `KeystrokeMonitor` will actually read,
/// and the cost of it ever being absent is an expansion loop in someone's document.
///
/// ## Threading
///
/// Safe to call from any thread — but **not from `KeystrokeMonitor`'s tap thread**, and that is a
/// correctness requirement rather than a preference. `paste(_:restoreClipboardAfter:)` blocks while
/// it copies the whole clipboard, which for an image or a promised item is unbounded work; doing
/// that inside a tap callback is the stall that makes the window server disable the tap. Injection
/// belongs off that thread, which is where Task 12 does it.
///
/// The clipboard dance — the one piece with state that outlives a call — is confined to a private
/// serial queue, which also hosts the delayed restore. Event posting itself is stateless, cheap, and
/// goes straight to the window server.
///
/// `NSPasteboard` is not thread-safe, and the queue is what makes its use here safe: every touch of
/// it happens on that one queue, including the restore that fires later. Anything else in this app
/// that wants the general pasteboard has to come through this type, or the guarantee is gone.
///
/// What is *not* safe is calling `paste(_:restoreClipboardAfter:)` for two expansions at once; see
/// the note there. In practice one keystroke produces one expansion, so this is a contract rather
/// than a lock.
///
/// ## Accessibility
///
/// Every method here needs Accessibility, and none of them can tell whether it has it: without the
/// grant, events are created and posted with no error and simply never arrive. `PermissionsChecker`
/// is where that is established, before any of this is called.
final class TextInjector: @unchecked Sendable {

    /// `"FWRD"` in ASCII. Stamped on every event this type creates so `KeystrokeMonitor` can tell the
    /// app's own typing from the user's, and drop it.
    static let injectionSourceUserData: Int64 = 0x46_57_52_44

    /// The two flags clipboard managers have agreed on for "do not keep this".
    ///
    /// `paste(_:restoreClipboardAfter:)` borrows the clipboard for a fraction of a second, but a
    /// clipboard manager watching for changes sees a copy like any other and files the expansion in
    /// the user's history — which is both noise and, for a snippet holding a password, an API token
    /// or an address, a copy of it somewhere the user did not put it. Neither flag is enforced by
    /// anything; they are a convention (nspasteboard.com) that the managers people actually use
    /// honour, and writing them costs two lines.
    ///
    /// Transient says "this is not a copy the user made". Concealed says "do not display or store
    /// this at all" — the stronger of the two, and the honest one for text this app has no way to
    /// classify: it cannot know which snippet is a signature and which is a licence key.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Virtual key codes, in the ANSI layout the window server speaks. These are positions on the
    /// keyboard, not characters: 9 is wherever `V` sits on a US keyboard and stays 9 on AZERTY, which
    /// is exactly what a ⌘V shortcut needs.
    private static let vKeyCode: CGKeyCode = 9
    private static let deleteKeyCode: CGKeyCode = 51
    private static let leftArrowKeyCode: CGKeyCode = 123

    /// The most UTF-16 units `CGEvent.keyboardSetUnicodeString` accepts on one event. Documented as
    /// 20; longer strings are truncated rather than refused, which is why `typeText` chunks.
    private static let maxUnicodeUnitsPerEvent = 20

    /// The source every injected event is created from, or `nil` if the window server would not give
    /// one out — in which case every method here does nothing, which is the same outcome as having no
    /// Accessibility grant and needs no separate handling.
    ///
    /// `.privateState` rather than `.combinedSessionState` matters: a combined-state source inherits
    /// the modifier keys the user is physically holding, so an expansion that landed while they still
    /// had ⌘ down would post ⌘-letters — menu shortcuts — instead of text.
    private let source: CGEventSource?

    /// Serialises the clipboard dance and hosts the delayed second half of it. Every stored property
    /// below is read and written only from this queue.
    private let clipboardQueue = DispatchQueue(label: "com.fwrds.text-injector.clipboard")

    /// What the user had on the clipboard before an expansion borrowed it, or `nil` when the app is
    /// not currently holding anything of theirs.
    private var savedClipboard: [NSPasteboardItem]?

    /// `NSPasteboard.changeCount` as it stood immediately after this app wrote to it. If it has moved
    /// by the time the restore runs, someone else has copied something since and the restore stands
    /// down rather than overwriting it.
    private var injectedChangeCount = 0

    /// Bumped on every `paste`, so that a restore scheduled by an earlier one recognises itself as
    /// stale and does nothing.
    private var restoreGeneration: UInt64 = 0

    init() {
        source = CGEventSource(stateID: .privateState)
        source?.userData = Self.injectionSourceUserData
        // The default is a quarter of a second during which *hardware* events are filtered after this
        // source posts. That is meant for remote-control software driving an unattended machine; here
        // it would eat the keystrokes the user makes in the moment after an expansion lands, which is
        // precisely when they carry on typing.
        source?.localEventsSuppressionInterval = 0
    }

    /// Sends `count` backspaces, to take back the trigger the user typed.
    ///
    /// Characters, not UTF-16 units: `TriggerMatch.typedText` is what was typed and the caller passes
    /// its `count`, so an emoji trigger costs one backspace, which is what the target app's own
    /// delete key would do.
    func deleteCharacters(_ count: Int) {
        for _ in 0..<max(count, 0) {
            press(Self.deleteKeyCode)
        }
    }

    /// Puts `text` on the clipboard, presses ⌘V, and gives the user's own clipboard back `delay`
    /// seconds later.
    ///
    /// Pasting rather than typing is what makes a long expansion land as one edit instead of a
    /// hundred keystrokes the target app has to redraw between. The clipboard is not the app's to
    /// spend, though, so the borrowing is careful in three ways:
    ///
    /// - **Every type is saved, not just the string.** A snapshot of each `NSPasteboardItem`'s data
    ///   for each of its types goes back afterwards, so an image, a file URL or a chunk of styled
    ///   text survives an expansion. Losing what someone copied is not an acceptable price for a
    ///   snippet. What cannot be preserved is a *promised* item — a lazy provider in another app that
    ///   has since quit — because there is nothing to copy at the moment the snapshot is taken.
    /// - **A copy made in the meantime wins.** If the change count has moved since this app wrote,
    ///   the user (or another app) has put something newer on the clipboard, and the restore is
    ///   abandoned rather than clobbering it.
    /// - **Clipboard managers are asked to skip it.** The write carries the transient and concealed
    ///   flags those apps watch for, so an expansion does not end up filed in someone's clipboard
    ///   history — see `transientType`/`concealedType` for what that is worth and why both.
    /// - **Overlapping expansions keep the first snapshot, unless the board moved.** A second `paste`
    ///   before the first has restored must not "save" the first expansion's text as if it were the
    ///   user's — but it must not miss a copy the user made in between either. The test for both is
    ///   the change count: if the clipboard still holds what this app last wrote, the existing
    ///   snapshot is the user's and is kept; if it has moved, somebody put something there since and
    ///   that is what gets saved.
    ///
    /// `delay` is the target app's grace period: it has to have read the clipboard before the paste
    /// is undone, and how long that takes is the app's business, not this one's. A caller with no
    /// opinion should pass a few hundred milliseconds rather than zero.
    ///
    /// **This call blocks for as long as copying the clipboard takes, and that is not bounded.** A
    /// copied image is typically several representations — TIFF, PNG, PDF — each of which is real
    /// bytes to duplicate, and a promised item costs synchronous IPC to whichever app is promising
    /// it. **It must therefore never be called on `KeystrokeMonitor`'s tap thread**, where a stall is
    /// precisely what makes the window server disable the tap. Task 12 hops off that thread before
    /// injecting anything, which is what makes this safe.
    ///
    /// The copy is not size-capped on purpose. Skipping large types would make the restore silently
    /// partial for exactly the payloads people would most mind losing — a big image is the worst
    /// thing to drop, not the easiest — so the cost is paid in full and kept off the tap thread by
    /// the contract above instead.
    func paste(_ text: String, restoreClipboardAfter delay: TimeInterval) {
        // Without a source there is no ⌘V to press, so cycling the user's clipboard would be pure
        // damage: it would be emptied and refilled to paste nothing at all.
        guard source != nil else { return }
        let generation = clipboardQueue.sync { borrowClipboard(for: text) }
        press(Self.vKeyCode, flags: .maskCommand)
        clipboardQueue.asyncAfter(deadline: .now() + max(delay, 0)) { [self] in
            returnClipboard(generation: generation)
        }
    }

    /// Types `text` as literal characters, for the cases where the clipboard must not be touched.
    ///
    /// Each event carries the text itself rather than a key to be interpreted, so the user's keyboard
    /// layout, dead keys and input method play no part: `é` arrives as `é` on a US layout. The
    /// virtual key code is nominal — an app that ignores the attached string and reads the code would
    /// see `a` — which is the known cost of this route and half of why `paste` is the default.
    ///
    /// Chunks never split a `Character`, so a surrogate pair or a flag emoji cannot be cut in half by
    /// the 20-unit limit. A single grapheme cluster longer than the limit — a pathological chain of
    /// zero-width joiners — is sent alone and truncated by the system, which is the one input this
    /// cannot render faithfully.
    func typeText(_ text: String) {
        guard let source else { return }
        for chunk in Self.chunks(of: text, maxUnits: Self.maxUnicodeUnitsPerEvent) {
            for isDown in [true, false] {
                guard
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                else { continue }
                var units = chunk
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                post(event, flags: [])
            }
        }
    }

    /// Presses the left arrow `times`, to put the caret where a `$|$` cursor hint asked for it.
    func pressArrowLeft(times: Int) {
        for _ in 0..<max(times, 0) {
            press(Self.leftArrowKeyCode)
        }
    }

    // MARK: Clipboard

    /// What the user has on the clipboard, as text, or `nil` when it holds nothing rendering can use.
    ///
    /// Here rather than in the renderer's caller because of the sentence at the top of this file: the
    /// general pasteboard is touched on `clipboardQueue` and nowhere else, and a `{{clipboard}}` read
    /// from another thread would race the restore an expansion has scheduled.
    ///
    /// It also answers the question honestly while an expansion is mid-flight. Between a `paste` and
    /// its restore the clipboard holds *this app's* text, and returning that would make a snippet
    /// that pastes the clipboard paste the previous expansion instead. When the board still holds
    /// what this app wrote, the snapshot taken from the user is what gets read.
    func clipboardText() -> String? {
        clipboardQueue.sync {
            let pasteboard = NSPasteboard.general
            guard let saved = savedClipboard, pasteboard.changeCount == injectedChangeCount else {
                return pasteboard.string(forType: .string)
            }
            return saved.compactMap { $0.string(forType: .string) }.first
        }
    }

    /// Saves the user's clipboard if what is on it is theirs, writes `text`, and returns the
    /// generation number the matching restore has to still be the newest one for.
    ///
    /// The condition is "not ours", not "nothing held". Holding a snapshot is not on its own a reason
    /// to skip taking a new one: between two expansions the user may have copied something, and the
    /// change count is the only thing that can tell that apart from the clipboard still holding the
    /// previous expansion's text.
    ///
    /// Getting this wrong destroys data, so the case it exists for is worth spelling out. Expansion A
    /// saves the user's clipboard and writes its text. The user copies an image. Expansion B runs
    /// before A's restore: if B skipped the snapshot merely because something was already held, the
    /// image would never be saved, A's restore would stand down as stale, and B's restore — whose
    /// change count *does* match, because B wrote last — would put the pre-image clipboard back over
    /// it. Comparing against the change count means B snapshots the image instead.
    ///
    /// Runs on `clipboardQueue`.
    private func borrowClipboard(for text: String) -> UInt64 {
        let pasteboard = NSPasteboard.general
        if savedClipboard == nil || pasteboard.changeCount != injectedChangeCount {
            savedClipboard = Self.snapshot(of: pasteboard)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Written after the string, and with an empty value: what these two say is carried by their
        // presence on the item, not by anything in them. See the note at each.
        pasteboard.setString("", forType: Self.transientType)
        pasteboard.setString("", forType: Self.concealedType)
        injectedChangeCount = pasteboard.changeCount
        restoreGeneration &+= 1
        return restoreGeneration
    }

    /// Puts the user's clipboard back, unless a newer `paste` or a newer copy has claimed it.
    ///
    /// Runs on `clipboardQueue`.
    private func returnClipboard(generation: UInt64) {
        guard generation == restoreGeneration, let saved = savedClipboard else { return }
        // Released either way: if the clipboard has moved on, this app has stopped holding anything
        // of the user's and the next expansion should snapshot afresh.
        savedClipboard = nil

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == injectedChangeCount else { return }
        pasteboard.clearContents()
        // An empty snapshot means the clipboard was empty to begin with, and `clearContents` alone is
        // the faithful restore. `writeObjects` with nothing to write would be a no-op anyway; the
        // guard is here so the intent reads.
        if !saved.isEmpty {
            _ = pasteboard.writeObjects(saved)
        }
    }

    /// A detached copy of everything on `pasteboard`, every item and every type.
    ///
    /// The items handed out by `pasteboardItems` belong to the pasteboard and stop being readable the
    /// moment it is cleared, so each one's data is copied into a fresh `NSPasteboardItem` here rather
    /// than referenced. Items that yield no data at all are dropped — they are promises whose provider
    /// is gone, and an item with no types cannot be written back.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                copy.setData(data, forType: type)
            }
            return copy.types.isEmpty ? nil : copy
        }
    }

    // MARK: Events

    /// Splits `text` into runs of at most `maxUnits` UTF-16 units, never cutting inside a `Character`.
    private static func chunks(of text: String, maxUnits: Int) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxUnits {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// Posts one keyDown/keyUp pair for a virtual key code.
    private func press(_ virtualKey: CGKeyCode, flags: CGEventFlags = []) {
        guard let source else { return }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: isDown)
            else { continue }
            post(event, flags: flags)
        }
    }

    /// Stamps `event` as this app's, sets exactly the modifiers asked for, and sends it.
    ///
    /// The flags are assigned rather than left alone even when empty. A private-state source starts
    /// with none, but this is the line that guarantees a backspace stays a backspace instead of
    /// picking up a modifier from anywhere, and it is one assignment.
    ///
    /// `.cghidEventTap` posts at the lowest point in the stack, so the event reaches every session
    /// tap — including this app's own, which is why the mark above it matters.
    private func post(_ event: CGEvent, flags: CGEventFlags) {
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.injectionSourceUserData)
        event.post(tap: .cghidEventTap)
    }
}
