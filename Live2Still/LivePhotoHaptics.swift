//
//  LivePhotoHaptics.swift
//  Live2Still
//

import SwiftUI

enum LivePhotoHaptics {
    /// Core Haptics often fails in Simulator (CHHapticEngine -4810); skip feedback there.
    static var isEnabled: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}

extension View {
    @ViewBuilder
    func livePhotoImpactFeedback(trigger: some Equatable) -> some View {
        if LivePhotoHaptics.isEnabled {
            sensoryFeedback(.impact(weight: .medium), trigger: trigger)
        } else {
            self
        }
    }

    @ViewBuilder
    func livePhotoRigidImpactFeedback(trigger: some Equatable) -> some View {
        if LivePhotoHaptics.isEnabled {
            sensoryFeedback(.impact(flexibility: .rigid), trigger: trigger)
        } else {
            self
        }
    }

    @ViewBuilder
    func livePhotoSelectionFeedback(trigger: some Equatable) -> some View {
        if LivePhotoHaptics.isEnabled {
            sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }
}
