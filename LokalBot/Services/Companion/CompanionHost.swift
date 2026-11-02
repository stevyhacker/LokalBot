import AppKit
import Foundation
import SystemConfiguration

/// Owns the sync host while Settings → Phones & tablets is on: the Mac's
/// static key, the listener, the Bonjour advertisement, the publisher that
/// keeps records current, and the device list Settings shows. With sharing
/// off none of it exists and nothing listens.
@MainActor
final class CompanionHost: ObservableObject {
    enum Status: Equatable {
        case off
        case starting
        case listening(port: Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var devices: [CompanionPairedDevice] = []
    @Published private(set) var connectedDeviceIDs: Set<String> = []
    @Published private(set) var pairing: CompanionPairingOffer?
    @Published private(set) var actionError: String?

    private struct Running: Sendable {
        let server: CompanionServer
        let publisher: CompanionPublisher
        let fingerprint: String
        let sharing: CompanionSharing
    }

    private let root: URL
    private let activityDatabaseURL: URL
    private let factory: CompanionServerFactory?
    private let opApplier: CompanionOpApplier
    private let askResponder: CompanionAskResponder
    private let language: () -> AppLanguage
    /// Every blocking call into the host runs here, never on the main thread.
    private let serverQueue = DispatchQueue(label: "me.dotenv.LokalBot.companion-server", qos: .userInitiated)
    private let bonjour = CompanionBonjourAdvertiser()
    private var running: Running?
    private var generation = 0
    private var tick: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var reconciledDay: String?

    init(root: URL, activityDatabaseURL: URL, factory: CompanionServerFactory?,
         opApplier: CompanionOpApplier, askResponder: CompanionAskResponder,
         language: @escaping () -> AppLanguage) {
        self.root = root
        self.activityDatabaseURL = activityDatabaseURL
        self.factory = factory
        self.opApplier = opApplier
        self.askResponder = askResponder
        self.language = language
    }

    var isListening: Bool {
        if case .listening = status { return true }
        return false
    }

    var databaseURL: URL {
        root.appendingPathComponent("companion", isDirectory: true).appendingPathComponent("companion.sqlite")
    }

    // MARK: - Lifecycle

    /// Start, reconfigure, or stop to match the settings.
    func apply(_ sharing: CompanionSharing) {
        guard sharing.enabled else {
            stop()
            return
        }
        if let running {
            if running.sharing.port != sharing.port {
                stop()
                start(sharing)
                return
            }
            running.publisher.update(context: context(for: sharing))
            self.running = Running(server: running.server, publisher: running.publisher,
                                   fingerprint: running.fingerprint, sharing: sharing)
            updateBonjour()
            return
        }
        if status == .starting { stop() }
        start(sharing)
    }

    func stop() {
        generation &+= 1
        tick?.invalidate()
        tick = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        bonjour.stop()
        askResponder.cancelAll()
        pairing = nil
        devices = []
        connectedDeviceIDs = []
        status = .off
        guard let stopping = running else { return }
        running = nil
        serverQueue.async { stopping.server.stop() }
    }

    private func start(_ sharing: CompanionSharing) {
        guard let factory else {
            status = .failed(CompanionServerError.unavailable.localizedDescription)
            return
        }
        generation &+= 1
        let attempt = generation
        status = .starting
        actionError = nil
        let events = EventsBridge(host: self)
        let configuration = (databaseURL: databaseURL, macName: Self.macName, port: sharing.port)
        serverQueue.async { [weak self] in
            let result = Result { () -> (CompanionServer, String, Int) in
                let key = try CompanionKeyStore.loadOrCreate(factory: factory)
                let folder = configuration.databaseURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let server = try factory.makeServer(
                    .init(databasePath: configuration.databaseURL.path, macName: configuration.macName,
                          staticPrivateKey: key.privateKey, port: configuration.port),
                    events)
                try server.start()
                return (server, factory.keyFingerprint(key.publicKey), server.boundPort())
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, attempt == self.generation else {
                        if case .success(let started) = result { self?.serverQueue.async { started.0.stop() } }
                        return
                    }
                    switch result {
                    case .success(let (server, fingerprint, port)):
                        self.didStart(server: server, fingerprint: fingerprint, port: port, sharing: sharing)
                    case .failure(let error):
                        lokalbotLog("companion host failed to start: \(error.localizedDescription)")
                        self.status = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func didStart(server: CompanionServer, fingerprint: String, port: Int, sharing: CompanionSharing) {
        let publisher = CompanionPublisher(sink: server, context: context(for: sharing))
        running = Running(server: server, publisher: publisher, fingerprint: fingerprint, sharing: sharing)
        status = .listening(port: port)
        lokalbotLog("companion host listening port=\(port)")
        publisher.reconcileAll()
        reconciledDay = CompanionJSON.day(Date())
        updateBonjour()
        refreshDevices()
        tick = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicRefresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicRefresh() }
        }
    }

    private func context(for sharing: CompanionSharing) -> CompanionPublisher.Context {
        CompanionPublisher.Context(root: root, activityDatabaseURL: activityDatabaseURL,
                                   sharing: sharing, macName: Self.macName)
    }

    /// Today's record while there is activity, and a full reconcile once a
    /// day, which also withdraws records that left the history window.
    private func periodicRefresh() {
        guard let running else { return }
        let today = CompanionJSON.day(Date())
        if today != reconciledDay {
            reconciledDay = today
            running.publisher.reconcileAll()
        } else {
            running.publisher.refreshTodayIfActive()
        }
    }

    private func updateBonjour() {
        guard let running, case .listening(let port) = status, running.sharing.advertisesOnBonjour else {
            bonjour.stop()
            return
        }
        bonjour.start(port: port, fingerprint: running.fingerprint)
    }

    /// The computer name from Sharing settings, as the pairing QR code and
    /// phones show it.
    static var macName: String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name! : "Mac"
    }

    // MARK: - Change hooks

    func evidenceChanged(days: [Date], meetingIDs: Set<UUID>) {
        guard let publisher = running?.publisher else { return }
        if meetingIDs.isEmpty {
            publisher.daysChanged(days)
        } else {
            publisher.meetingsChanged(meetingIDs, days: days)
        }
    }

    func dayDigestChanged(_ day: Date) {
        running?.publisher.daysChanged([day])
    }

    func connectionsChanged() {
        running?.publisher.connectionsChanged()
    }

    // MARK: - Devices

    func refreshDevices() {
        guard let server = running?.server else { return }
        serverQueue.async { [weak self] in
            let devices = (try? server.pairedDevices()) ?? []
            let connected = server.connectedDeviceIDs()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running?.server === server else { return }
                    let paired = devices.count > self.devices.count
                    self.devices = devices.sorted { ($0.pairedAt ?? .distantPast) > ($1.pairedAt ?? .distantPast) }
                    self.connectedDeviceIDs = connected
                    // A successful pairing consumes the offer.
                    if paired { self.pairing = nil }
                }
            }
        }
    }

