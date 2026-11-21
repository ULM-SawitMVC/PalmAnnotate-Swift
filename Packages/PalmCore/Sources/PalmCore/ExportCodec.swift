import Foundation

public enum ExportCodec {
    public static func readOutput(_ data: Data) throws -> LegacyOutput {
        let bom = Data([0xEF, 0xBB, 0xBF])
        return try JSONDecoder().decode(LegacyOutput.self, from: data.starts(with: bom) ? Data(data.dropFirst(3)) : data)
    }

    public static func output(_ tree: TreeDocument, generatedAt: Date) throws -> Data {
        let clusters = tree.clusters
        let weighted = tree.run.type == .bunchWeight
        let date = tree.captureDate
        var metadata: [String: Any] = [
            "date": date, "number": tree.number, "generated_at": iso(generatedAt),
            "variety": tree.run.variety, "operator": operatorName(tree),
            "gps_status": tree.gps.status.rawValue,
            "session_id": [date.filter(\.isNumber), tree.run.variety.uppercased(), tree.run.block.uppercased(),
                           tree.run.captureSet.deviceToken.uppercased()].filter { !$0.isEmpty }.joined(separator: "-")
        ]
        if !tree.run.captureSet.captureSetId.isEmpty { metadata["capture_set_id"] = tree.run.captureSet.captureSetId }
        if !tree.run.captureSet.deviceToken.isEmpty { metadata["device_token"] = tree.run.captureSet.deviceToken }
        var images: [String: Any] = [:]
        var counts: [String: Int] = [:]
        for side in tree.sides {
            let key = "side_\(side.id + 1)"
            let stem = "\(tree.id)_\(side.id + 1)"
            counts[key] = side.annotations.count
            var image: [String: Any] = [
                "filename": "\(stem).jpg", "label_file": "\(stem).txt", "side_index": side.id,
                "side_label": "Side \(side.id + 1)", "width": side.width, "height": side.height,
                "bbox_count": side.annotations.count,
                "capture_origin": "PHONE_CAMERA", "depth_required": false,
                "annotations": side.annotations.enumerated().map { index, annotation -> [String: Any] in
                    var entry: [String: Any] = [
                        "box_index": index, "bbox_pixel": pixel(annotation.rect),
                        "bbox_yolo": yolo(annotation.rect, side: side).map { $0.isFinite ? Double(fixed($0)) ?? 0 : 0 }
                    ]
                    if !weighted {
                        entry["class_id"] = annotation.ripeness.rawValue
                        entry["class_name"] = annotation.ripeness.label
                    }
                    entry.merge(measurements(annotation.measurements)) { _, new in new }
                    return entry
                }
            ]
            if side.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil {
                image["rgb_sha256"] = side.sha256.lowercased()
            }
            images[key] = image
        }
        let bunches = clusters.enumerated().map { index, cluster -> [String: Any] in
            let boxes = cluster.compactMap(tree.annotation)
            var bunch: [String: Any] = [
                "bunch_id": index + 1, "appearance_count": cluster.count,
                "appearances": cluster.sorted { $0.side < $1.side }.compactMap { ref -> [String: Any]? in
                    guard let box = tree.annotation(ref), let index = boxIndex(tree, ref) else { return nil }
                    var result: [String: Any] = [
                        "side": "side_\(ref.side + 1)", "side_index": ref.side,
                        "box_index": index, "bbox_pixel": pixel(box.rect)
                    ]
                    if !weighted { result["class_name"] = box.ripeness.label }
                    return result
                }
            ]
            if !weighted {
                bunch["class"] = dominant(boxes).label
                bunch["class_mismatch"] = Set(boxes.map(\.ripeness)).count > 1
            }
            if let first = boxes.first { bunch.merge(measurements(first.measurements)) { _, new in new } }
            return bunch
        }
        var seenLinks: [BoxRef: Set<BoxRef>] = [:]
        let links = tree.links.compactMap { link -> [String: Any]? in
            let (low, high) = link.a.side < link.b.side ? (link.a, link.b) : (link.b, link.a)
            let wrap = tree.sides.count > 2 && low.side == 0 && high.side == tree.sides.count - 1
            guard wrap || high.side - low.side == 1 else { return nil }
            let (a, b) = wrap ? (high, low) : (low, high)
            guard let ia = boxIndex(tree, a), let ib = boxIndex(tree, b) else { return nil }
            guard seenLinks[a, default: []].insert(b).inserted else { return nil }
            return ["linkId": link.id, "sideA": a.side, "bboxIdA": "b\(ia)", "sideB": b.side, "bboxIdB": "b\(ib)"]
        }
        let rawCount = counts.values.reduce(0, +)
        var summary: [String: Any] = [
            "total_unique_bunches": clusters.count, "total_detections": rawCount,
            "duplicates_linked": rawCount - clusters.count, "by_side": counts
        ]
        if !weighted {
            let counts = classCounts(tree)
            summary["by_class"] = Dictionary(uniqueKeysWithValues: Ripeness.allCases.map {
                ($0 == .unassigned ? "other" : $0.label, counts[$0, default: 0])
            })
        }
        return try json([
            "version": 4, "tree_id": tree.id, "tree_name": tree.id, "split": tree.run.split,
            "dataset_type": tree.run.type.rawValue, "metadata": metadata, "images": images,
            "bunches": bunches, "_confirmedLinks": links, "summary": summary
        ])
    }

