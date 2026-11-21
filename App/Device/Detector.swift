import CoreGraphics
import Foundation
import ImageIO
import PalmCore

actor Detector {
    static let shared = Detector()
    private var runtime: Runtime?

    func detect(_ photo: CapturedPhoto) throws -> [Annotation] {
        try predictions(jpeg: photo.jpeg).map(\.annotation)
    }

    func predictions(jpeg: Data) throws -> [YoloDetection.Prediction] {
        let model: Runtime
        if let runtime { model = runtime }
        else {
            model = try Runtime()
            runtime = model
        }

        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.photo }
        let size = model.config.inputSize
        let box = Letterbox(width: image.width, height: image.height, size: size)
        guard let scaled = Self.scaledSRGB(image, letterbox: box) else { throw CaptureError.photo }
        var input = box.tensor(scaled: scaled)
        var shape = [Int64](repeating: 0, count: 3)
        var count = 0
        var error = [CChar](repeating: 0, count: 1024)
        let capacity = error.count
        let result = input.withUnsafeMutableBufferPointer {
            PalmOrtRun(model.session, $0.baseAddress, Int64(size), &shape, &count, &error, capacity)
        }
        guard let result else { throw RuntimeError(message: Self.message(error)) }
        defer { PalmOrtFreeOutput(result) }
        let data = Array(UnsafeBufferPointer(start: result, count: count))
        return YoloDetection.predictions(data, shape: shape.map(Int.init), letterbox: box, config: model.config)
    }

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func scaledSRGB(_ image: CGImage, letterbox: Letterbox) -> [UInt8]? {
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let layout: (bytes: Int, red: Int)? = switch (image.bitsPerPixel, image.alphaInfo) {
        case (24, .none): (3, 0)
        case (32, .noneSkipLast): (4, 0)
        case (32, .noneSkipFirst): (4, 1)
        default: nil
        }
        guard image.bitsPerComponent == 8, let space = image.colorSpace, space.model == .rgb,
              order.isEmpty || order == .byteOrder32Big, let layout, let raw = image.dataProvider?.data as Data? else {
            guard let pixels = draw(image, width: image.width, height: image.height, into: srgb) else { return nil }
            return pixels.withUnsafeBytes {
                letterbox.scaled(pixels: $0, bytesPerRow: image.width * 4, bytesPerPixel: 4)
            }
        }
        let scaled = raw.withUnsafeBytes {
            letterbox.scaled(pixels: $0, bytesPerRow: image.bytesPerRow, bytesPerPixel: layout.bytes,
                             redOffset: layout.red)
        }
        guard scaled.count == letterbox.resizedWidth * letterbox.resizedHeight * 3 else { return nil }
        var padded = Data(count: scaled.count / 3 * 4)
        padded.withUnsafeMutableBytes { storage in
            for index in 0..<scaled.count / 3 {
                for channel in 0..<3 { storage[4 * index + channel] = scaled[3 * index + channel] }
                storage[4 * index + 3] = 255
            }
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: padded as CFData),
              let tagged = CGImage(width: letterbox.resizedWidth, height: letterbox.resizedHeight,
                                   bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: letterbox.resizedWidth * 4,
                                   space: space, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent),
              let converted = draw(tagged, width: tagged.width, height: tagged.height, into: srgb) else { return nil }
        return (0..<scaled.count).map { converted[$0 / 3 * 4 + $0 % 3] }
    }

    private static func draw(_ image: CGImage, width: Int, height: Int, into space: CGColorSpace) -> Data? {
        var data = Data(count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { storage -> Bool in
            let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: format) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }

    private static func message(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private struct RuntimeError: LocalizedError {
        let message: String
        var errorDescription: String? { "Deteksi otomatis gagal. \(message)" }
    }

    private final class Runtime {
        let session: OpaquePointer
        let config: DetectorConfiguration

        init() throws {
            guard let url = Bundle.main.url(forResource: "detector.config", withExtension: "json") else {
                throw RuntimeError(message: "Konfigurasi model tidak tersedia.")
            }
            config = try JSONDecoder().decode(DetectorConfiguration.self, from: Data(contentsOf: url))
            guard (1...2048).contains(config.inputSize),
                  let modelURL = Bundle.main.url(forResource: config.modelFile, withExtension: nil) else {
                throw RuntimeError(message: "Model ONNX tidak tersedia.")
            }
            var error = [CChar](repeating: 0, count: 1024)
            let capacity = error.count
            guard let session = modelURL.path.withCString({ PalmOrtCreate($0, &error, capacity) }) else {
                throw RuntimeError(message: Detector.message(error))
            }
            self.session = session
        }

        deinit { PalmOrtRelease(session) }
    }
}
