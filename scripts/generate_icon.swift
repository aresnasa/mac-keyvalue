#!/usr/bin/env swift

import AppKit
import Foundation

// MARK: - Icon Sizes required for macOS App Store

struct IconSize {
    let size: Int
    let scale: Int
    var pixelSize: Int { size * scale }
    var filename: String {
        if scale == 1 {
            return "icon_\(size)x\(size).png"
        } else {
            return "icon_\(size)x\(size)@\(scale)x.png"
        }
    }
}

let iconSizes: [IconSize] = [
    IconSize(size: 16, scale: 1),
    IconSize(size: 16, scale: 2),
    IconSize(size: 32, scale: 1),
    IconSize(size: 32, scale: 2),
    IconSize(size: 128, scale: 1),
    IconSize(size: 128, scale: 2),
    IconSize(size: 256, scale: 1),
    IconSize(size: 256, scale: 2),
    IconSize(size: 512, scale: 1),
    IconSize(size: 512, scale: 2),
]

// MARK: - Helper: draw a rounded rect path

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let minX = rect.minX, midX = rect.midX, maxX = rect.maxX
    let minY = rect.minY, midY = rect.midY, maxY = rect.maxY
    let r = min(radius, rect.width / 2, rect.height / 2)
    path.move(to: CGPoint(x: minX + r, y: minY))
    path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: midY), radius: r)
    path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: midX, y: maxY), radius: r)
    path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: midY), radius: r)
    path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: midX, y: minY), radius: r)
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func drawIcon(size pixelSize: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    img.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    let s = CGFloat(pixelSize)
    let bounds = CGRect(x: 0, y: 0, width: s, height: s)

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 1. BACKGROUND — white rounded rect
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let cornerRadius = s * 0.22
    let bgInset = s * 0.008
    let bgRect = bounds.insetBy(dx: bgInset, dy: bgInset)
    let bgPath = roundedRectPath(bgRect, radius: cornerRadius)

    // Clean white with a very subtle warm gradient for depth
    let bgColors: [CGColor] = [
        CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1.0),
        CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1.0),
    ]
    let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: bgColors as CFArray,
                            locations: [0.0, 0.6, 1.0])!

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.drawLinearGradient(bgGrad,
                           start: CGPoint(x: s / 2, y: s),
                           end: CGPoint(x: s / 2, y: 0),
                           options: [])
    ctx.restoreGState()

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 2. COMPOSITION LAYOUT — K [lock] V centred symmetrically
    //
    //    The lock sits at the exact horizontal centre.
    //    K is on the left, V mirrors on the right.
    //    Both letters' inner edges "hug" the lock so they feel connected.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let centerX = s * 0.50
    // Shift the whole K-lock-V composition slightly above true centre
    // so there is room for the "KeyValue" label underneath.
    let centerY = s * 0.52

    // Colour palette — sophisticated dark slate-blue
    let darkSlate   = CGColor(red: 0.18, green: 0.22, blue: 0.33, alpha: 1.0)
    let midSlate    = CGColor(red: 0.24, green: 0.29, blue: 0.40, alpha: 1.0)
    // lightSlate reserved for future use
    // let lightSlate = CGColor(red: 0.32, green: 0.37, blue: 0.48, alpha: 1.0)
    let goldAccent  = CGColor(red: 0.82, green: 0.70, blue: 0.38, alpha: 1.0)
    let goldBright  = CGColor(red: 0.92, green: 0.82, blue: 0.48, alpha: 1.0)

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 3. CENTRAL LOCK — the centrepiece that connects K and V
    //
    //    Drawn with Core Graphics for pixel-perfect control.
    //    Consists of: body (rounded rect) + shackle (arc) + keyhole
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let lockBodyW = s * 0.190
    let lockBodyH = s * 0.155
    let lockBodyR = lockBodyW * 0.24
    let lockBodyCY = centerY - s * 0.035     // body is slightly below composition centre
    let lockBodyTopY = lockBodyCY + lockBodyH / 2
    let lockBodyBotY = lockBodyCY - lockBodyH / 2

    // ── Lock body ──
    let lbRect = CGRect(x: centerX - lockBodyW / 2, y: lockBodyBotY,
                        width: lockBodyW, height: lockBodyH)
    let lbPath = roundedRectPath(lbRect, radius: lockBodyR)

    let lockGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [midSlate, darkSlate] as CFArray,
                              locations: [0.0, 1.0])!

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010),
                  blur: s * 0.035,
                  color: CGColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 0.40))
    ctx.addPath(lbPath)
    ctx.clip()
    ctx.drawLinearGradient(lockGrad,
                           start: CGPoint(x: centerX, y: lockBodyTopY),
                           end: CGPoint(x: centerX, y: lockBodyBotY),
                           options: [])
    ctx.restoreGState()

    // Inner highlight on top edge of lock body
    ctx.saveGState()
    ctx.addPath(lbPath)
    ctx.clip()
    let lockHlColors: [CGColor] = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.14),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ]
    let lockHlGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: lockHlColors as CFArray, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(lockHlGrad,
                           start: CGPoint(x: centerX, y: lockBodyTopY),
                           end: CGPoint(x: centerX, y: lockBodyCY),
                           options: [])
    ctx.restoreGState()

    // Subtle border around lock body
    ctx.saveGState()
    ctx.addPath(lbPath)
    ctx.setStrokeColor(CGColor(red: 0.12, green: 0.14, blue: 0.22, alpha: 0.20))
    ctx.setLineWidth(s * 0.003)
    ctx.strokePath()
    ctx.restoreGState()

    // ── Shackle ──
    let shackleR = lockBodyW * 0.36
    let shackleThickness = s * 0.034

    let shacklePath = CGMutablePath()
    shacklePath.addArc(center: CGPoint(x: centerX, y: lockBodyTopY),
                       radius: shackleR,
                       startAngle: .pi,
                       endAngle: 0,
                       clockwise: false)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.005),
                  blur: s * 0.015,
                  color: CGColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 0.30))
    ctx.setStrokeColor(midSlate)
    ctx.setLineWidth(shackleThickness)
    ctx.setLineCap(.round)
    ctx.addPath(shacklePath)
    ctx.strokePath()
    ctx.restoreGState()

    // Shackle highlight (thin white arc on the upper-left portion)
    let shackleHlPath = CGMutablePath()
    shackleHlPath.addArc(center: CGPoint(x: centerX, y: lockBodyTopY),
                         radius: shackleR,
                         startAngle: .pi * 0.82,
                         endAngle: .pi * 0.22,
                         clockwise: false)
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(shackleThickness * 0.40)
    ctx.setLineCap(.butt)
    ctx.addPath(shackleHlPath)
    ctx.strokePath()
    ctx.restoreGState()

    // ── Keyhole — golden accent ──
    let khCircleR = lockBodyW * 0.10
    let khCY = lockBodyCY + lockBodyH * 0.10

    // Circle
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.002),
                  blur: s * 0.008,
                  color: CGColor(red: 0.70, green: 0.55, blue: 0.15, alpha: 0.50))
    ctx.setFillColor(goldBright)
    ctx.fillEllipse(in: CGRect(x: centerX - khCircleR, y: khCY - khCircleR,
                               width: khCircleR * 2, height: khCircleR * 2))
    ctx.restoreGState()

    // Tapered slot below keyhole circle
    let slotTopW  = khCircleR * 1.15
    let slotBotW  = khCircleR * 0.55
    let slotH     = lockBodyH * 0.28
    let slotTopY  = khCY - khCircleR * 0.40

    let slotPath = CGMutablePath()
    slotPath.move(to: CGPoint(x: centerX - slotTopW / 2, y: slotTopY))
    slotPath.addLine(to: CGPoint(x: centerX + slotTopW / 2, y: slotTopY))
    slotPath.addLine(to: CGPoint(x: centerX + slotBotW / 2, y: slotTopY - slotH))
    slotPath.addLine(to: CGPoint(x: centerX - slotBotW / 2, y: slotTopY - slotH))
    slotPath.closeSubpath()

    ctx.saveGState()
    ctx.setFillColor(goldAccent)
    ctx.addPath(slotPath)
    ctx.fillPath()
    ctx.restoreGState()

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 4. LETTER "K" — drawn with NSAttributedString for clean typography
    //
    //    Uses Georgia (serif) for elegance.  Positioned so its right
    //    edge visually touches / slightly overlaps the lock's left side.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let fontSize = s * 0.36
    let letterNSColor = NSColor(cgColor: darkSlate) ?? NSColor(red: 0.18, green: 0.22, blue: 0.33, alpha: 1.0)

    // Try serif fonts in preference order
    let serifFont: NSFont = {
        let candidates = ["Georgia-Bold", "TimesNewRomanPS-BoldMT", "Palatino-Bold"]
        for name in candidates {
            if let f = NSFont(name: name, size: fontSize) { return f }
        }
        return NSFont.systemFont(ofSize: fontSize, weight: .bold)
    }()

    let letterAttrs: [NSAttributedString.Key: Any] = [
        .font: serifFont,
        .foregroundColor: letterNSColor,
    ]

    let kText = "K" as NSString
    let kSize = kText.size(withAttributes: letterAttrs)

    // Position K so its right edge is near the lock's left edge
    let lockLeftEdge = centerX - lockBodyW / 2
    let kGap = s * 0.020   // small breathing room
    let kX = lockLeftEdge - kGap - kSize.width
    let kY = centerY - kSize.height / 2 - s * 0.015  // fine-tune vertical alignment

    // Shadow behind K
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: s * 0.004, height: -s * 0.004),
                  blur: s * 0.012,
                  color: CGColor(red: 0.10, green: 0.12, blue: 0.22, alpha: 0.22))
    kText.draw(at: CGPoint(x: kX, y: kY), withAttributes: letterAttrs)
    ctx.restoreGState()

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 5. LETTER "V" — mirror-symmetric to K
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let vText = "V" as NSString
    // V has the same metrics as K for this serif font

    let lockRightEdge = centerX + lockBodyW / 2
    let vGap = s * 0.020
    let vX = lockRightEdge + vGap
    let vY = kY  // same baseline as K

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -s * 0.004, height: -s * 0.004),
                  blur: s * 0.012,
                  color: CGColor(red: 0.10, green: 0.12, blue: 0.22, alpha: 0.22))
    vText.draw(at: CGPoint(x: vX, y: vY), withAttributes: letterAttrs)
    ctx.restoreGState()

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 6. CONNECTING LINES — subtle horizontal bridges K→lock→V
    //
    //    Gradient-faded lines that visually tie the three elements.
    //    Drawn at the vertical midpoint of the composition.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let connY = lockBodyCY
    let connH = s * 0.0055

    // Left connector: K right edge → lock left edge
    let leftConnStart = kX + kSize.width + s * 0.002
    let leftConnEnd   = lockLeftEdge - s * 0.002
    if leftConnEnd > leftConnStart {
        let leftConnRect = CGRect(x: leftConnStart, y: connY - connH / 2,
                                  width: leftConnEnd - leftConnStart, height: connH)
        ctx.saveGState()
        let gradL = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [
                                   CGColor(red: 0.22, green: 0.27, blue: 0.38, alpha: 0.0),
                                   CGColor(red: 0.22, green: 0.27, blue: 0.38, alpha: 0.35),
                               ] as CFArray,
                               locations: [0.0, 1.0])!
        ctx.addPath(roundedRectPath(leftConnRect, radius: connH / 2))
        ctx.clip()
        ctx.drawLinearGradient(gradL,
                               start: CGPoint(x: leftConnStart, y: connY),
                               end: CGPoint(x: leftConnEnd, y: connY),
                               options: [])
        ctx.restoreGState()
    }

    // Right connector: lock right edge → V left edge
    let rightConnStart = lockRightEdge + s * 0.002
    let rightConnEnd   = vX - s * 0.002
    if rightConnEnd > rightConnStart {
        let rightConnRect = CGRect(x: rightConnStart, y: connY - connH / 2,
                                   width: rightConnEnd - rightConnStart, height: connH)
        ctx.saveGState()
        let gradR = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [
                                   CGColor(red: 0.22, green: 0.27, blue: 0.38, alpha: 0.35),
                                   CGColor(red: 0.22, green: 0.27, blue: 0.38, alpha: 0.0),
                               ] as CFArray,
                               locations: [0.0, 1.0])!
        ctx.addPath(roundedRectPath(rightConnRect, radius: connH / 2))
        ctx.clip()
        ctx.drawLinearGradient(gradR,
                               start: CGPoint(x: rightConnStart, y: connY),
                               end: CGPoint(x: rightConnEnd, y: connY),
                               options: [])
        ctx.restoreGState()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 7. GOLDEN ACCENT LINE — thin decorative rule below the logo mark
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let accentY = min(kY, vY) - s * 0.030
    let accentW = s * 0.36
    let accentH = s * 0.005

    let accentRect = CGRect(x: centerX - accentW / 2, y: accentY,
                            width: accentW, height: accentH)

    ctx.saveGState()
    let accentGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [
                                    CGColor(red: 0.82, green: 0.70, blue: 0.35, alpha: 0.0),
                                    CGColor(red: 0.88, green: 0.76, blue: 0.40, alpha: 0.45),
                                    CGColor(red: 0.92, green: 0.82, blue: 0.48, alpha: 0.55),
                                    CGColor(red: 0.88, green: 0.76, blue: 0.40, alpha: 0.45),
                                    CGColor(red: 0.82, green: 0.70, blue: 0.35, alpha: 0.0),
                                ] as CFArray,
                                locations: [0.0, 0.20, 0.5, 0.80, 1.0])!
    ctx.addPath(roundedRectPath(accentRect, radius: accentH / 2))
    ctx.clip()
    ctx.drawLinearGradient(accentGrad,
                           start: CGPoint(x: centerX - accentW / 2, y: accentY),
                           end: CGPoint(x: centerX + accentW / 2, y: accentY),
                           options: [])
    ctx.restoreGState()

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 8. APP NAME — "KeyValue" in a clean light weight below the accent
    //    Only drawn at sizes where text is legible (>= 64px)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    if s >= 64 {
        let labelFontSize = s * 0.068
        let labelFont = NSFont.systemFont(ofSize: labelFontSize, weight: .light)
        let labelColor = NSColor(red: 0.35, green: 0.38, blue: 0.48, alpha: 0.70)

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
            .kern: labelFontSize * 0.15,
        ]

        let labelText = "KeyValue" as NSString
        let labelSize = labelText.size(withAttributes: labelAttrs)
        let labelX = (s - labelSize.width) / 2
        let labelY = accentY - s * 0.020 - labelSize.height

        labelText.draw(at: CGPoint(x: labelX, y: labelY), withAttributes: labelAttrs)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 9. OUTER BORDER — very subtle, defines shape on white backgrounds
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(red: 0.72, green: 0.73, blue: 0.78, alpha: 0.35))
    ctx.setLineWidth(s * 0.004)
    ctx.strokePath()
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

