import AppKit
import Network

/// Tells the app when the Mac sleeps, wakes, or changes network.
///
/// All three callbacks arrive on the main thread.
final class PowerMonitor {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?
    /// `true` when there is a usable network after there was none, or when
    /// the Mac moved from one network to another.
    var onNetworkChange: ((Bool) -> Void)?

    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tuberview.network")
    private var observers: [NSObjectProtocol] = []
    private var lastAvailable: Bool?
    private var lastInterfaces: [String] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.onWillSleep?()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.onDidWake?()
        })

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let interfaces = path.availableInterfaces.map { $0.name }
            DispatchQueue.main.async {
                self?.pathChanged(available: available, interfaces: interfaces)
            }
        }
        pathMonitor.start(queue: queue)
    }

    func stop() {
        pathMonitor.cancel()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    private func pathChanged(available: Bool, interfaces: [String]) {
        defer {
            lastAvailable = available
            lastInterfaces = interfaces
        }
        // The first report is where things stand, not a change.
        guard let before = lastAvailable else { return }
        if available != before {
            onNetworkChange?(available)
        } else if available && interfaces.first != lastInterfaces.first {
            // Still online, but through a different connection.
            onNetworkChange?(true)
        }
    }
}
