import CFosforo

/// The vt core without a process: bytes in, Screen out. Not thread-safe;
/// Session puts a lock around it.
public final class Terminal {
  let raw: OpaquePointer
  private let box = HostBox()

  /// OSC sequences the core passes on (52 clipboard...): id and payload,
  /// called inside write.
  public var onOSC: ((UInt32, [UInt8]) -> Void)? {
    get { box.osc }
    set { box.osc = newValue }
  }

  /// BEL, called inside write.
  public var onBell: (() -> Void)? {
    get { box.bell }
    set { box.bell = newValue }
  }

  public init(rows: Int, cols: Int, history: Int) throws {
    var host = vt_host(
      user: Unmanaged.passUnretained(box).toOpaque(),
      osc: { user, id, data, len in
        guard let user, let data else { return }
        let box = Unmanaged<HostBox>.fromOpaque(user).takeUnretainedValue()
        box.osc?(id, Array(UnsafeBufferPointer(start: data, count: len)))
      },
      bell: { user in
        guard let user else { return }
        Unmanaged<HostBox>.fromOpaque(user).takeUnretainedValue().bell?()
      })
    guard let t = vt_new(Int32(rows), Int32(cols), Int32(history), &host) else {
      throw SessionError(description: "invalid size \(rows)x\(cols)")
    }
    raw = t
  }

  deinit {
    vt_free(raw)
  }

  public func write(_ bytes: [UInt8]) {
    bytes.withUnsafeBytes { vt_write(raw, $0.baseAddress, $0.count) }
  }

  public func write(_ text: String) {
    write(Array(text.utf8))
  }

  public func configure(color slot: Int, rgb: UInt32) {
    vt_config_color(raw, Int32(slot), rgb)
  }

  /// Screen and history gone, the cursor's line kept at the top.
  public func clear() {
    vt_clear(raw)
  }

  /// Copies the screen into `screen`, reusing its storage.
  public func snapshot(into screen: inout Screen, back: Int = 0) {
    var r: Int32 = 0
    var c: Int32 = 0
    vt_size(raw, &r, &c)
    screen.rows = Int(r)
    screen.cols = Int(c)
    let count = screen.rows * screen.cols
    if screen.cells.count != count {
      screen.cells = [vt_cell](repeating: vt_cell(), count: count)
    }
    screen.cells.withUnsafeMutableBufferPointer { vt_copy_screen(raw, Int32(back), $0.baseAddress) }
    screen.cursor = vt_get_cursor(raw)
    screen.modes = vt_modes(raw)
    screen.generation = vt_generation(raw)
    if screen.colors.count != Int(VT_SLOT_COUNT) {
      screen.colors = [UInt32](repeating: 0, count: Int(VT_SLOT_COUNT))
    }
    for slot in 0..<screen.colors.count {
      screen.colors[slot] = vt_color(raw, Int32(slot))
    }
  }
}

/// Where the core's callbacks find the terminal's handlers: alive as long
/// as the terminal, which owns it.
private final class HostBox {
  var osc: ((UInt32, [UInt8]) -> Void)?
  var bell: (() -> Void)?
}
