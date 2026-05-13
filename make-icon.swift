// Generates AppIcon.icns by rendering SF Symbol on a colored rounded-square
// background at every required size, then assembling with iconutil. Run:
//
//   swift make-icon.swift
//
// Output: Bundle/AppIcon.icns

import AppKit
import Foundation

let symbol = "battery.100.bolt"

// Required sizes for a macOS iconset (pt @ 1x and @ 2x).
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

let iconsetDir = URL(fileURLWithPath: "Bundle/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func render(size pixels: Int) -> NSImage {
    let size = CGFloat(pixels)
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    // Background: rounded square with a soft gradient (Apple style).
    let radius = size * 0.225
    let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                            xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.55, blue: 0.95, alpha: 1.0),  // top
        NSColor(srgbRed: 0.05, green: 0.30, blue: 0.75, alpha: 1.0),  // bottom
    ])!
    gradient.draw(in: path, angle: 270)

    // SF Symbol, white-tinted, centered, ~60% of size.
    let symbolPointSize = size * 0.60
    let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        .applying(.preferringMulticolor())
    let baseSymbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    let sf = (baseSymbol?.withSymbolConfiguration(config)) ?? baseSymbol
    if let sf {
        // Tint to white by drawing in a CGContext with destination-in mask.
        let symbolSize = sf.size
        let drawRect = NSRect(
            x: (size - symbolSize.width) / 2,
            y: (size - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )

        // Render the symbol shape filled with white.
        let symbolImage = NSImage(size: symbolSize, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            sf.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
        symbolImage.draw(in: drawRect)
    }

    img.unlockFocus()
    return img
}

for entry in entries {
    let img = render(size: entry.pixels)
    let tiff = img.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    let png = rep.representation(using: .png, properties: [:])!
    let url = iconsetDir.appendingPathComponent(entry.name)
    try png.write(to: url)
    print("✓ \(entry.name) (\(entry.pixels)×\(entry.pixels))")
}

print("\nAssembling AppIcon.icns…")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir.path, "-o", "Bundle/AppIcon.icns"]
try task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("✓ Bundle/AppIcon.icns")
    try? FileManager.default.removeItem(at: iconsetDir)
} else {
    print("✗ iconutil failed with status \(task.terminationStatus)")
    exit(1)
}
