import CFosforo
import CoreGraphics
import CoreText
import Foundation
import Metal

/// Cell size in device pixels. Integers on purpose: every cell edge lands on
/// a pixel edge, which is what keeps block art free of seams.
public struct CellMetrics: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let baseline: Int  // from the top of the cell
  public let descent: Int

  public init(font: CTFont, scale: Double) {
    var glyph = CGGlyph(0)
    var unichar = UniChar(0x4D)  // "M": the font is monospaced
    CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1)
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    let ascent = CTFontGetAscent(font) * scale
    let descent = CTFontGetDescent(font) * scale
    let leading = CTFontGetLeading(font) * scale
    width = max(1, Int((advance.width * scale).rounded()))
    height = max(1, Int((ascent + descent + leading).rounded(.up)))
    self.descent = Int(descent.rounded())
    baseline = height - self.descent
  }
}

enum Style: Int {
  case regular = 0
  case bold = 1
  case italic = 2
  case boldItalic = 3
}

struct Glyph {
  var slot: SIMD2<UInt16>
  var color = false  // in the RGBA atlas: drawn as is, not in the text color
}

/// Glyphs rasterized once per (rune, style, width) into slots of an R8
/// texture, one cell (or two, for wide runes) per slot. Color glyphs (emoji)
/// take the same slot in a second, RGBA texture.
final class Atlas {
  static let size = 2048
  /// A reset hands out fresh textures: a frame still on the GPU keeps the
  /// pair it was encoded with (Metal retains what a command buffer uses),
  /// so refilling the slots cannot change a picture before it is drawn.
  private(set) var texture: MTLTexture
  private(set) var colorTexture: MTLTexture
  private let device: MTLDevice
  let metrics: CellMetrics
  private let fonts: [CTFont]
  private var slots: [UInt64: Glyph] = [:]
  private var ascii: [Glyph?]
  // slots 0 and 1 stay empty: the blank cell, and the pair a wide glyph
  // that found no room samples
  private var next = 2
  private let perRow: Int
  private let capacity: Int
  private var scratch: [UInt8]
  private var rgba: [UInt8]

  init(device: MTLDevice, font: CTFont, scale: Double) throws {
    metrics = CellMetrics(font: font, scale: scale)
    fonts = Atlas.faces(font, scale: scale)
    self.device = device
    (texture, colorTexture) = try Atlas.makeTextures(device)
    perRow = Atlas.size / metrics.width
    capacity = perRow * (Atlas.size / metrics.height)
    ascii = [Glyph?](repeating: nil, count: 128 * 4)
    scratch = [UInt8](repeating: 0, count: metrics.width * 2 * metrics.height)
    rgba = [UInt8](repeating: 0, count: metrics.width * 2 * metrics.height * 4)
  }

  private static func variant(_ font: CTFont, _ trait: CTFontSymbolicTraits) -> CTFont {
    CTFontCreateCopyWithSymbolicTraits(font, 0, nil, trait, trait) ?? font
  }

  private static let facesLock = NSLock()
  nonisolated(unsafe) private static var facesCache: [String: [CTFont]] = [:]
  /// How many distinct fonts went to CoreText so far (tests).
  static var facesMade: Int {
    facesLock.lock()
    defer { facesLock.unlock() }
    return facesCache.count
  }

  /// The regular, bold, italic and bold italic faces of a font at a scale,
  /// made once per process: each variant is a synchronous XPC round trip to
  /// the font server, and a Renderer is made per window, theme and zoom.
  private static func faces(_ font: CTFont, scale: Double) -> [CTFont] {
    let key = "\(CTFontCopyPostScriptName(font))|\(CTFontGetSize(font))|\(scale)"
    facesLock.lock()
    defer { facesLock.unlock() }
    if let have = facesCache[key] {
      return have
    }
    let scaled = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
    let made = [
      scaled,
      variant(scaled, .traitBold),
      variant(scaled, .traitItalic),
      variant(variant(scaled, .traitBold), .traitItalic),
    ]
    facesCache[key] = made
    return made
  }

  /// Nearly full: the caller resets between frames, never in the middle of one.
  var nearlyFull: Bool { next > capacity - 64 }

  func reset() {
    slots.removeAll(keepingCapacity: true)
    ascii = [Glyph?](repeating: nil, count: 128 * 4)
    next = 2
    if let fresh = try? Atlas.makeTextures(device) {
      (texture, colorTexture) = fresh
    }
  }

