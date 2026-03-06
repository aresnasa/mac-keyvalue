#!/usr/bin/env swift
// ─────────────────────────────────────────────────────────────────────────────
//  generate_social_preview.swift
//
//  Generates a GitHub social preview image (1280×640) featuring the K🔒V
//  icon design consistent with the app icon, plus tagline and branding.
//
//  Usage:
//    swift scripts/generate_social_preview.swift
//
//  Output:
//    MacKeyValue/Resources/social-preview.png  (1280×640)
// ─────────────────────────────────────────────────────────────────────────────

import AppKit
import Foundation

// ── Paths ───────────────────────────────────────────────────────────────────
let scriptDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
let projectRoot = scriptDir.deletingLastPathComponent()
let outputDir = projectRoot.appendingPathComponent("MacKeyValue/Resources")
let outputPath = outputDir.appendingPathComponent("social-preview.png")

// ── Dimensions ──────────────────────────────────────────────────────────────
let width: CGFloat = 1280
let height: CGFloat = 640

// ── Colour Palette ──────────────────────────────────────────────────────────
let bgDark       = CGColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1.0)
let bgMid        = CGColor(red: 0.11, green: 0.13, blue: 0.20, alpha: 1.0)
let darkSlate    = CGColor(red: 0.18, green: 0.22, blue: 0.33, alpha: 1.0)
let midSlate     = CGColor(red: 0.24, green: 0.29, blue: 0.40, alpha: 1.0)
let lightSlate   = CGColor(red: 0.55, green: 0.60, blue: 0.72, alpha: 1.0)
let goldAccent   = CGColor(red: 0.82, green: 0.70, blue: 0.38, alpha: 1.0)
let goldBright   = CGColor(red: 0.92, green: 0.82, blue: 0.48, alpha: 1.0)
let textWhite    = CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0)
let textDim      = CGColor(red: 0.65, green: 0.68, blue: 0.75, alpha: 1.0)

// ── Helper: Rounded rect path ───────────────────────────────────────────────
func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2)
    let path = CGMutablePath()
    let minX = rect.minX, midX = rect.midX, maxX = rect.maxX
    let minY = rect.minY, midY = rect.midY, maxY = rect.maxY
    path.move(to: CGPoint(x: minX + r, y: minY))
    path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: midY), radius: r)
    path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: midX, y: maxY), radius: r)
    path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: midY), radius: r)
    path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: midX, y: minY), radius: r)
    path.closeSubpath()
    return path
}