    public static func labels(_ side: CaptureSide, type: DatasetType) -> Data {
        guard side.width > 0, side.height > 0 else { return Data() }
        let weighted = type == .bunchWeight
        let lines = side.annotations.compactMap { box -> String? in
            guard weighted || box.ripeness != .unassigned else { return nil }
            let coordinates = yolo(box.rect, side: side).map { fixed(min(max($0, 0), 1)) }
            return ([String(weighted ? 0 : box.ripeness.rawValue)] + coordinates)
                .joined(separator: " ")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    public static func csv(_ tree: TreeDocument) -> Data {
        func row(_ fields: [String]) -> String {
            fields.map { field in
                field.rangeOfCharacter(from: CharacterSet(charactersIn: ",\"\r\n")) != nil
                    ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: ",")
        }
        let clusters = tree.clusters
        if tree.run.type == .bunchWeight {
            let header = "sample_name,split,bunch_id,appearance_count,weight_kg,height_cm,circumference_cm,notes"
            let rows = clusters.enumerated().map { index, cluster in
                let value = cluster.first.flatMap(tree.annotation)?.measurements.normalized ?? Measurements()
                return row([tree.id, tree.run.split, String(index + 1), String(cluster.count),
                            decimal(value.weightKg), decimal(value.heightCm), decimal(value.circumferenceCm), value.notes ?? ""])
            }
            return Data(([header] + rows).joined(separator: "\n").utf8)
        }
        let counts = classCounts(tree)
        let fields = [tree.id, tree.run.split, String(clusters.count), String(clusters.flatMap { $0 }.count)]
            + [Ripeness.b1, .b2, .b3, .b4].map { String(counts[$0, default: 0]) }
        return Data(("tree_name,split,unique,raw,B1,B2,B3,B4\n" + row(fields)).utf8)
    }

    public static func identity(_ tree: TreeDocument) throws -> Data {
        let weighted = tree.run.type == .bunchWeight
        var mismatches = 0
        let bunches = tree.clusters.enumerated().map { index, cluster -> [String: Any] in
            let boxes = cluster.compactMap(tree.annotation)
            let mismatch = Set(boxes.map(\.ripeness)).count > 1
            if mismatch { mismatches += 1 }
            var bunch: [String: Any] = ["id": index + 1, "detections": cluster.compactMap { ref -> [String: Any]? in
                guard let box = tree.annotation(ref) else { return nil }
                var detection: [String: Any] = ["side": ref.side, "bboxId": ref.box,
                    "coords": [box.rect.x1, box.rect.y1, box.rect.x2, box.rect.y2].map(jsonFloat)]
                if !weighted { detection["class"] = box.ripeness.label }
                return detection
            }]
            if weighted, let first = boxes.first { bunch.merge(measurements(first.measurements)) { _, new in new } }
            if !weighted { bunch["classMismatch"] = mismatch }
            return bunch
        }
        var result: [String: Any] = ["tree_name": tree.id, "totalUniqueBunches": bunches.count, "bunches": bunches]
        if weighted { result["dataset_type"] = tree.run.type.rawValue }
        else { result["classMismatchCount"] = mismatches }
        return try json(result)
    }

    public static func classCounts(_ tree: TreeDocument) -> [Ripeness: Int] {
        Dictionary(grouping: tree.clusters.map { dominant($0.compactMap(tree.annotation)) }, by: { $0 }).mapValues(\.count)
    }

    static func metadata(_ tree: TreeDocument, generatedAt: Date) throws -> Data {
        var gps: [String: Any] = ["status": tree.gps.status.rawValue, "source": tree.gps.source, "provider": tree.gps.provider]
        gps["lat"] = tree.gps.latitude
        gps["lng"] = tree.gps.longitude
        gps["accuracyM"] = tree.gps.accuracyM.map { Double(Float($0)) }
        gps["fixEpochMs"] = tree.gps.fixTimeMillis
        gps["ageMs"] = tree.gps.ageMs
        if let millis = tree.gps.fixTimeMillis { gps["fixTimestamp"] = iso(Date(timeIntervalSince1970: Double(millis) / 1000)) }
        var artifacts: [String: Any] = ["sides": tree.sides.sorted { $0.id < $1.id }.map { side in
            ["sideIndex": side.id, "filename": "\(tree.id)_\(side.id + 1).jpg", "rgbSha256": side.sha256,
             "captureOrigin": "PHONE_CAMERA", "depthRequired": false] as [String: Any]
        }]
        if let video = tree.video { artifacts["video"] = ["filename": video.filename, "sizeBytes": video.sizeBytes, "sha256": video.sha256] }
        var result: [String: Any] = [
            "artifactSchemaVersion": 1, "name": tree.id, "variety": tree.run.variety, "blok": tree.run.block,
            "treeId": tree.number, "operator": operatorName(tree), "timestamp": iso(generatedAt),
            "captureDate": tree.captureDate, "captureSet": captureSet(tree.run.captureSet),
            "gps": gps, "artifacts": artifacts
        ]
        if let lat = tree.gps.latitude, let lng = tree.gps.longitude {
            result["lat"] = lat
            result["lng"] = lng
        }
        return try json(result)
    }

    public static func annotLog(_ tree: TreeDocument, side: CaptureSide) throws -> Data {
        let weighted = tree.run.type == .bunchWeight
        func boxes(_ items: [Annotation]) -> [[String: Any]] {
            items.map {
                var value: [String: Any] = ["id": $0.id, "bbox_pixel": pixel($0.rect)]
                if !weighted {
                    value["classId"] = $0.ripeness.rawValue
                    value["className"] = $0.ripeness.label
                }
                return value
            }
        }
        var result: [String: Any] = [
            "treeName": tree.id, "sideIndex": side.id, "split": tree.run.split,
            "savedAt": Int64(tree.savedAt.timeIntervalSince1970 * 1000),
            "suggestions": boxes(side.suggestions), "final": boxes(side.annotations)
        ]
        if weighted { result["datasetType"] = tree.run.type.rawValue }
        return try json(result)
    }

    static func manifest(_ tree: TreeDocument, output: Data, metadata: Data, labels: [Data]) throws -> Data {
        let outputHash = sha256(output)
        let sides = zip(tree.sides, labels).sorted { $0.0.id < $1.0.id }
        let labelHashes = sides.map { sha256($0.1) }
        return try json([
            "schemaVersion": 1, "treeName": tree.id, "captureSet": captureSet(tree.run.captureSet),
            "captureSetId": sha256(Data(sides.map { "\($0.0.id):\($0.0.sha256.lowercased())" }.joined(separator: "|").utf8)),
            "annotationRevision": sha256(Data(([outputHash] + labelHashes).joined(separator: "|").utf8)),
            "outputJson": ["file": "\(tree.id).json", "sha256": outputHash],
            "metadata": ["file": "\(tree.id).json", "sha256": sha256(metadata)],
            "sides": sides.enumerated().map { offset, entry -> [String: Any] in
                let side = entry.0
                let stem = "\(tree.id)_\(side.id + 1)"
                return ["sideIndex": side.id, "captureOrigin": "PHONE_CAMERA", "depthRequired": false,
                        "rgb": ["file": stem + ".jpg", "sha256": side.sha256.lowercased()],
                        "label": ["file": stem + ".txt", "sha256": labelHashes[offset]]]
            }
        ])
    }

    static func captureSet(_ value: CaptureSet) -> [String: Any] {
        ["schema": 1, "captureSetId": value.captureSetId, "deviceToken": value.deviceToken, "nameToken": value.nameToken]
    }

    static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func iso(_ date: Date, fractionalSeconds: Bool = true) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if fractionalSeconds { formatter.formatOptions.insert(.withFractionalSeconds) }
        return formatter.string(from: date)
    }

    static func archiveTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func captureDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func operatorName(_ tree: TreeDocument) -> String {
        let name = tree.run.operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "UNKNOWN" : name
    }

    private static func boxIndex(_ tree: TreeDocument, _ ref: BoxRef) -> Int? {
        tree.sides.first { $0.id == ref.side }?.annotations.firstIndex { $0.id == ref.box }
    }

    private static func dominant(_ boxes: [Annotation]) -> Ripeness {
        let counts = Dictionary(grouping: boxes, by: \.ripeness).mapValues(\.count)
        let highest = counts.values.max()
        return boxes.first { counts[$0.ripeness] == highest }?.ripeness ?? .unassigned
    }

    private static func measurements(_ value: Measurements) -> [String: Any] {
        var result: [String: Any] = [:]
        result["weight_kg"] = value.weightKg
        result["height_cm"] = value.heightCm
        result["circumference_cm"] = value.circumferenceCm
        result["notes"] = value.normalized.notes
        return result
    }

    private static func pixel(_ box: PixelBox) -> [Int] {
        [box.x1, box.y1, box.x2, box.y2].map { Int(floor(Double($0) + 0.5)) }
    }

    /// Kotlin boxes a `Float` into org.json, which prints `Float.toString`, the shortest decimal that
    /// round-trips the 32-bit value. Widening to `Double` first would print `12.100000381469727`.
    private static func jsonFloat(_ value: Float) -> Double {
        value.isFinite ? Double("\(value)") ?? Double(value) : 0
    }

    private static func yolo(_ box: PixelBox, side: CaptureSide) -> [Float] {
        let w = Float(side.width)
        let h = Float(side.height)
        return [(box.x1 + box.x2) / 2 / w, (box.y1 + box.y2) / 2 / h, (box.x2 - box.x1) / w, (box.y2 - box.y1) / h]
    }

    private static func fixed(_ value: Float) -> String {
        let scaled = (Double(value) * 1_000_000).rounded()
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), scaled / 1_000_000)
    }

    private static func decimal(_ value: Double?) -> String {
        guard let value else { return "" }
        guard value != 0, value.isFinite, abs(value) < 0.001 || abs(value) >= 10_000_000 else {
            return String(value)
        }
        let parts = String(abs(value)).lowercased().split(separator: "e")
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let fields = parts[0].split(separator: ".")
        let digits = Array(fields.joined())
        guard let first = digits.firstIndex(where: { $0 != "0" }),
              let last = digits.lastIndex(where: { $0 != "0" }) else { return String(value) }
        let fraction = first < last ? String(digits[(first + 1)...last]) : "0"
        let sign = value < 0 ? "-" : ""
        return "\(sign)\(digits[first]).\(fraction)E\(exponent + fields[0].count - first - 1)"
    }
}

public struct LegacyOutput: Decodable, Sendable {
    public struct Side: Decodable, Sendable {
        public struct Box: Decodable, Sendable {
            public let box_index: Int
            public let bbox_pixel: [Int]
        }
        public let side_index: Int
        public let width: Int
        public let height: Int
        public let annotations: [Box]
    }

    public struct Link: Decodable, Sendable {
        public let sideA: Int
        public let sideB: Int
        public let bboxIdA: String
        public let bboxIdB: String
    }

    public let version: Int
    public let tree_name: String
    public let dataset_type: DatasetType?
    public let images: [String: Side]
    public let _confirmedLinks: [Link]
}
