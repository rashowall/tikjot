import AppKit
import SwiftUI
import Testing
@testable import tikjot

/// Small in-house snapshot helper (no third-party dependency).
///
/// Renders a SwiftUI view offscreen (`NSHostingView.cacheDisplay`, 1× scale, animations off) and compares it
/// with a reference PNG from `AppTests/__Snapshots__/` (copied into the test bundle as a folder resource).
///
/// The host app is sandboxed, so the tests can't write into the repository. New / re-recorded references and
/// failure artefacts go to `/private/tmp/tikjot-captures/snapshots/` (the debug build's sandbox exception);
/// `scripts/build.sh test` copies `recorded/*.png` back into `AppTests/__Snapshots__/`.
///
/// - Missing reference → recorded, the test fails once ("re-run").
/// - `SNAPSHOT_RECORD=1` (passed as `TEST_RUNNER_SNAPSHOT_RECORD=1` to xcodebuild) → every snapshot is re-recorded.
/// - Mismatch → `<name>-actual.png` and `<name>-diff.png` in `failures/`.
@MainActor
enum Snapshot {
    /// A channel may differ by this much (0–255) before the pixel counts as different (antialiasing noise).
    static let channelTolerance = 12
    /// Share of differing pixels that still passes.
    static let maxDifferentPixels = 0.002
    /// Fresh renders tried before a mismatch counts (see `assert`).
    static let renderAttempts = 3

    static let outputDir = URL(fileURLWithPath: "/private/tmp/tikjot-captures/snapshots")
    static var recordDir: URL { outputDir.appendingPathComponent("recorded") }
    static var failureDir: URL { outputDir.appendingPathComponent("failures") }

    static var recordAll: Bool { ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1" }

    private final class BundleMarker {}

    static var referenceDir: URL? {
        Bundle(for: BundleMarker.self).url(forResource: "__Snapshots__", withExtension: nil)
    }

    /// Renders `view` and checks it against `__Snapshots__/<name>.png`.
    static func assert<V: View>(_ view: V, named name: String, size: CGSize? = nil, dark: Bool,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        guard var image = render(view, size: size, dark: dark) else {
            Issue.record("\(name): rendering failed", sourceLocation: sourceLocation)
            return
        }
        let ref = referenceDir?.appendingPathComponent("\(name).png")
        let refData = ref.flatMap { try? Data(contentsOf: $0) }
        if recordAll || refData == nil {
            // Record the look that repeats (see the retry below), not a rare variant.
            if let second = render(view, size: size, dark: dark), compare(second, image).failure != nil,
               let third = render(view, size: size, dark: dark) {
                image = compare(third, image).failure == nil ? image : second
            }
            write(image.representation(using: .png, properties: [:])!, to: recordDir.appendingPathComponent("\(name).png"))
            if refData == nil {
                Issue.record("\(name): no reference yet — recorded it; scripts/build.sh test copies it into AppTests/__Snapshots__, then re-run",
                             sourceLocation: sourceLocation)
            }
            return
        }
        guard let refImage = NSBitmapImageRep(data: refData!) else {
            Issue.record("\(name): reference PNG unreadable", sourceLocation: sourceLocation)
            return
        }
        var result = compare(image, refImage)
        // AppKit sometimes lays out a fresh TextField's text ~1 px lower (about 1 host in 12, identical frames, no
        // focus — popover-edit-light flaked on it). A new host renders it again; a real change fails every try.
        for _ in 0..<(renderAttempts - 1) where result.failure != nil {
            guard let again = render(view, size: size, dark: dark) else { break }
            image = again
            result = compare(image, refImage)
        }
        if let failure = result.failure {
            write(image.representation(using: .png, properties: [:])!, to: failureDir.appendingPathComponent("\(name)-actual.png"))
            if let diff = result.diff?.representation(using: .png, properties: [:]) {
                write(diff, to: failureDir.appendingPathComponent("\(name)-diff.png"))
            }
            Issue.record("\(name): \(failure) — see \(failureDir.path)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Rendering

    static func render<V: View>(_ view: V, size: CGSize?, dark: Bool) -> NSBitmapImageRep? {
        // cacheDisplay can't draw Liquid Glass (macOS 26): snapshots check the flat look, which every OS shares.
        LiquidGlass.forceFlat = true
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view
            .environment(\.colorScheme, dark ? .dark : .light)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let target = size ?? host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: target),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: target)
        // Let .onAppear / .task / layout settle (two passes catch views that resize after the first one).
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        defer { window.contentView = nil; window.close() }
        let w = Int(target.width.rounded()), h = Int(target.height.rounded())
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = target // 1 pt = 1 px: independent of the display the tests run on
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return rep
    }

    // MARK: Comparison

    struct Result { var failure: String?; var diff: NSBitmapImageRep? }

    /// RGBA8 pixels in sRGB, so both sides are compared in the same format whatever the PNG stored.
    static func pixels(_ rep: NSBitmapImageRep) -> (w: Int, h: Int, data: [UInt8])? {
        guard let cg = rep.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, data) : nil
    }

    static func compare(_ actual: NSBitmapImageRep, _ reference: NSBitmapImageRep) -> Result {
        guard let a = pixels(actual), let r = pixels(reference) else { return Result(failure: "couldn't decode pixels") }
        guard a.w == r.w, a.h == r.h else { return Result(failure: "size \(a.w)×\(a.h) ≠ reference \(r.w)×\(r.h)") }
        var different = 0
        var diff = [UInt8](repeating: 0, count: a.data.count)
        for i in stride(from: 0, to: a.data.count, by: 4) {
            var off = false
            for c in 0..<4 where abs(Int(a.data[i + c]) - Int(r.data[i + c])) > channelTolerance { off = true; break }
            if off {
                different += 1
                diff[i] = 255; diff[i + 3] = 255
            } else {
                // Faded reference so the red pixels stand out.
                diff[i] = r.data[i] / 4; diff[i + 1] = r.data[i + 1] / 4; diff[i + 2] = r.data[i + 2] / 4; diff[i + 3] = 255
            }
        }
        let share = Double(different) / Double(a.w * a.h)
        guard share > maxDifferentPixels else { return Result() }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: a.w, pixelsHigh: a.h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: a.w * 4, bitsPerPixel: 32)
        if let rep, let p = rep.bitmapData { diff.withUnsafeBytes { p.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: diff.count) } }
        return Result(failure: String(format: "%d pixels differ (%.2f %%, allowed %.2f %%)", different, share * 100, maxDifferentPixels * 100), diff: rep)
    }

    private static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
