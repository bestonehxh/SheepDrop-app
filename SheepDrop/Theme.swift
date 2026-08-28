import AppKit
import SwiftUI

/// Design v2 tokens — from the "SheepDrop" design canvas the user chose
/// (artifact 606456d6…, Theme artboard). Apple-flavored light/dark palette;
/// the only decorative color in the app is the per-protocol hue, used for
/// the dot, the badge and the progress bar, nowhere else.
enum Theme {
    // Surfaces
    static let content = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let header = dynamic(light: 0xFBFBFC, dark: 0x242426)
    static let sidebar = dynamic(light: 0xF6F6F8, dark: 0x2C2C2E)
    static let well = dynamicAlpha(light: (0x000000, 0.045), dark: (0xFFFFFF, 0.08))

    // Text
    static let text = dynamic(light: 0x1D1D1F, dark: 0xF5F5F7)          // primary
    static let text2 = dynamic(light: 0x3A3A3C, dark: 0xD1D1D6)         // secondary
    static let dimText = dynamic(light: 0x6E6E73, dark: 0xAEAEB2)       // tertiary
    static let faintText = dynamic(light: 0x86868B, dark: 0x8E8E93)     // quaternary
    static let disabledText = dynamic(light: 0xA1A1A6, dark: 0x636366)

    // Lines / fills
    static let hairline = dynamicAlpha(light: (0x000000, 0.10), dark: (0xFFFFFF, 0.14))
    static let hairlineSoft = dynamicAlpha(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.10))
    static let hover = dynamicAlpha(light: (0x000000, 0.04), dark: (0xFFFFFF, 0.07))
    static let control = dynamicAlpha(light: (0x000000, 0.055), dark: (0xFFFFFF, 0.12))
    static let selectedRow = dynamicAlpha(light: (0x000000, 0.075), dark: (0xFFFFFF, 0.10))

    // Accent + status — SheepDrop's coral-red, tuned to the app icon's
    // brick-red tile (#BD5852 → #873632) but a shade lighter/softer so buttons
    // read well on white while still matching the icon's identity.
    static let accent = dynamic(light: 0xC65D54, dark: 0xE88C82)
    static let ok = dynamic(light: 0x30A46C, dark: 0x4ED48A)
    static let warn = dynamic(light: 0xB8451F, dark: 0xFF8A5C)
    static let err = dynamic(light: 0xB8451F, dark: 0xFF8A5C)
    static let live = dynamic(light: 0x30D158, dark: 0x30D158)

    // Legacy aliases still referenced by older views.
    static let chrome = header
    static let chromeLine = hairline
    static let pane = content
    static let paneHeader = header
    static let selection = selectedRow
    static let tabActive = content
    static let tabText = text

    /// Protocol identity — one hue each, everywhere that protocol appears.
    static func protoColor(_ proto: TransferProtocolKind) -> Color {
        switch proto {
        case .sftp: dynamic(light: 0x30A46C, dark: 0x30A46C)
        case .scp: dynamic(light: 0x8B5CF6, dark: 0x8B5CF6)
        case .ftp: dynamic(light: 0xE0562A, dark: 0xE0562A)
        case .tftp: dynamic(light: 0x0EA5C4, dark: 0x0EA5C4)
        }
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    static func dynamicAlpha(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let pick = isDark ? dark : light
            return nsColor(pick.0).withAlphaComponent(pick.1)
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
