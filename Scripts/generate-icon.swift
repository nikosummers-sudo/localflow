#!/usr/bin/env swift
// Regenerates Sources/LocalFlow/Resources/AppIcon.icns from scratch.
//
//   swift Scripts/generate-icon.swift
//
// Renders a 1024×1024 master (macOS-style rounded tile, a diagonal Triptease
// orange→purple gradient, a centred white mic.fill with a soft shadow), fans it out
// sizes with `sips`, then packs the .icns with `iconutil`. The committed .icns is
// what the build bundles — this script only needs re-running when the art changes.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Design parameters

let canvas: CGFloat = 1024          // master pixel size
let tileMargin: CGFloat = 100       // transparent border around the rounded tile (Apple grid)
let cornerRadius: CGFloat = 230     // squircle-ish corner radius of the tile
let micHeightFraction: CGFloat = 0.46   // mic.fill height as a fraction of the canvas

// Triptease diagonal: orange-500 (top-leading) → a warm violet midpoint
// (purple-400) → purple-600 (bottom-trailing). Kept rich, not muddy.
// NOTE: these literals mirror BrandColors.swift — this standalone script can't
// import the app module, so the palette is duplicated here by necessity.
let gradientOrange500 = CGColor(red: 0xED / 255, green: 0x6E / 255, blue: 0x2E / 255, alpha: 1)
let gradientVioletMid = CGColor(red: 0x8D / 255, green: 0x5C / 255, blue: 0xF2 / 255, alpha: 1)
let gradientPurple600 = CGColor(red: 0x44 / 255, green: 0x31 / 255, blue: 0x8D / 255, alpha: 1)

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: #filePath)
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesDir = root.appendingPathComponent("Sources/LocalFlow/Resources")
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")

let fm = FileManager.default
try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

let workDir = fm.temporaryDirectory.appendingPathComponent("localflow-icon-\(UUID().uuidString)")
try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
let iconsetDir = workDir.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
let masterURL = workDir.appendingPathComponent("icon_1024.png")

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func run(_ launchPath: String, _ args: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    do {
        try process.run()
    } catch {
        fail("failed to launch \(launchPath): \(error)")
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        fail("\(launchPath) \(args.joined(separator: " ")) exited \(process.terminationStatus)")
    }
}

/// Returns a solid-white copy of a template SF Symbol image, preserving its alpha shape.
func whiteVersion(of image: NSImage) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    out.isTemplate = false
    return out
}

// MARK: - Render the 1024 master

let px = Int(canvas)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fail("could not allocate bitmap") }
rep.size = NSSize(width: canvas, height: canvas)   // 1 point == 1 pixel

guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fail("could not create graphics context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

// Rounded-rect tile filled with the vertical gradient.
let tileRect = CGRect(x: tileMargin, y: tileMargin,
                      width: canvas - 2 * tileMargin,
                      height: canvas - 2 * tileMargin)
let tilePath = CGPath(roundedRect: tileRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
guard let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [gradientOrange500, gradientVioletMid, gradientPurple600] as CFArray,
    locations: [0, 0.5, 1]
) else { fail("could not build gradient") }
// Diagonal, top-leading → bottom-trailing. Origin is bottom-left, so top-leading
// is (0, canvas) and bottom-trailing is (canvas, 0). Extend past the endpoints so
// the tile corners never leave a hairline of the clamped end colour.
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: canvas),
                       end: CGPoint(x: canvas, y: 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Centred white mic.fill with a soft shadow.
let targetHeight = canvas * micHeightFraction
let config = NSImage.SymbolConfiguration(pointSize: targetHeight, weight: .medium)
guard let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) else { fail("mic.fill symbol unavailable") }
let whiteMic = whiteVersion(of: symbol)

let aspect = whiteMic.size.width / whiteMic.size.height
let drawHeight = targetHeight
let drawWidth = drawHeight * aspect
let micRect = NSRect(x: (canvas - drawWidth) / 2,
                     y: (canvas - drawHeight) / 2,
                     width: drawWidth, height: drawHeight)

NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -14)   // y-up: negative drops the shadow downward
shadow.set()
whiteMic.draw(in: micRect, from: NSRect(origin: .zero, size: whiteMic.size), operation: .sourceOver, fraction: 1)
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else { fail("PNG encode failed") }
do {
    try pngData.write(to: masterURL)
} catch {
    fail("could not write master PNG: \(error)")
}

// MARK: - Fan out to the iconset and pack the .icns

// (point size, @2x?) — the iconset needs both 1x and 2x for each logical size.
let variants: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.base * variant.scale
    let suffix = variant.scale == 2 ? "@2x" : ""
    let name = "icon_\(variant.base)x\(variant.base)\(suffix).png"
    let out = iconsetDir.appendingPathComponent(name)
    if pixels == px {
        // 1024 master is already the right size — copy rather than resample.
        try? fm.removeItem(at: out)
        try fm.copyItem(at: masterURL, to: out)
    } else {
        run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", masterURL.path, "--out", out.path])
    }
}

try? fm.removeItem(at: icnsURL)
run("/usr/bin/iconutil", ["-c", "icns", iconsetDir.path, "-o", icnsURL.path])

try? fm.removeItem(at: workDir)

print("Wrote \(icnsURL.path)")
