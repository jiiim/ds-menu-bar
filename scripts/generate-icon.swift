// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT
//
// Generates Resources/AppIcon.icns for DS Menu Bar: the app's ✦ star glyph in
// white on a rounded-rect indigo-to-purple gradient, following the macOS icon
// grid (content rect inset ~10% per side).
//
// Usage: swift scripts/generate-icon.swift   (or: make icon)
// Requires: /usr/bin/iconutil (ships with macOS).

import AppKit

/// Render one square icon PNG at the given pixel size.
func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    let inset = size * 0.10
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.225

    NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.52, alpha: 1),
        ending: NSColor(calibratedRed: 0.46, green: 0.32, blue: 0.80, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius), angle: 90)

    // Center the glyph optically: draw by glyph bounds (capHeight-ish), not by
    // line-height metrics, which include leading and sit the star too low.
    let glyph = "\u{2726}" as NSString  // ✦ BLACK FOUR POINTED STAR
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: rect.height * 0.62, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    let attributed = NSAttributedString(string: glyph as String, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetImageBounds(line, NSGraphicsContext.current!.cgContext)
    let origin = NSPoint(
        x: rect.midX - bounds.midX,
        y: rect.midY - bounds.midY)
    glyph.draw(at: origin, withAttributes: attrs)

    return rep.representation(using: .png, properties: [:])!
}

// Standard 10-image iconset (16 → 1024, with @2x variants).
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let fm = FileManager.default
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let iconsetURL = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let outputURL = repoRoot.appendingPathComponent("Resources/AppIcon.icns")

try? fm.removeItem(at: iconsetURL)
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (name, pixels) in sizes {
    try renderPNG(pixels: pixels).write(to: iconsetURL.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconsetURL)

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (exit \(iconutil.terminationStatus))\n".utf8))
    exit(1)
}
print("wrote \(outputURL.path)")
