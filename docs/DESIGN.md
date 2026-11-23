# F Wrds — Design

*2026-08-12*

A free, open-source (MIT), native macOS text expander with a real management UI. Espanso's power, none of its buried-config friction. macOS 26 (Tahoe)+, SwiftUI, unsigned (no Apple Developer Program).

The name: strips the last vowel like the rest of the app family, and plays on "F words": *#@!% typing the same $#!% twice*. No actual swear words anywhere, in the app or on the site; cartoon swear symbols (`#@!%`) carry the joke.

## Goals

- Type-to-expand anywhere (Espanso-style), plus a hotkey-summoned search picker.
- Espanso feature parity for text expansion in v1: date/clipboard/choice/echo/shell variables, global variables, forms, regex triggers, word boundaries, case propagation, per-app filtering. (Rich-text output is the one deliberate exception — see Non-goals.)
- Native JSON store; Espanso YAML is an **import/export border**, not the live schema. Import is lossless (unmapped keys preserved verbatim and re-exported).
- A management UI good enough to be the reason the app exists.
- en-GB development language; en-US and fr translations via String Catalogs.

## Non-goals

- Rich-text/HTML/image expansions (imported configs keep them as unmapped data; not rendered in v1).
- Sync services, accounts, telemetry. Config sharing is file export.
- Code signing, notarisation, App Store.

## Architecture

```
f-wrds/
├── WrdsKit/          # Pure Swift package — all logic, zero UI, zero AppKit
│   └── Sources/WrdsKit/
│       ├── Snippet, Group, GlobalVariable, Settings   # model (Codable)
│       ├── SnippetStore, SettingsStore                # JSON persistence, fail-closed
│       ├── TriggerMatcher                             # rolling buffer + reversed prefix trie
│       ├── ExpansionRenderer                          # variables, forms model, cursor/case logic
│       ├── EspansoImporter, EspansoExporter           # YAML ↔ native model (Yams)
│       ├── ConfigBundle                               # whole-config JSON backup/restore
│       └── …validation, protocols for clock/clipboard/shell injection
└── App/              # SwiftUI macOS app — thin UI layer over WrdsKit
    └── Sources/
        ├── FWrdsApp          # @main, MenuBarExtra, manager Window, Settings scenes
        ├── AppModel          # @Observable coordinator; owns stores + engine
        ├── KeystrokeMonitor  # CGEventTap wrapper (app-side: owns the TCC grants)
        ├── TextInjector      # backspace + pasteboard-paste / typed injection
        └── …views (manager, picker, form panel, onboarding, settings)
```

Single process, menu-bar agent (`LSUIElement`), optional Dock icon via setting. No daemon, no helper: the event tap lives in the app process so Accessibility + Input Monitoring bind to one binary — the only workable unsigned story.

Split rule (same as HostsKit): everything testable is in WrdsKit with no AppKit import. The matcher consumes synthetic keystroke sequences; the renderer takes injected `Clock`, `ClipboardReading`, and `ShellRunning` protocol fakes. Only `KeystrokeMonitor` and `TextInjector` touch the OS, and they stay dumb.

## Expansion engine

**Detection.** `CGEventTap` on `keyDown`. Characters append to a rolling buffer (last 64 chars) in `TriggerMatcher`, which holds all triggers in a reversed prefix trie — each keystroke is a suffix lookup, no per-snippet scan. Buffer resets on modifiers-with-keys, arrows, return, escape, and mouse clicks (caret moved; context gone). Per-snippet options honoured: `wordBoundary` (fire only after a word delimiter), `propagateCase` (Hello → expansion capitalised), `uppercaseStyle` (uppercase first word / all).

**Regex triggers** match against the same bounded buffer, capture groups exposed to the template as variables. Evaluated only on buffer change; the 64-char bound caps pathological patterns.

**Injection.** On match:

1. Synthesise N backspaces to delete the trigger text on screen.
2. Render the expansion via `ExpansionRenderer`.
3. Save pasteboard contents, set rendered text, synthesise ⌘V, restore pasteboard after a short delay.

Paste injection is the default (works in Electron, browsers, native fields). Per-app override to **typed injection** (synthetic keystrokes) for apps that fight ⌘V (terminals). The tap re-enables itself on `kCGEventTapDisabledByTimeout` / `…ByUserInput` and surfaces a menu-bar warning if it cannot.

**Safety valves:**

- Secure Input (`IsSecureEventInputEnabled()`) ⇒ no expansion, ever.
- Global pause toggle (menu bar + optional hotkey) and per-app pause.
- Injected events tagged with a magic `CGEventSourceUserData` value; the tap ignores its own output.

**Undo:** ⌫ immediately after an expansion reverts to the raw trigger text.

**Rendering.** Variable types: `date` (format string + offset), `clipboard`, `choice` (random pick from list), `echo`, `shell` (`/bin/zsh -c`, hard timeout, failure renders a visible ⚠︎ token), `form`, and references to global variables. Variables resolve in dependency order; cycles detected and refused. `$|$` sets final cursor position via arrow-key synthesis after paste. Form snippets pop a native panel (see UI) before injection.

