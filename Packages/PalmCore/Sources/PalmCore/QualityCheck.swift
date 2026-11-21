import Foundation

public enum QualityCheck {
    public enum Level: String, Sendable {
        case ok = "OK", info = "INFO", warn = "WARN", error = "ERROR"
    }

    public struct Issue: Equatable, Sendable {
        public let code: String
        public let level: Level
        public let message: String
    }

    public struct Report: Equatable, Sendable {
        public let status: Level
        public let metrics: [String: Int]
        public let issues: [Issue]

        public var needsReview: Bool { status != .ok }
    }

    public static func analyzeCaptureShots(capturedSides: Int, expectedSides: Int, depthSides: Int,
                                           requiredDepthSides: Int? = nil, hasGps: Bool,
                                           hasVariety: Bool, hasBlock: Bool) -> Report {
        let requiredDepthSides = requiredDepthSides ?? capturedSides
        var issues: [Issue] = []
        if capturedSides < expectedSides {
            issues.append(Issue(code: "capture_view_missing", level: .error,
                message: "Hanya \(capturedSides) dari \(expectedSides) sisi yang berhasil ditangkap."))
        }
        if depthSides < requiredDepthSides {
            issues.append(Issue(code: "capture_rgb_depth_incomplete", level: .warn,
                message: "Hanya \(depthSides) dari \(requiredDepthSides) foto Orbbec yang memiliki data depth."))
        }
        if !hasGps {
            issues.append(Issue(code: "metadata_gps_missing", level: .warn,
                message: "Lokasi GPS tidak tersedia. Tambahkan GPS untuk metadata yang lebih lengkap."))
        }
        if !hasVariety {
            issues.append(Issue(code: "metadata_variety_missing", level: .error, message: "Metadata variety belum terisi."))
        }
        if !hasBlock {
            issues.append(Issue(code: "metadata_block_missing", level: .warn, message: "Metadata block belum terisi."))
        }
        return Report(status: status(issues), metrics: [
            "capturedSides": capturedSides,
            "expectedSides": expectedSides,
            "depthSides": depthSides,
            "requiredDepthSides": requiredDepthSides,
        ], issues: issues)
    }

    public static func analyzeCapture(run: CollectionRun, capturedSides: Int, gps: Provenance) -> Report {
        analyzeCaptureShots(
            capturedSides: capturedSides,
            expectedSides: run.type == .bunchWeight ? capturedSides : run.sideCount,
            depthSides: 0, requiredDepthSides: 0,
            hasGps: gps.latitude != nil && gps.longitude != nil,
            hasVariety: !isBlank(run.variety), hasBlock: !isBlank(run.block)
        )
    }

    public static func analyzeTree(_ tree: TreeDocument) -> Report {
        var issues: [Issue] = []
        let sides = tree.sides
        if isBlank(tree.run.variety) {
            issues.append(Issue(code: "metadata_variety_missing", level: .error, message: "Metadata variety belum terisi."))
        }
        if isBlank(tree.run.block) {
            issues.append(Issue(code: "metadata_block_missing", level: .warn, message: "Metadata block belum terisi."))
        }
        let sidesWithImages = sides.filter { !$0.sha256.isEmpty }.count
        if sidesWithImages < sides.count {
            issues.append(Issue(code: "image_missing", level: .warn,
                message: "\(sides.count - sidesWithImages) sisi tidak memiliki gambar."))
        }
        let emptySides = sides.filter(\.annotations.isEmpty).count
        if emptySides > 0 {
            issues.append(Issue(code: "annotation_empty", level: .warn,
                message: "\(emptySides) sisi belum memiliki anotasi bbox."))
        }
        let boxes = sides.flatMap(\.annotations)
        let unassigned = tree.run.type == .bunchWeight ? 0 : boxes.filter { $0.ripeness == .unassigned }.count
        if unassigned > 0 {
            issues.append(Issue(code: "annotation_unassigned", level: .warn,
                message: "\(unassigned) bbox belum diberi kelas (unassigned)."))
        }
        let tiny = boxes.filter { ($0.rect.x2 - $0.rect.x1) * ($0.rect.y2 - $0.rect.y1) < 100 }.count
        if tiny > 0 {
            issues.append(Issue(code: "annotation_tiny_bbox", level: .info,
                message: "\(tiny) bbox sangat kecil (< 10×10 px). Periksa apakah sudah benar."))
        }
        let mismatches = tree.clusters.filter { cluster in
            cluster.count > 1 && Set(cluster.compactMap { tree.annotation($0)?.ripeness }).count > 1
        }.count
        if mismatches > 0 {
            issues.append(Issue(code: "annotation_class_mismatch", level: .error,
                message: "\(mismatches) bunch memiliki kelas yang tidak konsisten antar sisi."))
        }
        if sides.count > 1 && boxes.count > 1 && tree.links.isEmpty {
            issues.append(Issue(code: "annotation_no_links", level: .warn,
                message: "Belum ada link cross-side. Gunakan Dedup untuk menghubungkan bunch yang sama."))
        }
        return Report(status: status(issues), metrics: [
            "totalSides": sides.count,
            "totalBboxes": boxes.count,
            "unassigned": unassigned,
            "links": tree.links.count,
            "mismatches": mismatches,
        ], issues: issues)
    }

    private static func status(_ issues: [Issue]) -> Level {
        if issues.contains(where: { $0.level == .error }) { return .error }
        if issues.contains(where: { $0.level == .warn }) { return .warn }
        return .ok
    }

    private static func isBlank(_ value: String) -> Bool {
        value.allSatisfy(\.isWhitespace)
    }
}
