import AppKit
import SwiftUI
import WrdsKit

/// First run's "get the two grants and see it work" walk — and, unchanged, the exact same flow rerun
/// after an update that has invalidated those grants. An ad-hoc-signed build is not exempt from that:
/// TCC records a grant against the app's code signature and path, so a re-signed update is, to
/// macOS, a different app, and the old grant does not follow it (see `PermissionsChecker`'s own doc
/// comment). `AppModel.onboardingShouldStartAtGrantsStep` is what tells the two situations apart and
/// tells this view which one it is.
///
/// Three steps: a paragraph explaining why F Wrds asks for anything at all, the two grants themselves
/// with indicators `PermissionsMonitor` keeps live, and a working text field to prove the promise was
/// kept before this ever gets out of the user's way.
struct OnboardingView: View {
    private enum Step {
        case welcome, grants, playground
    }

    /// How long the grants step waits, once both indicators go green, before moving on — long enough
    /// that the user actually sees both turn green rather than the step vanishing under their cursor
    /// the instant the second one does.
    private static let autoAdvanceDelay: Duration = .milliseconds(600)

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var monitor = PermissionsMonitor()
    @State private var step: Step
    @State private var playgroundText = ""
    /// The in-flight `scheduleAutoAdvance()` wait, if any — cancelled on disappear so a window closed
    /// mid-wait cannot still flip `step` on storage nothing is showing any more.
    @State private var autoAdvanceTask: Task<Void, Never>?

    /// True when this run exists to recover grants that went missing after an update, rather than to
    /// onboard someone new. Fixed at construction — see `init(startAtGrantsStep:)` — and used only for
    /// the grants step's extra line of copy; `step` itself still moves on normally from there.
    private let isRecoveringLostGrants: Bool

    /// - Parameter startAtGrantsStep: `AppModel.onboardingShouldStartAtGrantsStep`, read by
    ///   `FWrdsApp` at the moment it decides whether to show this window at all. Skips the welcome
    ///   paragraph — the user has seen it before — and opens straight on the two grants that need
    ///   confirming again.
    init(startAtGrantsStep: Bool) {
        _step = State(initialValue: startAtGrantsStep ? .grants : .welcome)
        isRecoveringLostGrants = startAtGrantsStep
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepContent
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { monitor.start() }
        .onDisappear {
            monitor.stop()
            autoAdvanceTask?.cancel()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .grants: grantsStep
        case .playground: playgroundStep
        }
    }

