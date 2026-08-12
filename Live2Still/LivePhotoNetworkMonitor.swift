//
//  LivePhotoNetworkMonitor.swift
//  Live2Still
//

import Network

@MainActor
final class LivePhotoNetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.live2still.network-monitor")
    private let onChange: (Bool) -> Void

    private(set) var isConnected = true

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let changed = self.isConnected != connected
                self.isConnected = connected
                if changed {
                    self.onChange(connected)
                }
            }
        }
        monitor.start(queue: queue)
        isConnected = monitor.currentPath.status == .satisfied
    }

    func stop() {
        monitor.cancel()
    }
}
