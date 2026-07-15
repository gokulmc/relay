#!/usr/bin/env swift
import AppKit

// Renders a simple template-friendly Relay icon into Support/AppIcon.icns.
// Usage: swift scripts/render-icon.swift

// iconutil accepts only this set of basenames.
let entries: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("relay-icon-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(calibratedRed: 0.12, green: 0.45, blue: 0.55, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()

    let inset = size * 0.22
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: inset, y: size * 0.35))
    arrow.line(to: NSPoint(x: size * 0.55, y: size * 0.35))
    arrow.line(to: NSPoint(x: size * 0.55, y: size * 0.22))
    arrow.line(to: NSPoint(x: size - inset, y: size * 0.5))
    arrow.line(to: NSPoint(x: size * 0.55, y: size * 0.78))
    arrow.line(to: NSPoint(x: size * 0.55, y: size * 0.65))
    arrow.line(to: NSPoint(x: inset, y: size * 0.65))
    arrow.close()
    NSColor.white.setFill()
    arrow.fill()

    return image
}

let iconset = tmp.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for entry in entries {
    let image = drawIcon(size: CGFloat(entry.size))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to render \(entry.name)\n", stderr)
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent(entry.name))
}

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = repoRoot.appendingPathComponent("Support/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("Wrote \(out.path)")
