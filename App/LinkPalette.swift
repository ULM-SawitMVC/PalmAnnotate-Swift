import SwiftUI

/// Kotlin `LINK_GROUP_COLORS`: one colour per link group, shared by the canvas ring, the badge and the Dedup list.
enum LinkPalette {
    private static let hex: [UInt32] = [
        0x22C55E, 0x3B82F6, 0xF59E0B, 0xEC4899, 0x06B6D4, 0xA855F7, 0xEF4444, 0x84CC16,
        0xEAB308, 0x14B8A6, 0xD946EF, 0x0EA5E9, 0xF97316, 0x8B5CF6, 0x10B981, 0xF43F5E,
    ]

    static var count: Int { hex.count }

    /// Colour for a 1-based group number.
    static func color(_ group: Int) -> Color {
        let value = hex[max(group - 1, 0) % hex.count]
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// Black or white, chosen like Kotlin's `luminance() > 0.5` so a digit on the badge always reads.
    static func textColor(_ group: Int) -> Color {
        let value = hex[max(group - 1, 0) % hex.count]
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((value >> 16) & 0xFF) + 0.7152 * linear((value >> 8) & 0xFF)
            + 0.0722 * linear(value & 0xFF)
        return luminance > 0.5 ? .black : .white
    }
}
