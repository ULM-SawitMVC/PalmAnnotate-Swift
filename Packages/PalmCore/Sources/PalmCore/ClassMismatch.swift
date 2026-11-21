public struct ClassMismatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let number: Int
    public let members: [(ref: BoxRef, ripeness: Ripeness)]
    public let observed: Set<Ripeness>
    public let majority: Ripeness

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.number == rhs.number && lhs.observed == rhs.observed && lhs.majority == rhs.majority
            && lhs.members.map(\.ref) == rhs.members.map(\.ref) && lhs.members.map(\.ripeness) == rhs.members.map(\.ripeness)
    }
}

extension TreeDocument {
    public func classMismatches() -> [ClassMismatch] {
        guard run.type == .multiside else { return [] }
        return clusters.enumerated().compactMap { index, cluster in
            guard cluster.count > 1 else { return nil }
            let members = cluster
                .sorted { ($0.side, boxOrder($0)) < ($1.side, boxOrder($1)) }
                .compactMap { ref in annotation(ref).map { (ref: ref, ripeness: $0.ripeness) } }
            let observed = Set(members.map(\.ripeness))
            guard observed.count > 1, let first = members.first else { return nil }
            var counts: [Ripeness: Int] = [:]
            var order: [Ripeness] = []
            for member in members {
                if counts[member.ripeness] == nil { order.append(member.ripeness) }
                counts[member.ripeness, default: 0] += 1
            }
            let majority = order.reduce(order[0]) { counts[$1]! > counts[$0]! ? $1 : $0 }
            return ClassMismatch(id: "\(first.ref.side):\(first.ref.box)", number: index + 1, members: members,
                                 observed: observed, majority: majority)
        }
    }

    public mutating func resolveClassMismatches(_ choices: [String: Ripeness] = [:]) {
        for mismatch in classMismatches() {
            let target = choices[mismatch.id] ?? mismatch.majority
            for member in mismatch.members { setRipeness(member.ref, ripeness: target) }
        }
    }

    private func boxOrder(_ ref: BoxRef) -> Int {
        sides.first { $0.id == ref.side }?.annotations.firstIndex { $0.id == ref.box } ?? 0
    }
}
