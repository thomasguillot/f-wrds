<img src="site/public/favicon.png" alt="" width="96" height="96">

# F Wrds

*#@!% typing the same $#!% twice.*

A native macOS menu-bar text expander with Espanso-style triggers and a real app
to manage your snippets.

**→ [Download page](https://fwrds.space.fast/)**: always points at the latest
release.

**Requires macOS 26 (Tahoe) or later, Apple Silicon. Not notarized: no Apple Developer Program needed.**

---

## For users

### What it does

- **Type-to-expand anywhere**: a trigger like `;fwrds` typed in any app expands into configured text, dates, clipboard contents or shell output. A single Accessibility + Input Monitoring event tap does the recognizing and the typing; there's no daemon or helper.
- **Snippet groups** — organise snippets into named groups, each with optional app filters (only in / never in), reorderable in the sidebar.
- **Variables**: date, clipboard, choice, fixed text, shell, ask-me questions, and references to global variables, edited as inline chips with config popovers and a live preview pane showing exactly what will be typed.
- **Regex triggers** — match a pattern instead of a fixed string, with capture groups available to the expansion.
- **Word boundaries & case matching**: expand only after a space or punctuation, and match the capitalization you typed (`Hello` → `Hello world`, not `hello world`).
- **Undo** — press ⌫ right after an expansion to put the trigger text back.
- **Snippet search (⌥Space)**: a floating palette to search and paste any snippet without typing its trigger, opened from a global hotkey or the menu bar.
- **Ask me**: a compact native panel collects text, multiline and choice answers before the snippet expands.
- **Menu bar** — pinned and recent snippets one click away, plus a way to pause expansion globally (optionally with its own hotkey) or just for the frontmost app.
- **Two insertion methods**: expansions arrive as a paste by default (fast, exact) or typed key by key for apps that resist ⌘V, switchable per app under Settings → Insertion.
- **Launch at login** — an optional toggle in Settings starts F Wrds automatically at startup.
- **Espanso import / export**: bring in Espanso match files (a folder or individual `.yml` files); import keeps any Espanso key the native model doesn't recognise and re-exports it verbatim. Export on its own is a migration path, not a backup, though: it can't carry app filters, enabled/disabled state or shell-variable timeouts, since Espanso's format has no field for them. Use Export Backup for a file that restores everything.
- **Backup and restore**: one JSON file that captures every group, snippet, global variable and setting.
- **Updates** — checks GitHub Releases and installs in place, no drag-and-drop.
- **Localised** — English (UK) source with US spelling variants, and French; switchable in Settings independently of the system language.

### Install

The app isn't signed with an Apple Developer ID or notarized (it deliberately uses no Apple Developer Program), so macOS blocks it on first launch. To allow it:

1. Double-click **F Wrds**; when macOS warns it "can't verify the developer," click **Done** (*not* "Move to Trash").
2. Open **System Settings → Privacy & Security** and scroll to the **Security** section.
3. Click **Open Anyway** next to *"F Wrds" was blocked to protect your Mac*, then authenticate and click **Open**.

macOS only asks once — after that it launches normally.

If you don't have a prebuilt app, build it from source — see [For developers](#for-developers).

### Permissions

F Wrds can't do anything until it has two grants:

- **Accessibility** — lets it type the expansion into whatever app you're working in.
- **Input Monitoring** — lets it recognise a trigger by watching what you type.

Neither is used for anything else. First launch walks you through both with an onboarding flow that shows live status for each and ends with a text field to try a starter snippet before you do anything else.

macOS ties each grant to the app's code signature. Release builds are signed with the same self-signed certificate every time, so both grants carry over when F Wrds updates itself. A build with a different signature (one you build from source without that certificate, for example) is a different app to macOS, and the grants don't carry over. F Wrds notices this and reopens onboarding at the grants step so you can confirm both again. Your snippets and settings are untouched either way.

### Using it

1. Launch the app. It lives in the **menu bar**, and shows in the Dock while one of its windows is open (or always, if you turn that on in Settings). Settings also has a **Launch at login** toggle, for starting it automatically.
2. Open **F Wrds…** from the menu bar to reach the manager window: create a group, then a snippet inside it, and give it a trigger.
3. Type that trigger in any app to see it expand. Add variables from the **Insert Variable** menu in the content editor. They show as chips you configure in a popover, with a live preview below showing the result.
4. Prefer a pattern over a fixed trigger? Switch the snippet to **regex** mode; capture groups are available in the content the same way variables are.
5. Press **⌥Space** (configurable in Settings) to open snippet search. Type to filter, ⏎ to paste the selection into the frontmost app, without ever typing the trigger.
6. An **Ask me** variable pops a small panel with its questions before the snippet expands. Fill them in, ⏎ or ⌘⏎ submits, ⎋ cancels and leaves the trigger text in place.
7. **Settings → Backup and Espanso** brings in Espanso files or writes your groups back out as Espanso YAML (also in the File menu). A single group can be exported from its right-click menu in the sidebar.
8. **Settings → Backup and Espanso** also exports and restores one file with everything (groups, snippets, global variables and settings) for moving to another Mac or just keeping a copy.

Your data lives in `~/Library/Application Support/FWrds/`.

---

## For developers

### Requirements

- macOS 26 (Tahoe)+, Xcode 26+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`) — optional. The build phase runs it when it's installed and prints a note when it isn't, so a build never fails for want of it; run `swiftlint` from the repo root to be sure it has actually run.

### Build

```sh
# Logic package (no Xcode needed)
cd WrdsKit && swift test

# App — generate the project, then open or build
cd App && xcodegen && open FWrds.xcodeproj
```

Headless build:

```sh
cd App && xcodegen && xcodebuild \
  -project FWrds.xcodeproj \
  -scheme FWrds \
  -destination 'platform=macOS' \
  build
```

> `App/FWrds.xcodeproj` is generated by xcodegen and git-ignored — edit `App/project.yml`, not the project file. Run SwiftLint from the repo **root**.

### Packaging a release

```sh
./scripts/make-dmg.sh
```

Builds the Release configuration and produces `dist/FWrds-<version>.dmg`, a drag-to-Applications disk image. The version comes from `MARKETING_VERSION` in `App/project.yml`. Requires `create-dmg` (`brew install create-dmg`).

### Architecture

```
f-wrds/
├── WrdsKit/          # Pure Swift package — all logic, zero UI, zero AppKit
│   └── Sources/WrdsKit/
│       ├── Snippet, SnippetGroup, GlobalVariable, AppSettings   # model (Codable)
│       ├── SnippetStore, SettingsStore                      # JSON persistence, fail-closed
│       ├── TriggerMatcher                                   # rolling buffer + reversed prefix trie
│       ├── ExpansionRenderer                                # variables, forms, cursor/case logic
│       ├── ShellRunner, StrftimeFormatter                   # shell variables (deadline + process
│       │                                                    #   sweep), date formats
│       ├── EspansoImporter, EspansoExporter                 # YAML ↔ native model (Yams)
│       ├── ConfigBundle                                     # whole-config JSON backup/restore
│       ├── UpdateAvailability, ReleaseNotes,                # what an update is, and what it has to
│       │   UpdateIntegrity                                  #   prove before it is installed
│       └── …validation, protocols for clock/clipboard/shell injection
└── App/              # SwiftUI macOS app — thin UI layer over WrdsKit
    └── Sources/
        ├── FWrdsApp          # @main, MenuBarExtra, manager Window, Settings scenes
        ├── AppModel          # @Observable coordinator; owns stores + engine
        ├── ExpansionEngine   # monitor → matcher → renderer → injector, on one serial queue
        ├── KeystrokeMonitor  # CGEventTap wrapper (app-side: owns the TCC grants)
        ├── TextInjector      # backspace + pasteboard-paste / typed injection
        ├── UpdateController  # + ReleaseFetcher/UpdateDownloader/UpdateInstaller: checks GitHub
        │                     #   Releases, verifies, swaps /Applications/F Wrds.app, relaunches
        ├── OnboardingView    # the two grants with live status, then a playground to try a snippet
        └── …views (manager, picker, form panel, settings)
```

Single process, menu-bar agent — no daemon, no helper: the event tap lives in the app process so Accessibility and Input Monitoring bind to one binary, the only workable story for an unsigned app.

Everything testable lives in `WrdsKit` with no AppKit import: the matcher consumes synthetic keystroke sequences, and the renderer takes injected clock/clipboard/shell fakes. Only `KeystrokeMonitor` and `TextInjector` touch the OS, and they stay dumb.

## Website

The marketing site lives in `site/` and is built with Astro. It needs Node 22.23.4 or later.

```sh
cd site && npm install && npm run dev
npm run build
```

## License

MIT