// MARK: - Save PNG

func savePNG(_ image: NSImage, pixelSize: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pixelSize,
                               pixelsHigh: pixelSize,
                               bitsPerSample: 8,
                               samplesPerPixel: 4,
                               hasAlpha: true,
                               isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0,
                               bitsPerPixel: 0)!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        print("  ❌ Failed to create PNG data for \(url.lastPathComponent)")
        return
    }

    do {
        try pngData.write(to: url)
        print("  ✅ \(url.lastPathComponent) (\(pixelSize)×\(pixelSize))")
    } catch {
        print("  ❌ Failed to write \(url.lastPathComponent): \(error)")
    }
}

// MARK: - Main

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let projectRoot = scriptDir.deletingLastPathComponent()

let iconsetDir = projectRoot
    .appendingPathComponent("MacKeyValue")
    .appendingPathComponent("Resources")
    .appendingPathComponent("AppIcon.appiconset")

let assetsIconsetDir = projectRoot
    .appendingPathComponent("MacKeyValue")
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

print("🎨 Generating KeyValue icon — K 🔒 V (white, symmetric, serif)")
print("   Target: \(iconsetDir.path)")

// Ensure directories exist
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: assetsIconsetDir, withIntermediateDirectories: true)

for iconSize in iconSizes {
    let px = iconSize.pixelSize
    let image = drawIcon(size: px)
    let url = iconsetDir.appendingPathComponent(iconSize.filename)
    savePNG(image, pixelSize: px, to: url)

    // Copy to assets catalog too
    let assetsURL = assetsIconsetDir.appendingPathComponent(iconSize.filename)
    savePNG(image, pixelSize: px, to: assetsURL)
}

