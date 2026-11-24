import SwiftUI

/// The Help window's content, one case per topic. Strings are kept as separate localised keys so each
/// paragraph translates on its own.
extension HelpTopic {
    var title: LocalizedStringKey {
        switch self {
        case .gettingStarted: "Getting started"
        case .snippets: "Snippets and triggers"
        case .variables: "Variables"
        case .groups: "Groups and app filters"
        case .picker: "Snippet search and menu bar"
        case .injection: "Paste or typing"
        case .espanso: "Espanso, backup and restore"
        case .troubleshooting: "Troubleshooting"
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: "sparkles"
        case .snippets: "text.cursor"
        case .variables: "curlybraces"
        case .groups: "folder"
        case .picker: "magnifyingglass"
        case .injection: "doc.on.clipboard"
        case .espanso: "externaldrive"
        case .troubleshooting: "wrench.and.screwdriver"
        }
    }

    var blocks: [HelpBlock] {
        switch self {
        case .gettingStarted:
            [
            .heading("What F Wrds does"),
            .paragraph("F Wrds replaces short triggers with longer text as you type. Type a trigger in any app and it expands on the spot. For example, `;sig` can become your full email signature."),
            .paragraph("F Wrds lives in the menu bar. Open the window from there to add and edit snippets."),
            .heading("Two permissions"),
            .paragraph("macOS asks you to allow two things. Neither is used for anything else."),
            .bullets([
                "**Input Monitoring** lets F Wrds see what you type, so it can notice a trigger.",
                "**Accessibility** lets F Wrds type the full text into the app you are using."
            ]),
            .paragraph("If something is missing, choose **Help → Run Setup Again…** to grant them."),
            .heading("Don't run Espanso at the same time"),
            .paragraph("If Espanso is still running, both apps react to the same trigger and the text comes out garbled. F Wrds warns you when it spots Espanso and offers to quit it.")
            ]
        case .snippets:
            [
            .heading("Add a snippet"),
            .paragraph("Select a group in the sidebar, then click **Add Snippet**. Write what you want inserted in **Content**. A **Label** is optional; it gives the snippet a name in lists and in snippet search."),
            .heading("Triggers"),
            .paragraph("With **Text** selected under the trigger type, type a trigger such as `;sig` in **Add trigger** and click **Add**."),
            .paragraph("A snippet can have several triggers. Any of them expands it. Click the cross on a trigger to remove it."),
            .paragraph("A snippet with no trigger never expands. A trigger can be up to 64 characters long."),
            .heading("Regex triggers"),
            .paragraph("Choose **Regex** to match a pattern instead of fixed text. Names captured by the pattern can be used in the content."),
            .paragraph("For example, the pattern `:hi(?<name>\\w+)` expands on `:hiAnna`, and `{{name}}` in the content becomes `Anna`."),
            .paragraph("A snippet uses either Text triggers or a Regex, not both. Switch back to **Text** and your triggers are still there."),
            .heading("Options"),
            .bullets([
                "**Only expand after a space or punctuation**: the trigger only expands when it follows a space or a punctuation mark.",
                "**Match the case I type**: type the trigger with a capital letter and the expansion follows. Type it in capitals and the expansion is in capitals.",
                "**Capital letters**: how a capitalised trigger changes the text. Choose None, First letter, Each word or All capitals. Use it with **Match the case I type**.",
                "**Enabled**: turn a snippet off without deleting it."
            ]),
            .heading("Undo an expansion"),
            .paragraph("Press `⌫` as the very next key after an expansion and F Wrds puts back the trigger you typed. You can turn this off in **Settings → Expansion** with **Press ⌫ right after an expansion to undo it**.")
            ]
        case .variables:
            [
            .heading("Put changing text in a snippet"),
            .paragraph("A variable is a placeholder that is filled in each time the snippet expands. Click **Insert Variable** above the content and pick a type. The variable appears in the content as a chip. Click a chip to set it up."),
            .bullets([
                "**Date**: today's date, or a date before or after it, in the format you choose.",
                "**Clipboard**: whatever you have copied.",
                "**Choice**: one option picked at random from a list.",
                "**Fixed text**: text that stays the same, handy for reusing a phrase.",
                "**Shell**: runs a command and inserts what it prints.",
                "**Ask me**: asks you a question when the snippet expands, then inserts your answer.",
                "**Global…**: a global variable you defined once (see below)."
            ]),
            .heading("Raw tokens and preview"),
            .paragraph("In the content, a variable shows as a chip. Behind it is text like `{{date}}`. Turn on **Show raw tokens** to see that text instead."),
            .paragraph("**Preview** shows what the snippet will expand to. Shell commands do not run in the preview."),
            .paragraph("A variable that is no longer in the content waits under **Not used in the content**. You can put it back or remove it there."),
            .heading("Global variables"),
            .paragraph("Save a value once, like your name or an email signature, and use it in any snippet. Change it and every snippet that uses it updates."),
            .paragraph("Select **Global Variables** at the top of the sidebar and click **Add Variable**. Then use **Insert Variable → Global…** in a snippet. That item stays off until at least one global variable exists.")
            ]
        case .groups:
            [
            .heading("Groups"),
            .paragraph("Groups keep snippets together. Click **Add Group** in the sidebar to make one. Select a group and press Return, or use the right-click menu, to rename it."),
            .bullets([
                "The checkbox next to a group turns all of its snippets on or off.",
                "Drag groups in the sidebar, and snippets in the list, to put them in order.",
                "Press `⌘⌫` to delete the selected group or snippet. You are asked to confirm first."
            ]),
            .heading("Choose which apps a group works in"),
            .paragraph("By default a group's snippets expand in every app. The button at the bottom of the snippet list shows where the group works: **All Apps**, **Only in N apps** or **Not in N apps**. Click it to change that."),
            .bullets([
                "**Only in these apps**: the group expands in these apps and nowhere else.",
                "**Never in these apps**: the group expands everywhere except in these apps."
            ]),
            .paragraph("Use **Add App…** to pick an app. Leave both lists empty to expand everywhere.")
            ]
        case .picker:
            [
            .heading("Snippet search"),
            .paragraph("Press `⌥Space` anywhere to open snippet search. You can change this shortcut in **Settings → Expansion**, under **Search snippets**."),
            .paragraph("Type to search by trigger, label or content. Use `↑` and `↓` to move, `↩` to expand the selected snippet and `esc` to close. You can also click a snippet."),
            .paragraph("Snippet search only lists snippets that can expand in the app you are using."),
            .heading("The menu bar menu"),
            .bullets([
                "**Pinned** snippets sit at the top of the menu. To pin one, right-click it in the snippet list and choose **Pin to Menu Bar**. Choose **Unpin from Menu Bar** to remove it.",
                "**Recent** lists the snippets you expanded last.",
                "Choose a snippet in the menu to insert it."
            ]),
            .heading("Pause expansion"),
            .bullets([
                "Turn off **Expand snippets** to pause F Wrds everywhere.",
                "Turn on **Pause in** followed by the app name to pause only in the app you are using.",
                "You can also set a keyboard shortcut in **Settings → Expansion**, under **Pause expansion**."
            ])
            ]
        case .injection:
            [
            .heading("Two ways to insert text"),
            .bullets([
                "**Paste** is fast and exact. It is the default.",
                "**Typed** types the text key by key. Use it for apps that do not accept a paste, mostly terminals."
            ]),
            .paragraph("Choose the default in **Settings → Insertion**, under **Default method**."),
            .heading("Exceptions by app"),
            .paragraph("To use a different method in one app, click **Add App…** under **Exceptions by app**, pick the app, then choose **Paste** or **Typed** for it. Click the minus button to remove the exception.")
            ]
        case .espanso:
            [
            .heading("Bring your snippets from Espanso"),
            .paragraph("Go to **Settings → Backup and Espanso** and click **Import from Espanso…**. F Wrds shows a preview before anything is added. The File menu has the same item."),
            .heading("Export to Espanso"),
            .paragraph("**Export to Espanso…** writes your snippets as Espanso files, also available in the File menu. It is not a backup: app filters and on/off switches are left out. To export one group, right-click it in the sidebar and choose **Export…**."),
            .heading("Back up and restore"),
            .paragraph("**Export Backup…** saves every group, snippet, global variable and setting to one file. It is the only export that puts you back exactly where you left off."),
            .paragraph("**Restore Backup…** replaces everything currently in F Wrds with what is in the file. This cannot be undone.")
            ]
        case .troubleshooting:
            [
            .heading("Nothing expands"),
            .bullets([
                "Open the menu bar menu. A line at the top says what is wrong, such as **Expansion paused** or **Needs permission from macOS**.",
                "If permissions are missing, choose **Help → Run Setup Again…**. An update can reset them.",
                "Check that **Expand snippets** is on and that **Pause in** followed by the app name is off.",
                "Check that the group and the snippet are both enabled, and that the group's app filter includes the app you are in."
            ]),
            .heading("Text comes out garbled"),
            .paragraph("Espanso is probably still running. Click **Quit Espanso** at the top of the menu bar menu."),
            .heading("An app ignores the paste"),
            .paragraph("Switch that app to typing. Add it under **Exceptions by app** in **Settings → Insertion** and set it to **Typed**."),
            .heading("A shell variable shows ⚠︎"),
            .paragraph("The command failed or took longer than its **Timeout**. Try the command in Terminal, and raise the timeout if it is slow.")
            ]
        }
    }
}
