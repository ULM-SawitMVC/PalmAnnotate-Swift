import Foundation
import Testing
@testable import PalmCore

@Test func detectorDecodesBothLayoutsWithStableScoreOrderAndClassAgnosticNMS() throws {
    let config = try JSONDecoder().decode(DetectorConfiguration.self, from: Data("""
        {"modelFile":"fixture.onnx","inputSize":100,"confThreshold":0.01,"iouThreshold":0.3,"maxBoxes":3}
        """.utf8))
    let letterbox = Letterbox(width: 100, height: 200, size: config.inputSize)
    let rows: [[Float]] = [
        [50, 30, 20, 10, 0.80, 0.10],
        [60, 70, 10, 10, 0.20, 0.80],
        [50, 30, 20, 10, 0.20, 0.70], // Suppressed across class channels.
        [20, 70, 5, 5, 0.99, 0],    // Entirely in the padding.
        [55, 70, 0.4, 5, 0.99, 0],  // Width below one original pixel.
        [50, 80, 10, 10, 0.009, 0],
        [75, 80, 12, 12, 0.01, 0],  // Exact confidence threshold, clipped to the right edge.
        [35, 20, 10, 10, 0.01, 0],  // Beyond the cap, after the earlier tie.
    ]
    let channels = (0..<6).flatMap { channel in rows.map { $0[channel] } }
    for (values, shape) in [(rows.flatMap { $0 }, [1, rows.count, 6]), (channels, [1, 6, rows.count])] {
        let detected = YoloDetection.predictions(values, shape: shape, letterbox: letterbox, config: config)
        #expect(detected.map(\.confidence) == [0.80, 0.80, 0.01])
        #expect(detected.map(\.annotation) == [
            Annotation(id: "det0", rect: PixelBox(x1: 30, y1: 50, x2: 70, y2: 70)),
            Annotation(id: "det1", rect: PixelBox(x1: 60, y1: 130, x2: 80, y2: 150)),
            Annotation(id: "det2", rect: PixelBox(x1: 88, y1: 148, x2: 100, y2: 172)),
        ])
    }
}

@Test func detectorLetterboxAllocatesOddPaddingToTheTrailingEdge() {
    let letterbox = Letterbox(width: 9, height: 7, size: 8)
    #expect(letterbox.resizedWidth == 8)
    #expect(letterbox.resizedHeight == 6)
    #expect(letterbox.padX == 0)
    #expect(letterbox.padY == 1)

    let odd = Letterbox(width: 2, height: 3, size: 8)
    #expect(odd.resizedWidth == 5)
    #expect(odd.padX == 1)
    #expect(odd.size - odd.padX - odd.resizedWidth == 2)
}
