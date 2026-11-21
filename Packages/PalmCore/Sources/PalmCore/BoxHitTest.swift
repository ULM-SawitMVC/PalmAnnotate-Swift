public enum BoxHitTest {
    public static func pick(_ boxes: [Annotation], x: Float, y: Float, tolerance: Float) -> String? {
        var best: Annotation?
        var bestArea = Float.greatestFiniteMagnitude
        for box in boxes {
            let rect = box.rect
            let area = (rect.x2 - rect.x1) * (rect.y2 - rect.y1)
            if x >= rect.x1, x <= rect.x2, y >= rect.y1, y <= rect.y2, area < bestArea {
                best = box
                bestArea = area
            }
        }
        if let best { return best.id }
        var bestDistance = tolerance
        for box in boxes {
            let rect = box.rect
            let dx = max(rect.x1 - x, 0, x - rect.x2)
            let dy = max(rect.y1 - y, 0, y - rect.y2)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= bestDistance {
                bestDistance = distance
                best = box
            }
        }
        return best?.id
    }
}