// ── Draw the K🔒V icon at a given size centred on (cx, cy) ─────────────────
func drawKLockV(ctx: CGContext, cx: CGFloat, cy: CGFloat, scale: CGFloat) {
    // "scale" is the equivalent of the icon's pixel size
    let s = scale

    // ── Lock body ──
    let lockBodyW = s * 0.190
    let lockBodyH = s * 0.155
    let lockBodyR = lockBodyW * 0.24
    let lockBodyCY = cy - s * 0.035
    let lockBodyTopY = lockBodyCY + lockBodyH / 2
    let lockBodyBotY = lockBodyCY - lockBodyH / 2

    let lbRect = CGRect(x: cx - lockBodyW / 2, y: lockBodyBotY,
                        width: lockBodyW, height: lockBodyH)
    let lbPath = roundedRectPath(lbRect, radius: lockBodyR)

    let lockGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [midSlate, darkSlate] as CFArray,
                              locations: [0.0, 1.0])!

    // Shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010),
                  blur: s * 0.045,
                  color: CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.50))
    ctx.addPath(lbPath)
    ctx.clip()
    ctx.drawLinearGradient(lockGrad,
                           start: CGPoint(x: cx, y: lockBodyTopY),
                           end: CGPoint(x: cx, y: lockBodyBotY),
                           options: [])
    ctx.restoreGState()

    // Highlight on top
    ctx.saveGState()
    ctx.addPath(lbPath)
    ctx.clip()
    let hlColors: [CGColor] = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.14),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ]
    let hlGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: hlColors as CFArray, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(hlGrad,
                           start: CGPoint(x: cx, y: lockBodyTopY),
                           end: CGPoint(x: cx, y: lockBodyCY),
                           options: [])
    ctx.restoreGState()

    // Border
    ctx.saveGState()
    ctx.addPath(lbPath)
    ctx.setStrokeColor(CGColor(red: 0.30, green: 0.35, blue: 0.50, alpha: 0.40))
    ctx.setLineWidth(s * 0.004)
    ctx.strokePath()
    ctx.restoreGState()

    // ── Shackle ──
    let shackleR = lockBodyW * 0.36
    let shackleThickness = s * 0.034
    let shacklePath = CGMutablePath()
    shacklePath.addArc(center: CGPoint(x: cx, y: lockBodyTopY),
                       radius: shackleR,
                       startAngle: .pi, endAngle: 0, clockwise: false)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.005),
                  blur: s * 0.020,
                  color: CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.35))
    ctx.setStrokeColor(midSlate)
    ctx.setLineWidth(shackleThickness)
    ctx.setLineCap(.round)
    ctx.addPath(shacklePath)
    ctx.strokePath()
    ctx.restoreGState()

    // Shackle highlight
    let shackleHlPath = CGMutablePath()
    shackleHlPath.addArc(center: CGPoint(x: cx, y: lockBodyTopY),
                         radius: shackleR,
                         startAngle: .pi * 0.82, endAngle: .pi * 0.22,
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

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.002),
                  blur: s * 0.012,
                  color: CGColor(red: 0.70, green: 0.55, blue: 0.15, alpha: 0.60))
    ctx.setFillColor(goldBright)
    ctx.fillEllipse(in: CGRect(x: cx - khCircleR, y: khCY - khCircleR,
                               width: khCircleR * 2, height: khCircleR * 2))
    ctx.restoreGState()

    // Tapered slot
    let slotTopW = khCircleR * 1.15
    let slotBotW = khCircleR * 0.55
    let slotH    = lockBodyH * 0.28
    let slotTopY = khCY - khCircleR * 0.40

    let slotPath = CGMutablePath()
    slotPath.move(to: CGPoint(x: cx - slotTopW / 2, y: slotTopY))
    slotPath.addLine(to: CGPoint(x: cx + slotTopW / 2, y: slotTopY))
    slotPath.addLine(to: CGPoint(x: cx + slotBotW / 2, y: slotTopY - slotH))
    slotPath.addLine(to: CGPoint(x: cx - slotBotW / 2, y: slotTopY - slotH))
    slotPath.closeSubpath()

    ctx.saveGState()
    ctx.setFillColor(goldAccent)
    ctx.addPath(slotPath)
    ctx.fillPath()
    ctx.restoreGState()

    // ── Letters K and V ──
    let fontSize = s * 0.36
    let letterNSColor = NSColor(red: 0.92, green: 0.93, blue: 0.96, alpha: 1.0)

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

    let lockLeftEdge = cx - lockBodyW / 2
    let kGap = s * 0.020
    let kX = lockLeftEdge - kGap - kSize.width
    let kY = cy - kSize.height / 2 - s * 0.015

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: s * 0.004, height: -s * 0.004),
                  blur: s * 0.018,
                  color: CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.40))
    kText.draw(at: CGPoint(x: kX, y: kY), withAttributes: letterAttrs)
    ctx.restoreGState()

    let vText = "V" as NSString
    let lockRightEdge = cx + lockBodyW / 2
    let vGap = s * 0.020
    let vX = lockRightEdge + vGap
    let vY = kY

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -s * 0.004, height: -s * 0.004),
                  blur: s * 0.018,
                  color: CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.40))
    vText.draw(at: CGPoint(x: vX, y: vY), withAttributes: letterAttrs)
    ctx.restoreGState()

    // ── Connecting lines ──
    let connY = lockBodyCY
    let connH = s * 0.0055

    let leftConnStart = kX + kSize.width + s * 0.002
    let leftConnEnd   = lockLeftEdge - s * 0.002
    if leftConnEnd > leftConnStart {
        let leftConnRect = CGRect(x: leftConnStart, y: connY - connH / 2,
                                  width: leftConnEnd - leftConnStart, height: connH)
        ctx.saveGState()
        let gradL = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [
                                   CGColor(red: 0.55, green: 0.60, blue: 0.72, alpha: 0.0),
                                   CGColor(red: 0.55, green: 0.60, blue: 0.72, alpha: 0.35),
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

    let rightConnStart = lockRightEdge + s * 0.002
    let rightConnEnd   = vX - s * 0.002
    if rightConnEnd > rightConnStart {
        let rightConnRect = CGRect(x: rightConnStart, y: connY - connH / 2,
                                   width: rightConnEnd - rightConnStart, height: connH)
        ctx.saveGState()
        let gradR = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [
                                   CGColor(red: 0.55, green: 0.60, blue: 0.72, alpha: 0.35),
                                   CGColor(red: 0.55, green: 0.60, blue: 0.72, alpha: 0.0),
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

    // ── Golden accent line ──
    let accentY = min(kY, vY) - s * 0.030
    let accentW = s * 0.36
    let accentH = s * 0.005
    let accentRect = CGRect(x: cx - accentW / 2, y: accentY,
                            width: accentW, height: accentH)

    ctx.saveGState()
    let accentGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [
                                    CGColor(red: 0.82, green: 0.70, blue: 0.35, alpha: 0.0),
                                    CGColor(red: 0.88, green: 0.76, blue: 0.40, alpha: 0.55),
                                    CGColor(red: 0.92, green: 0.82, blue: 0.48, alpha: 0.70),
                                    CGColor(red: 0.88, green: 0.76, blue: 0.40, alpha: 0.55),
                                    CGColor(red: 0.82, green: 0.70, blue: 0.35, alpha: 0.0),
                                ] as CFArray,
                                locations: [0.0, 0.20, 0.5, 0.80, 1.0])!
    ctx.addPath(roundedRectPath(accentRect, radius: accentH / 2))
    ctx.clip()
    ctx.drawLinearGradient(accentGrad,
                           start: CGPoint(x: cx - accentW / 2, y: accentY),
                           end: CGPoint(x: cx + accentW / 2, y: accentY),
                           options: [])
    ctx.restoreGState()
}

// ── Draw helper: centred text ───────────────────────────────────────────────
func drawCentredText(_ text: String, ctx: CGContext, centerX: CGFloat, y: CGFloat,
                     font: NSFont, color: NSColor, shadow: NSShadow? = nil,
                     kern: CGFloat = 0) {
    let nsText = text as NSString
    var attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
    ]
    if kern != 0 { attrs[.kern] = kern }
    let size = nsText.size(withAttributes: attrs)
    let x = centerX - size.width / 2

    if let shadow = shadow {
        ctx.saveGState()
        ctx.setShadow(offset: shadow.shadowOffset,
                      blur: shadow.shadowBlurRadius,
                      color: (shadow.shadowColor as? NSColor)?.cgColor
                          ?? CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
    }

    nsText.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)

    if shadow != nil {
        ctx.restoreGState()
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  MAIN — Compose the social preview
// ═══════════════════════════════════════════════════════════════════════════

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    print("❌ Failed to create graphics context")
    image.unlockFocus()
    exit(1)
}

let bounds = CGRect(x: 0, y: 0, width: width, height: height)

// ── 1. Background — dark gradient with subtle radial glow ───────────────
let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [
                            CGColor(red: 0.10, green: 0.12, blue: 0.19, alpha: 1.0),
                            CGColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1.0),
                            CGColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 1.0),
                        ] as CFArray,
                        locations: [0.0, 0.5, 1.0])!

