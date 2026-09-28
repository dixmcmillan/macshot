// Renders the Markclip app icon (indigo-to-violet gradient square with a white
// play-triangle/film-frame mark and an orange marker-pen accent stroke) at every
// size the AppIcon.appiconset needs, and overwrites the PNGs in place. Run with:
//   swift scripts/generate-app-icon.swift
// from anywhere — output paths are resolved relative to this file's location.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: #filePath)
let scriptsDir = scriptURL.deletingLastPathComponent()
let repoRoot = scriptsDir.deletingLastPathComponent()
let appIconSetDir = repoRoot
    .appendingPathComponent("macshot")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

struct IconSpec {
    let filename: String
    let pixels: Int
}

let specs: [IconSpec] = [
    IconSpec(filename: "icon_16x16.png", pixels: 16),
    IconSpec(filename: "icon_16x16@2x.png", pixels: 32),
    IconSpec(filename: "icon_32x32.png", pixels: 32),
    IconSpec(filename: "icon_32x32@2x.png", pixels: 64),
    IconSpec(filename: "icon_128x128.png", pixels: 128),
    IconSpec(filename: "icon_128x128@2x.png", pixels: 256),
    IconSpec(filename: "icon_256x256.png", pixels: 256),
    IconSpec(filename: "icon_256x256@2x.png", pixels: 512),
    IconSpec(filename: "icon_512x512.png", pixels: 512),
    IconSpec(filename: "icon_512x512@2x.png", pixels: 1024),
]

// MARK: - Drawing

func drawIcon(size: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let s = CGFloat(size)
    let rect = CGRect(x: 0, y: 0, width: s, height: s)

    // 1. Full-bleed background gradient: deep indigo (top-left) -> vivid violet (bottom-right).
    // macOS applies the rounded-square mask automatically, so we just fill the square.
    let bgColors = [
        CGColor(red: 0.09, green: 0.11, blue: 0.32, alpha: 1.0),  // deep indigo
        CGColor(red: 0.36, green: 0.20, blue: 0.62, alpha: 1.0),  // vivid violet
    ] as CFArray
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addRect(rect)
        ctx.clip()
        ctx.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: 0, y: s),
            end: CGPoint(x: s, y: 0),
            options: []
        )
        ctx.restoreGState()
    }

    // 2. White rounded-rect "film frame" centered in the canvas, drawn as a stroked
    // rounded rectangle to suggest a video frame/viewfinder.
    let frameInset = s * 0.14
    let frameRect = rect.insetBy(dx: frameInset, dy: frameInset)
    let frameCorner = s * 0.16
    let framePath = CGPath(roundedRect: frameRect, cornerWidth: frameCorner, cornerHeight: frameCorner, transform: nil)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.92))
    ctx.setLineWidth(max(s * 0.035, 1.0))
    ctx.addPath(framePath)
    ctx.strokePath()

    // 3. White play-triangle centered inside the frame, pointing right.
    let triHeight = frameRect.height * 0.5
    let triWidth = triHeight * 0.86
    let cx = frameRect.midX + s * 0.03 // optical centering nudge for a triangle
    let cy = frameRect.midY
    let triTop = CGPoint(x: cx - triWidth / 2, y: cy + triHeight / 2)
    let triBottom = CGPoint(x: cx - triWidth / 2, y: cy - triHeight / 2)
    let triTip = CGPoint(x: cx + triWidth / 2, y: cy)

    let triPath = CGMutablePath()
    triPath.move(to: triTop)
    triPath.addLine(to: triTip)
    triPath.addLine(to: triBottom)
    triPath.closeSubpath()

    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    ctx.addPath(triPath)
    ctx.fillPath()

    // 4. Orange "marker/highlighter" accent stroke crossing the lower-left corner
    // of the triangle, suggesting annotation/markup. Drawn as a rounded diagonal bar.
    ctx.saveGState()
    let markerLength = s * 0.5
    let markerWidth = s * 0.11
    let markerCenter = CGPoint(x: frameRect.minX + frameRect.width * 0.30, y: frameRect.minY + frameRect.height * 0.28)
    ctx.translateBy(x: markerCenter.x, y: markerCenter.y)
    ctx.rotate(by: 45 * .pi / 180)
    let markerRect = CGRect(x: -markerLength / 2, y: -markerWidth / 2, width: markerLength, height: markerWidth)
    let markerPath = CGPath(roundedRect: markerRect, cornerWidth: markerWidth / 2, cornerHeight: markerWidth / 2, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
    ctx.setFillColor(CGColor(red: 1.0, green: 0.62, blue: 0.13, alpha: 1.0)) // vivid orange
    ctx.addPath(markerPath)
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()
}

func writePNG(image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// MARK: - Main

var failures: [String] = []

for spec in specs {
    guard let image = drawIcon(size: spec.pixels) else {
        failures.append(spec.filename)
        continue
    }
    let outURL = appIconSetDir.appendingPathComponent(spec.filename)
    if !writePNG(image: image, to: outURL) {
        failures.append(spec.filename)
    } else {
        print("Wrote \(spec.filename) (\(spec.pixels)x\(spec.pixels))")
    }
}

if !failures.isEmpty {
    print("Failed to write: \(failures.joined(separator: ", "))")
    exit(1)
}

print("Done. Icons written to \(appIconSetDir.path)")
