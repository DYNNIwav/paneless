#!/usr/bin/env swift

import Cocoa

// Generate "Paneless" app icon
// Clean window pane layout: white frame, dark visor upper half, ^^ arc eyes, smile = horizontal divider
// Minimal — no energy rings, particles, or sparkles

func generateIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let scale = s / 1024.0
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // === BACKGROUND (dark blue-purple gradient) ===
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = 220 * scale
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    let bgColors = [
        CGColor(colorSpace: colorSpace, components: [0.10, 0.08, 0.20, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.07, 0.10, 0.24, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.08, 0.13, 0.28, 1.0])!,
    ]
    let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors as CFArray, locations: [0.0, 0.5, 1.0])!

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: s * 0.3, y: s), end: CGPoint(x: s * 0.7, y: 0), options: [])

    // Subtle center glow behind the frame
    let glowColors = [
        CGColor(colorSpace: colorSpace, components: [0.15, 0.35, 0.70, 0.18])!,
        CGColor(colorSpace: colorSpace, components: [0.10, 0.20, 0.50, 0.0])!,
    ]
    let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors as CFArray, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(glowGrad, startCenter: CGPoint(x: s * 0.5, y: s * 0.48),
                           startRadius: 0, endCenter: CGPoint(x: s * 0.5, y: s * 0.48),
                           endRadius: s * 0.50, options: [])
    ctx.restoreGState()

    // === WINDOW FRAME (white rounded rectangle) ===
    let frameW = s * 0.62
    let frameH = s * 0.62
    let frameX = (s - frameW) / 2
    let frameY = (s - frameH) / 2
    let frameRadius = 28 * scale
    let frameRect = CGRect(x: frameX, y: frameY, width: frameW, height: frameH)
    let framePath = CGPath(roundedRect: frameRect, cornerWidth: frameRadius, cornerHeight: frameRadius, transform: nil)

    // Soft glow behind frame
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30 * scale,
                   color: CGColor(colorSpace: colorSpace, components: [0.3, 0.6, 1.0, 0.20])!)
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.08, 0.10, 0.20, 1.0])!)
    ctx.addPath(framePath)
    ctx.fillPath()
    ctx.restoreGState()

    // Frame fill — all dark (robot visor / screen)
    ctx.saveGState()
    ctx.addPath(framePath)
    ctx.clip()
    let frameColors = [
        CGColor(colorSpace: colorSpace, components: [0.10, 0.12, 0.22, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.05, 0.07, 0.15, 1.0])!,
    ]
    let frameGrad = CGGradient(colorsSpace: colorSpace, colors: frameColors as CFArray, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(frameGrad, start: CGPoint(x: 0, y: frameRect.maxY), end: CGPoint(x: 0, y: frameRect.minY), options: [])
    ctx.restoreGState()

    // Frame border — light edge so the shape is visible
    ctx.addPath(framePath)
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.35, 0.45, 0.65, 0.6])!)
    ctx.setLineWidth(3 * scale)
    ctx.strokePath()

    let smileBaseY = frameY + frameH * 0.44

    // === VERTICAL DIVIDER (same glow style as smile) ===
    let lineW = 5 * scale
    let midX = frameX + frameW / 2

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16 * scale,
                   color: CGColor(colorSpace: colorSpace, components: [0.3, 0.85, 1.0, 0.7])!)
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.45, 0.92, 1.0, 1.0])!)
    ctx.setLineWidth(lineW)
    ctx.move(to: CGPoint(x: midX, y: frameY))
    ctx.addLine(to: CGPoint(x: midX, y: frameY + frameH))
    ctx.strokePath()
    ctx.restoreGState()

    // === SMILE (edge-to-edge curved horizontal divider) ===
    let smileY = smileBaseY
    let smileCurve = 30 * scale

    let smilePath = CGMutablePath()
    smilePath.move(to: CGPoint(x: frameX, y: smileY))
    smilePath.addCurve(to: CGPoint(x: frameX + frameW, y: smileY),
                        control1: CGPoint(x: frameX + frameW * 0.25, y: smileY - smileCurve),
                        control2: CGPoint(x: frameX + frameW * 0.75, y: smileY - smileCurve))

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16 * scale,
                   color: CGColor(colorSpace: colorSpace, components: [0.3, 0.85, 1.0, 0.7])!)
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.45, 0.92, 1.0, 1.0])!)
    ctx.setLineWidth(lineW)
    ctx.setLineCap(.butt)
    ctx.addPath(smilePath)
    ctx.strokePath()
    ctx.restoreGState()

    // === ^^ ARC EYES (like the reference robot — closed happy eyes) ===
    // Glowing cyan arcs in the upper half of the dark frame
    let paneW = frameW / 2 - lineW / 2
    let eyeY = smileBaseY + (frameRect.maxY - smileBaseY) * 0.48

    for side in [-1.0, 1.0] {
        let paneCenterX: CGFloat
        if side < 0 {
            paneCenterX = frameX + paneW / 2
        } else {
            paneCenterX = midX + lineW / 2 + paneW / 2
        }

        let arcW = paneW * 0.50   // width of each eye arc
        let arcH = 28 * scale      // height of the arc peak

        // Draw happy ^^ arc — single smooth upward curve (bump on top)
        let eyePath = CGMutablePath()
        eyePath.move(to: CGPoint(x: paneCenterX - arcW / 2, y: eyeY))
        eyePath.addCurve(to: CGPoint(x: paneCenterX + arcW / 2, y: eyeY),
                          control1: CGPoint(x: paneCenterX - arcW * 0.15, y: eyeY + arcH),
                          control2: CGPoint(x: paneCenterX + arcW * 0.15, y: eyeY + arcH))

        // Glow behind eye
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14 * scale,
                       color: CGColor(colorSpace: colorSpace, components: [0.3, 0.85, 1.0, 0.6])!)
        ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.45, 0.90, 1.0, 0.9])!)
        ctx.setLineWidth(6 * scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(eyePath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    image.unlockFocus()
    return image
}

// Generate all required icon sizes
let iconsetPath = "/Users/northpaal/Documents/GitHub/spacey/Resources/AppIcon.iconset"

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for (name, size) in sizes {
    let image = generateIcon(size: size)
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        fputs("Failed to generate \(name)\n", stderr)
        continue
    }

    let path = (iconsetPath as NSString).appendingPathComponent("\(name).png")
    try! pngData.write(to: URL(fileURLWithPath: path))
    print("Generated \(name).png (\(size)x\(size))")
}

print("\nIconset created at \(iconsetPath)")
