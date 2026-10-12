// Renders the fosforo App Store header: Gohan from banner.ans as exact
// pixels (each half block is two pixels), on black. The iPhone shows the
// header's centre at full height, the iPad a full-width band across the
// middle with the store's tab bar over its top: the cat stays inside both.
// usage: swift header.swift <banner.ans> <out.png> [width height]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let ans = try! String(contentsOfFile: args[1], encoding: .utf8)
let W = args.count > 4 ? Int(args[3])! : 3840
let H = args.count > 4 ? Int(args[4])! : 1646

func xterm(_ n: Int) -> (Int, Int, Int) {
  let base: [(Int, Int, Int)] = [
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205),
    (229, 229, 229), (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255),
    (255, 0, 255), (0, 255, 255), (255, 255, 255),
  ]
  if n < 16 { return base[n] }
  if n < 232 {
    let i = n - 16
    let v = [0, 95, 135, 175, 215, 255]
    return (v[i / 36], v[(i / 6) % 6], v[i % 6])
  }
  let g = 8 + (n - 232) * 10
  return (g, g, g)
}

// grid of pixels: [y][x] -> color index or nil (transparent)
var px: [Int: [Int: Int]] = [:]
var x = 0, y = 0  // y counts text rows; pixel row = 2*y (+1)
var fg = 7, bg: Int? = nil
let s = Array(ans.unicodeScalars)
var i = 0
func put(_ col: Int, _ row: Int, _ c: Int?) {
  guard let c else { return }
  px[row, default: [:]][col] = c
}
while i < s.count {
  let c = s[i]
  if c == "\u{1b}", i + 1 < s.count, s[i + 1] == "[" {
    var j = i + 2
    var p = ""
    while j < s.count, !(("A"..."Z").contains(s[j]) || ("a"..."z").contains(s[j])) {
      p.unicodeScalars.append(s[j])
      j += 1
    }
    let cmd = s[j]
    let n = Int(p) ?? 1
    switch cmd {
    case "C": x += n
    case "D": x -= n
    case "B": y += n
    case "A": y -= n
    case "m":
      let f = p.split(separator: ";").map { Int($0) ?? 0 }
      var k = 0
      if f.isEmpty { fg = 7; bg = nil }
      while k < f.count {
        switch f[k] {
        case 0: fg = 7; bg = nil
        case 30...37: fg = f[k] - 30
        case 40...47: bg = f[k] - 40
        case 49: bg = nil
        case 38: fg = f[k + 2]; k += 2
        case 48: bg = f[k + 2]; k += 2
        default: break
        }
        k += 1
      }
    default: break
    }
    i = j + 1
    continue
  }
  if c == "\n" { y += 1; x = 0; i += 1; continue }
  if c == "\r" { x = 0; i += 1; continue }
  switch c {
  case "\u{2580}": put(x, 2 * y, fg); put(x, 2 * y + 1, bg)
  case "\u{2584}": put(x, 2 * y, bg); put(x, 2 * y + 1, fg)
  case "\u{2588}": put(x, 2 * y, fg); put(x, 2 * y + 1, fg)
  case " ": put(x, 2 * y, bg); put(x, 2 * y + 1, bg)
  default: break
  }
  x += 1
  i += 1
}

let rows = px.keys.sorted()
let cols = px.values.flatMap { $0.keys }
let minX = cols.min()!, maxX = cols.max()!, minY = rows.first!, maxY = rows.last!
let gw = maxX - minX + 1, gh = maxY - minY + 1
FileHandle.standardError.write("cat \(gw)x\(gh) px\n".data(using: .utf8)!)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
  data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

let scale = min((H * 55 / 100) / gh, (W * 60 / 100) / gw)
let artW = gw * scale, artH = gh * scale
let ox = (W - artW) / 2
let topY = (H - artH) / 2 + H / 30  // below centre, clear of the iPad's tab bar
for (r, line) in px {
  for (c, idx) in line {
    let (R, G, B) = xterm(idx)
    ctx.setFillColor(
      CGColor(srgbRed: CGFloat(R) / 255, green: CGFloat(G) / 255, blue: CGFloat(B) / 255, alpha: 1))
    let rx = ox + (c - minX) * scale
    let ry = H - (topY + (r - minY + 1) * scale)  // CG origin bottom left
    ctx.fill(CGRect(x: rx, y: ry, width: scale, height: scale))
  }
}

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(
  URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
