import CryptoKit
import Foundation

public enum DatasetType: String, Codable, CaseIterable, Identifiable, Sendable {
    case multiside = "MULTISIDE"
    case multisideVideo = "MULTISIDE_VIDEO"
    case bunchWeight = "BUNCH_WEIGHT"

    public var id: String { rawValue }
    public var requiresVideo: Bool { self == .multisideVideo }
    public var sideOptions: [Int] { self == .bunchWeight ? [1, 2] : [4, 8] }
    var marker: String? {
        switch self {
        case .multiside: nil
        case .multisideVideo: "VID"
        case .bunchWeight: "BW"
        }
    }
}

public enum Ripeness: Int, Codable, CaseIterable, Identifiable, Sendable {
    case unassigned = -1, b1 = 0, b2 = 1, b3 = 2, b4 = 3
    public var id: Int { rawValue }
    public var label: String { self == .unassigned ? "U" : "B\(rawValue + 1)" }
}

public struct PixelBox: Codable, Equatable, Sendable {
    public let x1: Float
    public let y1: Float
    public let x2: Float
    public let y2: Float
    public init(x1: Float, y1: Float, x2: Float, y2: Float) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    public func clipped(width: Int, height: Int) -> Self? {
        guard [x1, y1, x2, y2].allSatisfy(\.isFinite) else { return nil }
        let result = Self(
            x1: min(max(0, x1), Float(width)), y1: min(max(0, y1), Float(height)),
            x2: min(max(0, x2), Float(width)), y2: min(max(0, y2), Float(height))
        )
        return result.x2 - result.x1 >= 1 && result.y2 - result.y1 >= 1 ? result : nil
    }

    public func iou(_ other: Self) -> Float {
        let w = max(0, min(x2, other.x2) - max(x1, other.x1))
        let h = max(0, min(y2, other.y2) - max(y1, other.y1))
        let intersection = w * h
        let union = (x2 - x1) * (y2 - y1) + (other.x2 - other.x1) * (other.y2 - other.y1) - intersection
        return union > 0 ? intersection / union : 0
    }
}

public struct Measurements: Codable, Equatable, Sendable {
    public var weightKg: Double?
    public var heightCm: Double?
    public var circumferenceCm: Double?
    public var notes: String?

    public init(weightKg: Double? = nil, heightCm: Double? = nil, circumferenceCm: Double? = nil, notes: String? = nil) {
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.circumferenceCm = circumferenceCm
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = trimmed == "" ? nil : trimmed
    }

    var normalized: Self {
        Self(weightKg: weightKg, heightCm: heightCm, circumferenceCm: circumferenceCm, notes: notes)
    }

    /// Kotlin `BunchMeasurements.validationError`: weight is required, and every given value must be above zero.
    public var validationError: String? {
        guard let weightKg else { return "Berat wajib diisi." }
        guard weightKg.isFinite, weightKg > 0 else { return "Berat harus lebih dari nol." }
        guard heightCm.map({ $0.isFinite && $0 > 0 }) ?? true else { return "Tinggi harus lebih dari nol bila diisi." }
        guard circumferenceCm.map({ $0.isFinite && $0 > 0 }) ?? true else { return "Lingkar harus lebih dari nol bila diisi." }
        return nil
    }
}

public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var rect: PixelBox
    public var ripeness: Ripeness
    public var measurements: Measurements

    public init(id: String, rect: PixelBox, ripeness: Ripeness = .unassigned, measurements: Measurements = .init()) {
        self.id = id
        self.rect = rect
        self.ripeness = ripeness
        self.measurements = measurements
    }
}

public struct CaptureSide: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let width: Int
    public let height: Int
    public let sha256: String
    public var annotations: [Annotation]
    public var suggestions: [Annotation]
    var nextBoxID: Int

    public init(id: Int, width: Int, height: Int, sha256: String, suggestions: [Annotation] = []) {
        self.id = id
        self.width = width
        self.height = height
        self.sha256 = sha256
        self.suggestions = suggestions
        self.annotations = suggestions
        self.nextBoxID = 0
    }
}

