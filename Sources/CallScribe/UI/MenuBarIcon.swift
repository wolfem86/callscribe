import AppKit

/// Monochrome template images built from SF Symbols, so the icon follows the menu bar's light/dark appearance.
enum MenuBarIcon {
    enum Kind {
        case idle, recording, paused, processing, warning, recordingWarning
    }

    private static var cache: [Kind: NSImage] = [:]

    static func image(_ kind: Kind) -> NSImage {
        if let cached = cache[kind] { return cached }
        let image = render(kind)
        cache[kind] = image
        return image
    }

    private static func render(_ kind: Kind) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let base: String
            switch kind {
            case .idle, .processing, .warning: base = "waveform.circle"
            case .recording, .recordingWarning: base = "waveform.circle.fill"
            case .paused: base = "pause.circle"
            }
            if let symbol = symbol(base, pointSize: 15) {
                let origin = NSPoint(x: (rect.width - symbol.size.width) / 2 - 1, y: (rect.height - symbol.size.height) / 2)
                symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }

            let badgeCenter = NSPoint(x: rect.maxX - 4, y: rect.maxY - 4)
            switch kind {
            case .recording:
                cutOut(around: badgeCenter, radius: 4.5)
                NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 3, y: badgeCenter.y - 3, width: 6, height: 6)).fill()
            case .warning, .recordingWarning:
                badge("exclamationmark.circle.fill", at: badgeCenter)
            case .processing:
                badge("arrow.triangle.2.circlepath.circle.fill", at: badgeCenter)
            case .idle, .paused:
                break
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func symbol(_ name: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
    }

    /// Clears a ring around the badge so it reads clearly on top of the base symbol.
    private static func cutOut(around center: NSPoint, radius: CGFloat) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        context.restoreGraphicsState()
    }

    private static func badge(_ name: String, at center: NSPoint) {
        guard let badge = symbol(name, pointSize: 8) else { return }
        cutOut(around: center, radius: max(badge.size.width, badge.size.height) / 2 + 1)
        badge.draw(at: NSPoint(x: center.x - badge.size.width / 2, y: center.y - badge.size.height / 2),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
}
