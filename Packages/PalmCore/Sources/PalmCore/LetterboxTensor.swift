import Foundation

extension Letterbox {
    /// Scales decoded 8-bit pixels to `resizedWidth` x `resizedHeight` packed RGB bytes.
    ///
    /// Android scales with `Bitmap.createScaledBitmap(..., filter = true)`. On the pinned Android 14
    /// image, Skia's CPU bitmap sampler produces the result, and this method reproduces it exactly:
    ///
    /// - The source position of a destination pixel centre comes from the inverse scale matrix, held
    ///   as Float, then in 32.32 fixed point, less half a pixel.
    /// - The bilinear weights keep only 4 fractional bits per axis, and the blend truncates (`>> 8`).
    /// - Each row of source positions is recomputed from Float every 127 pixels and stepped in fixed
    ///   point in between.
    /// - Taps clamp to the image edge.
    ///
    /// - Parameters:
    ///   - pixels: The decoded image, `width` x `height`, with the red byte at `redOffset` and green
    ///     and blue following it.
    ///   - bytesPerPixel: 3 for packed RGB or 4 for RGBX/XRGB.
    /// - Returns: The scaled bytes, or an empty array when the buffer cannot hold the image.
    public func scaled(pixels: UnsafeRawBufferPointer, bytesPerRow: Int, bytesPerPixel: Int,
                       redOffset: Int = 0) -> [UInt8] {
        guard resizedWidth > 0, resizedHeight > 0, bytesPerPixel >= redOffset + 3,
              pixels.count >= (height - 1) * bytesPerRow + width * bytesPerPixel else { return [] }
        var scaled = [UInt8](repeating: 0, count: resizedWidth * resizedHeight * 3)

        let inverseX = 1 / (Float(resizedWidth) / Float(width))
        let inverseY = 1 / (Float(resizedHeight) / Float(height))
        func position(_ destination: Int, _ inverse: Float) -> Int64 {
            Int64(Double((Float(destination) + 0.5) * inverse) * 4_294_967_296)
        }
        func taps(_ fixed32: Int64, _ limit: Int) -> (low: Int, high: Int, weight: Int) {
            let fixed16 = (fixed32 - (1 << 31)) >> 16
            let low = Int(fixed16 >> 16)
            return (min(max(low, 0), limit - 1), min(max(low + 1, 0), limit - 1), Int((fixed16 >> 12) & 0xF))
        }
        let step = Int64(Double(inverseX) * 4_294_967_296)
        var columns: [(low: Int, high: Int, weight: Int)] = []
        var fixed: Int64 = 0
        for column in 0..<resizedWidth {
            if column % 127 == 0 { fixed = position(column, inverseX) }
            columns.append(taps(fixed, width))
            fixed += step
        }
        for row in 0..<resizedHeight {
            let y = taps(position(row, inverseY), height)
            let upper = y.low * bytesPerRow + redOffset
            let lower = y.high * bytesPerRow + redOffset
            for (column, x) in columns.enumerated() {
                let corner = x.weight * y.weight
                let weights = (256 - 16 * y.weight - 16 * x.weight + corner, 16 * x.weight - corner,
                               16 * y.weight - corner, corner)
                for channel in 0..<3 {
                    let blend = Int(pixels[upper + x.low * bytesPerPixel + channel]) * weights.0
                        + Int(pixels[upper + x.high * bytesPerPixel + channel]) * weights.1
                        + Int(pixels[lower + x.low * bytesPerPixel + channel]) * weights.2
                        + Int(pixels[lower + x.high * bytesPerPixel + channel]) * weights.3
                    scaled[(row * resizedWidth + column) * 3 + channel] = UInt8(blend >> 8)
                }
            }
        }
        return scaled
    }

    /// Places packed RGB bytes from ``scaled(pixels:bytesPerRow:bytesPerPixel:redOffset:)`` in the
    /// padded square input as planar floats in 0...1. The padding is grey 114.
    public func tensor(scaled: [UInt8]) -> [Float] {
        let area = size * size
        var tensor = [Float](repeating: 114.0 / 255, count: 3 * area)
        guard scaled.count == resizedWidth * resizedHeight * 3 else { return tensor }
        for row in 0..<resizedHeight {
            let output = (padY + row) * size + padX
            for column in 0..<resizedWidth {
                for channel in 0..<3 {
                    tensor[channel * area + output + column] = Float(scaled[(row * resizedWidth + column) * 3 + channel]) / 255
                }
            }
        }
        return tensor
    }

    /// Scales decoded 8-bit pixels and places them in the padded input.
    public func tensor(pixels: UnsafeRawBufferPointer, bytesPerRow: Int, bytesPerPixel: Int,
                       redOffset: Int = 0) -> [Float] {
        tensor(scaled: scaled(pixels: pixels, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel,
                              redOffset: redOffset))
    }
}
