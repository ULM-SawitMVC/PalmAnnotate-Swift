import CJPEGTurbo
import Foundation

/// Decodes JPEG photos with libjpeg-turbo, the decoder Android uses.
///
/// The automatic detector samples the photo with Android's bilinear scaler, which reads 4 source
/// pixels per output pixel. Apple's ImageIO decodes slightly different pixel values (chroma
/// upsampling and IDCT rounding), and those differences moved boxes by up to 5 px against Android.
public enum JPEGDecoder {
    public struct RGBImage: Sendable {
        public let width: Int
        public let height: Int
        /// Packed R, G, B bytes, `width * 3` bytes per row, no padding.
        public let pixels: [UInt8]
    }

    /// Returns the decoded photo, or nil when the data is not an 8-bit gray, YCbCr or RGB JPEG that
    /// libjpeg-turbo can decode (for example CMYK, 12-bit, or damaged data). Callers fall back to
    /// another decoder in that case.
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
