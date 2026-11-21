import AppKit
import QuartzCore

private struct Raster {
    let width: Int, height: Int
    let bytes: Data
    let png: Data
    var visiblePixels: Int { stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 3 }.count }
    func solidHeight(scale: CGFloat) -> CGFloat {
        var rows = [Int]()
        for y in 0..<height {
            if (0..<width).contains(where: { bytes[(y * width + $0) * 4 + 3] >= 128 }) { rows.append(y) }
        }
        return rows.isEmpty ? 0 : CGFloat(rows.last! - rows.first! + 1) / scale
    }
}

@main enum CursorArtworkChecks {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func raster(_ size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> Raster {
            let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.scaleBy(x: scale, y: scale)
            draw(context)
            return Raster(width: width, height: height,
                bytes: Data(bytes: context.data!, count: width * height * 4),
                png: NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!)
        }
        func render(_ layer: CALayer, scale: CGFloat) -> Raster {
            raster(layer.bounds.size, scale: scale) { layer.render(in: $0) }
        }
        var measurements = [[String: Any]]()
        for scale: CGFloat in [1, 2] {
            let idle = CursorArtwork.makeCursorArtwork()
            let moving = CursorArtwork.makeCursorArtwork(glowIntensity: 1)
            let label = idle.sublayers!.first { $0.name == CursorArtwork.agentLabelName }!
            let text = label.sublayers!.first as! CATextLayer
            check("Agent label at \(scale)x", (text.string as? NSAttributedString)?.string == "Agent")
            let layout = CursorArtwork.cursorLayout()
            check("label below arrow at \(scale)x", label.frame.maxY < layout.cursorRect.minY)
            let glow = idle.sublayers!.first { $0.name == CursorArtwork.motionGlowName }!
            let activeGlow = moving.sublayers!.first { $0.name == CursorArtwork.motionGlowName } as! CAShapeLayer
            check("glow hidden at rest at \(scale)x", glow.opacity == 0)
            check("moving glow has soft shadow at \(scale)x", activeGlow.opacity == 1 && activeGlow.shadowRadius > 0)
            let still = render(idle, scale: scale), motion = render(moving, scale: scale)
            try still.png.write(to: output.appendingPathComponent("cursor-idle-\(Int(scale))x.png"))
            try motion.png.write(to: output.appendingPathComponent("cursor-moving-\(Int(scale))x.png"))
            check("moving glow produces visible halo at \(scale)x", motion.visiblePixels > still.visiblePixels)
            let arrow = CursorArtwork.makeCursorArtwork()
            arrow.sublayers?.filter { $0.name == CursorArtwork.agentLabelName || $0.name == CursorArtwork.motionGlowName }
                .forEach { $0.removeFromSuperlayer() }
            let renderedArrow = render(arrow, scale: scale)
            let native = NSCursor.arrow.image
            let system = raster(native.size, scale: scale) { context in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                native.draw(in: CGRect(origin: .zero, size: native.size))
                NSGraphicsContext.restoreGraphicsState()
            }
            let agentHeight = renderedArrow.solidHeight(scale: scale), nativeHeight = system.solidHeight(scale: scale)
            check("solid arrow height matches Mac cursor at \(scale)x", abs(agentHeight - nativeHeight) <= 2)
            measurements.append(["scale": scale, "agentSolidHeight": agentHeight, "nativeSolidHeight": nativeHeight,
                                 "idleVisiblePixels": still.visiblePixels, "movingVisiblePixels": motion.visiblePixels])
            #if CURSOR_ARTWORK_BASELINE
            let baseline = render(BaselineCursorArtwork.makeCursorArtwork(), scale: scale)
            let baselineMotion = render(BaselineCursorArtwork.makeCursorArtwork(glowIntensity: 1), scale: scale)
            check("approved idle pixels unchanged at \(scale)x", baseline.bytes == still.bytes)
            check("approved moving pixels unchanged at \(scale)x", baselineMotion.bytes == motion.bytes)
            #endif
        }
        let size = 128
        let silhouette = raster(CGSize(width: size, height: size), scale: 1) { context in
            context.addPath(CursorArtwork.agentCursorPath(in: CGRect(x: 0, y: 0, width: size, height: size)))
            context.setFillColor(NSColor.white.cgColor)
            context.fillPath()
        }
        var difference = 0, mainDiagonalDifference = 0, vectorMismatches = 0
        let outline = CursorArtwork.agentCursorPath(in: CGRect(x: 0, y: 0, width: size, height: size))
        for y in 0..<size { for x in 0..<size {
            let first = silhouette.bytes[(y * size + x) * 4 + 3]
            let mirrored = silhouette.bytes[((size - 1 - x) * size + size - 1 - y) * 4 + 3]
            difference += abs(Int(first) - Int(mirrored))
            mainDiagonalDifference += abs(Int(first) - Int(silhouette.bytes[(x * size + y) * 4 + 3]))
            let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
            let reflection = CGPoint(x: Double(size) - point.y, y: Double(size) - point.x)
            if outline.contains(point) != outline.contains(reflection) { vectorMismatches += 1 }
        } }
        let symmetryError = Double(difference) / Double(size * size * 255)
        // Check the path in its own coordinate system. Bitmap row order can
        // reverse which diagonal represents that same reflection.
        check("rear wings retain reflection symmetry", Double(vectorMismatches) / Double(size * size) < 0.001)
        check("offscreen test creates no windows", NSApp.windows.isEmpty)
        check("offscreen test prohibits activation", NSApp.activationPolicy() == .prohibited)
        let value: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "checks": checks, "measurements": measurements, "rasterAntidiagonalDifference": symmetryError,
            "rasterMainDiagonalDifference": Double(mainDiagonalDifference) / Double(size * size * 255),
            "vectorSymmetryMismatches": vectorMismatches,
            "foregroundUnchanged": foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier,
            "physicalInputPosted": false, "windowsCreated": NSApp.windows.count]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        print("\(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count) cursor artwork checks passed")
        exit(checks.allSatisfy { $0["passed"] as? Bool == true } ? 0 : 1)
    }
}
