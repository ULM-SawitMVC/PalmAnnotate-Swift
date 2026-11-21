import CJPEGTurbo
import Foundation

public enum JPEGDecoder {
    public struct RGBImage: Sendable {
        public let width: Int
        public let height: Int
        public let pixels: [UInt8]
    }

    public static func decodeRGB(_ jpeg: Data) -> RGBImage? {
        var width: Int32 = 0
        var height: Int32 = 0
        var buffer: UnsafeMutablePointer<UInt8>?
        let status = jpeg.withUnsafeBytes { bytes -> Int32 in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return palm_jpeg_decode_rgb(base, bytes.count, &width, &height, &buffer)
        }
        guard status == 0, let buffer else { return nil }
        defer { palm_jpeg_free(buffer) }
        let count = Int(width) * Int(height) * 3
        return RGBImage(width: Int(width), height: Int(height),
                        pixels: Array(UnsafeBufferPointer(start: buffer, count: count)))
    }
}
