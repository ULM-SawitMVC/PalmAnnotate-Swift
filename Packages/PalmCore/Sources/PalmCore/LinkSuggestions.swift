/// AUTO at or above `autoMin`, CANDIDATE below it.
public enum LinkCategory: String, Equatable, Sendable {
    case auto, candidate

    public static let autoMin: Float = 0.75
    public static let candidateMin: Float = 0.50

    public init(score: Float) {
        self = score >= Self.autoMin ? .auto : .candidate
    }
}

public struct LinkSuggestion: Identifiable, Equatable, Sendable {
    public let a: BoxRef
    public let b: BoxRef
    public let score: Float
    public var category: LinkCategory { LinkCategory(score: score) }
    public var percent: Int { Int(score * 100) }
    public var id: String { "\(a.side):\(a.box)-\(b.side):\(b.box)" }
}

extension TreeDocument {
    /// Every unconfirmed seam match between adjacent sides, ordered by side pair. `a` is on the lower side.
    public func linkSuggestions(clockwise: Bool = true) -> [LinkSuggestion] {
        guard sides.count > 1 else { return [] }
        let pairs = sides.count == 2 ? [(0, 1)] : sides.indices.map { ($0, ($0 + 1) % sides.count) }
        var seen = Set<String>()
        var result: [LinkSuggestion] = []
        for (first, second) in pairs {
            for match in Self.seamSuggestions(a: sides[first], b: sides[second], clockwise: clockwise) {
                let (a, b) = match.a.side < match.b.side ? (match.a, match.b) : (match.b, match.a)
                guard canLink(a, b) else { continue }
                let suggestion = LinkSuggestion(a: a, b: b, score: match.score)
                if seen.insert(suggestion.id).inserted { result.append(suggestion) }
            }
        }
        return result.sorted { ($0.a.side, $0.b.side) < ($1.a.side, $1.b.side) }
    }

    public func suggestedLinks(from ref: BoxRef, clockwise: Bool = true) -> [BoxRef] {
        linkSuggestions(clockwise: clockwise).compactMap { suggestion in
            if suggestion.a == ref { return suggestion.b }
            if suggestion.b == ref { return suggestion.a }
            return nil
        }
    }

    /// A 1-based group number per linked box, numbered by the order each group's first
    /// link was confirmed, so adding a link never renumbers an existing group.
    public func linkGroups() -> [BoxRef: Int] {
        var parent: [BoxRef: BoxRef] = [:]
        func root(_ ref: BoxRef) -> BoxRef {
            var current = ref
            while let next = parent[current], next != current { current = next }
            return current
        }
        for link in links {
            for ref in [link.a, link.b] where parent[ref] == nil { parent[ref] = ref }
            let (ra, rb) = (root(link.a), root(link.b))
            if ra != rb { parent[ra] = rb }
        }
        var numbers: [BoxRef: Int] = [:]
        var next = 1
        for link in links where numbers[root(link.a)] == nil {
            numbers[root(link.a)] = next
            next += 1
        }
        return Dictionary(uniqueKeysWithValues: parent.keys.map { ($0, numbers[root($0)] ?? 1) })
    }

    /// New boxes get `det<n>` ids (one past the highest numeric suffix on the
    /// side), boxes overlapping an existing one by IoU above 0.5 are skipped, and an empty suggestion baseline
    /// is seeded with the new boxes.
    @discardableResult
    public mutating func mergeDetections(side index: Int, _ found: [Annotation]) -> [BoxRef] {
        guard sides.indices.contains(index) else { return [] }
        let width = sides[index].width
        let height = sides[index].height
        let existing = sides[index].annotations
        func suffix(_ id: String) -> Int { Int(String(id.reversed().prefix { $0.isNumber }.reversed())) ?? -1 }
        var next = (existing.map { suffix($0.id) }.max() ?? -1) + 1
        var added: [Annotation] = []
        for candidate in found {
            guard let rect = candidate.rect.clipped(width: width, height: height),
                  !existing.contains(where: { $0.rect.iou(rect) > 0.5 }) else { continue }
            added.append(Annotation(id: "det\(next)", rect: rect))
            next += 1
        }
        sides[index].annotations.append(contentsOf: added)
        if sides[index].suggestions.isEmpty { sides[index].suggestions = added }
        return added.map { BoxRef(side: index, box: $0.id) }
    }

    private struct SeamBox {
        let id: String
        let centerY: Float
        let area: Float
        let aspect: Float
        let seam: Float
        let ripeness: Int
    }

    private static func seamSuggestions(a: CaptureSide, b: CaptureSide, clockwise: Bool) -> [(a: BoxRef, b: BoxRef, score: Float)] {
        let left = seamBoxes(a, seamOnLeft: clockwise)
        let right = seamBoxes(b, seamOnLeft: !clockwise)
        var bestForLeft: [Int: (index: Int, score: Float)] = [:]
        var bestForRight: [Int: (index: Int, score: Float)] = [:]

        for (i, source) in left.enumerated() {
            for (j, target) in right.enumerated() {
                let areaRatio = min(source.area, target.area) / max(source.area, target.area)
                guard areaRatio >= 0.30 else { continue }
                let aspectRatio = min(source.aspect, target.aspect) / max(source.aspect, target.aspect)
                let vertical = 1 - min(1, abs(source.centerY - target.centerY) / 0.20)
                let seam = (source.seam + target.seam) / 2
                let size = 0.6 * areaRatio + 0.4 * aspectRatio
                let gap = abs(source.ripeness - target.ripeness)
                let multiplier: Float = gap == 0 ? 1 : (gap == 1 ? 0.85 : 0.5)
                let score = (0.45 * seam + 0.35 * vertical + 0.20 * size) * multiplier
                guard score >= LinkCategory.candidateMin else { continue }
                if score > (bestForLeft[i]?.score ?? 0) { bestForLeft[i] = (j, score) }
                if score > (bestForRight[j]?.score ?? 0) { bestForRight[j] = (i, score) }
            }
        }

        return left.indices.compactMap { i in
            guard let j = bestForLeft[i]?.index, bestForRight[j]?.index == i else { return nil }
            let score = bestForLeft[i]?.score ?? 0
            return (BoxRef(side: a.id, box: left[i].id), BoxRef(side: b.id, box: right[j].id), score)
        }
    }

    private static func seamBoxes(_ side: CaptureSide, seamOnLeft: Bool) -> [SeamBox] {
        guard side.width > 0, side.height > 0 else { return [] }
        return side.annotations.compactMap { annotation in
            let rect = annotation.rect
            let centerX = (rect.x1 + rect.x2) / (2 * Float(side.width))
            let distance = seamOnLeft ? centerX : 1 - centerX
            guard distance <= 0.5 else { return nil }
            let w = (rect.x2 - rect.x1) / Float(side.width)
            let h = (rect.y2 - rect.y1) / Float(side.height)
            return SeamBox(id: annotation.id, centerY: (rect.y1 + rect.y2) / (2 * Float(side.height)),
                           area: max(w * h, 1e-6), aspect: max(w / max(h, 1e-6), 1e-6),
                           seam: 1 - 2 * distance, ripeness: annotation.ripeness.rawValue)
        }
    }
}
