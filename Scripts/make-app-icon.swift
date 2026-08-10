#!/usr/bin/env swift
// Generates the doppelganger app icon: a cute ghost with its translucent
// doppelganger behind it, on a dark slate→blue gradient. Renders the 1024
// master with CoreGraphics and writes every size slot of the appiconset.
//
// Usage (from the repo root):
//   swift Scripts/make-app-icon.swift
//
// Overwrites the PNGs and Contents.json in App/Assets.xcassets/AppIcon.appiconset.

import AppKit
import CoreGraphics
import Foundation

let master: CGFloat = 1024

// MARK: - Drawing

func ghostPath(in rect: CGRect) -> CGPath {
    // Body: dome top, straight-ish sides, wavy hem of four scallops.
    let path = CGMutablePath()
    let w = rect.width
    let h = rect.height
    let x0 = rect.minX
    let y0 = rect.minY // bottom in CG coordinates
    let hemHeight = h * 0.10

    let scallops = 4
    let scallopWidth = w / CGFloat(scallops)

    path.move(to: CGPoint(x: x0, y: y0 + hemHeight))
    // Left side up to the dome.
    path.addLine(to: CGPoint(x: x0, y: y0 + h * 0.55))
    // Dome.
    path.addArc(
        center: CGPoint(x: x0 + w / 2, y: y0 + h * 0.55),
        radius: w / 2,
        startAngle: .pi,
        endAngle: 0,
        clockwise: true
    )
    // Right side down to the hem.
    path.addLine(to: CGPoint(x: x0 + w, y: y0 + hemHeight))
    // Wavy hem, right to left: down-scallops alternating with up-curves.
    for i in 0..<scallops {
        let startX = x0 + w - CGFloat(i) * scallopWidth
        let endX = startX - scallopWidth
        let midX = (startX + endX) / 2
        let dip: CGFloat = (i % 2 == 0) ? -hemHeight : hemHeight
        path.addQuadCurve(
            to: CGPoint(x: endX, y: y0 + hemHeight),
            control: CGPoint(x: midX, y: y0 + hemHeight + dip)
        )
    }
    path.closeSubpath()
    return path
}

func drawGhost(_ ctx: CGContext, body: CGRect, alpha: CGFloat, withFace: Bool) {
    ctx.saveGState()
    ctx.setAlpha(alpha)

    // Body with a soft vertical shading.
    let path = ghostPath(in: body)
    ctx.addPath(path)
    ctx.clip()
    let bodyColors = [
        NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.85, green: 0.89, blue: 0.98, alpha: 1).cgColor,
    ] as CFArray
    let bodyGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: bodyColors,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        bodyGradient,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: []
    )
    ctx.resetClip()

    guard withFace else {
        ctx.restoreGState()
        return
    }

    // Eyes: two tall rounded ovals, dark slate.
    let eyeColor = NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1)
    ctx.setFillColor(eyeColor.cgColor)
    let eyeWidth = body.width * 0.115
    let eyeHeight = body.height * 0.19
    let eyeY = body.minY + body.height * 0.46
    for dx: CGFloat in [-0.16, 0.16] {
        let eye = CGRect(
            x: body.midX + dx * body.width - eyeWidth / 2,
            y: eyeY,
            width: eyeWidth,
            height: eyeHeight
        )
        ctx.fillEllipse(in: eye)
        // Catchlight.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(
            x: eye.midX + eye.width * 0.05,
            y: eye.maxY - eye.height * 0.36,
            width: eye.width * 0.42,
            height: eye.width * 0.42
        ))
        ctx.setFillColor(eyeColor.cgColor)
    }

    // Blush: soft pink circles under the eyes.
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.68, alpha: 0.55).cgColor)
    let blushSize = body.width * 0.11
    for dx: CGFloat in [-0.27, 0.27] {
        ctx.fillEllipse(in: CGRect(
            x: body.midX + dx * body.width - blushSize / 2,
            y: body.minY + body.height * 0.40 - blushSize / 2,
            width: blushSize,
            height: blushSize * 0.72
        ))
    }

    // Mouth: small open "oh".
    ctx.setFillColor(eyeColor.withAlphaComponent(0.85).cgColor)
    let mouth = body.width * 0.075
    ctx.fillEllipse(in: CGRect(
        x: body.midX - mouth / 2,
        y: body.minY + body.height * 0.335,
        width: mouth,
        height: mouth * 0.8
    ))

    ctx.restoreGState()
}

