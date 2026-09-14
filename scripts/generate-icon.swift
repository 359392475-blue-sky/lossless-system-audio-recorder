import AppKit

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("No graphics context")
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
let colors = [
    NSColor(calibratedRed: 0.20, green: 0.11, blue: 0.48, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.81, green: 0.16, blue: 0.47, alpha: 1).cgColor
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
let roundedRect = CGPath(
    roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880),
    cornerWidth: 210,
    cornerHeight: 210,
    transform: nil
)
context.saveGState()
context.addPath(roundedRect)
context.clip()
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 140, y: 900),
    end: CGPoint(x: 900, y: 100),
    options: []
)

context.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
context.fillEllipse(in: CGRect(x: 180, y: 510, width: 700, height: 700))
context.restoreGState()

context.setStrokeColor(NSColor.white.cgColor)
context.setLineWidth(54)
context.setLineCap(.round)
let heights: [CGFloat] = [180, 310, 470, 650, 430, 300, 170]
let startX: CGFloat = 260
for (index, height) in heights.enumerated() {
    let x = startX + CGFloat(index) * 84
    context.move(to: CGPoint(x: x, y: 512 - height / 2))
    context.addLine(to: CGPoint(x: x, y: 512 + height / 2))
    context.strokePath()
}

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}
try png.write(to: outputURL)
