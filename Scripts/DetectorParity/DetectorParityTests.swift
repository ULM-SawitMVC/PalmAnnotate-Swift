import Foundation
import PalmCore
import XCTest
@testable import PalmAnnotate

final class DetectorParityTests: XCTestCase {
    func testFieldJPEGs() async throws {
        let bundle = Bundle(for: Self.self)
        let images = ["jpg", "jpeg", "png"].flatMap {
            bundle.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? []
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(images.isEmpty)
        let detector = Detector()
        let clock = ContinuousClock()
        let cold = try await clock.measure { _ = try await detector.predictions(jpeg: Data(contentsOf: images[0])) }
        print("PALM_DETECT_COLD_MS \(cold.milliseconds)")
        for image in images {
            var predictions: [YoloDetection.Prediction] = []
            let elapsed = try await clock.measure {
                predictions = try await detector.predictions(jpeg: Data(contentsOf: image))
            }
            let rows = predictions.map { prediction in
                let box = prediction.annotation.rect
                return [prediction.annotation.id, String(prediction.annotation.ripeness.rawValue),
                        String(prediction.confidence), String(box.x1), String(box.y1),
                        String(box.x2), String(box.y2)].joined(separator: ",")
            }
            print("PALM_DETECT_BEGIN " + image.lastPathComponent)
            print("PALM_DETECT_MS \(elapsed.milliseconds)")
            for row in rows { print("PALM_DETECT_BOX " + row) }
            print("PALM_DETECT_END")
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
