import AppKit
import SwiftUI

/// One app the picker can offer: enough to draw a row, and enough to store — group app filters are
/// bundle IDs, never paths, since a path can move on an update and a bundle ID does not.
private struct AppPickerEntry: Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let icon: NSImage?
}

/// Picks one app by bundle ID, for a group's "only in" / "never in" filter lists.
///
/// The list is `NSWorkspace.shared.runningApplications` — what is actually open right now, with a
/// live icon and name for free — merged with a shallow scan of `/Applications`, so an app the user
/// wants to filter by does not have to be running first. A running app wins a collision: its icon and
/// name are already loaded, where the scan would have to open the bundle again for the same answer.
struct AppPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let excluding: Set<String>
    let onPick: (String) -> Void

    @State private var searchText = ""
    @State private var apps: [AppPickerEntry] = []

    private var filtered: [AppPickerEntry] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an App")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            // A manual field rather than `.searchable`: this view has no enclosing navigation
            // stack for a searchable toolbar to attach to, and a plain sheet is not guaranteed one.
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            .padding(.horizontal)
            .padding(.bottom, 8)

            List(filtered) { app in
                Button {
                    onPick(app.bundleID)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app")
                                .frame(width: 20, height: 20)
                        }
                        Text(app.name)
                        Spacer()
                        Text(app.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 420, height: 480)
        .onAppear(perform: loadApps)
    }

    private func loadApps() {
        var byBundleID: [String: AppPickerEntry] = [:]

        for running in NSWorkspace.shared.runningApplications {
            guard let bundleID = running.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier
            else { continue }
            byBundleID[bundleID] = AppPickerEntry(
                bundleID: bundleID, name: running.localizedName ?? bundleID, icon: running.icon)
        }

        for url in Self.scanApplications() {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier, byBundleID[bundleID] == nil
            else { continue }
            let name = (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            byBundleID[bundleID] = AppPickerEntry(
                bundleID: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
        }

        apps = byBundleID.values
            .filter { !excluding.contains($0.bundleID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `.app` bundles directly inside `/Applications`, plus one level of subfolders (`Utilities`,
    /// vendor folders like `Adobe`) — deep enough to find what a typical install puts there without
    /// walking the whole filesystem.
    private static func scanApplications(maxDepth: Int = 1) -> [URL] {
        var results: [URL] = []
        func scan(_ directory: URL, depth: Int) {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            else { return }
            for item in items {
                if item.pathExtension == "app" {
                    results.append(item)
                } else if depth < maxDepth,
                          (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    scan(item, depth: depth + 1)
                }
            }
        }
        scan(URL(fileURLWithPath: "/Applications"), depth: 0)
        return results
    }
}
