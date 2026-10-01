//
//  LivePhotoRootView.swift
//  Live2Still
//

import SwiftUI

struct LivePhotoRootView: View {
    @State private var store = LivePhotoLibraryStore()

    var body: some View {
        ContentView(store: store)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .task {
            await store.prepare()
        }
    }
}

#Preview {
    LivePhotoRootView()
}