  /// An empty R8 atlas and its RGBA twin for color glyphs.
  private static func makeTextures(_ device: MTLDevice) throws -> (MTLTexture, MTLTexture) {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm, width: Atlas.size, height: Atlas.size, mipmapped: false)
    d.usage = [.shaderRead]
    d.storageMode = .shared
    let cd = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: Atlas.size, height: Atlas.size, mipmapped: false)
    cd.usage = [.shaderRead]
    cd.storageMode = .shared
    guard let t = device.makeTexture(descriptor: d), let ct = device.makeTexture(descriptor: cd)
    else {
      throw RenderError(description: "atlas texture")
    }
    let zero = [UInt8](repeating: 0, count: Atlas.size * Atlas.size)
    t.replace(
      region: MTLRegionMake2D(0, 0, Atlas.size, Atlas.size), mipmapLevel: 0, withBytes: zero,
      bytesPerRow: Atlas.size)
    return (t, ct)
  }

  func glyph(_ cp: UInt32, style: Style, wide: Bool) -> Glyph {
    if cp == 0 || cp == 32 {
      return Glyph(slot: .zero)
    }
    if cp < 128 && !wide, let s = ascii[Int(cp) * 4 + style.rawValue] {
      return s
    }
    let key = UInt64(cp) | UInt64(style.rawValue) << 32 | (wide ? 1 << 40 : 0)
    if let s = slots[key] {
      return s
    }
    guard let slot = allocate(wide: wide) else {
      // no room left this frame: a blank cell rather than a slot some glyph
      // already drawn in; not cached, so the next frame (a fresh atlas) has it
      return Glyph(slot: .zero)
    }
    let s = Glyph(slot: slot, color: false)
    let g = draw(cp, style: style, wide: wide, at: s)
    slots[key] = g
    if cp < 128 && !wide {
      ascii[Int(cp) * 4 + style.rawValue] = g
    }
    return g
  }

  /// The next free slot (two, side by side on one row, for a wide glyph);
  /// nil when the texture is full.
  private func allocate(wide: Bool) -> SIMD2<UInt16>? {
    var at = next
    if wide && at % perRow == perRow - 1 {
      at += 1
    }
    let need = wide ? 2 : 1
    guard at + need <= capacity else { return nil }
    next = at + need
    return SIMD2(UInt16(at % perRow), UInt16(at / perRow))
  }

  private func draw(_ cp: UInt32, style: Style, wide: Bool, at g: Glyph) -> Glyph {
    let w = metrics.width * (wide ? 2 : 1)
    let h = metrics.height
    let region = MTLRegion(
      origin: MTLOrigin(x: Int(g.slot.x) * metrics.width, y: Int(g.slot.y) * metrics.height, z: 0),
      size: MTLSize(width: w, height: h, depth: 1))
    let drawn = scratch.withUnsafeMutableBufferPointer {
      glyph_draw(cp, Int32(w), Int32(h), $0.baseAddress) != 0
    }
    if !drawn, let (face, glyph) = face(for: cp, font: fonts[style.rawValue]),
      CTFontGetSymbolicTraits(face).contains(.traitColorGlyphs)
    {
      rasterizeColor(face, glyph, width: w, height: h)
      colorTexture.replace(region: region, mipmapLevel: 0, withBytes: rgba, bytesPerRow: w * 4)
      return Glyph(slot: g.slot, color: true)
    }
    if !drawn {
      rasterize(cp, font: fonts[style.rawValue], width: w, height: h)
    }
    texture.replace(region: region, mipmapLevel: 0, withBytes: scratch, bytesPerRow: w)
    return g
  }

  /// The face that has the rune: the configured font, else the system's
  /// fallback for it (CJK, emoji).
  private func face(for cp: UInt32, font: CTFont) -> (CTFont, CGGlyph)? {
    guard let scalar = Unicode.Scalar(cp) else {
      return nil
    }
    let units = Array(String(Character(scalar)).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    if CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) {
      return (font, glyphs[0])
    }
    let s = String(Character(scalar)) as CFString
    let face = CTFontCreateForString(font, s, CFRange(location: 0, length: units.count))
    guard CTFontGetGlyphsForCharacters(face, units, &glyphs, units.count) else {
      return nil
    }
    return (face, glyphs[0])
  }

  /// Emoji scaled to the cell's height and centred in its width, into rgba
  /// (premultiplied).
  private func rasterizeColor(_ face: CTFont, _ glyph: CGGlyph, width: Int, height: Int) {
    for i in 0..<(width * height * 4) {
      rgba[i] = 0
    }
    let tall = CTFontGetAscent(face) + CTFontGetDescent(face)
    let fitted = CTFontCreateCopyWithAttributes(
      face, CTFontGetSize(face) * CGFloat(height) / tall, nil, nil)
    var g = glyph
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(fitted, .horizontal, &g, &advance, 1)
    rgba.withUnsafeMutableBytes { raw in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else {
        return
      }
      var position = CGPoint(
        x: max(0, (CGFloat(width) - advance.width) / 2), y: CTFontGetDescent(fitted))
      CTFontDrawGlyphs(fitted, &g, &position, 1, ctx)
    }
  }

  private func rasterize(_ cp: UInt32, font: CTFont, width: Int, height: Int) {
    for i in 0..<(width * height) {
      scratch[i] = 0
    }
    guard let (face, glyph) = face(for: cp, font: font) else {
      return
    }
    var glyphs = [glyph]
    scratch.withUnsafeMutableBytes { raw in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else {
        return
      }
      ctx.setAllowsFontSmoothing(false)
      ctx.setShouldAntialias(true)
      ctx.setFillColor(gray: 1, alpha: 1)
      var position = CGPoint(x: 0, y: CGFloat(metrics.descent))
      CTFontDrawGlyphs(face, &glyphs, &position, 1, ctx)
    }
  }
}

public struct RenderError: Error, CustomStringConvertible {
  public let description: String
}