ctx.saveGState()
ctx.drawLinearGradient(bgGrad,
                       start: CGPoint(x: width / 2, y: height),
                       end: CGPoint(x: width / 2, y: 0),
                       options: [])
ctx.restoreGState()

// Subtle radial glow behind the icon area
let glowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [
                              CGColor(red: 0.18, green: 0.22, blue: 0.35, alpha: 0.30),
                              CGColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 0.0),
                          ] as CFArray,
                          locations: [0.0, 1.0])!

ctx.saveGState()
ctx.drawRadialGradient(glowGrad,
                       startCenter: CGPoint(x: width / 2, y: height * 0.55),
                       startRadius: 0,
                       endCenter: CGPoint(x: width / 2, y: height * 0.55),
                       endRadius: 350,
                       options: [])
ctx.restoreGState()

// ── 2. Subtle grid/dot pattern for texture ──────────────────────────────
let dotSpacing: CGFloat = 32
let dotRadius: CGFloat = 0.6
ctx.saveGState()
ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.025))
var dotY: CGFloat = 0
while dotY < height {
    var dotX: CGFloat = 0
    while dotX < width {
        ctx.fillEllipse(in: CGRect(x: dotX - dotRadius, y: dotY - dotRadius,
                                   width: dotRadius * 2, height: dotRadius * 2))
        dotX += dotSpacing
    }
    dotY += dotSpacing
}
ctx.restoreGState()

