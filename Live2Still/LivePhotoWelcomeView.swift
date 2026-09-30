//
//  LivePhotoWelcomeView.swift
//  Live2Still
//

import SwiftUI

struct LivePhotoWelcomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let store: LivePhotoLibraryStore
    let onContinue: () -> Void
    let onAddPhotos: () -> Void
    let onOpenSettings: () -> Void

    @State private var symbolActive = false

    private var loadingLabel: String {
        if store.loadingStatusMessage.isEmpty {
            return store.isLoading ? "Scanning your Live Photos…" : "Ready"
        }
        return store.loadingStatusMessage
    }

    var body: some View {
        VStack(spacing: LivePhotoDesign.launchVerticalSpacing) {
            Spacer()

            Image(systemName: "livephoto")
                .font(.system(size: LivePhotoDesign.launchIconSize))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating, isActive: symbolActive && !reduceMotion)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Here's how Live2Still works while your library loads.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                welcomeTip(
                    icon: "square.grid.2x2",
                    title: "Album",
                    detail: "Browse Live Photos, select the ones you want, and convert them to stills."
                )
                welcomeTip(
                    icon: "hand.draw",
                    title: "Swipe",
                    detail: "Review one photo at a time — swipe to queue converts or deletes."
                )
                welcomeTip(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Convert",
                    detail: "Optionally remove the original Live Photo after conversion to save space."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.isLimited {
                limitedAccessCallout
            }

            Spacer()

            loadingFooter

            Button("Continue", action: onContinue)
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)

            LivePhotoLegalFooter()
                .padding(.top, 4)
        }
        .padding(.horizontal, LivePhotoDesign.launchHorizontalPadding)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            symbolActive = true
        }
    }

    private var limitedAccessCallout: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Limited photo access", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text(
                "Only photos you selected are visible. Add more below, or open Settings → Photos → Live2Still and choose Full Access."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Add Photos", action: onAddPhotos)
                    .buttonStyle(.bordered)

                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: LivePhotoDesign.cardCornerRadius))
    }

    private var loadingFooter: some View {
        HStack(spacing: 10) {
            if store.isLoading {
                ProgressView()
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Text(loadingLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func welcomeTip(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    LivePhotoWelcomeView(
        store: LivePhotoLibraryStore(),
        onContinue: {},
        onAddPhotos: {},
        onOpenSettings: {}
    )
}
