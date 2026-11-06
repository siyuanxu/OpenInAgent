import AppKit
import Foundation

struct IconDefinition {
    let dimension: Int
    let filename: String
}

let targetIcons: [IconDefinition] = [
    .init(dimension: 16, filename: "icon_16x16.png"),
    .init(dimension: 32, filename: "icon_16x16@2x.png"),
    .init(dimension: 32, filename: "icon_32x32.png"),
    .init(dimension: 64, filename: "icon_32x32@2x.png"),
    .init(dimension: 128, filename: "icon_128x128.png"),
    .init(dimension: 256, filename: "icon_128x128@2x.png"),
    .init(dimension: 256, filename: "icon_256x256.png"),
    .init(dimension: 512, filename: "icon_256x256@2x.png"),
    .init(dimension: 512, filename: "icon_512x512.png"),
    .init(dimension: 1024, filename: "icon_512x512@2x.png")
]

func usage(_ executable: String) {
    print("Usage: \(executable) <output.iconset>")
}

func folderColor() -> NSColor {
    return NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1.0)
}

func glyphColor() -> NSColor {
    return NSColor(calibratedRed: 0.18, green: 0.16, blue: 0.38, alpha: 1.0)
}

func drawOpenInAgentIcon(size dimension: Int) throws -> NSBitmapImageRep {
    let size = CGSize(width: dimension, height: dimension)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: dimension,
        pixelsHigh: dimension,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(
            domain: "IconGenerator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap context"]
        )
    }
    bitmap.size = NSSize(width: dimension, height: dimension)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphicsContext.cgContext

    context.clear(CGRect(origin: .zero, size: size))
    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    let bounds = CGRect(origin: .zero, size: size)
    let corner = floor(size.width * 0.22)
    let margin = size.width * 0.08
    let cardRect = bounds.insetBy(dx: margin, dy: margin)
    let cardPath = CGPath(
        roundedRect: cardRect,
        cornerWidth: corner,
        cornerHeight: corner,
        transform: nil
    )

    let start = NSColor(calibratedRed: 0.24, green: 0.41, blue: 0.98, alpha: 0.98).cgColor
    let end = NSColor(calibratedRed: 0.41, green: 0.28, blue: 0.94, alpha: 0.98).cgColor
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [start, end] as CFArray,
        locations: [0.0, 1.0]
    )

    context.saveGState()
    context.addPath(cardPath)
    context.clip()
    context.drawLinearGradient(
        gradient!,
        start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
        end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
        options: []
    )
    context.restoreGState()

    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 0.8, color: NSColor.black.withAlphaComponent(0.12).cgColor)
    context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.35).cgColor)
    context.setLineWidth(max(1.0, CGFloat(dimension) * 0.006))
    context.addPath(cardPath)
    context.strokePath()
    context.setShadow(offset: .zero, blur: 0, color: nil)

    let folderWidth = size.width * 0.66
    let folderHeight = size.height * 0.38
    let folderX = size.width * 0.17
    let folderY = size.height * 0.32
    let folderRect = CGRect(
        x: folderX,
        y: folderY,
        width: folderWidth,
        height: folderHeight
    )
    let folderRadius = max(2.0, floor(size.width * 0.055))

    context.saveGState()
    context.setFillColor(folderColor().cgColor)
    let folderBody = CGPath(
        roundedRect: folderRect,
        cornerWidth: folderRadius,
        cornerHeight: folderRadius,
        transform: nil
    )
    context.addPath(folderBody)
    context.fillPath()

    let tabHeight = max(3.0, folderHeight * 0.36)
    let tabWidth = folderWidth * 0.48
    let tabRect = CGRect(
        x: folderRect.minX + folderWidth * 0.10,
        y: folderRect.maxY - (tabHeight * 0.35),
        width: tabWidth,
        height: tabHeight
    )
    let tabPath = CGMutablePath()
    tabPath.move(to: CGPoint(x: tabRect.minX + folderRadius * 0.25, y: tabRect.maxY))
    tabPath.addLine(to: CGPoint(x: tabRect.maxX - folderRadius * 0.20, y: tabRect.maxY))
    tabPath.addLine(to: CGPoint(x: tabRect.maxX, y: tabRect.minY))
    tabPath.addLine(to: CGPoint(x: tabRect.minX, y: tabRect.minY))
    tabPath.closeSubpath()
    context.addPath(tabPath)
    context.fillPath()

    let folderOutline = NSColor(calibratedWhite: 0.9, alpha: 1.0).cgColor
    context.setStrokeColor(folderOutline)
    context.setLineWidth(max(1.0, floor(size.width * 0.007)))
    context.addPath(folderBody)
    context.strokePath()
    context.restoreGState()

    context.setLineCap(.round)
    context.setLineJoin(.round)
    let tip = max(1.0, CGFloat(dimension) * 0.045)
    context.setLineWidth(tip)
    context.setStrokeColor(glyphColor().cgColor)

    let glyphWidth = folderWidth * 0.66
    let glyphHeight = max(2.0, size.height * 0.13)
    let glyphLeft = folderRect.minX + (folderWidth - glyphWidth) * 0.17
    let glyphTop = folderRect.maxY - (folderHeight * 0.18)
    let glyphBaseY = glyphTop - glyphHeight * 0.38
    let glyphMidX = glyphLeft + glyphWidth * 0.52
    let glyphRight = glyphLeft + glyphWidth

    context.move(to: CGPoint(x: glyphLeft, y: glyphBaseY))
    context.addLine(to: CGPoint(x: glyphMidX, y: glyphTop))
    context.addLine(to: CGPoint(x: glyphRight, y: glyphBaseY))
    context.strokePath()

    context.setLineWidth(max(2.0, tip * 0.80))
    let underscoreTop = glyphBaseY - (glyphHeight * 0.33)
    context.move(to: CGPoint(x: glyphRight - glyphWidth * 0.03, y: underscoreTop))
    context.addLine(to: CGPoint(x: glyphRight + glyphWidth * 0.28, y: underscoreTop))
    context.strokePath()

    context.setShadow(offset: .zero, blur: 0, color: nil)
    return bitmap
}

func writePNG(for bitmap: NSBitmapImageRep, at url: URL) throws {
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "IconGenerator",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG data"]
        )
    }

    try pngData.write(to: url)
}

let arguments = CommandLine.arguments
let executable = URL(fileURLWithPath: arguments[0]).lastPathComponent
guard arguments.count == 2 else {
    usage(executable)
    exit(EXIT_FAILURE)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fileManager = FileManager.default
if fileManager.fileExists(atPath: outputDirectory.path) {
    try? fileManager.removeItem(at: outputDirectory)
}
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

var wroteFiles: [String] = []
do {
    for icon in targetIcons {
        let image = try drawOpenInAgentIcon(size: icon.dimension)
        let outputURL = outputDirectory.appendingPathComponent(icon.filename)
        try writePNG(for: image, at: outputURL)
        wroteFiles.append(outputURL.lastPathComponent)
    }
    print("Generated \(wroteFiles.count) icons in \(outputDirectory.path)")
    for file in wroteFiles.sorted() {
        print(file)
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
