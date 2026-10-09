import CFosforo
import CoreGraphics
import CoreText
import FosforoCore
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// One quad per cell: background and glyph come out of the same fragment, so
/// there is no second pass that could leave a seam between them.
struct CellInstance {
  var pos: SIMD2<UInt16>
  var slot: SIMD2<UInt16>
  var fg: UInt32
  var bg: UInt32
  var flags: UInt32
}

enum CellFlag {
  static let underlineMask: UInt32 = 7
  static let strike: UInt32 = 1 << 3
  static let overline: UInt32 = 1 << 4
  static let wide: UInt32 = 1 << 5
  static let cursorBar: UInt32 = 1 << 6
  static let cursorUnderline: UInt32 = 1 << 7
  static let colorGlyph: UInt32 = 1 << 8
}

struct Uniforms {
  var viewport: SIMD2<Float>
  var cell: SIMD2<Float>
  var origin: SIMD2<Float>
  var cursorColor: UInt32
  var lineThickness: Float
  var underlineY: Float
  var strikeY: Float
  var shift: SIMD2<Float>
  var zoom: Float
}

private let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct Cell { ushort2 pos; ushort2 slot; uint fg; uint bg; uint flags; };
  struct Uniforms {
    float2 viewport; float2 cell; float2 origin;
    uint cursorColor; float lineThickness; float underlineY; float strikeY;
    float2 shift; float zoom;
  };
  struct VOut {
    float4 position [[position]];
    float2 local;
    float column;  // x from the grid's left edge: patterns run on across cells
    ushort2 slot [[flat]];
    uint fg [[flat]];
    uint bg [[flat]];
    uint flags [[flat]];
  };

  static float4 rgb(uint c) {
    return float4(float((c >> 16) & 255u), float((c >> 8) & 255u), float(c & 255u), 255.0) / 255.0;
  }

  vertex VOut cell_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Cell *cells [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    Cell c = cells[iid];
    float2 corner = float2(float(vid & 1u), float(vid >> 1));
    float2 size = u.cell * float2((c.flags & 32u) != 0 ? 2.0 : 1.0, 1.0);
    float2 px = u.origin + float2(c.pos) * u.cell + corner * size;
    VOut o;
    float2 on = px * u.zoom + u.shift;
    o.position = float4(on.x / u.viewport.x * 2.0 - 1.0, 1.0 - on.y / u.viewport.y * 2.0, 0.0, 1.0);
    o.local = corner * size;
    o.column = px.x - u.origin.x;
    o.slot = c.slot;
    o.fg = c.fg;
    o.bg = c.bg;
    o.flags = c.flags;
    return o;
  }

  fragment float4 cell_fragment(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                texture2d<float> colorAtlas [[texture(1)]],
                                constant Uniforms &u [[buffer(1)]]) {
    constexpr sampler s(coord::pixel, filter::nearest);
    float2 local = floor(in.local);
    float2 texel = float2(in.slot) * u.cell + local + 0.5;
    float t = u.lineThickness;
    bool bar = (in.flags & 64u) != 0u && local.x < max(t, 2.0);
    bool under = (in.flags & 128u) != 0u && local.y >= u.cell.y - max(t, 2.0);
    if ((in.flags & 256u) != 0u) {
      if (bar || under) {
        return rgb(u.cursorColor);  // the cursor shows over an emoji too
      }
      float4 e = colorAtlas.sample(s, texel);  // premultiplied
      return float4(e.rgb + rgb(in.bg).rgb * (1.0 - e.a), 1.0);
    }
    float cov = atlas.sample(s, texel).r;
    uint ul = in.flags & 7u;
    bool line = local.y >= u.underlineY && local.y < u.underlineY + t;
    float x = floor(in.column);
    if (ul == 1u && line) {
      cov = 1.0;
    }
    if (ul == 2u && (line || (local.y >= u.underlineY - 2.0 * t && local.y < u.underlineY - t))) {
      cov = 1.0;
    }
    if (ul == 3u) {  // one wave per cell
      float a = max(t, 1.5);
      float mid = min(u.underlineY, u.cell.y - a - t);
      float y = mid + a * sin(x / u.cell.x * 6.2831853);
      if (abs(local.y + 0.5 - y) <= t * 0.5 + 0.5) {
        cov = 1.0;
      }
    }
    if (ul == 4u && line && fmod(floor(x / max(t, 2.0)), 2.0) < 1.0) {
      cov = 1.0;
    }
    if (ul == 5u && line && fmod(x, u.cell.x) < u.cell.x * 0.6) {
      cov = 1.0;
    }
    if ((in.flags & 8u) != 0u && local.y >= u.strikeY && local.y < u.strikeY + t) {
      cov = 1.0;
    }
    if ((in.flags & 16u) != 0u && local.y < t) {
      cov = 1.0;
    }
    float4 color = mix(rgb(in.bg), rgb(in.fg), cov);
    if (bar || under) {
      color = rgb(u.cursorColor);
    }
    return color;
  }
  """

/// Draws a Screen with Metal, into a window's drawable or an offscreen
/// texture (tests, -snapshot).
public final class Renderer {
  public let device: MTLDevice
  public private(set) var metrics: CellMetrics
  public var theme: Theme
  private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private var atlas: Atlas
  private var scale: Double
  /// The picture enlarged, not the font: device pixels on screen are
  /// grid pixels * zoom + shift. The grid keeps its rows and columns.
  public var zoom: Float = 1
  public var shift = SIMD2<Float>(0, 0)
  private var instances: [CellInstance] = []
  /// Where the grid starts, in device pixels: the safe area on a phone, so
  /// the camera housing covers nothing.
  public var inset = SIMD2<Int>(0, 0)
  /// Selected cells in screen coordinates, start before end, both inclusive.
  public var selection: (start: (row: Int, col: Int), end: (row: Int, col: Int))?
  /// Copy mode's mark: a block where the keyboard is, in place of the cursor.
  public var mark: (row: Int, col: Int)?
  /// Blink phase for the cursor: blink() on a timer, typed() on every key.
  public var cursorOn = true
  private var restUntil = Date.distantPast

  /// Typing holds the cursor lit; it blinks again once the keys rest.
  public func typed() {
    cursorOn = true
    restUntil = Date().addingTimeInterval(0.8)
  }

  public func blink() {
    cursorOn = Date() < restUntil || !cursorOn
  }

  private var flashUntil = Date.distantPast
  public static let flashLength = 0.12

  /// BEL as a visual bell: the whole frame in reverse video for a moment.
  /// The view draws again now and once more when it is over.
  public func flash() {
    flashUntil = Date().addingTimeInterval(Renderer.flashLength)
  }
  /// The hyperlink under the pointer: its cells get a solid underline.
  public var hoverLink: UInt8 = 0
  /// A row of cells drawn under the grid (the status bar); gridSize leaves
  /// room for it while it is on. Colors resolve against the screen's.
  public var statusBar = false
  public var status: [vt_cell] = []
  /// Search matches on screen (row, first and last column): highlighted,
  /// the current one as a selection.
  public var matches: [(row: Int, start: Int, end: Int)] = []

  public init(theme: Theme, scale: Double, device: MTLDevice? = nil) throws {
    guard let dev = device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
      throw RenderError(description: "no Metal device")
    }
    self.device = dev
    self.theme = theme
    queue = q
    let library = try dev.makeLibrary(source: shaderSource, options: nil)
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "cell_vertex")
    d.fragmentFunction = library.makeFunction(name: "cell_fragment")
    d.colorAttachments[0].pixelFormat = .bgra8Unorm
    pipeline = try dev.makeRenderPipelineState(descriptor: d)
    atlas = try Atlas(device: dev, font: Renderer.font(theme), scale: scale)
    metrics = atlas.metrics
    self.scale = scale
  }

  /// The window is on a screen of another density (a 1x monitor beside the
  /// Retina one): the atlas is drawn again at it, else the glyphs come out
  /// half or double size.
  public func setScale(_ s: Double) throws {
    guard s != scale else { return }
    atlas = try Atlas(device: device, font: Renderer.font(theme), scale: s)
    metrics = atlas.metrics
    scale = s
  }

  /// Another font size: the cells change, so the caller fits the grid again.
  public func setFontSize(_ size: Double) throws {
    var t = theme
    t.fontSize = size
    atlas = try Atlas(device: device, font: Renderer.font(t), scale: scale)
    metrics = atlas.metrics
    theme = t
  }

  /// The configured font, or Menlo when it is not installed.
  public static func font(_ theme: Theme) -> CTFont {
    let f = CTFontCreateWithName(theme.fontName as CFString, theme.fontSize, nil)
    let got = CTFontCopyPostScriptName(f) as String
    if got == theme.fontName {
      return f
    }
    return CTFontCreateWithName("Menlo-Regular" as CFString, theme.fontSize, nil)
  }

  /// Grid that fits in a pixel area.
  public func gridSize(width: Int, height: Int) -> (rows: Int, cols: Int) {
    (
      max(1, height / metrics.height - (statusBar ? 1 : 0)),
      max(1, width / metrics.width)
    )
  }

  private func color(_ c: UInt32, _ colors: [UInt32], fallback: Int) -> UInt32 {
    switch c >> 24 {
    case 1: return colors[Int(c & 0xFF)]
    case 2: return c & 0xFF_FFFF
    default: return colors[fallback]
    }
  }

  private static func dim(_ c: UInt32, toward bg: UInt32) -> UInt32 {
    var out: UInt32 = 0
    for shift: UInt32 in [0, 8, 16] {
      let a = (c >> shift) & 0xFF
      let b = (bg >> shift) & 0xFF
      out |= ((a * 2 + b) / 3) << shift
    }
    return out
  }

  /// Unicode gives Nerd Font icons width 1, and the programs that print one
  /// follow it with a space for the icon to spread into.
  static func iconWithRoom(_ cell: vt_cell, _ next: vt_cell) -> Bool {
    Atlas.isIcon(cell.cp) && UInt32(cell.flags) & UInt32(VT_CELL_WIDE) == 0
      && (next.cp == 0 || next.cp == 0x20) && next.bg == cell.bg && next.attr == cell.attr
  }

  private func instance(
    _ cell: vt_cell, row: Int, col: Int, colors: [UInt32], stretch: Bool = false
  ) -> CellInstance {
    let attr = UInt32(cell.attr)
    let bold = attr & UInt32(VT_ATTR_BOLD) != 0
    var fgColor = cell.fg
    if bold && theme.brightBold && fgColor >> 24 == 1 && fgColor & 0xFF < 8 {
      fgColor += 8
    }
    var fg = color(fgColor, colors, fallback: Int(VT_SLOT_FG))
    if bold && cell.fg == VT_COLOR_DEFAULT {
      fg = theme.bold
    }
    var bg = color(cell.bg, colors, fallback: Int(VT_SLOT_BG))
    if attr & UInt32(VT_ATTR_INVERSE) != 0 {
      swap(&fg, &bg)
    }
    if attr & UInt32(VT_ATTR_DIM) != 0 {
      fg = Renderer.dim(fg, toward: bg)
    }
    if attr & UInt32(VT_ATTR_INVISIBLE) != 0 {
      fg = bg
    }
    let italic = attr & UInt32(VT_ATTR_ITALIC) != 0
    let style = Style(rawValue: (bold ? 1 : 0) | (italic ? 2 : 0)) ?? .regular
    let wide = stretch || UInt32(cell.flags) & UInt32(VT_CELL_WIDE) != 0
    var flags = (attr & UInt32(VT_ATTR_UL_MASK)) >> UInt32(VT_ATTR_UL_SHIFT)
    if flags == 0 && cell.link != 0 {
      // a hyperlink shows it is one, and which one the pointer is on
      flags = UInt32(cell.link == hoverLink ? VT_UL_SINGLE : VT_UL_DASHED)
    }
    if attr & UInt32(VT_ATTR_STRIKE) != 0 {
      flags |= CellFlag.strike
    }
    if attr & UInt32(VT_ATTR_OVERLINE) != 0 {
      flags |= CellFlag.overline
    }
    if wide {
      flags |= CellFlag.wide
    }
    var glyph = atlas.glyph(cell.cp, style: style, wide: wide)
    if glyph.color && attr & UInt32(VT_ATTR_INVISIBLE) != 0 {
      glyph = Glyph(slot: .zero)  // SGR 8 hides an emoji as it hides text
    }
    if glyph.color {
      flags |= CellFlag.colorGlyph
    }
    return CellInstance(
      pos: SIMD2(UInt16(col), UInt16(row)), slot: glyph.slot, fg: fg, bg: bg, flags: flags)
  }

  private func build(_ screen: Screen, cursorVisible: Bool) {
    if atlas.nearlyFull {
      atlas.reset()
    }
    instances.removeAll(keepingCapacity: true)
    let reverse = (screen.modes & UInt32(VT_MODE_REVERSE) != 0) != (Date() < flashUntil)
    // the matches of each row by column, walked along with its cells: the
    // cost is cells + matches, not their product (10k matches on a 200x60
    // grid took 22 ms a frame when every cell asked every match)
    var byRow = [[(start: Int, end: Int)]](repeating: [], count: screen.rows)
    for m in matches where m.row >= 0 && m.row < screen.rows {
      byRow[m.row].append((m.start, m.end))
    }
    for r in 0..<screen.rows {
      let hits = byRow[r].sorted { $0.start < $1.start }
      var hi = 0
      var covered = false
      for c in 0..<screen.cols {
        let cell = screen.cell(r, c)
        if covered || UInt32(cell.flags) & UInt32(VT_CELL_WIDE_TAIL) != 0 {
          covered = false
          continue
        }
        let icon = c + 1 < screen.cols && Renderer.iconWithRoom(cell, screen.cell(r, c + 1))
        covered = icon
        var inst = instance(cell, row: r, col: c, colors: screen.colors, stretch: icon)
        if reverse {
          swap(&inst.fg, &inst.bg)
        }
        while hi < hits.count && hits[hi].end < c {
          hi += 1
        }
        if hi < hits.count && c >= hits[hi].start {
          inst.fg = theme.matchText
          inst.bg = theme.match
        }
        if selected(r, c) {
          inst.fg = theme.selectionText
          inst.bg = theme.selection
        }
        instances.append(inst)
      }
    }
    applyCursor(screen, visible: cursorVisible)
    if let m = mark,
      let i = instances.firstIndex(where: { Int($0.pos.y) == m.row && Int($0.pos.x) == m.col })
    {
      (instances[i].fg, instances[i].bg) = (instances[i].bg, instances[i].fg)
    }
    if statusBar {
      for (c, cell) in status.prefix(screen.cols).enumerated()
      where UInt32(cell.flags) & UInt32(VT_CELL_WIDE_TAIL) == 0 {
        instances.append(instance(cell, row: screen.rows, col: c, colors: screen.colors))
      }
    }
  }

  private func selected(_ r: Int, _ c: Int) -> Bool {
    guard let sel = selection else { return false }
    let at = r * 100_000 + c
    return at >= sel.start.row * 100_000 + sel.start.col
      && at <= sel.end.row * 100_000 + sel.end.col
  }

  private func applyCursor(_ screen: Screen, visible: Bool) {
    let cur = screen.cursor
    guard visible, cur.visible != 0, cursorOn || cur.style % 2 == 0 && cur.style != 0 else {
      return
    }
    guard
      let i = instances.firstIndex(where: {
        Int($0.pos.y) == Int(cur.row) && Int($0.pos.x) <= Int(cur.col)
          && Int(cur.col) < Int($0.pos.x) + ($0.flags & CellFlag.wide != 0 ? 2 : 1)
      })
    else {
      return
    }
    switch cur.style {
    case 3, 4:
      instances[i].flags |= CellFlag.cursorUnderline
    case 5, 6:
      instances[i].flags |= CellFlag.cursorBar
    default:  // a block: the cell in reverse video
      (instances[i].fg, instances[i].bg) = (instances[i].bg, instances[i].fg)
    }
  }

  private func uniforms(width: Int, height: Int) -> Uniforms {
    let t = Float(max(1, (metrics.width + 4) / 8))
    return Uniforms(
      viewport: SIMD2(Float(width), Float(height)),
      cell: SIMD2(Float(metrics.width), Float(metrics.height)),
      origin: SIMD2(Float(inset.x), Float(inset.y)),
      cursorColor: theme.cursor,
      lineThickness: t,
      underlineY: Float(min(metrics.height - Int(t), metrics.baseline + 1)),
      strikeY: Float(metrics.baseline - metrics.height / 4),
      shift: shift, zoom: zoom)
  }

  /// Encodes one frame of `screen` into `target`.
  public func encode(
    _ screen: Screen, into target: MTLTexture, commandBuffer: MTLCommandBuffer,
    cursorVisible: Bool = true
  ) {
    build(screen, cursorVisible: cursorVisible)
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let bg = screen.colors.isEmpty ? theme.background : screen.colors[Int(VT_SLOT_BG)]
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: Double((bg >> 16) & 0xFF) / 255, green: Double((bg >> 8) & 0xFF) / 255,
      blue: Double(bg & 0xFF) / 255, alpha: 1)
    guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      return
    }
    var u = uniforms(width: target.width, height: target.height)
    enc.setRenderPipelineState(pipeline)
    if !instances.isEmpty {
      instances.withUnsafeBytes { raw in
        if raw.count <= 4096 {
          enc.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
        } else if let b = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) {
          enc.setVertexBuffer(b, offset: 0, index: 0)
        }
      }
      enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
      enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
      enc.setFragmentTexture(atlas.texture, index: 0)
      enc.setFragmentTexture(atlas.colorTexture, index: 1)
      enc.drawPrimitives(
        type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }
    enc.endEncoding()
  }

  public func makeCommandBuffer() -> MTLCommandBuffer? {
    queue.makeCommandBuffer()
  }

  /// Renders offscreen and returns BGRA bytes, row 0 at the top.
  public func pixels(_ screen: Screen, width: Int, height: Int, cursorVisible: Bool = true) throws
    -> [UInt8]
  {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    guard let target = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else {
      throw RenderError(description: "offscreen target")
    }
    encode(screen, into: target, commandBuffer: cb, cursorVisible: cursorVisible)
    cb.commit()
    cb.waitUntilCompleted()
    var out = [UInt8](repeating: 0, count: width * height * 4)
    target.getBytes(
      &out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return out
  }

  /// Offscreen frame as an image, the size of the drawable it stands for.
  public func image(_ screen: Screen, width: Int, height: Int) throws -> CGImage {
    let px = try pixels(screen, width: width, height: height)
    let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
    guard let provider = CGDataProvider(data: Data(px) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)
    else {
      throw RenderError(description: "image")
    }
    return image
  }

  /// Offscreen frame as a PNG: the window's renderer, checkable from a script.
  public func snapshot(_ screen: Screen, to path: String) throws {
    let width = screen.cols * metrics.width
    let height = (screen.rows + (statusBar ? 1 : 0)) * metrics.height
    let image = try image(screen, width: width, height: height)
    guard
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
      throw RenderError(description: "png encoder")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw RenderError(description: "cannot write \(path)")
    }
  }
}