// ── Contents.json for both iconset directories ──
let contentsJSON = """
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

for dir in [iconsetDir, assetsIconsetDir] {
    let contentsURL = dir.appendingPathComponent("Contents.json")
    try! contentsJSON.write(to: contentsURL, atomically: true, encoding: .utf8)
}
print("\n  ✅ Contents.json (both locations)")

// ── Generate .icns file ──
print("\n🔧 Generating AppIcon.icns …")

let icnsURL = projectRoot
    .appendingPathComponent("MacKeyValue")
    .appendingPathComponent("Resources")
    .appendingPathComponent("AppIcon.icns")

let tmpIconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: tmpIconset)
try? FileManager.default.createDirectory(at: tmpIconset, withIntermediateDirectories: true)

for iconSize in iconSizes {
    let srcURL = iconsetDir.appendingPathComponent(iconSize.filename)
    let dstURL = tmpIconset.appendingPathComponent(iconSize.filename)
    try? FileManager.default.copyItem(at: srcURL, to: dstURL)
}

let iconutilProcess = Process()
iconutilProcess.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutilProcess.arguments = ["-c", "icns", "-o", icnsURL.path, tmpIconset.path]
let pipe = Pipe()
iconutilProcess.standardError = pipe

do {
    try iconutilProcess.run()
    iconutilProcess.waitUntilExit()
    if iconutilProcess.terminationStatus == 0 {
        print("  ✅ AppIcon.icns created")
    } else {
        let errData = pipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        print("  ⚠️  iconutil exited with \(iconutilProcess.terminationStatus): \(errStr)")
    }
} catch {
    print("  ❌ Failed to run iconutil: \(error)")
}

try? FileManager.default.removeItem(at: tmpIconset)

print("\n✅ Icon generation complete!")
print("   Design: K 🔒 V — white background, serif K & V, central lock with gold keyhole")
print("   Symmetric layout, platform-neutral (no Mac branding)")