public struct BoxRef: Codable, Hashable, Sendable {
    public let side: Int
    public let box: String
    public init(side: Int, box: String) {
        self.side = side
        self.box = box
    }
}

public struct CrossSideLink: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let a: BoxRef
    public let b: BoxRef
}

public struct CaptureSet: Codable, Hashable, Sendable {
    public let captureSetId: String
    public let deviceToken: String
    public var nameToken: String
}

public struct Provenance: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case fresh = "FRESH", stale = "STALE", unavailable = "UNAVAILABLE"
        case permissionDenied = "PERMISSION_DENIED", locationOff = "LOCATION_OFF", unknown = "UNKNOWN"
    }

    public var status: Status
    public let latitude: Double?
    public let longitude: Double?
    public let accuracyM: Double?
    public let fixTimeMillis: Int64?
    public var ageMs: Int64?
    public let provider: String
    public let source: String

    public init(status: Status, latitude: Double? = nil, longitude: Double? = nil, accuracyM: Double? = nil,
                fixTimeMillis: Int64? = nil, provider: String = "", source: String = "NONE") {
        self.status = status
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyM = accuracyM
        self.fixTimeMillis = fixTimeMillis
        self.provider = provider
        self.source = source
    }

    public func atCommit(_ date: Date) -> Self {
        guard let fixTimeMillis, status == .fresh || status == .stale else { return self }
        let age = Int64(date.timeIntervalSince1970 * 1000) - fixTimeMillis
        var result = self
        result.ageMs = age >= 0 ? age : nil
        result.status = status == .fresh && (0...60_000).contains(age) ? .fresh : .stale
        return result
    }
}

public struct CollectionRun: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let type: DatasetType
    public let variety: String
    public let block: String
    public var operatorName: String
    public let sideCount: Int
    public let split: String
    public var captureSet: CaptureSet
    var nextNumber: Int

    public func treeName(number: Int) -> String {
        [variety, block, type.marker, captureSet.nameToken, String(format: "%04d", number)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "_")
    }

    public var nextTreeName: String { treeName(number: nextNumber) }

    public static func sanitizedVariety(_ value: String) -> String {
        value.uppercased().replacingOccurrences(of: "[^A-Z0-9_]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    public static func sanitizedBlock(_ value: String) -> String {
        value.uppercased().replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)
    }
}

public struct VideoArtifact: Codable, Equatable, Sendable {
    public let filename: String
    public let sizeBytes: UInt64
    public let sha256: String
}

