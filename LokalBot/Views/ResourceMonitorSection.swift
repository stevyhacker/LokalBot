import SwiftUI

/// A compact live readout in Settings → Advanced. Whole-app figures use
/// native process accounting for LokalBot and its helpers; model rows merge
/// subprocess-backed GGUF/ONNX runtimes with retained CoreML/MLX models.
struct ResourceMonitorSection: View {
    @ObservedObject private var residency = ModelResidency.shared
    @ObservedObject private var modelRuntimes = ModelRuntimeRegistry.shared
    @StateObject private var monitor = ResourceMonitorViewModel()

    /// Two even columns keep the four metrics in a balanced 2×2 grid.
    private let columns = [
        GridItem(.flexible(), spacing: 8, alignment: .leading),
        GridItem(.flexible(), spacing: 8, alignment: .leading),
    ]

    var body: some View {
        Section("Resource Monitor") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                metricTile(
                    icon: "cpu",
                    value: ResourceMonitorPresentation.percent(monitor.cpuUsagePercent),
                    label: "CPU",
                    identifier: "settings.resourceMonitor.cpu"
                )
                metricTile(
                    icon: "memorychip",
                    value: ResourceMonitorPresentation.memory(
                        monitor.snapshot?.totalPhysicalFootprintBytes
                    ),
                    label: memoryLabel,
                    identifier: "settings.resourceMonitor.memory"
                )
                metricTile(
                    icon: "square.stack.3d.up",
                    value: String(loadedModels.count),
                    label: "models loaded",
                    identifier: "settings.resourceMonitor.models"
                )
                metricTile(
                    icon: "shippingbox",
                    value: ResourceMonitorPresentation.modelMemorySummary(
                        models: loadedModels,
                        snapshot: monitor.snapshot
                    ),
                    label: "model memory",
                    identifier: "settings.resourceMonitor.modelMemory"
                )
            }

            if loadedModels.isEmpty {
                Label("No LokalBot model runtimes are loaded.", systemImage: "moon.zzz")
                    .font(.system(size: 12))
                    .settingsSecondary()
            } else {
                ForEach(loadedModels) { model in
                    modelRow(model)
                }
            }

            SettingsHelp("Updates every 2 seconds. Includes LokalBot and its helpers, so multi-core CPU can exceed 100%. External Ollama and Apple Intelligence models aren't counted.")
        }
        .task(id: trackedProcessIdentities) {
            await monitor.poll(additionalProcessIdentities: trackedProcessIdentities)
        }
    }

    private var trackedProcessIdentities: [SystemResourceSampler.ProcessIdentity] {
        let ggufIdentities: [SystemResourceSampler.ProcessIdentity] =
            residency.residents.compactMap { resident in
                guard let processIdentifier = resident.processIdentifier,
                      let startTime = resident.processStartTime else { return nil }
                return .init(processIdentifier: processIdentifier, startTime: startTime)
            }
        let helperIdentities: [SystemResourceSampler.ProcessIdentity] =
            modelRuntimes.residents.compactMap { resident in
                guard let processIdentifier = resident.processIdentifier,
                      let startTime = resident.processStartTime else { return nil }
                return .init(processIdentifier: processIdentifier, startTime: startTime)
            }
        return Set(ggufIdentities + helperIdentities).sorted {
            if $0.processIdentifier != $1.processIdentifier {
                return $0.processIdentifier < $1.processIdentifier
            }
            return $0.startTime < $1.startTime
        }
    }

    private var loadedModels: [ResourceMonitorPresentation.Model] {
        ResourceMonitorPresentation.models(
            residency: residency.residents,
            runtimes: modelRuntimes.residents,
            snapshot: monitor.snapshot,
            pinnedIDs: residency.pinnedIDs,
            leaseDescriptions: residency.leaseDescriptions
        )
    }

    private var memoryLabel: String {
        guard let bytes = monitor.snapshot?.totalPhysicalFootprintBytes,
              ProcessInfo.processInfo.physicalMemory > 0 else { return "memory" }
        let percentage = Double(bytes) / Double(ProcessInfo.processInfo.physicalMemory) * 100
        return "memory · " + String(format: "%.0f", percentage) + "% RAM"
    }

    private func modelRow(_ model: ResourceMonitorPresentation.Model) -> some View {
        let reading = ResourceMonitorPresentation.memoryReading(
            for: model,
            snapshot: monitor.snapshot
        )
        let value = ResourceMonitorPresentation.modelMemoryValue(reading)
        return LabeledContent {
            Text(value)
                .font(.callout.monospacedDigit())
                .settingsSecondary()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.role)
                Text(model.label)
                    .font(WorkspaceTypography.metadata)
                    .settingsSecondary()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.label)
                if let note = model.leaseNote {
                    Text(note)
                        .font(WorkspaceTypography.metadata)
                        .settingsSecondary()
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.role + ", " + model.label)
        .accessibilityValue(ResourceMonitorPresentation.spokenMemoryValue(reading))
    }

    private func metricTile(icon: String, value: String, label: String,
                            identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(value, systemImage: icon)
                .font(WorkspaceTypography.bodyEmphasis.monospacedDigit())
            Text(label).font(WorkspaceTypography.editorialBody).settingsSecondary()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: Brand.Radius.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value.replacingOccurrences(of: "≈", with: "approximately "))
            .accessibilityIdentifier(identifier)
    }
}

