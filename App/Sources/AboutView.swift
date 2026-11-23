import AppKit
import SwiftUI

/// The About window: app icon, name, version, licence line and a way back to the source. The only
/// place in the app the tagline gets to say what it actually means — every other string stays
/// clean.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("F Wrds")
                    .font(.title2.bold())
                Text("Version \(Self.version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("#@!% typing the same $#!% twice.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                Text("© 2026 Thomas Guillot · MIT-Licensed")
                Link("github.com/thomasguillot/f-wrds", destination: Self.repoURL)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private static let repoURL = URL(string: "https://github.com/thomasguillot/f-wrds")!
}
