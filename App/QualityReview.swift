import PalmCore
import SwiftUI

/// Port of Kotlin `QualityGateModal`. The operator reads every issue, then either returns to fix the
/// sample or continues. No level blocks the action, matching Kotlin.
struct QualityReview: ViewModifier {
    @Binding var report: QualityCheck.Report?
    let question: String
    let continueTitle: String
    let onContinue: () -> Void
    @State private var continuing = false

    func body(content: Content) -> some View {
        // Continue after the sheet is gone so the action may dismiss the presenting screen.
        content.sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } }), onDismiss: {
            guard continuing else { return }
            continuing = false
            onContinue()
        }) {
            if let report {
                QualityReviewSheet(report: report, question: question, continueTitle: continueTitle) {
                    self.report = nil
                } onContinue: {
                    continuing = true
                    self.report = nil
                }
            }
        }
    }
}

extension View {
    func qualityReview(_ report: Binding<QualityCheck.Report?>, question: String, continueTitle: String,
                       onContinue: @escaping () -> Void) -> some View {
        modifier(QualityReview(report: report, question: question, continueTitle: continueTitle, onContinue: onContinue))
    }
}

private struct QualityReviewSheet: View {
    let report: QualityCheck.Report
    let question: String
    let continueTitle: String
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Ditemukan masalah berikut:") {
                    ForEach(report.issues, id: \.code) { issue in
                        Label(issue.message, systemImage: issue.level.symbol)
                            .foregroundStyle(issue.level.color)
                            .accessibilityIdentifier("quality-issue-\(issue.code)")
                    }
                }
                Section {
                    Text(question).font(.headline)
                    Button(continueTitle, action: onContinue)
                    Button("Kembali perbaiki", role: .cancel, action: onBack).bold()
                }
            }
            .navigationTitle("Pemeriksaan kualitas")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

private extension QualityCheck.Level {
    var symbol: String {
        switch self {
        case .error: "xmark.octagon"
        case .warn: "exclamationmark.triangle"
        case .info, .ok: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .error: .red
        case .warn: .orange
        case .info, .ok: .secondary
        }
    }
}

#if DEBUG
/// A complete multiside draft for the quality review UI test. UI tests skip GPS, so saving it raises
/// the missing-GPS warning, and the committed sample has no boxes.
@MainActor
func seedQualityReviewFixture(_ store: PackageStore) async throws {
    let run = try await store.createRun(type: .multiside, variety: "DAMIMAS", block: "QC", operatorName: "",
                                        sideCount: 4, split: "field", tokenized: false)
    for side in 0..<4 {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 360)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
            UIColor.systemBrown.setFill()
            context.fill(CGRect(x: 60 + side * 80, y: 110, width: 120, height: 120))
        }
        try await store.saveDraftPhoto(normalizedPhoto(image), runID: run.id, side: side)
    }
}
#endif
