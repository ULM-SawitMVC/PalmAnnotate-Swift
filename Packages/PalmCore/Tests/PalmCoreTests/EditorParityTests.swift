import Foundation
import PalmCore
import Testing

@Suite struct EditorParityTests {
    private let photo = CapturedPhoto(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1000, height: 1000)

    // MARK: Suggestion categories

    @Test func categoryThresholdsMatchKotlin() {
        #expect(LinkCategory.autoMin == 0.75)
        #expect(LinkCategory.candidateMin == 0.50)
        #expect(LinkCategory(score: 0.75) == .auto)
        #expect(LinkCategory(score: 0.9999) == .auto)
        #expect(LinkCategory(score: 0.7499) == .candidate)
        #expect(LinkCategory(score: 0.50) == .candidate)
    }

    @Test func seamMatchIsAutoWithPercent() async throws {
        try await withTree { tree in
            tree.addBox(side: 0, rect: PixelBox(x1: 0, y1: 400, x2: 100, y2: 600))
            tree.addBox(side: 1, rect: PixelBox(x1: 900, y1: 400, x2: 1000, y2: 600))
            let suggestions = tree.linkSuggestions()
            #expect(suggestions.count == 1)
            let found = try #require(suggestions.first)
            #expect(found.category == .auto)
            #expect(found.percent == 95)
            #expect(found.a.side == 0 && found.b.side == 1)
        }
    }

    @Test func weakerSeamMatchIsCandidate() async throws {
        try await withTree { tree in
            tree.addBox(side: 0, rect: PixelBox(x1: 300, y1: 400, x2: 400, y2: 600))
            tree.addBox(side: 1, rect: PixelBox(x1: 600, y1: 400, x2: 700, y2: 600))
            let found = try #require(tree.linkSuggestions().first)
            #expect(found.category == .candidate)
            #expect(found.score >= LinkCategory.candidateMin && found.score < LinkCategory.autoMin)
            #expect(found.percent == 68)
        }
    }

    @Test func classGapDropsAMatchBelowTheCandidateFloor() async throws {
        try await withTree { tree in
            let a = try add(&tree, 0, PixelBox(x1: 0, y1: 400, x2: 100, y2: 600))
            let b = try add(&tree, 1, PixelBox(x1: 900, y1: 400, x2: 1000, y2: 600))
            tree.setRipeness(a, ripeness: .b1)
            tree.setRipeness(b, ripeness: .b2)
            #expect(tree.linkSuggestions().first?.category == .auto)
            tree.setRipeness(b, ripeness: .b4)
            #expect(tree.linkSuggestions().isEmpty)
        }
    }

    @Test func confirmedPairsAreNotSuggestedAgain() async throws {
        try await withTree { tree in
            let a = try add(&tree, 0, PixelBox(x1: 0, y1: 400, x2: 100, y2: 600))
            let b = try add(&tree, 1, PixelBox(x1: 900, y1: 400, x2: 1000, y2: 600))
            #expect(tree.suggestedLinks(from: a) == [b])
            tree.link(a, b)
            #expect(tree.linkSuggestions().isEmpty)
            #expect(tree.suggestedLinks(from: a).isEmpty)
        }
    }

    // MARK: Link groups

    @Test func linkGroupsFollowConfirmationOrder() async throws {
        try await withTree { tree in
            let a0 = try add(&tree, 0, PixelBox(x1: 0, y1: 0, x2: 100, y2: 100))
            let a1 = try add(&tree, 0, PixelBox(x1: 0, y1: 500, x2: 100, y2: 600))
            let b0 = try add(&tree, 1, PixelBox(x1: 900, y1: 0, x2: 1000, y2: 100))
            let b1 = try add(&tree, 1, PixelBox(x1: 900, y1: 500, x2: 1000, y2: 600))
            let c0 = try add(&tree, 2, PixelBox(x1: 0, y1: 0, x2: 100, y2: 100))
            #expect(tree.linkGroups().isEmpty)
            tree.link(a1, b1)
            #expect(tree.linkGroups() == [a1: 1, b1: 1])
            tree.link(a0, b0)
            #expect(tree.linkGroups()[a0] == 2 && tree.linkGroups()[b0] == 2)
            #expect(tree.linkGroups()[a1] == 1, "an earlier group keeps its number")
            tree.link(b0, c0)
            #expect(tree.linkGroups()[c0] == 2, "a chain joins the group of its first link")
        }
    }

    // MARK: Detection merge

    @Test func detectionsGetUniqueIdsSkipOverlapsAndSeedTheBaseline() async throws {
        try await withTree { tree in
            tree.addBox(side: 0, rect: PixelBox(x1: 100, y1: 100, x2: 300, y2: 300))
            #expect(tree.sides[0].suggestions.isEmpty)
            let found = [
                Annotation(id: "det0", rect: PixelBox(x1: 110, y1: 110, x2: 300, y2: 300)),
                Annotation(id: "det1", rect: PixelBox(x1: 500, y1: 500, x2: 700, y2: 700)),
                Annotation(id: "det2", rect: PixelBox(x1: 800, y1: 100, x2: 900, y2: 200)),
            ]
            let added = tree.mergeDetections(side: 0, found)
            #expect(added.map(\.box) == ["det1", "det2"])
            #expect(tree.sides[0].annotations.map(\.id) == ["b0", "det1", "det2"])
            #expect(tree.sides[0].suggestions.map(\.id) == ["det1", "det2"])

            let again = tree.mergeDetections(side: 0, [Annotation(id: "det0", rect: PixelBox(x1: 10, y1: 800, x2: 90, y2: 900))])
            #expect(again.map(\.box) == ["det3"])
            #expect(tree.sides[0].suggestions.map(\.id) == ["det1", "det2"])
        }
    }

