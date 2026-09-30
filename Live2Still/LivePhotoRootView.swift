//
//  LivePhotoRootView.swift
//  Live2Still
//

import SwiftUI

struct LivePhotoRootView: View {
    @State private var store: LivePhotoLibraryStore?
    @State private var isBootstrapped = false

    var body: some View {
        Group {
            if let store, isBootstrapped {
                ContentView(store: store)
            } else {
                LivePhotoLaunchShellView(mode: .starting)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .task {
            await bootstrapStoreIfNeeded()
        }
    }

    @MainActor
    private func bootstrapStoreIfNeeded() async {
        guard !isBootstrapped else { return }

        // Paint the launch shell before touching the Photos framework.
        await Task.yield()

        if store == nil {
            store = LivePhotoLibraryStore()
        }

        guard let store else { return }
        // Commit a real app screen before Photos performs any framework or
        // library work. On-device Photos setup can be delayed by iCloud or a
        // large library, and must never hold the first visible frame hostage.
        isBootstrapped = true
        await store.prepare()
    }
}

#Preview {
    LivePhotoRootView()
}
