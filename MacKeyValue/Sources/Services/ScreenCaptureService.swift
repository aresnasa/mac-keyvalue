import AppKit
import Foundation
import Vision

// MARK: - ScreenCaptureService

/// Provides two global-hotkey-driven screen operations:
///   1. **Screenshot → Clipboard** — interactive region capture, result placed
///      on the system clipboard as an image (uses `screencapture -c -i`).
///   2. **Screenshot → OCR → Clipboard** — same capture, then Vision
///      `VNRecognizeTextRequest` extracts all text and places it on the
///      clipboard as a plain string.
///
/// Both operations hide the main KeyValue window beforehand so the app UI is
/// not included in the captured area.
final class ScreenCaptureService {

    static let shared = ScreenCaptureService()
    private init() {}

    // MARK: - Public API

    /// Hides the app window, presents a native crosshair overlay so the user
    /// can drag a region with the mouse, then copies the captured area to the
    /// system clipboard as an image.
    @MainActor
    func captureToClipboard() async {
        hideMainWindow()
        // Let the window finish its hide animation before the overlay appears.
        try? await Task.sleep(nanoseconds: 300_000_000)

        guard let regionArg = await selectScreenRegion() else {
            restoreMainWindow()
            return
        }

        // screencapture -c  → to clipboard
        //               -x  → silence shutter sound
        //               -R  → capture specific rect (x,y,w,h, top-left origin)
        let ok = await runScreencapture(args: ["-c", "-x", "-R", regionArg])
        restoreMainWindow()

        if ok {
            NotificationCenter.default.post(
                name: .screenCaptureCompleted,
                object: "截图已复制到剪贴板"
            )
        }
    }

    /// Hides the app window, presents the crosshair overlay for region
    /// selection, runs Vision OCR on the captured image, and copies the
    /// recognised text to the clipboard.
    @MainActor
    func captureAndOCR() async {
        hideMainWindow()
        try? await Task.sleep(nanoseconds: 300_000_000)

        guard let regionArg = await selectScreenRegion() else {
            restoreMainWindow()
            return
        }

        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv_ocr_\(Int(Date().timeIntervalSince1970)).png")
            .path

        let ok = await runScreencapture(args: ["-x", "-R", regionArg, tmpFile])
        restoreMainWindow()

        guard ok, FileManager.default.fileExists(atPath: tmpFile) else { return }
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        guard let image  = NSImage(contentsOfFile: tmpFile),
              let cgImg  = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let text = await recognizeText(in: cgImg)
        guard !text.isEmpty else {
            NotificationCenter.default.post(
                name: .screenCaptureCompleted,
                object: "OCR：未识别到文字"
            )
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let preview = String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        NotificationCenter.default.post(
            name: .screenCaptureCompleted,
            object: "OCR 已复制：\(preview)\(text.count > 60 ? "…" : "")"
        )
    }

    // MARK: - Interactive Region Selection

    /// Shows a full-screen crosshair overlay on every connected display and
    /// waits for the user to drag a selection rectangle.
    ///
    /// Returns a `screencapture -R` coordinate string `"x,y,w,h"` where the
    /// origin is at the **top-left of the main display** (logical points), or
    /// `nil` when the user presses **Escape** or makes a too-small selection.
    @MainActor
    private func selectScreenRegion() async -> String? {
        await withCheckedContinuation { cont in
            let win = ScreenRegionSelectorWindow()
            win.selectorView?.completion = { nsRect in
                win.orderOut(nil)
                guard let rect = nsRect else {
                    cont.resume(returning: nil)
                    return
                }
                // Convert from NSScreen coordinates (Y↑, origin at bottom-left
                // of main display) to screencapture -R coordinates (Y↓,
                // origin at top-left of main display).
                let mainH = NSScreen.main?.frame.height ?? 0
                let x = Int(rect.minX)
                let y = Int(mainH - rect.maxY)
                let w = max(1, Int(rect.width))
                let h = max(1, Int(rect.height))
                cont.resume(returning: "\(x),\(y),\(w),\(h)")
            }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            _ = win.selectorView?.becomeFirstResponder()
        }
    }

    // MARK: - Vision OCR

    private func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap {
                    $0.topCandidates(1).first?.string
                }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel       = .accurate
            request.usesLanguageCorrection = true
            // Prefer Chinese + English; Vision auto-detects if left empty.
            request.recognitionLanguages   = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("[ScreenCaptureService] Vision OCR error: \(error)")
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: - Shell: screencapture

    /// Runs `/usr/sbin/screencapture` with the given args.
    /// Returns `true` when the process exits with status 0.
    private func runScreencapture(args: [String]) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments     = args
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    cont.resume(returning: proc.terminationStatus == 0)
                } catch {
                    print("[ScreenCaptureService] screencapture error: \(error)")
                    cont.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Window Helpers

    private func hideMainWindow() {
        DispatchQueue.main.async {
            NSApp.windows.forEach { w in
                if w.isKeyWindow || w.isMainWindow { w.orderOut(nil) }
            }
        }
    }

    private func restoreMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted after a screenshot / OCR operation finishes.
    /// `object` is a `String` message suitable for the status bar.
    static let screenCaptureCompleted = Notification.Name("com.mackeyvalue.screenCaptureCompleted")
}

// MARK: - Region Selector Window

/// A borderless, full-screen `NSWindow` that covers every connected display.
/// Used as the container for `ScreenRegionSelectorView`.
private final class ScreenRegionSelectorWindow: NSWindow {

