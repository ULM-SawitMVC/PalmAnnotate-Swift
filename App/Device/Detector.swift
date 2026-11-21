import CoreGraphics
import Foundation
import ImageIO
import PalmCore

actor Detector {
    static let shared = Detector()
    private var runtime: Runtime?

    func detect(_ photo: CapturedPhoto) throws -> [Annotation] {
        let model: Runtime
        if let runtime { model = runtime }
        else {
            model = try Runtime()
            runtime = model
        }

        guard let source = CGImageSourceCreateWithData(photo.jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.photo }
        let size = model.config.inputSize
        let box = Letterbox(width: image.width, height: image.height, size: size)
        var pixels = [UInt8](repeating: 114, count: size * size * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            guard let context = CGContext(data: storage.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: format) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: box.padX, y: size - box.padY - box.resizedHeight,
                                            width: box.resizedWidth, height: box.resizedHeight))
            return true
        }
        guard rendered else { throw CaptureError.photo }
        let area = size * size
        var input = [Float](repeating: 0, count: 3 * area)
        for index in 0..<area {
            for channel in 0..<3 { input[channel * area + index] = Float(pixels[4 * index + channel]) / 255 }
        }
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
        return YoloDetection.decode(data, shape: shape.map(Int.init), letterbox: box, config: model.config)
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
