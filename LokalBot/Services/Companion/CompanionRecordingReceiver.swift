import Foundation

/// A recording as `receive_recording` describes it (Companion/protocol/ffi.md).
/// The device name comes from the pairing, the rest from the device.
struct CompanionDeviceRecording: Decodable, Equatable, Sendable {
    /// ADTS AAC, which a recorder that dies leaves readable.
    static let supportedFormat = "aac-adts"

    var id: String
    var title: String?
    var startedAt: String?
    var format: String
    var deviceName: String
}

/// Makes meetings of the recordings paired devices send. A device deletes its
/// copy once it hears `accepted`, so that answer waits until the meeting is
/// stored; `rejected` is for what no retry can fix, and everything else is
/// `deferred`.
@MainActor
final class CompanionRecordingReceiver {
    struct Dependencies {
        /// Anywhere in the library, merged sources included: an id can't be
        /// used twice on disk.
        var meetingExists: (UUID) async -> Bool
        var language: () -> AppLanguage
        var importRecording: (URL, MeetingImportService.DeviceOrigin) async throws -> Meeting
        var didImport: (Meeting) -> Void
    }

    private let dependencies: Dependencies
    /// Outlives the host, which restarts when sharing is switched off and on
    /// while an import goes on.
    private var importing: Set<UUID> = []

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func receive(_ json: String, fileURL: URL) async -> CompanionUploadOutcome {
        guard let recording = try? JSONDecoder().decode(CompanionDeviceRecording.self, from: Data(json.utf8)),
              let id = UUID(uuidString: recording.id) else {
            return .rejected("The recording's description could not be read.")
        }
        guard recording.format == CompanionDeviceRecording.supportedFormat else {
            return .rejected("This Mac can't read “\(recording.format)” recordings. Update LokalBot on it.")
        }
        guard importing.insert(id).inserted else {
            return .deferred("This Mac is already importing this recording.")
        }
        defer { importing.remove(id) }
        // The Mac stored it but the crash or disconnect came before the device
        // heard: answer again without making a second meeting.
        if await dependencies.meetingExists(id) { return .accepted(meetingID: id) }
        let origin = MeetingImportService.DeviceOrigin(
            id: id, title: title(of: recording),
            startedAt: recording.startedAt.flatMap(CompanionSyncServer.date),
            deviceName: String(recording.deviceName.prefix(60)))
        do {
            dependencies.didImport(try await dependencies.importRecording(fileURL, origin))
            return .accepted(meetingID: id)
        } catch MeetingImportService.ImportError.unreadable, MeetingImportService.ImportError.noAudio {
            return .rejected("This recording has no audio your Mac can transcribe.")
        } catch {
            lokalbotLog("device recording import failed meeting=\(id)")
            return .deferred(error.localizedDescription)
        }
    }

    private func title(of recording: CompanionDeviceRecording) -> String {
        let chosen = recording.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !chosen.isEmpty { return String(chosen.prefix(200)) }
        return String(format: dependencies.language().localized("Recording from %@"), recording.deviceName)
    }
}
