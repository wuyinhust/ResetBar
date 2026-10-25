import AppKit

// Place the actual exported, transparent status-button renders on their
// corresponding backgrounds for visual QA; no system appearance is changed.
for (name, white) in [("dark", 0.11), ("light", 0.965)] {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    let source = try Data(contentsOf: folder.appendingPathComponent("status-item-\(name).png"))
    let image = NSBitmapImageRep(data: source)!
    let target = CGContext(data: nil, width: image.pixelsWide, height: image.pixelsHigh,
                           bitsPerComponent: 8, bytesPerRow: image.pixelsWide * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh)
    target.setFillColor(CGColor(gray: white, alpha: 1))
    target.fill(rect)
    target.draw(image.cgImage!, in: rect)
    let result = NSBitmapImageRep(cgImage: target.makeImage()!)
    try result.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("status-item-\(name)-contrast.png"))
    print("\(name): rendered actual native control onto matching background")
}