    func beginPairing() {
        guard let server = running?.server, let factory else { return }
        actionError = nil
        serverQueue.async { [weak self] in
            let result = Result { try server.beginPairing(addresses: factory.localAddresses()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running?.server === server else { return }
                    switch result {
                    case .success(let offer): self.pairing = offer
                    case .failure(let error): self.actionError = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancelPairing() {
        pairing = nil
        guard let server = running?.server else { return }
        serverQueue.async { server.cancelPairing() }
    }

    func removeDevice(_ device: CompanionPairedDevice) {
        guard let server = running?.server else { return }
        actionError = nil
        serverQueue.async { [weak self] in
            let failure: Error?
            do { try server.removeDevice(id: device.id); failure = nil } catch { failure = error }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let failure { self.actionError = failure.localizedDescription }
                    self.refreshDevices()
                }
            }
        }
    }

    // MARK: - Host callbacks

    fileprivate func applyOp(_ json: String) -> (CompanionOpResult, CompanionPublisher?) {
        let outcome = opApplier.apply(json)
        return (outcome.result, outcome.result.status == .applied ? running?.publisher : nil)
    }

    fileprivate func answer(_ json: String, output: CompanionAskOutput) {
        guard running != nil else {
            output.failed("Sharing with phones and tablets is turned off on your Mac.")
            return
        }
        askResponder.answer(json, output: output)
    }

    fileprivate var promptLanguage: AppLanguage { language() }

    /// The host's callbacks arrive on its own threads. Each one hops to the
    /// main actor for app state and blocks only where the protocol waits.
    private final class EventsBridge: CompanionServerEvents, @unchecked Sendable {
        private weak var host: CompanionHost?

        init(host: CompanionHost) {
            self.host = host
        }

        func approvePairing(deviceName: String, platform: String) -> Bool {
            let language = DispatchQueue.main.sync { MainActor.assumeIsolated { host?.promptLanguage } }
            guard let language else { return false }
            return CompanionPairingPrompt.ask(deviceName: deviceName, platform: platform, language: language)
        }

        func applyOp(_ json: String) -> CompanionOpResult {
            let applied = DispatchQueue.main.sync { MainActor.assumeIsolated { host?.applyOp(json) } }
            guard let (result, publisher) = applied else {
                return CompanionOpResult(status: .rejected, message: "Sharing is turned off on your Mac.")
            }
            if let publisher, let meetingID = (try? JSONDecoder().decode(
                CompanionSetStatusOp.self, from: Data(json.utf8))).flatMap({ UUID(uuidString: $0.meetingId) }) {
                publisher.republishNow(meetingID: meetingID)
            }
            return result
        }

        func ask(_ requestJSON: String, output: CompanionAskOutput) {
            DispatchQueue.main.async { [weak host] in
                MainActor.assumeIsolated {
                    guard let host else {
                        output.failed("Sharing with phones and tablets is turned off on your Mac.")
                        return
                    }
                    host.answer(requestJSON, output: output)
                }
            }
        }

        func devicesChanged() {
            DispatchQueue.main.async { [weak host] in
                MainActor.assumeIsolated { host?.refreshDevices() }
            }
        }
    }
}
