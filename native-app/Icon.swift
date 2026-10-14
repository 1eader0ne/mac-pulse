import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let base = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 204, yRadius: 204)
let gradient = NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.64, blue: 0.63, alpha: 1),
                          ending: NSColor(calibratedRed: 0.05, green: 0.29, blue: 0.39, alpha: 1))!
gradient.draw(in: base, angle: -75)
NSColor.white.withAlphaComponent(0.12).setFill()
NSBezierPath(ovalIn: NSRect(x: 170, y: 170, width: 684, height: 684)).fill()
let wave = NSBezierPath(); wave.move(to: NSPoint(x: 212, y: 490))
for point in [NSPoint(x: 347, y: 490), NSPoint(x: 415, y: 660), NSPoint(x: 515, y: 338), NSPoint(x: 591, y: 555), NSPoint(x: 640, y: 490), NSPoint(x: 814, y: 490)] { wave.line(to: point) }
wave.lineWidth = 52; wave.lineJoinStyle = .round; wave.lineCapStyle = .round
NSColor.white.setStroke(); wave.stroke(); image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
