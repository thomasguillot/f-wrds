# Changelog

All notable changes to F Wrds are documented in this file.

## 1.0.0 (2026-11-23)

First release: a native macOS menu bar text expander with a real app to manage
your snippets.

- Type-to-expand triggers in any app, recognized by a single Accessibility and
  Input Monitoring event tap. No daemon, no helper. Press Backspace straight
  after an expansion to get the trigger back.
- Snippet groups with app filters (only in these apps, never in these apps),
  reorderable in the sidebar, each snippet with one or more triggers or a regex.
- Variables edited as chips with a live preview: date, clipboard, choice, fixed
  text, shell, "Ask me" questions before expanding, and global variables defined
  once and reused anywhere.
- Regex triggers with named groups, word boundaries and case matching.
- Snippet search (⌥Space by default) to paste any snippet without typing its
  trigger, plus pinned and recent snippets in the menu bar.
- Pause expansion everywhere or just in the app in front.
- Two insertion methods, paste (default) or simulated typing, with exceptions
  per app for apps that won't take a paste.
- Espanso import and export. Import keeps any Espanso keys F Wrds doesn't use
  and writes them back on export. Export is a migration path, not a backup.
- Backup and restore of every group, snippet, global variable and setting in
  one file.
- In-place updates from GitHub Releases, with release notes in the app and the
  download verified against the published SHA-256.
- Guided setup for the two permissions, built-in Help, and an option to open
  the window at launch. Launch at login is optional.
- English and French.
- Free, MIT-Licensed, no account, no telemetry.
