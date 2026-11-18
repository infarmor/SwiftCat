import AppKit

public struct SwiftIconRenderer {
    public static func renderIcon(size: CGFloat = 512) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        
        guard let context = NSGraphicsContext.current?.cgContext else {
            img.unlockFocus()
            return img
        }
        
        let scale = size / 1024.0
        let inset: CGFloat = 100 * scale
        let squircleRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let cornerRadius: CGFloat = 185 * scale
        let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: cornerRadius, yRadius: cornerRadius)
        
        // 1. Ambient Drop Shadow under the glass tile
        context.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowOffset = NSSize(width: 0, height: -14 * scale)
        shadow.shadowBlurRadius = 24 * scale
        shadow.set()
        
        NSColor(calibratedWhite: 0.15, alpha: 0.95).setFill()
        squirclePath.fill()
        context.restoreGState()
        
        // 2. Glass Base Gradient
        context.saveGState()
        squirclePath.addClip()
        
        let baseGradient = NSGradient(colorsAndLocations:
            (NSColor(calibratedWhite: 0.38, alpha: 1.0), 0.0),
            (NSColor(calibratedWhite: 0.24, alpha: 1.0), 0.45),
            (NSColor(calibratedWhite: 0.17, alpha: 1.0), 1.0)
        )
        baseGradient?.draw(in: squircleRect, angle: -90)
        
        // 3. Curved Glass Top Reflection Sheen
        let sheenRect = NSRect(x: inset, y: size / 2.0, width: size - 2 * inset, height: (size / 2.0) - inset)
        let sheenGradient = NSGradient(
            starting: NSColor.white.withAlphaComponent(0.20),
            ending: NSColor.white.withAlphaComponent(0.0)
        )
        sheenGradient?.draw(in: sheenRect, angle: -90)
        
        // 4. Subtle Radial Center Glow
        let centerPt = NSPoint(x: size / 2.0, y: size / 2.0 + 35 * scale)
        let centerGlow = NSGradient(
            starting: NSColor.white.withAlphaComponent(0.12),
            ending: NSColor.clear
        )
        centerGlow?.draw(fromCenter: centerPt, radius: 0, toCenter: centerPt, radius: 360 * scale, options: [])
        context.restoreGState()
        
        // 5. Specular Rim Highlight
        context.saveGState()
        let rimPath = NSBezierPath(roundedRect: squircleRect.insetBy(dx: 1.5 * scale, dy: 1.5 * scale), xRadius: cornerRadius - 1.5 * scale, yRadius: cornerRadius - 1.5 * scale)
        rimPath.lineWidth = 2.5 * scale
        
        let rimGradient = NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(0.72), 0.0),
            (NSColor.white.withAlphaComponent(0.36), 0.3),
            (NSColor.white.withAlphaComponent(0.12), 0.7),
            (NSColor.white.withAlphaComponent(0.22), 1.0)
        )
        rimGradient?.draw(in: rimPath, angle: -90)
        context.restoreGState()
        
        // 6. Swift Bird Glyph
        let symbolPointSize = 470 * scale
        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
        
        if let symbol = NSImage(systemSymbolName: "swift", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let symSize = symbol.size
            let drawX = (size - symSize.width) / 2.0 - 6 * scale
            let drawY = (size - symSize.height) / 2.0 + 8 * scale
            let drawRect = NSRect(x: drawX, y: drawY, width: symSize.width, height: symSize.height)
            
            context.saveGState()
            let glyphShadow = NSShadow()
            glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
            glyphShadow.shadowOffset = NSSize(width: 0, height: -4 * scale)
            glyphShadow.shadowBlurRadius = 8 * scale
            glyphShadow.set()
            
            symbol.draw(in: drawRect)
            context.restoreGState()
        }
        
        img.unlockFocus()
        return img
    }
}
