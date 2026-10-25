import AppKit
// GitHub social preview, 1280×640: icon, name, tagline, the menu bar and the Battery view.
let a = CommandLine.arguments
let icon = NSImage(contentsOfFile: a[2])!, battery = NSImage(contentsOfFile: a[3])!, bar = NSImage(contentsOfFile: a[4])!
let W = 1280, H = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.16, alpha: 1), ending: NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)
icon.draw(in: NSRect(x: 80, y: 400, width: 120, height: 120))
let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 84, weight: .bold), .foregroundColor: NSColor.white]
("WattNook" as NSString).draw(at: NSPoint(x: 222, y: 405), withAttributes: title)
let para = NSMutableParagraphStyle(); para.lineSpacing = 6
let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32, weight: .medium), .foregroundColor: NSColor(white: 0.82, alpha: 1), .paragraphStyle: para]
("Free battery care for Apple Silicon Macs.\nWorks on macOS 27." as NSString).draw(in: NSRect(x: 84, y: 250, width: 640, height: 110), withAttributes: body)
let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: NSColor(white: 0.6, alpha: 1)]
("Heat Protection · limits from 50% · power flow\nAI limits in the menu bar · app uninstaller" as NSString).draw(in: NSRect(x: 84, y: 150, width: 680, height: 80), withAttributes: small)
// Menu-bar strip under the text, rounded.
let barRect = NSRect(x: 84, y: 70, width: 510, height: 45)
NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: barRect, xRadius: 10, yRadius: 10).addClip()
bar.draw(in: barRect); NSGraphicsContext.restoreGraphicsState()
// Battery view on the right, centred.
let bw: CGFloat = 400, bh = bw * battery.size.height / battery.size.width
let shadow = NSShadow(); shadow.shadowBlurRadius = 40; shadow.shadowColor = NSColor(white: 0, alpha: 0.6); shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState(); shadow.set()
let br = NSRect(x: CGFloat(W) - bw - 70, y: (CGFloat(H) - bh)/2, width: bw, height: bh)
let clip = NSBezierPath(roundedRect: br, xRadius: 24, yRadius: 24); NSColor.black.setFill(); clip.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState(); clip.addClip(); battery.draw(in: br); NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