    // MARK: Class mismatches

    @Test func mismatchMajorityTieAndResolution() async throws {
        try await withTree { tree in
            let a = try add(&tree, 0, PixelBox(x1: 0, y1: 0, x2: 100, y2: 100))
            let b = try add(&tree, 1, PixelBox(x1: 900, y1: 0, x2: 1000, y2: 100))
            let c = try add(&tree, 2, PixelBox(x1: 0, y1: 0, x2: 100, y2: 100))
            tree.link(a, b)
            #expect(tree.classMismatches().isEmpty)
            tree.setRipeness(a, ripeness: .b3)
            tree.setRipeness(b, ripeness: .b2)
            var mismatch = try #require(tree.classMismatches().first)
            #expect(mismatch.members.map(\.ref) == [a, b])
            #expect(mismatch.observed == [.b3, .b2])
            #expect(mismatch.majority == .b3, "a tie goes to the class of the first member")
            tree.link(b, c)
            tree.setRipeness(c, ripeness: .b2)
            mismatch = try #require(tree.classMismatches().first)
            #expect(mismatch.majority == .b2)

            var chosen = tree
            chosen.resolveClassMismatches([mismatch.id: .b4])
            #expect([a, b, c].allSatisfy { chosen.annotation($0)?.ripeness == .b4 })
            #expect(chosen.classMismatches().isEmpty)

            tree.resolveClassMismatches()
            #expect([a, b, c].allSatisfy { tree.annotation($0)?.ripeness == .b2 })
        }
    }

    // MARK: Hit testing

    @Test func hitTestPrefersTheSmallestContainingBoxThenTheNearestWithinTolerance() {
        let big = Annotation(id: "big", rect: PixelBox(x1: 0, y1: 0, x2: 200, y2: 200))
        let small = Annotation(id: "small", rect: PixelBox(x1: 50, y1: 50, x2: 100, y2: 100))
        let far = Annotation(id: "far", rect: PixelBox(x1: 300, y1: 0, x2: 400, y2: 100))
        #expect(BoxHitTest.pick([big, small], x: 60, y: 60, tolerance: 10) == "small")
        #expect(BoxHitTest.pick([big, far], x: 150, y: 150, tolerance: 10) == "big")
        #expect(BoxHitTest.pick([big, far], x: 290, y: 50, tolerance: 10) == "far")
        #expect(BoxHitTest.pick([big, far], x: 289, y: 50, tolerance: 10) == nil)
        #expect(BoxHitTest.pick([big, far], x: 250, y: 50, tolerance: 60) == "far")
        #expect(BoxHitTest.pick([], x: 0, y: 0, tolerance: 24) == nil)
    }

    // MARK: Measurement input and validation

    @Test func validationMessagesSeparateRequiredAndNonPositive() {
        #expect(Measurements().validationError == "Berat wajib diisi.")
        #expect(Measurements(weightKg: 0).validationError == "Berat harus lebih dari nol.")
        #expect(Measurements(weightKg: -1).validationError == "Berat harus lebih dari nol.")
        #expect(Measurements(weightKg: 2, heightCm: 0).validationError == "Tinggi harus lebih dari nol bila diisi.")
        #expect(Measurements(weightKg: 2, circumferenceCm: -3).validationError == "Lingkar harus lebih dari nol bila diisi.")
        #expect(Measurements(weightKg: 2).validationError == nil)
    }

    @Test func parseAcceptsCommaAndKeepsEmptyOptionalsNil() throws {
        let value = try Measurements.parse(weight: " 12,5 ", height: "", circumference: " ", notes: "  ")
        #expect(value == Measurements(weightKg: 12.5))
        #expect(value.heightCm == nil && value.circumferenceCm == nil && value.notes == nil)
        let full = try Measurements.parse(weight: "3", height: "40,5", circumference: "100", notes: " Grade A ")
        #expect(full == Measurements(weightKg: 3, heightCm: 40.5, circumferenceCm: 100, notes: "Grade A"))
    }

    @Test(arguments: [
        ("", "", "", "Berat wajib diisi."),
        ("abc", "", "", "Berat harus berupa angka."),
        ("0", "", "", "Berat harus lebih dari nol."),
        ("1.2.3", "", "", "Berat harus berupa angka."),
        ("5", "x", "", "Tinggi harus berupa angka."),
        ("5", "0", "", "Tinggi harus lebih dari nol bila diisi."),
        ("5", "", "y", "Lingkar harus berupa angka."),
        ("5", "", "-2", "Lingkar harus lebih dari nol bila diisi."),
    ])
    func parseReportsTheFirstProblem(weight: String, height: String, circumference: String, message: String) {
        #expect(throws: Measurements.InputError(message: message)) {
            try Measurements.parse(weight: weight, height: height, circumference: circumference, notes: "")
        }
    }

    // MARK: Helpers

    private func add(_ tree: inout TreeDocument, _ side: Int, _ rect: PixelBox) throws -> BoxRef {
        let ref = tree.addBox(side: side, rect: rect)
        return try #require(ref)
    }

    private func withTree(_ body: (inout TreeDocument) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PackageStore(root: directory)
        let run = try await store.createRun(type: .multiside, variety: "DAMIMAS", block: "QA", operatorName: "",
                                            sideCount: 4, split: "field", tokenized: false)
        for side in 0..<4 { try await store.saveDraftPhoto(photo, runID: run.id, side: side) }
        var tree = try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable))
        try await body(&tree)
    }
}
