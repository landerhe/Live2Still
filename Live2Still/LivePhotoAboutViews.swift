//
//  LivePhotoAboutViews.swift
//  Live2Still
//

import SwiftUI

enum LivePhotoSupportLinks {
    /// Replace with your public support URL or keep mailto for App Store Connect.
    static let supportURL = URL(string: "mailto:support@live2still.app")!
    static let privacyPolicyURL = URL(string: "https://live2still.app/privacy")!
}

struct LivePhotoAboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivacyPolicy = false

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Version", value: versionString)
                }

                Section {
                    Button("Privacy Policy") {
                        showPrivacyPolicy = true
                    }
                    Link("Support", destination: LivePhotoSupportLinks.supportURL)
                } footer: {
                    Text("Live2Still processes Live Photos on your device. Photos are not uploaded to any server.")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPrivacyPolicy) {
                LivePhotoPrivacyPolicyView()
            }
        }
    }
}

struct LivePhotoPrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Privacy Policy")
                        .font(.title2.weight(.semibold))

                    Text("Last updated: August 12, 2026")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    policySection(
                        title: "Overview",
                        body: "Live2Still converts Live Photos into still images on your iPhone. The app does not create accounts, show ads, or send your photos to a server."
                    )

                    policySection(
                        title: "Photos access",
                        body: "With your permission, Live2Still reads Live Photos in your library, saves converted stills, and—only when you enable “Remove original Live Photo”—asks iOS to delete the original Live Photo. Conversion may copy existing date, location, album membership, favorite, and hidden flags onto the new still so it stays organized in Photos."
                    )

                    policySection(
                        title: "Data collection",
                        body: "Live2Still does not collect personal data for analytics, advertising, or tracking. Photo processing happens on-device. Temporary image files used during conversion are deleted when the conversion finishes."
                    )

                    policySection(
                        title: "On-device preferences",
                        body: "The app stores small preferences on your device (for example, whether you finished onboarding and “On this device only”) using Apple’s standard UserDefaults storage. These preferences do not leave your device."
                    )

                    policySection(
                        title: "Third parties",
                        body: "Live2Still does not embed advertising, analytics, or social SDKs that share your data."
                    )

                    policySection(
                        title: "Your choices",
                        body: "You can revoke Photos access at any time in Settings → Privacy & Security → Photos → Live2Still. Deleted Live Photos may remain in Photos → Recently Deleted until that album empties. Because Live2Still does not upload your library, there is no cloud copy for us to delete."
                    )

                    policySection(
                        title: "Contact",
                        body: "Questions about privacy: support@live2still.app"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func policySection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LivePhotoLegalFooter: View {
    @State private var showPrivacyPolicy = false
    @State private var showAbout = false

    var body: some View {
        HStack(spacing: 16) {
            Button("Privacy") {
                showPrivacyPolicy = true
            }
            .buttonStyle(.plain)

            Text("·")
                .foregroundStyle(.tertiary)

            Button("About") {
                showAbout = true
            }
            .buttonStyle(.plain)

            Text("·")
                .foregroundStyle(.tertiary)

            Link("Support", destination: LivePhotoSupportLinks.supportURL)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showPrivacyPolicy) {
            LivePhotoPrivacyPolicyView()
        }
        .sheet(isPresented: $showAbout) {
            LivePhotoAboutSheet()
        }
    }
}

#Preview("About") {
    LivePhotoAboutSheet()
}

#Preview("Privacy") {
    LivePhotoPrivacyPolicyView()
}
