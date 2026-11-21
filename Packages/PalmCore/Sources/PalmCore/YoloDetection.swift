import Foundation

public struct DetectorConfiguration: Decodable, Sendable {
    public let modelFile: String
    public let inputSize: Int
    public let confThreshold: Float
    public let iouThreshold: Float
    public let maxBoxes: Int
}

public struct Letterbox: Sendable {
    public let width: Int
    public let height: Int
    public let size: Int
    public let scale: Float
    public let resizedWidth: Int
    public let resizedHeight: Int
    public let padX: Int
    public let padY: Int

    public init(width: Int, height: Int, size: Int) {
        self.width = width
        self.height = height
        self.size = size
        scale = min(Float(size) / Float(width), Float(size) / Float(height))
        resizedWidth = Int((Float(width) * scale).rounded())
        resizedHeight = Int((Float(height) * scale).rounded())
        padX = (size - resizedWidth) / 2
        padY = (size - resizedHeight) / 2
    }

    public func originalBox(cx: Float, cy: Float, width: Float, height: Float) -> PixelBox? {
        PixelBox(x1: (cx - width / 2 - Float(padX)) / scale, y1: (cy - height / 2 - Float(padY)) / scale,
                 x2: (cx + width / 2 - Float(padX)) / scale, y2: (cy + height / 2 - Float(padY)) / scale)
            .clipped(width: self.width, height: self.height)
    }
}

public enum YoloDetection {
    public struct Prediction: Sendable {
        public let annotation: Annotation
        public let confidence: Float
    }

    public static func decode(_ data: [Float], shape: [Int], letterbox: Letterbox,
                              config: DetectorConfiguration) -> [Annotation] {
        predictions(data, shape: shape, letterbox: letterbox, config: config).map(\.annotation)
    }

    public static func predictions(_ data: [Float], shape: [Int], letterbox: Letterbox,
                                   config: DetectorConfiguration) -> [Prediction] {
        guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[2] > 0,
              shape[1] <= data.count / shape[2], config.maxBoxes > 0 else { return [] }
        let channelsFirst = shape[1] < shape[2]
        let rows = channelsFirst ? shape[2] : shape[1]
        let fields = channelsFirst ? shape[1] : shape[2]
        guard fields > 4 else { return [] }
        func field(_ row: Int, _ column: Int) -> Float {
            channelsFirst ? data[column * rows + row] : data[row * fields + column]
        }
        var candidates: [(index: Int, score: Float, box: PixelBox)] = []
        for row in 0..<rows {
            let score = (4..<fields).reduce(Float(0)) { max($0, field(row, $1)) }
            guard score >= config.confThreshold,
                  let box = letterbox.originalBox(cx: field(row, 0), cy: field(row, 1),
                                                  width: field(row, 2), height: field(row, 3)) else { continue }
            candidates.append((row, score, box))
        }
        candidates.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        var selected: [Prediction] = []
        for candidate in candidates where !selected.contains(where: {
            candidate.box.iou($0.annotation.rect) > config.iouThreshold
        }) {
            selected.append(Prediction(annotation: Annotation(id: "det\(selected.count)", rect: candidate.box),
                                       confidence: candidate.score))
            if selected.count == config.maxBoxes { break }
        }
        return selected
    }
}
