// Renders app/icon/loophole.svg into the iOS and Android launcher PNGs. macOS only.
// Usage: swift scripts/make_icons.swift   (from the repository root)
// The Android adaptive and monochrome icons are vectors in app/android/app/src/main/res/drawable.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let svg = NSImage(contentsOfFile: "app/icon/loophole.svg")!

/// Opaque RGB, no alpha channel: App Store icons may not have one.
func render(_ size: Int, to path: String) {
  let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.interpolationQuality = .high
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  svg.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.current = nil
  let out = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(out, ctx.makeImage()!, nil)
  guard CGImageDestinationFinalize(out) else { fatalError("could not write \(path)") }
}

let ios = "app/ios/Runner/Assets.xcassets/AppIcon.appiconset/"
let list = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: ios + "Contents.json")))
for entry in (list as! [String: Any])["images"] as! [[String: String]] {
  guard let file = entry["filename"], let size = entry["size"], let scale = entry["scale"] else { continue }
  let points = Double(size.split(separator: "x")[0])!
  render(Int((points * Double(scale.dropLast())!).rounded()), to: ios + file)
}
for (density, size) in ["mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192] {
  render(size, to: "app/android/app/src/main/res/mipmap-\(density)/ic_launcher.png")
}
