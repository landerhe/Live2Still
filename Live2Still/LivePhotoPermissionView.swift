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

                Text("Save still copies and review Live Photos in batches.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                permissionTip(
                    icon: "photo.on.rectangle.angled",
                    text: "Live2Still reads the photos you allow to find Live Photos and offer optional on-device review suggestions."
                )
                permissionTip(
                    icon: "photo.stack",
                    text: "Limited access works. Choose **Full Access** only if you want to browse your entire Live Photo library at once."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)

            Spacer()

            Button("Allow Photo Access", action: onRequestAccess)
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)

            Text(
                "You can change access later in Settings → Privacy & Security → Photos → Live2Still."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)

            LivePhotoLegalFooter()
                .padding(.top, 8)
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
