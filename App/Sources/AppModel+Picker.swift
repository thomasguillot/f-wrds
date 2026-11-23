import Foundation
import WrdsKit

/// The search palette and the two global hotkeys. Split out of `AppModel.swift` for the same reason
/// as `AppModel+Library.swift` — that class body was over SwiftLint's line ceiling with this inlined
/// — and reaching `engine`/`hotKeyCenter`/`pickerPanel` from here is why those three lost their
/// `private` back in `AppModel.swift`; see the note at each.
extension AppModel {
    /// Re-applies `settings.pickerHotKey`/`pauseHotKey` to the window server — a hotkey with no spec
    /// is unregistered rather than left claiming its old combination. Call after every change that
    /// could touch either. `update(_:)` calls it on every save rather than only when a hotkey field
    /// actually changed: registering the same spec again is a cheap, side-effect-free no-op for
    /// Carbon, and that is simpler than tracking which field moved.
    ///
    /// Does nothing before `activate()`: `HotKeyCenter` needs `NSApplication`'s run loop already
    /// pumping to receive Carbon's hotkey-pressed events, which is not guaranteed yet while `AppModel`
    /// is still being constructed. `activate()` calls this once, after `isActivated` flips, which is
    /// what makes every later call here take effect instead of being silently skipped.
    func reregisterHotKeys() {
        guard isActivated else { return }
        var pickerFailed = false
        var pauseFailed = false

        if let spec = settings.pickerHotKey {
            let registered = hotKeyCenter.register(spec, id: Self.pickerHotKeyID) { [weak self] in
                self?.openPicker()
            }
            if !registered { pickerFailed = true }
        } else {
            hotKeyCenter.unregister(id: Self.pickerHotKeyID)
        }

        if let spec = settings.pauseHotKey {
            let registered = hotKeyCenter.register(spec, id: Self.pauseHotKeyID) { [weak self] in
                self?.toggleEngineEnabled()
            }
            if !registered { pauseFailed = true }
        } else {
            hotKeyCenter.unregister(id: Self.pauseHotKeyID)
        }

        hotKeyFailure = Self.hotKeyFailureMessage(pickerFailed: pickerFailed, pauseFailed: pauseFailed)
    }

    /// One sentence naming whichever of the two shortcuts the window server refused, or `nil` when
    /// neither did. Spelled out per combination, rather than joining a list with "or", so the message
    /// reads as a real sentence in every language rather than an English list-joining rule applied to
    /// translated fragments.
    private static func hotKeyFailureMessage(pickerFailed: Bool, pauseFailed: Bool) -> String? {
        switch (pickerFailed, pauseFailed) {
        case (true, true):
            return String(localized: """
                The shortcuts for search and pause are probably used by another app. Choose \
                different ones.
                """)
        case (true, false):
            return String(localized: """
                The shortcut for search is probably used by another app. Choose a different one.
                """)
        case (false, true):
            return String(localized: """
                The shortcut for pause is probably used by another app. Choose a different one.
                """)
        case (false, false):
            return nil
        }
    }

    /// Toggles the engine on or off, exactly as the menu's "Expand snippets" switch does. What
    /// `pauseHotKey` fires.
    func toggleEngineEnabled() {
        var updated = settings
        updated.engineEnabled.toggle()
        update(updated)
    }

    /// Shows the search palette over whatever app is frontmost, offering every snippet reachable
    /// there. What the picker hotkey calls — see `openPickerFromMenu()` for the menu's "Open Picker"
    /// item, which is *not* the same call: the two differ in exactly one thing, and it matters.
    ///
    /// `frontmostAppBundleID` is read here, before `PickerPanel.show` does anything — which is both
    /// "capture the frontmost app before showing the panel" and simpler than it sounds, because that
    /// property already *is* the answer: `frontmostAppChanged(bundleID:name:)` never updates it to F
    /// Wrds' own bundle ID, so it already reads as whatever app the user was in a moment ago whether
    /// this was triggered by a global hotkey (which never activates F Wrds) or by clicking the menu
    /// item (which briefly can). The same value is threaded through to
    /// `ExpansionEngine.expand(_:inApp:)` so the eventual injection cannot land somewhere else if the
    /// frontmost app changes again while the palette is open.
    func openPicker() {
        showPicker(openedFromMenu: false)
    }

    /// What the menu's "Open Picker" item calls instead of `openPicker()`.
    ///
    /// Clicking any `MenuBarExtra` menu item transiently activates F Wrds — the same way clicking a
    /// snippet in the menu does, which is exactly the race `expandFromMenu(_:)` already waits 200 ms
    /// for. `openPicker()`'s hotkey path has no such moment (`.nonactivatingPanel` never activates
    /// this app at all), so it can get away with a much shorter wait; this path cannot, and
    /// `PickerPanel.show(groups:canExpand:openedFromMenu:onExpand:)` uses `openedFromMenu` to pick the
    /// right one rather than this app guessing at a single number that would have to be safe for both.
    func openPickerFromMenu() {
        showPicker(openedFromMenu: true)
    }

    private func showPicker(openedFromMenu: Bool) {
        let bundleID = frontmostAppBundleID
        let groups = pickerGroups(forApp: bundleID)
        let engine = self.engine
        pickerPanel.show(
            groups: groups, canExpand: canExpandFromMenu, openedFromMenu: openedFromMenu
        ) { snippet in
            engine.expand(snippet, inApp: bundleID)
        }
    }
}
