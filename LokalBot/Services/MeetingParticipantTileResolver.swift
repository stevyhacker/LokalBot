import Foundation

/// Read participant identity from the tile's own accessible label or from a
/// matching name + participant control. Generic OCR/page text is insufficient.
enum MeetingParticipantTileResolver {
    struct VisibleLabel: Sendable {
        var text: String
        var frame: CGRect
    }

    /// Only the name strip of a leaf video-sized container is a candidate.
    /// OCR must corroborate these candidates before they leave the provider.
    static func nameStrip(frame: CGRect, labels: [VisibleLabel], controls: [String]) -> String? {
        guard frame.width >= 120, frame.height >= 90,
              !controls.contains(where: { label in
                  let key = label.lowercased()
                  return key.contains("presenting") || key.contains("presentation") || key == "call controls"
                    || key == "side panel" || key == "participants" || key == "in the meeting"
                    || key == "leave call" || key == "chat with everyone"
              }) else { return nil }
        let visible = labels.filter { frame.contains($0.frame) }
        let names = Set(visible.compactMap { label -> String? in
            guard label.frame.minY >= frame.minY + frame.height * 0.75,
                  label.frame.minX <= frame.minX + min(80, frame.width * 0.25),
                  label.frame.height <= 40, label.frame.width < frame.width * 0.85,
                  let name = ParticipantObservation.safeName(label.text),
                  name.rangeOfCharacter(from: .letters) != nil else { return nil }
            return name
        })
        // Camera-off initials are allowed, but page/slide paragraphs are not.
        let substantive = visible.filter { $0.text.count > 1 }
        guard names.count == 1, substantive.count == 1 else { return nil }
        return names.first
    }

    static func selfName(_ label: String) -> String? {
        for suffix in [" (You)", " (you)"] where label.hasSuffix(suffix) {
            return ParticipantObservation.safeName(String(label.dropLast(suffix.count)))
        }
        return nil
    }

    static func selfName(rowLabels: [String], descendantLabels: [String]) -> String? {
        let labels = rowLabels + descendantLabels
        if let combined = labels.compactMap(selfName).first { return combined }
        guard labels.contains("(You)") || labels.contains("(you)") else { return nil }
        let names = Set(rowLabels.compactMap(ParticipantObservation.safeName))
        return names.count == 1 ? names.first : nil
    }
    static func name(ownLabels: [String], descendantLabels: [String]) -> String? {
        let direct = Set(ownLabels.compactMap { MeetingParticipantAccessibilityReader.tileName(description: $0) })
        if direct.count == 1 { return direct.first }
        guard direct.isEmpty else { return nil }
        let labels = Set((ownLabels + descendantLabels).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        var names = Set<String>()
        for label in labels {
            var candidate: String?
            for prefix in ["More options for ", "Mute ", "Pin ", "Unpin "] where label.hasPrefix(prefix) {
                candidate = String(label.dropFirst(prefix.count))
                for suffix in [" to your main screen", " from your main screen", " for everyone"] {
                    if candidate?.hasSuffix(suffix) == true { candidate = String(candidate!.dropLast(suffix.count)) }
                }
            }
            guard let candidate, let name = ParticipantObservation.safeName(candidate),
                  labels.contains(name) || labels.contains(name + " (You)") || labels.contains(name + " (you)") else { continue }
            names.insert(name)
        }
        return names.count == 1 ? names.first : nil
    }

    static func tile(name: String, frame: CGRect, labels: [String]) -> MeetingParticipantTile {
        let keys = Set(labels.map { $0.lowercased() })
        let key = name.lowercased()
        let speaking = keys.contains("\(key) is speaking") || keys.contains("speaking: \(key)") || keys.contains("speaking")
        let silent = keys.contains("\(key) is not speaking") || keys.contains("not speaking")
        return MeetingParticipantTile(name: name, frame: frame,
            speaking: speaking && !silent ? true : silent ? false : nil,
            muted: keys.contains("\(key)'s microphone is off") || keys.contains("microphone off") || keys.contains("microphone is off"),
            isSelf: keys.contains("your tile") || keys.contains("you") || keys.contains("\(key) (you)")
                || keys.contains("reframe") || keys.contains("backgrounds and effects")
                || keys.contains("others might see more of your background. click to view your full video."),
            sharedRoom: keys.contains(where: { $0.contains("paired") || $0.contains("conference room") || $0 == "meeting room" })
                || key.range(of: #"\b(room|boardroom)\b| & | and "#, options: .regularExpression) != nil)
    }

    static func innermostTiles(_ tiles: [MeetingParticipantTile]) -> [MeetingParticipantTile] {
        var result: [MeetingParticipantTile] = []
        for tile in tiles.sorted(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            guard !result.contains(where: {
                ParticipantObservation.nameKey($0.name) == ParticipantObservation.nameKey(tile.name) && tile.frame.contains($0.frame)
            }) else { continue }
            result.append(tile)
        }
        return result.sorted {
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.name < $1.name
        }
    }
}
