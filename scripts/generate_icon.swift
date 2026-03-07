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
    // 1. BACKGROUND — white rounded rect with subtle warm gradient
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let cornerRadius = s * 0.22
    let bgInset = s * 0.008
    let bgRect = bounds.insetBy(dx: bgInset, dy: bgInset)
    let bgPath = roundedRectPath(bgRect, radius: cornerRadius)

    let bgColors: [CGColor] = [
        CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1.0),
        CGColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1.0),
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
    // 2. LAYOUT — K [padlock] V
    //
    //    The padlock is large, roughly the same height as the letters.
    //    K and V are tightly positioned against the lock body.
    //    The lock has a tall, clearly visible U-shaped shackle.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let centerX = s * 0.50
    let centerY = s * 0.50   // true centre — lock sits exactly in the middle of the icon

    // ── Colour palette ──
    // Lock body: rich gold metallic (like emoji 🔒)
    let lockDark    = CGColor(red: 0.55, green: 0.40, blue: 0.08, alpha: 1.0)
    let lockMid     = CGColor(red: 0.72, green: 0.55, blue: 0.12, alpha: 1.0)
    let lockLight   = CGColor(red: 0.88, green: 0.72, blue: 0.22, alpha: 1.0)
    let lockBright  = CGColor(red: 1.00, green: 0.86, blue: 0.38, alpha: 1.0)

    // Shackle: slightly darker gold / bronze
    let shackleDark = CGColor(red: 0.50, green: 0.38, blue: 0.10, alpha: 1.0)
    let shackleMid  = CGColor(red: 0.70, green: 0.55, blue: 0.18, alpha: 1.0)
    let shackleHi   = CGColor(red: 0.92, green: 0.78, blue: 0.35, alpha: 1.0)

    // Gold accent for keyhole (darker contrast against gold body)
    let goldDeep    = CGColor(red: 0.40, green: 0.28, blue: 0.05, alpha: 1.0)
    let goldMain    = CGColor(red: 0.55, green: 0.40, blue: 0.08, alpha: 1.0)
    let goldBright  = CGColor(red: 0.75, green: 0.58, blue: 0.15, alpha: 1.0)
    let goldGlow    = CGColor(red: 1.00, green: 0.88, blue: 0.40, alpha: 1.0)

    // Letter colour — deep navy for contrast against gold lock
    let letterColor = CGColor(red: 0.12, green: 0.16, blue: 0.30, alpha: 1.0)

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 3. PADLOCK — The centrepiece
    //
    //    Proportions inspired by a real padlock:
    //      - Body: wide, ~60% of lock height
    //      - Shackle: tall U-shape, ~50% of lock height, clearly above body
    //      - Total lock height ≤ K cap height (never taller than the letters)
    //
    //    The lock is drawn as filled shapes (not stroked arcs).
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // ── Font setup (must precede lock geometry so kSize can constrain lock height) ──
    let fontSize      = s * 0.34
    let letterNSColor = NSColor(cgColor: letterColor)
                        ?? NSColor(red: 0.14, green: 0.20, blue: 0.34, alpha: 1.0)
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
    let kSize = ("K" as NSString).size(withAttributes: letterAttrs)

    // ── K draw-origin (declared here so lock geometry can reference it) ──
    // NSString draws from bounding-box bottom; centering the box at centerY:
    let kY = centerY - kSize.height * 0.50

    // ── Lock proportions — lock spans K's full visual (glyph) height ──
    // Georgia Bold line-box fractions (measured via CoreText):
    //   descent fraction  ≈ 0.19  → K glyph bottom = kY + kSize.height * 0.19
    //   cap-top fraction  ≈ 0.80  → K glyph top    = kY + kSize.height * 0.80
    // shackleTopY = lockBodyBotY + lockTotalH * spanFactor
    //   spanFactor = bodyRatio + straightRatio + outerArcRatio
    //              = 0.55 + 0.18 + (0.55 * 1.10 * 0.38)  ≈ 0.960
    // Solving for lockTotalH so shackleTopY == K glyph top:
    let kGlyphBotFrac: CGFloat = 0.19
    let kGlyphTopFrac: CGFloat = 0.80
    let spanFactor:    CGFloat = 0.55 + 0.18 + 0.55 * 1.10 * 0.38   // ≈ 0.960
    let lockTotalH  = kSize.height * (kGlyphTopFrac - kGlyphBotFrac) / spanFactor
    let lockBodyH   = lockTotalH * 0.55      // body = lower 55 % of lock
    let lockBodyW   = lockBodyH * 1.10       // body slightly wider than tall
    let lockBodyR   = lockBodyW * 0.14

    // Lock bottom aligned to K glyph bottom; everything else derived from this
    let lockBodyBotY = kY + kSize.height * kGlyphBotFrac
    let lockBodyTopY = lockBodyBotY + lockBodyH
    let lockBodyCY   = (lockBodyBotY + lockBodyTopY) / 2

    // Shackle geometry — the U sits on top of the body
    // Make the shackle taller with straight vertical bars + a semicircular arc
    let shackleBarW    = lockBodyW * 0.13  // bar thickness proportional to body
    let shackleInnerW  = lockBodyW * 0.50  // inner gap width
    let shackleOuterW  = shackleInnerW + shackleBarW * 2
    let shackleOuterR  = shackleOuterW / 2
    let shackleInnerR  = shackleInnerW / 2
    // The arc centre is raised above the body top by straight bar height
    let shackleStraightH = lockTotalH * 0.18  // straight vertical section of shackle
    let shackleArcCY   = lockBodyTopY + shackleStraightH  // arc centre above body
    let shackleTopY    = shackleArcCY + shackleOuterR     // very top of shackle

    // ── 3a. Golden glow behind the entire lock (subtle halo) ──
    ctx.saveGState()
    let haloGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [
                                  CGColor(red: 1.0, green: 0.88, blue: 0.40, alpha: 0.18),
                                  CGColor(red: 1.0, green: 0.88, blue: 0.40, alpha: 0.0),
                              ] as CFArray, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(haloGrad,
                           startCenter: CGPoint(x: centerX, y: lockBodyCY),
                           startRadius: 0,
                           endCenter: CGPoint(x: centerX, y: lockBodyCY),
                           endRadius: lockTotalH * 0.8,
                           options: [])
    ctx.restoreGState()

    // ── 3b. Draw shackle (behind the body) ──
    // Build the shackle as a closed filled path:
    //   left bar → outer arc → right bar → inner arc (reversed)
    let shackleFill = CGMutablePath()

    let barLOuterX = centerX - shackleOuterW / 2
    let barLInnerX = centerX - shackleInnerW / 2
    let barRInnerX = centerX + shackleInnerW / 2
    let barROuterX = centerX + shackleOuterW / 2
    let barBotY    = lockBodyTopY - lockBodyH * 0.12  // bars extend slightly into body

    // Left outer edge, going up
    shackleFill.move(to: CGPoint(x: barLOuterX, y: barBotY))
    shackleFill.addLine(to: CGPoint(x: barLOuterX, y: shackleArcCY))
    // Outer arc left → right (going over the top; clockwise=true in flipped AppKit context)
    shackleFill.addArc(center: CGPoint(x: centerX, y: shackleArcCY),
                       radius: shackleOuterR,
                       startAngle: .pi,
                       endAngle: 0,
                       clockwise: true)
    // Right outer edge, going down
    shackleFill.addLine(to: CGPoint(x: barROuterX, y: barBotY))
    // Across bottom of right bar
    shackleFill.addLine(to: CGPoint(x: barRInnerX, y: barBotY))
    // Right inner edge, going up
    shackleFill.addLine(to: CGPoint(x: barRInnerX, y: shackleArcCY))
    // Inner arc right → left (reversed, going over the top)
    shackleFill.addArc(center: CGPoint(x: centerX, y: shackleArcCY),
                       radius: shackleInnerR,
                       startAngle: 0,
                       endAngle: .pi,
                       clockwise: false)
    // Left inner edge, going down
    shackleFill.addLine(to: CGPoint(x: barLInnerX, y: barBotY))
    shackleFill.closeSubpath()

    // Shackle drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006),
                  blur: s * 0.018,
                  color: CGColor(red: 0.30, green: 0.20, blue: 0.05, alpha: 0.45))

    // Shackle gradient fill (metallic: left-dark → center-bright → right-dark)
    ctx.addPath(shackleFill)
    ctx.clip()
    let shackleGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [shackleDark, shackleMid, shackleHi, shackleMid, shackleDark] as CFArray,
                                 locations: [0.0, 0.25, 0.45, 0.70, 1.0])!
    ctx.drawLinearGradient(shackleGrad,
                           start: CGPoint(x: barLOuterX, y: shackleArcCY),
                           end: CGPoint(x: barROuterX, y: shackleArcCY),
                           options: [])
    ctx.restoreGState()

    // Shackle top highlight — bright arc along the very top
    ctx.saveGState()
    let shackleHlArc = CGMutablePath()
    shackleHlArc.addArc(center: CGPoint(x: centerX, y: shackleArcCY),
                        radius: (shackleOuterR + shackleInnerR) / 2,
                        startAngle: .pi * 0.80,
                        endAngle: .pi * 0.20,
                        clockwise: true)
    ctx.setStrokeColor(CGColor(red: 1.00, green: 0.94, blue: 0.70, alpha: 0.60))
    ctx.setLineWidth(shackleBarW * 0.50)
    ctx.setLineCap(.butt)
    ctx.addPath(shackleHlArc)
    ctx.strokePath()
    ctx.restoreGState()

    // Shackle subtle border
    ctx.saveGState()
    ctx.addPath(shackleFill)
    ctx.setStrokeColor(CGColor(red: 0.45, green: 0.32, blue: 0.06, alpha: 0.35))
    ctx.setLineWidth(s * 0.002)
    ctx.strokePath()
    ctx.restoreGState()

    // ── 3c. Lock body — the main rectangle ──
    let lbRect = CGRect(x: centerX - lockBodyW / 2, y: lockBodyBotY,
                        width: lockBodyW, height: lockBodyH)
    let lbPath = roundedRectPath(lbRect, radius: lockBodyR)

    // Body shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008),
                  blur: s * 0.030,
                  color: CGColor(red: 0.30, green: 0.20, blue: 0.05, alpha: 0.50))

    // Body gradient (top bright → bottom dark, 3D metallic feel)
    ctx.addPath(lbPath)
    ctx.clip()
    let bodyGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [lockBright, lockLight, lockMid, lockDark] as CFArray,
                              locations: [0.0, 0.30, 0.65, 1.0])!
    ctx.drawLinearGradient(bodyGrad,
                           start: CGPoint(x: centerX, y: lockBodyTopY),
                           end: CGPoint(x: centerX, y: lockBodyBotY),
                           options: [])
    ctx.restoreGState()

    // Body top-edge highlight (bright band for chrome shine)
    ctx.saveGState()
    ctx.addPath(lbPath)
    ctx.clip()
    let topHlGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [
                                   CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
                                   CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
                               ] as CFArray, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(topHlGrad,
                           start: CGPoint(x: centerX, y: lockBodyTopY),
                           end: CGPoint(x: centerX, y: lockBodyTopY - lockBodyH * 0.25),
                           options: [])
    ctx.restoreGState()

    // Body left-side specular highlight (vertical chrome stripe)
    ctx.saveGState()
    ctx.addPath(lbPath)
    ctx.clip()
    let specX = centerX - lockBodyW * 0.38
    let specW = lockBodyW * 0.12
    let specGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [
                                  CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
                                  CGColor(red: 1, green: 1, blue: 1, alpha: 0.15),
                                  CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
                              ] as CFArray, locations: [0.0, 0.5, 1.0])!
    ctx.drawLinearGradient(specGrad,
                           start: CGPoint(x: specX, y: lockBodyCY),
                           end: CGPoint(x: specX + specW, y: lockBodyCY),
                           options: [])
    ctx.restoreGState()

    // Body border for definition
    ctx.saveGState()
    ctx.addPath(lbPath)
    ctx.setStrokeColor(CGColor(red: 0.45, green: 0.32, blue: 0.06, alpha: 0.35))
    ctx.setLineWidth(s * 0.0025)
    ctx.strokePath()
    ctx.restoreGState()

    // Horizontal divider line near top of body (where shackle enters)
    let divY = lockBodyTopY - lockBodyH * 0.16
    ctx.saveGState()
    ctx.move(to: CGPoint(x: centerX - lockBodyW * 0.42, y: divY))
    ctx.addLine(to: CGPoint(x: centerX + lockBodyW * 0.42, y: divY))
    ctx.setStrokeColor(CGColor(red: 0.45, green: 0.32, blue: 0.06, alpha: 0.20))
    ctx.setLineWidth(s * 0.002)
    ctx.strokePath()
    ctx.restoreGState()

    // ── 3d. Keyhole — golden circle + tapered slot ──

    let khCY = lockBodyCY - lockBodyH * 0.06
    let khR  = lockBodyW * 0.10

    // Outer dark shadow around keyhole
    ctx.saveGState()
    let khGlowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [
                                    CGColor(red: 0.20, green: 0.12, blue: 0.0, alpha: 0.50),
                                    CGColor(red: 0.30, green: 0.20, blue: 0.0, alpha: 0.15),
                                    CGColor(red: 0.40, green: 0.28, blue: 0.0, alpha: 0.0),
                                ] as CFArray,
                                locations: [0.0, 0.45, 1.0])!
    ctx.drawRadialGradient(khGlowGrad,
                           startCenter: CGPoint(x: centerX, y: khCY),
                           startRadius: khR * 0.5,
                           endCenter: CGPoint(x: centerX, y: khCY),
                           endRadius: khR * 3.5,
                           options: [])
    ctx.restoreGState()

    // Keyhole circle — dark cutout with subtle depth
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.002),
                  blur: s * 0.008,
                  color: CGColor(red: 0.10, green: 0.06, blue: 0.0, alpha: 0.70))
    let khCircleRect = CGRect(x: centerX - khR, y: khCY - khR,
                              width: khR * 2, height: khR * 2)
    let khCirclePath = CGPath(ellipseIn: khCircleRect, transform: nil)
    let khGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [goldBright, goldMain, goldDeep] as CFArray,
                            locations: [0.0, 0.5, 1.0])!
    ctx.addPath(khCirclePath)
    ctx.clip()
    ctx.drawLinearGradient(khGrad,
                           start: CGPoint(x: centerX, y: khCY + khR),
                           end: CGPoint(x: centerX, y: khCY - khR),
                           options: [])
    ctx.restoreGState()

    // Tiny bright highlight spot on keyhole rim
    ctx.saveGState()
    let khSpotR = khR * 0.22
    let khSpotCY = khCY + khR * 0.35
    ctx.setFillColor(CGColor(red: 0.90, green: 0.72, blue: 0.30, alpha: 0.50))
    ctx.fillEllipse(in: CGRect(x: centerX - khSpotR, y: khSpotCY - khSpotR,
                               width: khSpotR * 2, height: khSpotR * 2))
    ctx.restoreGState()

    // Tapered slot below keyhole
    let slotTopW = khR * 0.80
    let slotBotW = khR * 0.30
    let slotH    = lockBodyH * 0.22
    let slotTopY = khCY - khR * 0.45

    let slotPath = CGMutablePath()
    slotPath.move(to:    CGPoint(x: centerX - slotTopW / 2, y: slotTopY))
    slotPath.addLine(to: CGPoint(x: centerX + slotTopW / 2, y: slotTopY))
    slotPath.addLine(to: CGPoint(x: centerX + slotBotW / 2, y: slotTopY - slotH))
    slotPath.addLine(to: CGPoint(x: centerX - slotBotW / 2, y: slotTopY - slotH))
    slotPath.closeSubpath()

    ctx.saveGState()
    ctx.setFillColor(goldDeep)
    ctx.addPath(slotPath)
    ctx.fillPath()
    ctx.restoreGState()

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 4. LETTER "K" — positioned tightly left of the lock body
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // (fontSize / serifFont / letterAttrs / kSize already declared above)
    let kText = "K" as NSString

    // Position K: right edge hugs lock body's left edge
    // kY declared above in lock geometry section
    let lockLeftEdge = centerX - lockBodyW / 2
    let kGap = s * 0.038
    let kX   = lockLeftEdge - kGap - kSize.width

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: s * 0.003, height: -s * 0.003),
                  blur: s * 0.008,
                  color: CGColor(red: 0.08, green: 0.12, blue: 0.24, alpha: 0.18))
    kText.draw(at: CGPoint(x: kX, y: kY), withAttributes: letterAttrs)
    ctx.restoreGState()

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 5. LETTER "V" — mirror-symmetric to K, right of lock body
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let vText = "V" as NSString
    let lockRightEdge = centerX + lockBodyW / 2
    let vGap = s * 0.038
    let vX   = lockRightEdge + vGap
    let vY   = kY    // same centre-line as K

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -s * 0.003, height: -s * 0.003),
                  blur: s * 0.008,
                  color: CGColor(red: 0.08, green: 0.12, blue: 0.24, alpha: 0.18))
    vText.draw(at: CGPoint(x: vX, y: vY), withAttributes: letterAttrs)
    ctx.restoreGState()

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 6. CONNECTING LINES — subtle gradient bridges K→lock→V
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let connY = lockBodyCY
    let connH = s * 0.004

    // Left connector: K → lock
    let leftConnStart = kX + kSize.width + s * 0.002
    let leftConnEnd   = lockLeftEdge - s * 0.002
    if leftConnEnd > leftConnStart {
        let rect = CGRect(x: leftConnStart, y: connY - connH / 2,
                          width: leftConnEnd - leftConnStart, height: connH)
        ctx.saveGState()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [
                               CGColor(red: 0.70, green: 0.55, blue: 0.18, alpha: 0.0),
                               CGColor(red: 0.70, green: 0.55, blue: 0.18, alpha: 0.28),
                           ] as CFArray, locations: [0.0, 1.0])!
        ctx.addPath(roundedRectPath(rect, radius: connH / 2))
        ctx.clip()
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: leftConnStart, y: connY),
                               end: CGPoint(x: leftConnEnd, y: connY),
                               options: [])
        ctx.restoreGState()
    }

    // Right connector: lock → V
    let rightConnStart = lockRightEdge + s * 0.002
    let rightConnEnd   = vX - s * 0.002
    if rightConnEnd > rightConnStart {
        let rect = CGRect(x: rightConnStart, y: connY - connH / 2,
                          width: rightConnEnd - rightConnStart, height: connH)
        ctx.saveGState()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [
                               CGColor(red: 0.70, green: 0.55, blue: 0.18, alpha: 0.28),
                               CGColor(red: 0.70, green: 0.55, blue: 0.18, alpha: 0.0),
                           ] as CFArray, locations: [0.0, 1.0])!
        ctx.addPath(roundedRectPath(rect, radius: connH / 2))
        ctx.clip()
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: rightConnStart, y: connY),
                               end: CGPoint(x: rightConnEnd, y: connY),
                               options: [])
        ctx.restoreGState()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 7. GOLDEN ACCENT LINE — decorative rule below the logo
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    let accentY = min(kY, vY) - s * 0.025
    let accentW = s * 0.32
    let accentH = s * 0.004

    let accentRect = CGRect(x: centerX - accentW / 2, y: accentY,
                            width: accentW, height: accentH)

    ctx.saveGState()
    let accentGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [
                                    CGColor(red: 0.88, green: 0.74, blue: 0.28, alpha: 0.0),
                                    CGColor(red: 0.92, green: 0.78, blue: 0.32, alpha: 0.40),
                                    CGColor(red: 1.00, green: 0.88, blue: 0.42, alpha: 0.55),
                                    CGColor(red: 0.92, green: 0.78, blue: 0.32, alpha: 0.40),
                                    CGColor(red: 0.88, green: 0.74, blue: 0.28, alpha: 0.0),
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
    // 8. APP NAME — "KeyValue" below the accent line (≥ 64px only)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    if s >= 64 {
        let labelFontSize = s * 0.062
        let labelFont = NSFont.systemFont(ofSize: labelFontSize, weight: .light)
        let labelColor = NSColor(red: 0.35, green: 0.40, blue: 0.52, alpha: 0.60)

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
            .kern: labelFontSize * 0.14,
        ]

        let labelText = "KeyValue" as NSString
        let labelSize = labelText.size(withAttributes: labelAttrs)
        let labelX = (s - labelSize.width) / 2
        let labelY = accentY - s * 0.016 - labelSize.height

        labelText.draw(at: CGPoint(x: labelX, y: labelY), withAttributes: labelAttrs)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 9. OUTER BORDER — very subtle, defines shape on white backgrounds
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(red: 0.72, green: 0.73, blue: 0.78, alpha: 0.28))
    ctx.setLineWidth(s * 0.003)
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

print("🎨 Generating KeyValue icon — K 🔒 V")
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
print("   Design: K 🔒 V — navy-blue padlock with tall shackle, golden keyhole glow")
print("   Letters K & V tightly flank the lock, symbolising encrypted key-value data")