public struct TreeDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let run: CollectionRun
    public let number: Int
    public let capturedAt: Date
    public let captureDate: String
    let captureDraftID: String
    public let gps: Provenance
    public let video: VideoArtifact?
    public internal(set) var sides: [CaptureSide]
    public internal(set) var links: [CrossSideLink] = []
    public internal(set) var revision = 0
    public internal(set) var isComplete = false
    var savedAt: Date
    private var nextLinkID = 0

    public var clusters: [[BoxRef]] {
        let refs = sides.flatMap { side in side.annotations.map { BoxRef(side: side.id, box: $0.id) } }
        let indices = Dictionary(uniqueKeysWithValues: refs.enumerated().map { ($1, $0) })
        var parent = Array(refs.indices)
        var rank = Array(repeating: 0, count: refs.count)
        var members = refs.map { [$0] }
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        for link in links {
            guard let a = indices[link.a], let b = indices[link.b] else { continue }
            let ra = root(a)
            let rb = root(b)
            guard ra != rb else { continue }
            let (winner, loser) = rank[ra] < rank[rb] ? (rb, ra) : (ra, rb)
            if rank[ra] == rank[rb] { rank[winner] += 1 }
            parent[loser] = winner
            members[winner].append(contentsOf: members[loser])
            members[loser].removeAll()
        }
        return members.filter { !$0.isEmpty }
    }

    public func annotation(_ ref: BoxRef) -> Annotation? {
        sides.first { $0.id == ref.side }?.annotations.first { $0.id == ref.box }
    }

    public var completionError: String? {
        guard run.type == .bunchWeight else { return nil }
        let clusters = clusters
        if clusters.isEmpty { return "Tambahkan minimal satu kotak tandan." }
        for (index, cluster) in clusters.enumerated() {
            let values = cluster.compactMap { annotation($0)?.measurements.normalized }
            guard let first = values.first, values.allSatisfy({ $0 == first }) else {
                return "Tandan \(index + 1): ukuran dari sisi yang ditautkan berbeda."
            }
            if let error = first.validationError { return "Tandan \(index + 1): \(error)" }
        }
        return nil
    }

    @discardableResult
    public mutating func addBox(side: Int, rect: PixelBox) -> BoxRef? {
        guard sides.indices.contains(side),
              let rect = rect.clipped(width: sides[side].width, height: sides[side].height) else { return nil }
        let id = "b\(sides[side].nextBoxID)"
        sides[side].nextBoxID += 1
        sides[side].annotations.append(Annotation(id: id, rect: rect))
        return BoxRef(side: side, box: id)
    }

    public mutating func changeBox(_ ref: BoxRef, rect: PixelBox) {
        guard sides.indices.contains(ref.side),
              let rect = rect.clipped(width: sides[ref.side].width, height: sides[ref.side].height) else { return }
        edit(ref) { $0.rect = rect }
    }

    public mutating func deleteBox(_ ref: BoxRef) {
        guard sides.indices.contains(ref.side) else { return }
        sides[ref.side].annotations.removeAll { $0.id == ref.box }
        links.removeAll { $0.a == ref || $0.b == ref }
    }

    public mutating func setRipeness(_ ref: BoxRef, ripeness: Ripeness) {
        guard run.type == .multiside else { return }
        edit(ref) { $0.ripeness = ripeness }
    }

    public mutating func setMeasurements(_ ref: BoxRef, _ value: Measurements) {
        guard run.type == .bunchWeight,
              let cluster = clusters.first(where: { $0.contains(ref) }) else { return }
        let normalized = value.normalized
        for member in cluster { edit(member) { $0.measurements = normalized } }
    }

    public func canLink(_ source: BoxRef, _ target: BoxRef) -> Bool {
        let distance = abs(source.side - target.side)
        guard distance == 1 || (sides.count > 2 && distance == sides.count - 1),
              annotation(source) != nil, annotation(target) != nil else { return false }
        let (a, b) = source.side < target.side ? (source, target) : (target, source)
        return !links.contains { $0.a == a && $0.b == b }
    }

    @discardableResult
    public mutating func link(_ source: BoxRef, _ target: BoxRef) -> Bool {
        guard canLink(source, target), let sourceValue = annotation(source)?.measurements.normalized,
              let targetValue = annotation(target)?.measurements.normalized else { return false }
        let (a, b) = source.side < target.side ? (source, target) : (target, source)
        links.removeAll { $0.a.side == a.side && $0.b.side == b.side && ($0.a == a || $0.b == b) }
        links.append(CrossSideLink(id: "L\(nextLinkID)", a: a, b: b))
        nextLinkID += 1
        let value = sourceValue == Measurements() ? targetValue : sourceValue
        setMeasurements(source, value)
        return run.type == .bunchWeight && targetValue != Measurements() && targetValue != value
    }

    public mutating func unlink(_ id: String) {
        links.removeAll { $0.id == id }
    }

    private mutating func edit(_ ref: BoxRef, _ apply: (inout Annotation) -> Void) {
        guard sides.indices.contains(ref.side),
              let index = sides[ref.side].annotations.firstIndex(where: { $0.id == ref.box }) else { return }
        apply(&sides[ref.side].annotations[index])
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