    // MARK: Step 1 — welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Same source AboutView uses — the running app's own icon, not a bundled duplicate that
            // could drift from it.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Welcome to F Wrds")
                .font(.title2.bold())
            Text("""
                Type a short trigger such as ;fwrds in any app and F Wrds swaps in the full text. To \
                do that it needs two permissions from macOS. Neither is used for anything else.
                """)
            .fixedSize(horizontal: false, vertical: true)
            continueRow(title: "Continue", showsSkip: true) { step = .grants }
        }
    }

    // MARK: Step 2 — grants

    private var grantsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Turn on two permissions")
                .font(.title2.bold())
            if isRecoveringLostGrants {
                Text("""
                    The update reset these permissions. macOS ties them to the exact build of an \
                    app. Turn both on again and expansion carries on.
                    """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            grantRow(
                title: "Accessibility",
                reason: "Lets F Wrds type the full text into the app you're using.",
                granted: monitor.hasAccessibility,
                actionTitle: "Allow\u{2026}",
                action: PermissionsChecker.requestAccessibility
            )
            grantRow(
                title: "Input Monitoring",
                reason: "Lets F Wrds notice when you type a trigger.",
                granted: monitor.hasInputMonitoring,
                actionTitle: "Open System Settings\u{2026}",
                action: PermissionsChecker.openInputMonitoringSettings
            )
            // No paired primary action here — this step advances itself once both grants land, via
            // `scheduleAutoAdvance()` below. Its own row, on its own line, keeps it well clear of the
            // two "Allow…"/"Open System Settings…" buttons above.
            skipSetupRow
        }
        // `initial: true`: without it, a grants step that opens with both already true — granted to
        // an earlier build under the same signature and path, say — would never see a *change* to
        // react to, and this step has no manual "Continue" of its own to fall back on.
        .onChange(of: bothGranted, initial: true) { _, granted in
            guard granted else { return }
            scheduleAutoAdvance()
        }
    }

    private var bothGranted: Bool {
        monitor.hasAccessibility && monitor.hasInputMonitoring
    }

    /// Waits `autoAdvanceDelay`, then moves to the playground — but only if both grants are still in
    /// place and the user has not already left this step by the time the wait is over. A grant that
    /// flickers (System Settings toggled off again) or a step change from elsewhere must not carry an
    /// advance through that no longer applies.
    private func scheduleAutoAdvance() {
        autoAdvanceTask?.cancel()
        autoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.autoAdvanceDelay)
            guard !Task.isCancelled, step == .grants, bothGranted else { return }
            // The engine could not start until both grants existed — see
            // `AppModel.refreshEngineState()` — so this is the moment it actually can, and the
            // playground needs it running to have anything to demonstrate.
            model.recheckEngine()
            step = .playground
        }
    }

    private func grantRow(
        title: LocalizedStringKey, reason: LocalizedStringKey, granted: Bool,
        actionTitle: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
                .disabled(granted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(granted ? "Allowed" : "Not allowed"))
    }

    // MARK: Step 3 — playground

    private var playgroundStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try It")
                .font(.title2.bold())
            Text(playgroundInstruction)
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $playgroundText, prompt: Text("Type here\u{2026}"))
                .textFieldStyle(.plain)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            Text("F Wrds lives in the menu bar. Open its window from the icon to add and edit snippets.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            continueRow(title: "Done", action: finish)
        }
    }

    /// Whether the seeded `;fwrds` example is still there to expand: it can be deleted, and the
    /// playground's instruction has to say something sensible if it has been, rather than telling the
    /// user to type a trigger that no longer does anything.
    private var hasFwrdsSnippet: Bool {
        model.groups.contains { group in
            group.isEnabled
                && group.snippets.contains { $0.isEnabled && $0.triggers.contains(";fwrds") }
        }
    }

    private var playgroundInstruction: String {
        hasFwrdsSnippet
            ? String(localized: "Type ;fwrds below and watch it expand.")
            : String(localized: "Add a snippet in the F Wrds window, then type its trigger here.")
    }

    private func finish() {
        UserDefaults.standard.hasCompletedOnboarding = true
        dismissWindow(id: "onboarding")
        openWindow(id: "manager")
    }

    /// Closes the window without finishing onboarding, so it presents again next launch —
    /// `FWrdsApp`'s `.defaultLaunchBehavior` reads `hasCompletedOnboarding` fresh each time, and this
    /// deliberately leaves it untouched. The recovery path for anyone who changes their mind is the
    /// menu bar's "Open Setup…", which `MenuBarView` shows for as long as a permission is missing,
    /// independent of this flag.
    private func skipSetup() {
        dismissWindow(id: "onboarding")
        openWindow(id: "manager")
    }

    // MARK: Shared

    /// A quiet, un-prominent "Set Up Later" at the leading edge — the same secondary-button
    /// treatment `UpdateWindowView` gives "Skip This Version" — kept off to the side of whatever
    /// primary action a step has, so it reads as an unhurried option rather than a warning.
    private var skipSetupRow: some View {
        HStack {
            Button("Set Up Later", action: skipSetup)
            Spacer()
        }
    }

    private func continueRow(
        title: LocalizedStringKey, showsSkip: Bool = false, action: @escaping () -> Void
    ) -> some View {
        HStack {
            if showsSkip {
                Button("Set Up Later", action: skipSetup)
            }
            Spacer()
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

extension UserDefaults {
    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"

    /// Whether this device has finished the onboarding flow at least once.
    ///
    /// Device-local state, not a preference: `AppSettings` (WrdsKit) is exported and imported with
    /// the rest of a backup, and a restored backup carrying this flag onto a machine that has never
    /// actually granted anything would skip straight past the one flow that gets it granted.
    /// `UserDefaults` is the app's own record of what this particular install has been through, which
    /// is exactly what this is.
    var hasCompletedOnboarding: Bool {
        get { bool(forKey: Self.hasCompletedOnboardingKey) }
        set { set(newValue, forKey: Self.hasCompletedOnboardingKey) }
    }
}