/// Pure presentation logic kept outside the SwiftUI state lifecycle so the
/// model count, stale-PID filtering, and measured-vs-estimated memory rules are
/// deterministic unit-test targets.
enum ResourceMonitorPresentation {
    struct Model: Identifiable, Equatable {
        let id: String
        let role: String
        let label: String
        let estimatedBytes: UInt64?
        let processIdentifier: pid_t?
        let processStartTime: UInt64?
        /// "in use — chat (interactive)" while the broker holds leases on this
        /// row; nil when idle. Only GGUF (residency) rows carry notes.
        let leaseNote: String?
    }

    struct MemoryReading: Equatable {
        let bytes: UInt64
        let estimated: Bool
    }

    static func models(residency: [ModelResidency.Resident],
                       runtimes: [ModelRuntimeRegistry.Resident],
                       snapshot: SystemResourceSampler.UsageSnapshot?,
                       pinnedIDs: Set<String> = [],
                       leaseDescriptions: [String: [String]] = [:]) -> [Model] {
        let ggufModels = residency.compactMap { resident -> Model? in
            if let processIdentifier = resident.processIdentifier,
               let snapshot {
                guard let usage = snapshot.usage(for: processIdentifier),
                      let expectedStartTime = resident.processStartTime,
                      usage.startTime == expectedStartTime else { return nil }
            }
            return Model(
                id: resident.id,
                role: role(for: resident.id),
                label: resident.label,
                estimatedBytes: resident.bytes > 0 ? UInt64(resident.bytes) : nil,
                processIdentifier: resident.processIdentifier,
                processStartTime: resident.processStartTime,
                leaseNote: leaseNote(for: resident.id, pinnedIDs: pinnedIDs,
                                     leaseDescriptions: leaseDescriptions)
            )
        }
        let otherModels = runtimes.compactMap { runtime -> Model? in
            if let processIdentifier = runtime.processIdentifier,
               let snapshot {
                guard let usage = snapshot.usage(for: processIdentifier),
                      let expectedStartTime = runtime.processStartTime,
                      usage.startTime == expectedStartTime else { return nil }
            }
            return Model(
                id: runtime.id,
                role: runtime.role,
                label: runtime.label,
                estimatedBytes: runtime.estimatedBytes,
                processIdentifier: runtime.processIdentifier,
                processStartTime: runtime.processStartTime,
                leaseNote: nil
            )
        }
        return (ggufModels + otherModels).sorted {
            if $0.role != $1.role {
                return $0.role.localizedCaseInsensitiveCompare($1.role) == .orderedAscending
            }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private static func leaseNote(for id: String, pinnedIDs: Set<String>,
                                  leaseDescriptions: [String: [String]]) -> String? {
        guard pinnedIDs.contains(id) else { return nil }
        let purposes = leaseDescriptions[id] ?? []
        return purposes.isEmpty ? "in use" : "in use — " + purposes.joined(separator: ", ")
    }

    static func memoryReading(for model: Model,
                              snapshot: SystemResourceSampler.UsageSnapshot?) -> MemoryReading? {
        if let processIdentifier = model.processIdentifier,
           let expectedStartTime = model.processStartTime,
           let usage = snapshot?.usage(for: processIdentifier),
           usage.startTime == expectedStartTime,
           usage.physicalFootprintBytes > 0 {
            return MemoryReading(bytes: usage.physicalFootprintBytes, estimated: false)
        }
        guard let estimatedBytes = model.estimatedBytes, estimatedBytes > 0 else { return nil }
        return MemoryReading(bytes: estimatedBytes, estimated: true)
    }

    static func modelMemorySummary(models: [Model],
                                   snapshot: SystemResourceSampler.UsageSnapshot?) -> String {
        guard !models.isEmpty else { return "0 MB" }
        let readings = models.compactMap { memoryReading(for: $0, snapshot: snapshot) }
        guard !readings.isEmpty else { return "included" }
        let total = readings.reduce(UInt64(0)) { $0 + $1.bytes }
        let isEstimate = readings.count != models.count || readings.contains { $0.estimated }
        return (isEstimate ? "≈" : "") + memory(total)
    }

    static func modelMemoryValue(_ reading: MemoryReading?) -> String {
        guard let reading else { return "Included in total" }
        return (reading.estimated ? "≈" : "") + memory(reading.bytes)
    }

    static func spokenMemoryValue(_ reading: MemoryReading?) -> String {
        guard let reading else { return "Included in total memory" }
        return (reading.estimated ? "Approximately " : "") + memory(reading.bytes)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    private static func role(for residencyID: String) -> String {
        switch residencyID {
        case "llama-server:17872": "Main LLM"
        case "llama-server:17873": "Embeddings"
        case "llama-server:17874", "cotyping-in-process": "Autocomplete"
        case "llama-server:17875": "Transcription"
        default: "Local model"
        }
    }
}

@MainActor
private final class ResourceMonitorViewModel: ObservableObject {
    @Published private(set) var snapshot: SystemResourceSampler.UsageSnapshot?
    @Published private(set) var cpuUsagePercent: Double?

    private var previousSnapshot: SystemResourceSampler.UsageSnapshot?

    func poll(additionalProcessIdentities: [SystemResourceSampler.ProcessIdentity]) async {
        previousSnapshot = nil
        snapshot = nil
        cpuUsagePercent = nil

        while !Task.isCancelled {
            let current = await Task.detached(priority: .utility) {
                SystemResourceSampler.usageSnapshot(
                    additionalProcessIdentities: additionalProcessIdentities
                )
            }.value
            guard !Task.isCancelled else { return }
            if let previousSnapshot {
                cpuUsagePercent = SystemResourceSampler.cpuUsagePercent(
                    from: previousSnapshot,
                    to: current
                )
            }
            previousSnapshot = current
            snapshot = current

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }
}
