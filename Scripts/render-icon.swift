#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <output.png>\n".utf8))
    exit(2)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                            CGFloat(hex & 0xff) / 255, alpha])!
}

let gradient = CGGradient(colorsSpace: space, colors: [color(0x1B5E20), color(0x2E7D32), color(0x43A047)] as CFArray,
                          locations: [0, 0.55, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(size)), options: [])

let base = CGPoint(x: 512, y: 430)
let angles: [CGFloat] = [-80, -60, -40, -20, 0, 20, 40, 60, 80]
for angle in angles {
    let spread = angle * .pi / 180
    let length: CGFloat = 470 - abs(angle) * 1.6
    context.saveGState()
    context.translateBy(x: base.x, y: base.y)
    context.rotate(by: -spread)
    let leaf = CGMutablePath()
    leaf.move(to: .zero)
    leaf.addQuadCurve(to: CGPoint(x: 0, y: length), control: CGPoint(x: 66, y: length * 0.48))
    leaf.addQuadCurve(to: .zero, control: CGPoint(x: -66, y: length * 0.48))
    context.addPath(leaf)
    context.setFillColor(color(0xF1F8E9))
    context.fillPath()
    context.setStrokeColor(color(0x66BB6A))
    context.setLineWidth(9)
    context.setLineCap(.round)
    context.move(to: .zero)
    context.addLine(to: CGPoint(x: 0, y: length * 0.92))
    context.strokePath()
    context.restoreGState()
}

let fruits: [(CGFloat, CGFloat, CGFloat)] = [
    (512, 330, 92), (420, 300, 82), (604, 300, 82), (512, 235, 86), (440, 205, 72), (584, 205, 72), (512, 150, 66)
]
for (x, y, radius) in fruits {
    context.setFillColor(color(0xE65100))
    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2 * 1.12))
    context.setFillColor(color(0xFFB74D))
    let shine = radius * 0.38
    context.fillEllipse(in: CGRect(x: x - radius * 0.5, y: y + radius * 0.2, width: shine, height: shine * 1.3))
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
