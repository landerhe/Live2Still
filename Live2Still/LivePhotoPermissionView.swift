//
//  LivePhotoPermissionView.swift
//  Live2Still
//

import SwiftUI

struct LivePhotoPermissionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onRequestAccess: () -> Void

    @State private var symbolActive = false

    var body: some View {
        VStack(spacing: LivePhotoDesign.launchVerticalSpacing) {
            Spacer()

            Image(systemName: "livephoto")
                .font(.system(size: LivePhotoDesign.launchIconSize))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating, isActive: symbolActive && !reduceMotion)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Welcome to Live2Still")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Turn Live Photos into stills and free up storage.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                permissionTip(
                    icon: "photo.on.rectangle.angled",
                    text: "Live2Still needs access to your photo library to find Live Photos."
                )
                permissionTip(
                    icon: "photo.stack",
                    text: "For the full album experience, choose **Allow Access to All Photos** when iOS asks."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)

            Spacer()

            Button("Allow Photo Access", action: onRequestAccess)
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)

            Text(
                "If iOS does not ask again, photo access was already granted. Open Settings → Privacy & Security → Photos → Live2Still to change access or choose Full Access."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
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

    private func permissionTip(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    LivePhotoPermissionView(onRequestAccess: {})
}
