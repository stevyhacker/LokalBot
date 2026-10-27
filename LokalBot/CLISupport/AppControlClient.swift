import Foundation

/// Sends one request to the running app, starting the app in the background
/// when no copy is running for this library. Every settings read and write
/// goes through the app, so its decoding and coupling rules apply once.
struct AppControlClient {
    var root: URL
    var gate: SettingsControlGate
    var requestTimeout: TimeInterval = 15

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
        self.gate = SettingsControlGate(root: root)
    }

    var socketPath: String {
        AppControlSocket.path(controlDirectory: gate.controlDirectory)
    }

    /// The result of `method`, or a thrown `AppControlError`.
    func request(
        _ method: AppControlProtocol.Method,
        params: [String: JSONValue]? = nil,
        launch: Bool = true,
        launchTimeout: TimeInterval = 30
    ) throws -> JSONValue {
        // Never start the app for an agent the person has not allowed.
        guard gate.isEnabled else { throw AppControlError.settingsAccessDisabled }
        let request = AppControlRequest(method: method, params: params)
        if let response = try? send(request) { return try unwrap(response) }

        if !isAppRunning {
            guard launch else {
                throw AppControlError.appNotRunning("LokalBot is not running, and --no-launch was given.")
            }
            guard let app = Self.enclosingApp(forExecutable: Bundle.main.executableURL) else {
                throw AppControlError.appNotRunning(
                    "LokalBot is not running, and this lokalbot-cli is not inside LokalBot.app, so it cannot start it.")
            }
            try Self.launchInBackground(app)
        }

        let deadline = Date().addingTimeInterval(max(1, launchTimeout))
        while Date() < deadline {
            if let response = try? send(request) { return try unwrap(response) }
            usleep(250_000)
        }
        throw AppControlError.appNotResponding
    }

    /// One connection, one request line, one response line.
    func send(_ request: AppControlRequest) throws -> AppControlResponse {
        let descriptor = try AppControlSocket.connect(path: socketPath, timeout: requestTimeout)
        defer { Darwin.close(descriptor) }
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        try AppControlSocket.writeAll(descriptor, line)
        let reply = try AppControlSocket.readLine(descriptor)
        return try JSONDecoder().decode(AppControlResponse.self, from: reply)
    }

    private func unwrap(_ response: AppControlResponse) throws -> JSONValue {
        if let error = response.error { throw error }
        return response.result ?? .null
    }

    /// True while a GUI copy holds this library's instance lock.
    var isAppRunning: Bool {
        let path = root.appendingPathComponent(LibraryInstanceLock.fileName).path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// The LokalBot app bundle containing this executable, resolved through
    /// the installed `~/.local/bin` symlink. Launching by path, never by
    /// name, keeps a CLI from starting a different copy with another library.
    static func enclosingApp(forExecutable executable: URL?) -> URL? {
        var directory = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let candidate = directory, candidate.path != "/" {
            if candidate.pathExtension == "app",
               let identifier = Bundle(url: candidate)?.bundleIdentifier,
               AppIdentifiers.Identity(rawValue: identifier) != nil {
                return candidate
            }
            directory = candidate.deletingLastPathComponent()
        }
        return nil
    }

    /// Starts the app hidden and in the background; it stays running as the
    /// normal menu-bar app afterwards.
    static func launchInBackground(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", app.path, "--args", AppControlProtocol.backgroundLaunchArgument]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppControlError.appNotRunning("Could not start LokalBot: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppControlError.appNotRunning("Could not start LokalBot at \(app.path).")
        }
    }
}
