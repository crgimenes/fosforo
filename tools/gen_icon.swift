import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The app icon from fosforo's kamon (assets/kamon.svg, circles only, drawn here
// at every size): macOS wants the rounded square in the artwork, iOS masks
// a full square itself.
// usage: swift tools/gen_icon.swift OUTDIR

func kamon(size: Int, rounded: Bool) -> CGImage {
  // iOS's square is opaque, and the App Store refuses an icon with alpha
  let alpha: CGImageAlphaInfo = rounded ? .premultipliedLast : .noneSkipLast
  let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: alpha.rawValue)!
  let s = CGFloat(size)
  // the macOS shape: 824 of 1024 points, corners at 185/824 of the side
  let side = rounded ? s * 824 / 1024 : s
  let origin = (s - side) / 2
  let square = CGRect(x: origin, y: origin, width: side, height: side)
  ctx.setFillColor(CGColor(gray: 0, alpha: 1))
  if rounded {
    ctx.addPath(CGPath(roundedRect: square, cornerWidth: side * 185 / 824, cornerHeight: side * 185 / 824, transform: nil))
    ctx.fillPath()
  } else {
    ctx.fill(square)
  }
  let k = side / 200  // the SVG is 200x200
  func disc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, white: Bool) {
    ctx.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
    ctx.fillEllipse(
      in: CGRect(x: origin + (cx - r) * k, y: origin + (200 - cy - r) * k, width: 2 * r * k, height: 2 * r * k))
  }
  disc(100, 100, 95, white: true)
  disc(100, 100, 90, white: false)
  disc(100, 100, 70, white: true)
  for (cx, cy) in [(70, 130), (100, 70), (100, 130), (130, 100), (130, 130)] {
    disc(CGFloat(cx), CGFloat(cy), 12, white: false)
  }
  return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("gen_icon: cannot write \(url.path)\n".utf8))
    exit(1)
  }
}

guard CommandLine.arguments.count == 2 else {
  print("usage: swift tools/gen_icon.swift OUTDIR")
  exit(CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") ? 0 : 2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = out.appendingPathComponent("fosforo.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = "icon_\(pt)x\(pt)" + (scale == 2 ? "@2x" : "") + ".png"
    write(kamon(size: pt * scale, rounded: true), to: set.appendingPathComponent(name))
  }
}
// iOS: home screen (60, 76, 83.5), Settings and Spotlight (20, 29, 40) and
// the 1024 marketing icon App Store Connect asks for
for (name, px) in [
  ("AppIcon20x20@2x", 40), ("AppIcon20x20@3x", 60), ("AppIcon29x29@2x", 58),
  ("AppIcon29x29@3x", 87), ("AppIcon40x40@2x", 80), ("AppIcon40x40@3x", 120),
  ("AppIcon60x60@2x", 120), ("AppIcon60x60@3x", 180), ("AppIcon76x76@2x", 152),
  ("AppIcon83.5x83.5@2x", 167), ("Marketing1024", 1024),  // not an AppIcon*: stays out of the bundle
] {
  write(kamon(size: px, rounded: false), to: out.appendingPathComponent(name + ".png"))
}
