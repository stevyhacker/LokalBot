import Foundation

final class CotypingVisibleContextReplay: CotypingVisibleContextSource {
    struct Fixture: Codable {
        var target: CotypingVisibleContext.Target
        var afterTarget: CotypingVisibleContext.Target?
        var nodes: [Node]
        var excludedApps: [String]?
        var excludedDomains: [String]?
    }

    struct Node: Codable {
        var region: CotypingVisibleContext.Region
        var children: [String]
        var text: String?
    }

    let fixture: Fixture
    var withinBudget = true
    var onTextRead: ((String) -> Void)?
    var regionOverrides: [String: CotypingVisibleContext.Region] = [:]
    private(set) var textReadIDs: [String] = []
    private(set) var metadataReadIDs: [String] = []
    private(set) var targetReads = 0

    init(_ fixture: Fixture) { self.fixture = fixture }

    func capture(enabled: Bool) -> CotypingVisibleContext.Snapshot? {
        CotypingVisibleContext.capture(
            from: self, policy: .init(enabled: enabled, excludedApps: fixture.excludedApps ?? [],
                                     excludedDomains: fixture.excludedDomains ?? []))
    }

    func target() -> CotypingVisibleContext.Target? {
        targetReads += 1
        return targetReads > 1 ? fixture.afterTarget ?? fixture.target : fixture.target
    }

    func region(_ id: String) -> CotypingVisibleContext.Region? {
        metadataReadIDs.append(id)
        return regionOverrides[id] ?? fixture.nodes.first { $0.region.id == id }?.region
    }

    func children(_ id: String) -> [String] {
        fixture.nodes.first { $0.region.id == id }?.children ?? []
    }

    func text(_ id: String) -> String? {
        textReadIDs.append(id)
        onTextRead?(id)
        return fixture.nodes.first { $0.region.id == id }?.text
    }
}
