//
//  LivePhotoNetworkMonitor.swift
//  Live2Still
//

import Network

@MainActor
final class LivePhotoNetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.live2still.network-monitor")
    private let onChange: @MainActor @Sendable (Bool) -> Void

    private(set) var isConnected = true

    init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        // Capture the Sendable callback, not this MainActor-isolated monitor.
        let changeHandler = onChange
        monitor.pathUpdateHandler = { path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                changeHandler(connected)
            }
        }
        monitor.start(queue: queue)
        isConnected = monitor.currentPath.status == .satisfied
    }

    func stop() {
        monitor.cancel()
    }
}
