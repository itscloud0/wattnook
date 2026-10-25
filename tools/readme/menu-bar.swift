import AppKit
import ImageIO
import UniformTypeIdentifiers

// Composes the README menu-bar animation: WattNook's real status-item images
// (template, drawn white) on a dark macOS menu bar beside a few system items.
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let items = args.dropFirst(2).map { NSImage(contentsOfFile: $0)! }
let scale: CGFloat = 2, width: CGFloat = 340, height: CGFloat = 30
let px = NSSize(width: width*scale, height: height*scale)

func symbol(_ name: String, _ size: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}
func white(_ image: NSImage) -> NSImage {
    let copy = NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        NSColor.white.set(); rect.fill(using: .sourceAtop)
        return true
    }
    return copy
}

func frame(_ item: NSImage) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.12, blue: 0.20, alpha: 1),
                              ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.10, alpha: 1))!
    gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 0)
    // Right to left: clock, Control Center, Wi-Fi, then WattNook.
    let clock = "Sun 25 Oct  14:05" as NSString
    let clockStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
    var x = width - 12 - clock.size(withAttributes: clockStyle).width
    clock.draw(at: NSPoint(x: x, y: (height - clock.size(withAttributes: clockStyle).height)/2), withAttributes: clockStyle)
    for name in ["switch.2", "wifi"] {
        let s = white(symbol(name, 13))
        x -= 16 + s.size.width
        s.draw(in: NSRect(x: x, y: (height - s.size.height)/2, width: s.size.width, height: s.size.height))
    }
    let item = white(item)
    x -= 14 + item.size.width
    item.draw(in: NSRect(x: x, y: (height - item.size.height)/2, width: item.size.width, height: item.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

let delays = [2.4] + Array(repeating: 1.6, count: items.count - 1)
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, items.count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (i, item) in items.enumerated() {
    let image = frame(item)
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[i]]] as CFDictionary)
    if i == 1 { // a still of the Claude page for previews
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try! png.write(to: out.deletingPathExtension().appendingPathExtension("png"))
    }
}
precondition(CGImageDestinationFinalize(dest))