    private(set) var selectorView: ScreenRegionSelectorView?

    init() {
        // Cover the union of all display frames so the overlay spans every monitor.
        let unionRect = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        super.init(
            contentRect: unionRect,
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )
        level              = .screenSaver          // float above everything
        isOpaque           = false
        backgroundColor    = .clear
        ignoresMouseEvents = false
        hasShadow          = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ScreenRegionSelectorView()
        view.frame = NSRect(origin: .zero, size: unionRect.size)
        contentView  = view
        selectorView = view
    }
}

// MARK: - Region Selector View

/// An `NSView` that draws a semi-transparent dark overlay and lets the user
/// drag to select a rectangular region with the mouse.
///
/// - Press **Escape** to cancel.
/// - `completion` fires exactly once with the selected rect in
///   **NSScreen coordinates** (Y↑ from bottom-left of main display), or
///   `nil` when cancelled / selection too small.
private final class ScreenRegionSelectorView: NSView {

    var completion: ((NSRect?) -> Void)?

    private var startPoint:  NSPoint?
    private var currentRect: NSRect?

    // MARK: First-responder

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Mouse Events

    override func mouseDown(with event: NSEvent) {
        startPoint  = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(s.x, p.x), y: min(s.y, p.y),
            width:  abs(p.x - s.x),
            height: abs(p.y - s.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint   = nil
            currentRect  = nil
            needsDisplay = true
        }
        guard let rect = currentRect, rect.width > 5, rect.height > 5 else {
            finish(nil)     // tiny click or accidental drag — treat as cancel
            return
        }
        // Convert view-local rect → window rect → screen rect (NSScreen coords).
        let windowRect = convert(rect, to: nil)
        let screenRect = window?.convertToScreen(windowRect) ?? .zero
        finish(screenRect)
    }

    // MARK: Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) }   // Escape → cancel
    }

    // MARK: One-shot helper

    private func finish(_ rect: NSRect?) {
        completion?(rect)
        completion = nil    // prevent double-firing
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // ── Dark overlay ──────────────────────────────────────────────────
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        guard let rect = currentRect, rect.width > 0, rect.height > 0 else { return }

        // ── Punch a transparent "window" for the selected area ────────────
        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        NSColor.clear.setFill()
        NSBezierPath(rect: rect).fill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)

        // ── Dashed white border ───────────────────────────────────────────
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.setLineDash([5, 3], count: 2, phase: 0)
        border.stroke()

        // ── Corner handles ────────────────────────────────────────────────
        drawCornerHandles(rect)

        // ── Dimension label ───────────────────────────────────────────────
        drawDimensionLabel(for: rect)
    }

    private func drawCornerHandles(_ rect: NSRect) {
        let sz: CGFloat = 6
        let corners: [NSPoint] = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY),
        ]
        NSColor.white.setFill()
        for c in corners {
            let r = NSRect(x: c.x - sz / 2, y: c.y - sz / 2, width: sz, height: sz)
            NSBezierPath(ovalIn: r).fill()
        }
    }

    private func drawDimensionLabel(for rect: NSRect) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let astr = NSAttributedString(string: label, attributes: attrs)
        let sz   = astr.size()
        let pad: CGFloat = 5

        // Prefer placing the label above the selection; move inside if near top edge.
        let labelY: CGFloat = (rect.maxY + sz.height + 8 <= bounds.maxY)
            ? rect.maxY + 5
            : rect.maxY - sz.height - 8

        let bgRect = NSRect(
            x: rect.minX,
            y: labelY - pad + 1,
            width:  sz.width + pad * 2 + 2,
            height: sz.height + pad
        )
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()
        astr.draw(at: NSPoint(x: rect.minX + pad, y: labelY))
    }
}
