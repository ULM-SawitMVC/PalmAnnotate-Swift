extension TreeDocument {
    public func suggestedLinks(from ref: BoxRef, clockwise: Bool = true) -> [BoxRef] {
        guard sides.count > 1, sides.indices.contains(ref.side) else { return [] }
        let pairs = sides.count == 2 ? [(0, 1)] : sides.indices.map { ($0, ($0 + 1) % sides.count) }
        return pairs.filter { $0.0 == ref.side || $0.1 == ref.side }.flatMap { a, b in
            Self.seamSuggestions(a: sides[a], b: sides[b], clockwise: clockwise).compactMap { pair in
                let target: BoxRef
                if pair.0 == ref { target = pair.1 }
                else if pair.1 == ref { target = pair.0 }
                else { return nil }
                return canLink(ref, target) ? target : nil
            }
        }
    }

    private struct SeamBox {
        let id: String
        let centerY: Float
        let area: Float
        let aspect: Float
        let seam: Float
        let ripeness: Int
    }

    private static func seamSuggestions(a: CaptureSide, b: CaptureSide, clockwise: Bool) -> [(BoxRef, BoxRef)] {
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
                guard score >= 0.50 else { continue }
                if score > (bestForLeft[i]?.score ?? 0) { bestForLeft[i] = (j, score) }
                if score > (bestForRight[j]?.score ?? 0) { bestForRight[j] = (i, score) }
            }
        }

        return left.indices.compactMap { i in
            guard let j = bestForLeft[i]?.index, bestForRight[j]?.index == i else { return nil }
            return (BoxRef(side: a.id, box: left[i].id), BoxRef(side: b.id, box: right[j].id))
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
