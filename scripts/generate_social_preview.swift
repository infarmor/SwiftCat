#!/usr/bin/env swift
// Renders docs/social-preview.png (1280x640), the image GitHub shows when the
// repository is shared. Usage: swift scripts/generate_social_preview.swift [repo-root]
import AppKit

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let size = NSSize(width: 1280, height: 640)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Could not create a drawing context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// Background
NSGradient(colors: [
    NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1),
    NSColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1)
])!.draw(in: NSRect(origin: .zero, size: size), angle: -35)

// Soft glow behind the icon
NSGradient(colors: [
    NSColor(red: 0.20, green: 0.75, blue: 0.95, alpha: 0.28),
    NSColor(red: 0.20, green: 0.75, blue: 0.95, alpha: 0)
])!.draw(fromCenter: NSPoint(x: 270, y: 320), radius: 0,
         toCenter: NSPoint(x: 270, y: 320), radius: 330, options: [])

// Icon
let iconURL = URL(fileURLWithPath: root).appendingPathComponent("docs/icon.png")
if let icon = NSImage(contentsOf: iconURL) {
    icon.draw(in: NSRect(x: 110, y: 160, width: 320, height: 320))
}

func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight,
          color: NSColor, mono: Bool = false) {
    let font = mono
        ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    text.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}

draw("SwiftCat", at: NSPoint(x: 500, y: 340), size: 120, weight: .bold, color: .white)
draw("Native macOS AI coding assistant", at: NSPoint(x: 504, y: 290), size: 40, weight: .medium,
     color: NSColor(white: 1, alpha: 0.80))
draw("Chat  ·  review diffs  ·  built-in terminal", at: NSPoint(x: 506, y: 235), size: 28,
     weight: .regular, color: NSColor(white: 1, alpha: 0.55))
draw("Apple Intelligence   Ollama   OpenRouter", at: NSPoint(x: 506, y: 160), size: 24,
     weight: .medium, color: NSColor(red: 0.35, green: 0.82, blue: 0.95, alpha: 0.95), mono: true)

NSGraphicsContext.restoreGraphicsState()

let output = URL(fileURLWithPath: root).appendingPathComponent("docs/social-preview.png")
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path)")
