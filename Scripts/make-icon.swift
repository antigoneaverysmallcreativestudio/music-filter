#!/usr/bin/env swift
import AppKit
import Foundation

// Run: swift Scripts/make-icon.swift [output.icns] [preview.png]
// Places the user's unmodified music.hand4 artwork on the existing white tile.
// Drawing its existing vector PDF preserves the exact opaque black artwork.
// This application icon is independent of the menu bar's music.hand7 selection.

enum IconError: Error { case renderingFailed, missingArtwork, invalidArtwork, encodingFailed, iconutilFailed }

let fileManager = FileManager.default
let projectURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : projectURL.appendingPathComponent("Resources/AppIcon.icns")
let preview = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : URL(fileURLWithPath: "/tmp/music-filter-app-icon-v4-preview.png")
let artworkURL = projectURL.appendingPathComponent("Artwork/AppIcon/music.hand4.pdf")
guard let artworkDocument = CGPDFDocument(artworkURL as CFURL),
      let artworkPage = artworkDocument.page(at: 1) else {
    throw IconError.missingArtwork
}
let artworkBounds = artworkPage.getBoxRect(.mediaBox)
guard artworkBounds.width > 0, artworkBounds.height > 0 else {
    throw IconError.invalidArtwork
}
let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("MusicFilterIcon-" + UUID().uuidString)
let iconset = temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporaryDirectory) }
try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.renderingFailed
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.setShouldAntialias(true)

    let tile = NSRect(x: 68, y: 68, width: 888, height: 888)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.20)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // A neutral rim keeps the white tile legible on a light desktop.
    NSColor.black.withAlphaComponent(0.09).setStroke()
    tilePath.lineWidth = 2
    tilePath.stroke()

    // Fit the original silhouette into 70% of the white tile, preserving its
    // aspect ratio at every resolution. Only the tile casts a shadow.
    let artworkScale = min(tile.width * 0.70 / artworkBounds.width,
                           tile.height * 0.70 / artworkBounds.height)
    let artworkSize = NSSize(width: artworkBounds.width * artworkScale,
                             height: artworkBounds.height * artworkScale)
    context.cgContext.saveGState()
    context.cgContext.translateBy(x: tile.midX - artworkSize.width / 2,
                                  y: tile.midY - artworkSize.height / 2)
    context.cgContext.scaleBy(x: artworkScale, y: artworkScale)
    context.cgContext.translateBy(x: -artworkBounds.minX, y: -artworkBounds.minY)
    context.cgContext.drawPDFPage(artworkPage)
    context.cgContext.restoreGState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.encodingFailed
    }
    return png
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let filename = "icon_\(size)x\(size)\(suffix).png"
        try renderIcon(pixels: size * scale).write(to: iconset.appendingPathComponent(filename))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { throw IconError.iconutilFailed }
try fileManager.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
try renderIcon(pixels: 1024).write(to: preview)
print("Created \(destination.path)")
print("Preview \(preview.path)")
