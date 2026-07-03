import AppKit
import SwiftUI

/// Triptease brand palette — the single source of truth for every colour in the
/// LocalFlow UI. Nothing else in the app should hardcode a colour value; the only
/// other place a raw hex lives is the standalone icon-generation script
/// (Scripts/generate-icon.swift), which can't import this module.
///
/// Official Triptease palette:
///   Orange  300 #F79E6F · 400 #F4864B · 500 #ED6E2E  (primary accent)
///   Purple  300 #AA85F5 · 400 #8D5CF2 · 500 #5E43C2  (primary interactive)
///           600 #44318D · 800 #2C1D65
extension Color {
    /// Builds an opaque sRGB colour from a 0xRRGGBB literal.
    init(ttHex hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    static let ttOrange300 = Color(ttHex: 0xF79E6F)
    static let ttOrange400 = Color(ttHex: 0xF4864B)
    static let ttOrange500 = Color(ttHex: 0xED6E2E)   // primary accent

    static let ttPurple300 = Color(ttHex: 0xAA85F5)
    static let ttPurple400 = Color(ttHex: 0x8D5CF2)
    static let ttPurple500 = Color(ttHex: 0x5E43C2)   // primary interactive
    static let ttPurple600 = Color(ttHex: 0x44318D)
    static let ttPurple800 = Color(ttHex: 0x2C1D65)

    /// Linear sRGB blend of two brand colours — lets us derive an in-between stop
    /// (e.g. the centre voice bar) without hardcoding a new hex value.
    static func ttBlend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let na = NSColor(a).usingColorSpace(.sRGB) ?? .clear
        let nb = NSColor(b).usingColorSpace(.sRGB) ?? .clear
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(t) }
        return Color(nsColor: NSColor(srgbRed: lerp(na.redComponent, nb.redComponent),
                                      green: lerp(na.greenComponent, nb.greenComponent),
                                      blue: lerp(na.blueComponent, nb.blueComponent),
                                      alpha: 1))
    }

    /// Warm→cool sweep for the HUD's five voice-reactive bars, left→right from
    /// orange-400 to purple-400 — every stop sourced from the palette above.
    static let ttVoiceBars: [Color] = [
        .ttOrange400,
        .ttOrange300,
        ttBlend(.ttOrange300, .ttPurple300, 0.5),
        .ttPurple300,
        .ttPurple400,
    ]
}

/// AppKit mirror of the palette for any context that draws with NSColor.
extension NSColor {
    static let ttOrange300 = NSColor(Color.ttOrange300)
    static let ttOrange400 = NSColor(Color.ttOrange400)
    static let ttOrange500 = NSColor(Color.ttOrange500)
    static let ttPurple300 = NSColor(Color.ttPurple300)
    static let ttPurple400 = NSColor(Color.ttPurple400)
    static let ttPurple500 = NSColor(Color.ttPurple500)
    static let ttPurple600 = NSColor(Color.ttPurple600)
    static let ttPurple800 = NSColor(Color.ttPurple800)
}