## Data model

All Codable, JSON on disk:

- **Snippet** — `id`, `triggers: [String]` *or* `regexTrigger`, `content`, `label`, `wordBoundary`, `propagateCase`, `uppercaseStyle`, `variables: [Variable]`, `isEnabled`, `unmapped: [String: String]` — unrecognised Espanso keys kept as raw YAML fragments for lossless round-trip.
- **Variable** — typed enum: `date`, `clipboard`, `choice`, `echo`, `shell`, `form`, `global(ref)`. This enum is the parity backbone: import, export, rendering, and editor UI all switch over it.
- **Group** — named, ordered snippet collection (sidebar unit). Optional app filters: only-in / never-in bundle-ID lists.
- **GlobalVariable** — shared across snippets.
- **Settings** — engine toggles, per-app injection overrides, picker hotkey, pause hotkey, Dock icon, launch at login, language, update prefs.

**Persistence.** `~/Library/Application Support/FWrds/store.json` + `settings.json`. Atomic writes; corrupt files copied to `.corrupt` before any overwrite; `version` field for migrations.

## Espanso border

**Import.** From a folder (defaults to Espanso's config dir when present) or individual `.yml` files. Match file → Group; matches → Snippets; `global_vars` → GlobalVariables. Unknown keys/extensions (e.g. `image_path`, `html`, `markdown`) are preserved verbatim in `unmapped` and listed in a post-import report. Parse-everything-then-commit: import never partially applies, and never overwrites existing groups without asking.

**Export.** Any group or the whole set → valid Espanso YAML, `unmapped` data re-emitted.

**Backup.** Whole-config JSON bundle export/import (ConfigBundle).

## UI

**Menu bar** (`MenuBarExtra`): engine on/off, pinned/recent snippets (click to paste), pause-for-this-app, Open F Wrds, status line when attention is needed (grants lost, engine paused). Menu bar icon is a template rendering of the glyph.

**Manager window** — three panes:

- *Sidebar:* groups; drag-to-reorder; right-click rename/delete/export; new-group button.
- *List:* the group's snippets — trigger, label, enabled toggle; search filters by trigger/label/content.
- *Editor:* trigger field(s) with live conflict detection (shadow/duplicate warnings); multi-line content editor with an **Insert Variable** menu — variables render as inline chips with config popovers, plus a raw-text mode showing `{{syntax}}`; options (word boundary, case, app filters via a native app browser); live preview pane (dates resolved; shell shows a "runs on expand" placeholder — never executed while editing).

**Picker:** global hotkey (default ⌥Space, configurable) opens a floating search palette; ⏎ pastes the selection into the frontmost app. Also in the menu bar.

**Form panel:** compact native panel for form snippets — text, multiline, and choice fields; ⏎ submits, ⎋ cancels (trigger text left in place).

**Onboarding:** first-run flow for Accessibility + Input Monitoring with live-polling status indicators and one-sentence explanations; reruns automatically when an update invalidates grants; includes a playground text field to try a starter snippet immediately.

**Settings:** engine (pause hotkey, backspace-undo), injection (default mode, per-app overrides), appearance (Dock icon, menu-bar options), language (system / en-GB / en-US / fr), updates, launch at login.

**Localisation:** String Catalog; en-GB development language; en-US and fr translations shipped in v1.

## Branding

- Off-white monoline speech bubble holding "#!" (`App/Icon/bubble-glyph.svg`, 24×24 grid, 1.5 stroke, round caps) on an orange→red gradient (`#E35A1E` → `#D63A26`), generated by `scripts/make-icon.swift`. Both stops must clear WCAG 3:1 and APCA Lc 60 against the glyph; the script fails if they do not. The same glyph is the menu bar template. Same visual family as Hosts Switchr, Petit Café and Video Extractr.
- In-app accent: the same red/orange, used sparingly.
- Tagline "#@!% typing the same $#!% twice." appears in the About box. No actual swear words anywhere in the product or its site; grawlix symbols only.

## Error handling

Fail-closed throughout: `.corrupt` preservation; tap self-heal + surfaced warning; shell timeouts render ⚠︎ instead of hanging; failed injection restores the clipboard and leaves the trigger text untouched; atomic import; Secure Input always wins.

## Testing

WrdsKit is fully testable headless (`swift test`): matcher (synthetic keystroke streams — resets, boundaries, case, regex captures), renderer (fake clock/clipboard/shell; cycle detection), importer/exporter round-trips against real Espanso fixture files (including exotica-laden ones), store corruption + migration. App layer: manual smoke + onboarding playground.

## Distribution

- Public repo `thomasguillot/f-wrds`, MIT.
- Unsigned; install dance documented like Hosts Switchr's README.
- xcodegen (`App/project.yml`), SwiftLint in build phase, `scripts/make-dmg.sh`, in-place GitHub Releases updater.
- Post-update grant check: if macOS dropped Accessibility/Input Monitoring for the new binary, onboarding's permission step reruns.
- GitHub Pages site (later phase).