// ── 3. Draw the K🔒V icon — centred, large ──────────────────────────────
let iconCX = width / 2
let iconCY = height * 0.58
let iconScale: CGFloat = 480

drawKLockV(ctx: ctx, cx: iconCX, cy: iconCY, scale: iconScale)

// ── 4. "KeyValue" title text below icon ─────────────────────────────────
let titleFont = NSFont.systemFont(ofSize: 28, weight: .light)
let titleColor = NSColor(red: 0.70, green: 0.73, blue: 0.80, alpha: 0.80)
drawCentredText("KeyValue", ctx: ctx, centerX: width / 2, y: height * 0.23,
                font: titleFont, color: titleColor, kern: 5.0)

// ── 5. Tagline ──────────────────────────────────────────────────────────
let tagFont = NSFont.systemFont(ofSize: 18, weight: .regular)
let tagColor = NSColor(red: 0.55, green: 0.58, blue: 0.68, alpha: 0.70)
drawCentredText("Secure Password & Key-Value Manager for macOS",
                ctx: ctx, centerX: width / 2, y: height * 0.15,
                font: tagFont, color: tagColor, kern: 1.0)

// ── 6. Feature badges at the bottom ─────────────────────────────────────
let badges = ["AES-256", "Keyboard Simulation", "Clipboard", "Gist Sync", "MIT License"]
let badgeFont = NSFont.systemFont(ofSize: 11, weight: .medium)
let badgeAttrs: [NSAttributedString.Key: Any] = [
    .font: badgeFont,
    .foregroundColor: NSColor(red: 0.60, green: 0.63, blue: 0.72, alpha: 0.80),
    .kern: 0.5,
]

let badgePadH: CGFloat = 14
let badgePadV: CGFloat = 6
let badgeGap: CGFloat = 10
let badgeY: CGFloat = height * 0.06

// Calculate total width
var totalBadgeWidth: CGFloat = 0
var badgeSizes: [CGSize] = []
for badge in badges {
    let size = (badge as NSString).size(withAttributes: badgeAttrs)
    badgeSizes.append(size)
    totalBadgeWidth += size.width + badgePadH * 2
}
totalBadgeWidth += CGFloat(badges.count - 1) * badgeGap

var badgeX = (width - totalBadgeWidth) / 2

for (i, badge) in badges.enumerated() {
    let size = badgeSizes[i]
    let bw = size.width + badgePadH * 2
    let bh = size.height + badgePadV * 2
    let bRect = CGRect(x: badgeX, y: badgeY, width: bw, height: bh)
    let bPath = roundedRectPath(bRect, radius: bh / 2)

    // Badge background
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 0.15, green: 0.18, blue: 0.26, alpha: 0.70))
    ctx.addPath(bPath)
    ctx.fillPath()
    ctx.restoreGState()

    // Badge border
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0.30, green: 0.34, blue: 0.45, alpha: 0.35))
    ctx.setLineWidth(0.8)
    ctx.addPath(bPath)
    ctx.strokePath()
    ctx.restoreGState()

    // Badge text
    (badge as NSString).draw(
        at: CGPoint(x: badgeX + badgePadH, y: badgeY + badgePadV),
        withAttributes: badgeAttrs
    )

    badgeX += bw + badgeGap
}

