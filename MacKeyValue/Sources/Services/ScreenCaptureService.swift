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

    /// Hides the app window, lets the user select a region, and copies the
    /// resulting screenshot to the clipboard as an image.
    @MainActor
    func captureToClipboard() async {
        hideMainWindow()
        // Small delay so the window finishes its hide animation
        try? await Task.sleep(nanoseconds: 300_000_000)

        // screencapture -c  → to clipboard
        //               -i  → interactive selection
        //               -x  → silence shutter sound
        let ok = await runScreencapture(args: ["-c", "-i", "-x"])
        restoreMainWindow()

        if ok {
            NotificationCenter.default.post(
                name: .screenCaptureCompleted,
                object: "截图已复制到剪贴板"
            )
        }
    }

    /// Hides the app window, lets the user select a region, runs Vision OCR
    /// on the captured image, and copies the recognised text to the clipboard.
    @MainActor
    func captureAndOCR() async {
        hideMainWindow()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Capture to a temp file so we can read it back for OCR
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv_ocr_\(Int(Date().timeIntervalSince1970)).png")
            .path

        let ok = await runScreencapture(args: ["-i", "-x", tmpFile])
        restoreMainWindow()

        guard ok, FileManager.default.fileExists(atPath: tmpFile) else { return }
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        guard let image = NSImage(contentsOfFile: tmpFile),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let text = await recognizeText(in: cgImage)
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
            request.recognitionLevel   = .accurate
            request.usesLanguageCorrection = true
            // Prefer Chinese + English; Vision auto-detects if left empty
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

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
