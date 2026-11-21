import Foundation
import Testing
@testable import PalmCore

private func tensor(_ letterbox: Letterbox, width: Int, height: Int, bytesPerPixel: Int = 3, redOffset: Int = 0,
                    pixel: (Int, Int, Int) -> UInt8) -> [Float] {
    var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    for y in 0..<height { for x in 0..<width { for channel in 0..<3 {
        bytes[(y * width + x) * bytesPerPixel + redOffset + channel] = pixel(x, y, channel)
    } } }
    return bytes.withUnsafeBytes {
        letterbox.tensor(pixels: $0, bytesPerRow: width * bytesPerPixel, bytesPerPixel: bytesPerPixel,
                         redOffset: redOffset)
    }
}

private func bytes(_ tensor: [Float], _ letterbox: Letterbox, channel: Int, row: Int) -> [Int] {
    let area = letterbox.size * letterbox.size
    return (0..<letterbox.size).map { Int((tensor[channel * area + row * letterbox.size + $0] * 255).rounded()) }
}

@Test func tensorTruncatesBilinearBlendsAndKeepsPlanesSeparate() {
    let letterbox = Letterbox(width: 4, height: 4, size: 2)
    let result = tensor(letterbox, width: 4, height: 4) { x, y, channel in UInt8(x + 2 * y + 10 * channel) }
    #expect(bytes(result, letterbox, channel: 0, row: 0) == [1, 3])
    #expect(bytes(result, letterbox, channel: 0, row: 1) == [5, 7])
    #expect(bytes(result, letterbox, channel: 1, row: 0) == [11, 13])
    #expect(bytes(result, letterbox, channel: 2, row: 1) == [25, 27])
}

@Test func tensorPadsWithGreyAndCopiesAnUnscaledImage() {
    let letterbox = Letterbox(width: 4, height: 2, size: 4)
    #expect(letterbox.padY == 1)
    let result = tensor(letterbox, width: 4, height: 2) { x, y, channel in UInt8(40 * y + 10 * x + channel) }
    #expect(bytes(result, letterbox, channel: 0, row: 0) == [114, 114, 114, 114])
    #expect(bytes(result, letterbox, channel: 0, row: 1) == [0, 10, 20, 30])
    #expect(bytes(result, letterbox, channel: 2, row: 2) == [42, 52, 62, 72])
    #expect(bytes(result, letterbox, channel: 1, row: 3) == [114, 114, 114, 114])
}

@Test func tensorClampsTapsAtTheImageEdgeWhenEnlarging() {
    let letterbox = Letterbox(width: 2, height: 1, size: 4)
    let result = tensor(letterbox, width: 2, height: 1) { x, _, _ in x == 0 ? 100 : 200 }
    #expect(bytes(result, letterbox, channel: 0, row: 1) == [100, 125, 175, 200])
    #expect(bytes(result, letterbox, channel: 0, row: 2) == [100, 125, 175, 200])
}

@Test func tensorReadsPackedAndPaddedPixelLayoutsIdentically() {
    let letterbox = Letterbox(width: 9, height: 5, size: 4)
    func pixel(_ x: Int, _ y: Int, _ channel: Int) -> UInt8 { UInt8((x * 37 + y * 91 + channel * 53) % 256) }
    let packed = tensor(letterbox, width: 9, height: 5, pixel: pixel)
    #expect(tensor(letterbox, width: 9, height: 5, bytesPerPixel: 4, pixel: pixel) == packed)
    #expect(tensor(letterbox, width: 9, height: 5, bytesPerPixel: 4, redOffset: 1, pixel: pixel) == packed)
}

@Test func tensorOfATruncatedBufferIsAllPadding() {
    let letterbox = Letterbox(width: 4, height: 4, size: 2)
    let result = [UInt8](repeating: 0, count: 10).withUnsafeBytes {
        letterbox.tensor(pixels: $0, bytesPerRow: 12, bytesPerPixel: 3)
    }
    #expect(result == [Float](repeating: 114.0 / 255, count: 12))
}

@Test(arguments: [
    (37, 23, 16, UInt64(0xdadc2632ac0e986a)),
    (700, 500, 200, UInt64(0x86506e36a7cce61b)),
    (333, 611, 160, UInt64(0xa1f5e44c4ab63191)),
    (4624, 3468, 640, UInt64(0x125c18216761992a)),
])
func tensorMatchesAndroidCreateScaledBitmap(width: Int, height: Int, size: Int, expected: UInt64) {
    var state = UInt32(width * 65536 + height)
    func next() -> UInt8 {
        state = state &* 1_664_525 &+ 1_013_904_223
        return UInt8(state >> 24)
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 3)
    for index in pixels.indices { pixels[index] = next() }
    let letterbox = Letterbox(width: width, height: height, size: size)
    let result = pixels.withUnsafeBytes { letterbox.tensor(pixels: $0, bytesPerRow: width * 3, bytesPerPixel: 3) }

    var hash: UInt64 = 0xcbf29ce484222325
    let area = size * size
    for row in 0..<letterbox.resizedHeight { for column in 0..<letterbox.resizedWidth { for channel in 0..<3 {
        let value = result[channel * area + (letterbox.padY + row) * size + letterbox.padX + column] * 255
        hash = (hash ^ UInt64(value.rounded())) &* 0x100000001b3
    } } }
    #expect(hash == expected)
}