// ── 7. Subtle golden line accent at top ─────────────────────────────────
let topLineW: CGFloat = 200
let topLineH: CGFloat = 2.5
let topLineRect = CGRect(x: (width - topLineW) / 2, y: height - 30,
                         width: topLineW, height: topLineH)

ctx.saveGState()
let topLineGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [
                                 CGColor(red: 0.82, green: 0.70, blue: 0.35, alpha: 0.0),
                                 CGColor(red: 0.88, green: 0.76, blue: 0.40, alpha: 0.50),
                                 CGColor(red: 0.92, green: 0.82, blue: 0.48, alpha: 0.65),
                                 CGColor(red: 0.88, green: 0.76, blue: 0.40, alpha: 0.50),
                                 CGColor(red: 0.82, green: 0.70, blue: 0.35, alpha: 0.0),
                             ] as CFArray,
                             locations: [0.0, 0.20, 0.5, 0.80, 1.0])!
ctx.addPath(roundedRectPath(topLineRect, radius: topLineH / 2))
ctx.clip()
ctx.drawLinearGradient(topLineGrad,
                       start: CGPoint(x: (width - topLineW) / 2, y: height - 30),
                       end: CGPoint(x: (width + topLineW) / 2, y: height - 30),
                       options: [])
ctx.restoreGState()

// ── 8. Corner vignette ──────────────────────────────────────────────────
let vignetteGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [
                                  CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
                                  CGColor(red: 0, green: 0, blue: 0, alpha: 0.25),
                              ] as CFArray,
                              locations: [0.0, 1.0])!

ctx.saveGState()
ctx.drawRadialGradient(vignetteGrad,
                       startCenter: CGPoint(x: width / 2, y: height / 2),
                       startRadius: min(width, height) * 0.35,
                       endCenter: CGPoint(x: width / 2, y: height / 2),
                       endRadius: sqrt(width * width + height * height) / 2,
                       options: [])
ctx.restoreGState()

image.unlockFocus()

// ═══════════════════════════════════════════════════════════════════════════
//  Save PNG
// ═══════════════════════════════════════════════════════════════════════════

func savePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        print("❌ Failed to create bitmap representation")
        exit(1)
    }

    // Ensure we write at the exact pixel dimensions
    rep.size = NSSize(width: width, height: height)

    guard let pngData = rep.representation(using: .png, properties: [
        .compressionFactor: 0.9,
    ]) else {
        print("❌ Failed to create PNG data")
        exit(1)
    }

    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try pngData.write(to: url)
        print("✅ Social preview saved: \(url.path)")
        print("   Size: \(Int(width))×\(Int(height)) pixels")
        print("   File: \(ByteCountFormatter.string(fromByteCount: Int64(pngData.count), countStyle: .file))")
    } catch {
        print("❌ Failed to write PNG: \(error)")
        exit(1)
    }
}

savePNG(image, to: outputPath)

// ── Usage reminder ──────────────────────────────────────────────────────────
print("")
print("📋 To set as GitHub social preview:")
print("   1. Go to https://github.com/aresnasa/mac-keyvalue/settings")
print("   2. Scroll to 'Social preview'")
print("   3. Click 'Edit' → 'Upload an image'")
print("   4. Upload: MacKeyValue/Resources/social-preview.png")
print("")
print("   Or use gh CLI:")
print("   gh api repos/aresnasa/mac-keyvalue -X PATCH \\")
print("     -f social_preview=\"$(base64 < MacKeyValue/Resources/social-preview.png)\"")
print("")
