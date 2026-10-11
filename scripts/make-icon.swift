// Draws the 1024×1024 app icon PNG. Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824×824 rounded square centered on a 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
           ending: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.16, alpha: 1))!.draw(in: path, angle: -90)

// Waveform bars.
let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.9, 0.62, 0.38, 0.55, 0.3]
let barWidth: CGFloat = 46, gap: CGFloat = 30
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = tile.midX - totalWidth / 2
NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
for h in heights {
    let height = 520 * h
    NSBezierPath(roundedRect: NSRect(x: x, y: tile.midY - height / 2, width: barWidth, height: height),
                 xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: output)