func renderMaster() -> CGImage {
    let size = Int(master)
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Background: dark slate → deep blue diagonal gradient, full bleed
    // (macOS 26 applies the squircle mask itself).
    let bg = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.42, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.65, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(
        bg,
        start: CGPoint(x: 0, y: master),
        end: CGPoint(x: master, y: 0),
        options: []
    )

    // Faint oversized checkmark watermark in the lower-right corner — the
    // verification promise, kept subtle.
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.setLineWidth(master * 0.09)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: master * 0.55, y: master * 0.28))
    ctx.addLine(to: CGPoint(x: master * 0.72, y: master * 0.12))
    ctx.addLine(to: CGPoint(x: master * 1.05, y: master * 0.52))
    ctx.strokePath()
    ctx.restoreGState()

    // The doppelganger: translucent twin behind and offset up-left, faceless.
    let bodyWidth = master * 0.46
    let bodyHeight = master * 0.52
    let mainBody = CGRect(
        x: (master - bodyWidth) / 2 + master * 0.03,
        y: master * 0.20,
        width: bodyWidth,
        height: bodyHeight
    )
    let twinBody = mainBody.offsetBy(dx: -master * 0.115, dy: master * 0.075)
    drawGhost(ctx, body: twinBody, alpha: 0.30, withFace: false)

    // Soft shadow under the main ghost.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -master * 0.02),
        blur: master * 0.06,
        color: NSColor.black.withAlphaComponent(0.45).cgColor
    )
    drawGhost(ctx, body: mainBody, alpha: 1.0, withFace: true)
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Output

func writePNG(_ image: CGImage, pixels: Int, to url: URL) {
    let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let scaled = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: scaled)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(url.lastPathComponent)")
    }
    try! data.write(to: url)
    print("  \(url.lastPathComponent) (\(pixels)×\(pixels))")
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()
let iconset = scriptDir
    .deletingLastPathComponent()
    .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

guard FileManager.default.fileExists(atPath: iconset.path) else {
    fatalError("appiconset not found at \(iconset.path) — run from the repo root")
}

let masterImage = renderMaster()

struct Slot {
    let size: Int
    let scale: Int
    var pixels: Int { size * scale }
    var filename: String { "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png" }
}

let slots = [
    Slot(size: 16, scale: 1), Slot(size: 16, scale: 2),
    Slot(size: 32, scale: 1), Slot(size: 32, scale: 2),
    Slot(size: 128, scale: 1), Slot(size: 128, scale: 2),
    Slot(size: 256, scale: 1), Slot(size: 256, scale: 2),
    Slot(size: 512, scale: 1), Slot(size: 512, scale: 2),
]

print("Rendering app icon into \(iconset.path)")
for slot in slots {
    writePNG(masterImage, pixels: slot.pixels, to: iconset.appendingPathComponent(slot.filename))
}

let contents: [String: Any] = [
    "images": slots.map { slot in
        [
            "filename": slot.filename,
            "idiom": "mac",
            "scale": "\(slot.scale)x",
            "size": "\(slot.size)x\(slot.size)",
        ]
    },
    "info": ["author": "xcode", "version": 1],
]
let json = try! JSONSerialization.data(
    withJSONObject: contents,
    options: [.prettyPrinted, .sortedKeys]
)
try! json.write(to: iconset.appendingPathComponent("Contents.json"))
print("Done.")
