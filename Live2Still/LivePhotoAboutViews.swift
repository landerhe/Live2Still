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
                    Text("Live2Still processes photos on your device. The app does not upload them to its own servers. Photos may download or sync through Apple iCloud Photos when you enable cloud access.")
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

                    Text("Last updated: October 4, 2026")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    policySection(
                        title: "Overview",
                        body: "Live2Still saves still copies of Live Photos and helps you review your photo library on your iPhone. The app does not create accounts, show ads, or upload your photos to an app-operated server."
                    )

                    policySection(
                        title: "Photos access",
                        body: "With your permission, Live2Still reads the photos you allow, including ordinary photos for Clean Up. It saves still copies with the current appearance and checks dates, locations, favorite and hidden flags, and album membership before removing originals. Motion and reversible edit history are not included in a still copy. Conversion removes originals only after your explicit choice; separate Delete actions also require confirmation through iOS. Deletion can sync to other devices through iCloud Photos."
                    )

                    policySection(
                        title: "Data collection",
                        body: "Live2Still does not collect personal data for analytics, advertising, or tracking. Optional on-device analysis uses thumbnails to suggest codes, text, food, and photos worth reviewing. Suggestions can be wrong and never cause automatic deletion. Temporary conversion and analysis files are removed on completion, failure, or cancellation; abandoned files are cleaned on the next launch."
                    )

                    policySection(
                        title: "On-device preferences",
                        body: "The app stores preferences, queued decisions, review progress, conversion output identifiers and results, and analysis classifications locally. These records contain photo identifiers and metadata needed for safe retries. Temporary image caches are held locally. The app does not transmit these records to an app-operated service; device backups are governed by your Apple settings."
                    )

                    policySection(
                        title: "Third parties",
                        body: "Live2Still does not embed advertising, analytics, or social SDKs. Showing cloud photos can let PhotoKit download images from Apple iCloud Photos. Cloud analysis requires its own opt-in. With cloud access off, image and conversion requests do not request downloads; a local preview does not guarantee the full original or motion is available."
                    )

                    policySection(
                        title: "Your choices",
                        body: "You can limit or revoke Photos access at any time in Settings → Privacy & Security → Photos → Live2Still. Queued decisions outside limited access are preserved until you expand access or clear the queue. Deleted photos may remain in Photos → Recently Deleted and do not immediately free storage. Removing Live2Still removes its local records; photos it already saved remain in Photos. Your iCloud Photos library is controlled by Apple and your settings."
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
