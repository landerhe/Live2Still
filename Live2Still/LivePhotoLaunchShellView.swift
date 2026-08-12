//
//  LivePhotoLaunchShellView.swift
//  Live2Still
//

import SwiftUI

struct LivePhotoLaunchShellView: View {
    enum Mode {
        case starting
        case loading(message: String, showsProgress: Bool)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var mode: Mode = .starting
    var showsTips: Bool = false

    @State private var symbolActive = false

    var body: some View {
        VStack(spacing: LivePhotoDesign.launchVerticalSpacing) {
            Spacer()

            brandHeader

            if showsTips {
                tipsSection
            }

            Spacer()

            footer
        }
        .padding(.horizontal, LivePhotoDesign.launchHorizontalPadding)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            symbolActive = true
        }
    }

    private var brandHeader: some View {
        VStack(spacing: LivePhotoDesign.launchVerticalSpacing) {
            Image(systemName: "livephoto")
                .font(.system(size: LivePhotoDesign.launchIconSize))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating, isActive: symbolActive && !reduceMotion)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Live2Still")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Turn Live Photos into stills and free up storage.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            tipRow(icon: "square.grid.2x2", title: "Album", detail: "Browse and select Live Photos to convert.")
            tipRow(icon: "hand.draw", title: "Swipe", detail: "Review one at a time and queue actions.")
            tipRow(icon: "arrow.triangle.2.circlepath", title: "Convert", detail: "Save stills and optionally remove originals.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        switch mode {
        case .starting:
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel("Starting")
        case .loading(let message, let showsProgress):
            HStack(spacing: 10) {
                if showsProgress {
                    ProgressView()
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func tipRow(icon: String, title: String, detail: String) -> some View {
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

#Preview("Starting") {
    LivePhotoLaunchShellView()
}

#Preview("Loading") {
    LivePhotoLaunchShellView(
        mode: .loading(message: "Scanning your Live Photos…", showsProgress: true),
        showsTips: true
    )
}
