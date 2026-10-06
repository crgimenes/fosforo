import CFosforo
import Darwin
import FosforoCore
import FosforoSSH
import Foundation

/// Mosh: SSH starts mosh-server, then state synchronization over UDP
/// (AES-128-OCB, zlib, protobuf). The server sends each screen as a diff
/// from a state the client acknowledged; this client keeps those states as
/// vt copies and hands the session either the diff itself (when it applies
/// to what is on display) or a full repaint.
public final class MoshTransport: Transport, @unchecked Sendable {
  public struct Endpoint: Sendable {
    public var host: String
    public var port: Int
    public var key: String
    public var serverPID: Int?
  }

  /// Runs mosh-server over SSH and reads where it listens.
  /// prepare sees the SSH client before it connects: to cancel it from
  /// elsewhere, or to refuse when the command is already over.
  public static func bootstrap(
    ssh: SSHConfig, server: String = "mosh-server",
    prepare: ((SSHClient) throws -> Void)? = nil
  ) throws -> Endpoint {
    var c = ssh
    c.command = "\(server) new -s -c 256 -l LANG=en_US.UTF-8"
    let client = SSHClient(config: c)
    let box = Collector()
    client.onData = { box.append($0) }
    client.onClose = { _, _ in box.finish() }
    try prepare?(client)
    try client.connect()
    client.start()
    guard box.wait(seconds: c.timeout) else {
      client.close()
      throw MoshError(description: "mosh-server did not answer")
    }
    let text = box.text
    let words = text.split(whereSeparator: { $0.isWhitespace })
    guard let i = words.firstIndex(where: { $0 == "CONNECT" }), i > 0, words[i - 1] == "MOSH",
      i + 2 < words.count, let port = Int(words[i + 1]), (1...65535).contains(port),
      words[i + 2].count == 22, let host = client.peerAddress
    else {
      let tail = text.split(separator: "\n").last.map(String.init) ?? "no output"
      throw MoshError(
        description: "mosh-server: \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    var pid: Int?
    if let r = text.range(of: "pid = ") {
      pid = Int(text[r.upperBound...].prefix { $0.isNumber })
    }
    return Endpoint(host: host, port: port, key: String(words[i + 2]), serverPID: pid)
  }

  // MARK: - state

  static let ackDelay = 0.1
  static let heartbeat = 3.0
  static let retransmit = 1.0
  static let fragmentMax = 1000  // payload per datagram: well under any path MTU
  static let shutdownNum = UInt64.max

  private let lock = NSLock()
  private var fd: Int32  // replaced when the network changes; loop thread only
  private let endpoint: Endpoint
  private(set) var lastHeard = Date()
  private var lastHop = Date()
  private var hopWanted = false
  private let wake: (read: Int32, write: Int32)
  private let ocb: OCB
  private let started = Date()
  private var output: (@Sendable ([UInt8]) -> Void)?
  private var exit: (@Sendable (Int32) -> Void)?
  private var running = true

  // outgoing user stream: events since the state the server acknowledged
  private var events: [UserEvent] = []
  private var eventsBase = 0  // absolute index of events[0]
  private var sent: [(num: UInt64, count: Int, at: Date)] = [(0, 0, .distantPast)]
  private var lastSend = Date.distantPast
  private var sendSeq: UInt64 = 0
  private var instructionID: UInt64 = 0
  private var shuttingDown = false
  var predictor = Predictor()
  private var echoMap: [(num: UInt64, count: Int)] = [(0, 0)]  // input state → events in it
  private var echoed = 0

  // incoming screen states
  private var states: [(num: UInt64, term: OpaquePointer, echo: UInt64)] = []
  private var remoteNum: UInt64 = 0
  private var displayed: UInt64 = 0
  private var ackDue: Date?
  private var sessionRows: Int
  private var sessionCols: Int
  private var lastRemoteTS: (ts: UInt16, at: Date)?
  private var fragID: UInt64?
  private var fragments: [Int: [UInt8]] = [:]
  private var fragTotal: Int?
  /// Test hook: datagrams it returns true for are dropped on arrival.
  var drop: (@Sendable () -> Bool)?
  private(set) var repaints = 0
  var predictionPending: Bool {
    lock.lock()
    defer { lock.unlock() }
    return predictor.pending
  }

  public init(endpoint: Endpoint, rows: Int, cols: Int) throws {
    guard let keyData = Data(base64Encoded: endpoint.key + "=="), keyData.count == 16,
      let ocb = OCB(key: [UInt8](keyData))
    else {
      throw MoshError(description: "bad mosh key")
    }
    guard let first = vt_new(Int32(rows), Int32(cols), 0, nil) else {
      throw MoshError(description: "bad size \(rows)x\(cols)")
    }
    self.ocb = ocb
    sessionRows = rows
    sessionCols = cols
    states = [(0, first, 0)]
    self.endpoint = endpoint
    fd = try MoshTransport.udp(host: endpoint.host, port: endpoint.port)
    var p: [Int32] = [0, 0]
    guard pipe(&p) == 0 else {
      close(fd)
      throw MoshError(description: "pipe")
    }
    wake = (p[0], p[1])
    _ = fcntl(wake.read, F_SETFL, O_NONBLOCK)
    _ = fcntl(wake.write, F_SETFL, O_NONBLOCK)
    events.append(.resize(cols: cols, rows: rows))
  }

  deinit {
    for s in states {
      vt_free(s.term)
    }
    close(fd)
    close(wake.read)
    close(wake.write)
  }

  private static func udp(host: String, port: Int) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_DGRAM
    hints.ai_flags = AI_NUMERICHOST
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let a = res else {
      throw MoshError(description: "bad address \(host)")
    }
    defer { freeaddrinfo(a) }
    let fd = socket(a.pointee.ai_family, SOCK_DGRAM, 0)
    guard fd >= 0, connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 else {
      if fd >= 0 { close(fd) }
      throw MoshError(description: "udp \(host):\(port): \(String(cString: strerror(errno)))")
    }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    return fd
  }

  // MARK: - Transport

  public func start(
    output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
  ) {
    lock.lock()
    self.output = output
    self.exit = exit
    lock.unlock()
    let t = Thread { [self] in loop() }
    t.name = "fosforo.mosh"
    t.start()
  }

  public func send(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    lock.lock()
    events.append(.keys(bytes))
    let real = vt_get_cursor(states[states.count - 1].term)
    predictor.typed(
      bytes, index: eventsBase + events.count, echoed: echoed,
      real: (Int(real.row), Int(real.col)), cols: sessionCols, now: Date())
    lock.unlock()
    poke()
  }

  public func resize(rows: Int, cols: Int) {
    lock.lock()
    sessionRows = rows
    sessionCols = cols
    events.append(.resize(cols: cols, rows: rows))
    predictor.reset()
    lock.unlock()
    poke()
  }

  public func overlay(_ screen: inout Screen) {
    lock.lock()
    predictor.overlay(&screen)
    lock.unlock()
  }

  public var overlayGeneration: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return predictor.generation
  }

  /// Asks the server to end the session (it hangs up the shell).
  public func hangup() {
    lock.lock()
    shuttingDown = true
    lock.unlock()
    poke()
  }

  private func poke() {
    var b: UInt8 = 1
    _ = Darwin.write(wake.write, &b, 1)
  }

  // MARK: - loop

  private func loop() {
    var buf = [UInt8](repeating: 0, count: 65536)
    var shutdownSends = 0
    while true {
      lock.lock()
      let alive = running
      lock.unlock()
      if !alive {
        break
      }
      var fds = [
        pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
        pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0),
      ]
      _ = poll(&fds, 2, 50)
      if fds[1].revents != 0 {
        var drain = [UInt8](repeating: 0, count: 64)
        while read(wake.read, &drain, drain.count) > 0 {}
      }
      while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 {
          break
        }
        receive(Array(buf[0..<n]))
      }
      lock.lock()
      let quitting = shuttingDown
      lock.unlock()
      if quitting {
        // no reply comes once the server is gone: a few tries, then done
        if shutdownSends < 3 && Date().timeIntervalSince(lastSend) > 0.3 {
          transmitShutdown()
          shutdownSends += 1
        }
        if shutdownSends >= 3 && Date().timeIntervalSince(lastSend) > 0.5 {
          finish(0)
        }
        continue
      }
      hopIfLost()
      lock.lock()
      predictor.tick(now: Date())
      lock.unlock()
      tick()
    }
  }

  static let hopAfter = 10.0

  /// Test hook: take a new socket (a new source port) on the next turn.
  func hop() {
    lock.lock()
    hopWanted = true
    lock.unlock()
    poke()
  }

  /// A new source port after a failed send or a silence: the network may
  /// have changed under us (Wi-Fi to cellular), and the server follows the
  /// address of the last authentic packet it gets, as in the Mosh client.
  private func hopIfLost() {
    lock.lock()
    let wanted = hopWanted
    hopWanted = false
    lock.unlock()
    let now = Date()
    let silent =
      now.timeIntervalSince(lastHeard) > MoshTransport.hopAfter
      && now.timeIntervalSince(lastHop) > MoshTransport.hopAfter
    guard wanted || silent,
      let fresh = try? MoshTransport.udp(host: endpoint.host, port: endpoint.port)
    else {
      return
    }
    close(fd)
    fd = fresh
    lastHop = now
  }

  private func finish(_ status: Int32) {
    lock.lock()
    let e = running ? exit : nil
    running = false
    lock.unlock()
    e?(status)
  }

  /// Decides whether to send: new keystrokes, an ack that is due, an
  /// unacknowledged state to retransmit, or the heartbeat.
  private func tick() {
    let now = Date()
    lock.lock()
    let total = eventsBase + events.count
    let lastSent = sent[sent.count - 1]
    let newInput = total != lastSent.count
    let ack = ackDue.map { now >= $0 } ?? false
    let unacked = sent.count > 1 && now.timeIntervalSince(lastSent.at) > MoshTransport.retransmit
    let beat = now.timeIntervalSince(lastSend) > MoshTransport.heartbeat
    guard newInput || ack || unacked || beat else {
      lock.unlock()
      return
    }
    if newInput {
      let num = lastSent.num + 1
      sent.append((num, total, now))
      echoMap.append((num, total))
    } else if unacked {
      sent[sent.count - 1].at = now
    }
    let base = sent[0]
    let target = sent[sent.count - 1]
    let diff =
      base.count == target.count
      ? []
      : encodeUser(events[(base.count - eventsBase)..<(target.count - eventsBase)])
    let inst = Instruction(
      oldNum: base.num, newNum: target.num, ackNum: remoteNum, throwawayNum: base.num, diff: diff)
    ackDue = nil
    lock.unlock()
    transmit(inst)
  }

  private func transmitShutdown() {
    lock.lock()
    let base = sent[0]
    let inst = Instruction(
      oldNum: base.num, newNum: MoshTransport.shutdownNum, ackNum: remoteNum,
      throwawayNum: base.num, diff: [])
    lock.unlock()
    transmit(inst)
  }

  private func timestamp16(_ at: Date = Date()) -> UInt16 {
    let ms = UInt64(at.timeIntervalSince(started) * 1000) % 65536
    return ms == 65535 ? 0 : UInt16(ms)
  }

  private func transmit(_ inst: Instruction) {
    let payload = Zlib.compress(inst.encode())
    lock.lock()
    instructionID += 1
    let id = instructionID
    var reply: UInt16 = 0xFFFF
    if let r = lastRemoteTS, Date().timeIntervalSince(r.at) < 1 {
      reply = r.ts &+ UInt16(Date().timeIntervalSince(r.at) * 1000)
    }
    lastSend = Date()
    lock.unlock()
    var chunks: [[UInt8]] = []
    var off = 0
    repeat {
      let end = min(payload.count, off + MoshTransport.fragmentMax)
      chunks.append(Array(payload[off..<end]))
      off = end
    } while off < payload.count
    for (i, chunk) in chunks.enumerated() {
      var frag: [UInt8] = []
      for s in stride(from: 56, through: 0, by: -8) {
        frag.append(UInt8((id >> UInt64(s)) & 0xFF))
      }
      let num = UInt16(i) | (i == chunks.count - 1 ? 0x8000 : 0)
      frag += [UInt8(num >> 8), UInt8(num & 0xFF)] + chunk
      let ts = timestamp16()
      let plain = [UInt8(ts >> 8), UInt8(ts & 0xFF), UInt8(reply >> 8), UInt8(reply & 0xFF)] + frag
      lock.lock()
      let seq = sendSeq & ~(UInt64(1) << 63)  // direction bit clear: to the server
      sendSeq += 1
      lock.unlock()
      var nonce8: [UInt8] = []
      for s in stride(from: 56, through: 0, by: -8) {
        nonce8.append(UInt8((seq >> UInt64(s)) & 0xFF))
      }
      let datagram = nonce8 + ocb.seal(plain, nonce: [0, 0, 0, 0] + nonce8)
      let sent = datagram.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
      if sent < 0 {
        lock.lock()
        hopWanted = true  // network unreachable, route gone: try a new socket
        lock.unlock()
      }
    }
  }

  // MARK: - receiving

  /// The highest datagram sequence heard; an older one is a replay or a
  /// straggler and counts for nothing, not even as a sign of life (mosh's
  /// expected_receiver_seq).
  private var highestSeq: UInt64?

  func receive(_ datagram: [UInt8]) {
    guard datagram.count >= 24, drop?() != true else { return }
    let nonce8 = Array(datagram[0..<8])
    guard nonce8[0] & 0x80 != 0,  // from the server
      let plain = ocb.open(Array(datagram[8...]), nonce: [0, 0, 0, 0] + nonce8),
      plain.count >= 4 + 10
    else {
      return
    }
    let seq = nonce8.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } & ~(UInt64(1) << 63)
    let ts = UInt16(plain[0]) << 8 | UInt16(plain[1])
    let reply = UInt16(plain[2]) << 8 | UInt16(plain[3])
    lock.lock()
    if let high = highestSeq, seq <= high {
      lock.unlock()
      return
    }
    highestSeq = seq
    lastRemoteTS = (ts, Date())
    lastHeard = Date()
    if reply != 0xFFFF {
      let ms = timestamp16() &- reply  // our own clock, echoed back: the round trip
      if ms < 5000 {
        predictor.rtt(Double(ms) / 1000)
      }
    }
    lock.unlock()
    let frag = Array(plain[4...])
    let id = frag[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    let num = UInt16(frag[8]) << 8 | UInt16(frag[9])
    guard
      let whole = assemble(
        id: id, index: Int(num & 0x7FFF), final: num & 0x8000 != 0, Array(frag[10...])),
      let bytes = try? Zlib.decompress(whole),
      let inst = try? Instruction.decode(bytes)
    else {
      return
    }
    process(inst)
  }

  private func assemble(id: UInt64, index: Int, final: Bool, _ data: [UInt8]) -> [UInt8]? {
    if fragID != id {
      fragID = id
      fragments = [:]
      fragTotal = nil
    }
    guard index < 4096 else { return nil }
    fragments[index] = data
    if final {
      fragTotal = index + 1
    }
    guard let total = fragTotal, fragments.count == total else { return nil }
    var out: [UInt8] = []
    for i in 0..<total {
      guard let f = fragments[i] else { return nil }
      out += f
    }
    fragID = nil
    return out
  }

  private func process(_ inst: Instruction) {
    lock.lock()
    // the server acknowledged one of our states: what came before it is done
    if let i = sent.firstIndex(where: { $0.num == inst.ackNum }) {
      let drop = sent[i].count - eventsBase
      if drop > 0 {
        events.removeFirst(min(drop, events.count))
        eventsBase += drop
      }
      sent.removeFirst(i)
    }
    if inst.newNum == MoshTransport.shutdownNum {
      remoteNum = MoshTransport.shutdownNum
      lock.unlock()
      transmitShutdownAck()
      finish(0)
      return
    }
    guard inst.newNum > remoteNum,
      let base = states.first(where: { $0.num == inst.oldNum }),
      let next = vt_clone(base.term)
    else {
      ackDue = ackDue ?? Date().addingTimeInterval(MoshTransport.ackDelay)
      lock.unlock()
      return
    }
    lock.unlock()
    guard let host = try? decodeHost(inst.diff) else {
      vt_free(next)
      return
    }
    var raw: [UInt8] = []
    var resized = false
    var echo = base.echo
    var discard = [UInt8](repeating: 0, count: 4096)
    for e in host {
      switch e {
      case .bytes(let b):
        b.withUnsafeBytes { vt_write(next, $0.baseAddress, $0.count) }
        raw += b
      case .resize(let cols, let rows):
        vt_resize(next, Int32(rows), Int32(cols))
        resized = true
      case .echoAck(let n):
        echo = n
      }
      while vt_reply(next, &discard, discard.count) > 0 {}
    }
    var r: Int32 = 0
    var c: Int32 = 0
    vt_size(next, &r, &c)
    lock.lock()
    let direct =
      displayed == inst.oldNum && !resized && Int(r) == sessionRows && Int(c) == sessionCols
    states.append((inst.newNum, next, echo))
    while states.count > 1 && states[0].num < inst.throwawayNum {
      vt_free(states.removeFirst().term)
    }
    remoteNum = inst.newNum
    displayed = inst.newNum
    ackDue = ackDue ?? Date().addingTimeInterval(MoshTransport.ackDelay)
    checkPredictions(next, echo: echo, rows: Int(r), cols: Int(c))
    let out = output
    lock.unlock()
    if direct {
      if !raw.isEmpty {
        out?(raw)
      }
      return
    }
    lock.lock()
    repaints += 1
    lock.unlock()
    let need = vt_repaint(next, nil, 0)
    var paint = [UInt8](repeating: 0, count: need)
    _ = paint.withUnsafeMutableBufferPointer { vt_repaint(next, $0.baseAddress, need) }
    out?(paint)
  }

  /// With the lock held: how much input the server has echoed, and the
  /// guesses that covers checked against its screen.
  private func checkPredictions(_ term: OpaquePointer, echo: UInt64, rows: Int, cols: Int) {
    if let i = echoMap.lastIndex(where: { $0.num <= echo }) {
      echoed = max(echoed, echoMap[i].count)
      echoMap.removeFirst(i)
    }
    guard predictor.pending else { return }
    var cells = [vt_cell](repeating: vt_cell(), count: rows * cols)
    cells.withUnsafeMutableBufferPointer { vt_copy_screen(term, 0, $0.baseAddress) }
    let cur = vt_get_cursor(term)
    predictor.check(
      echoed: echoed,
      cell: { r, c in r < rows && c < cols ? cells[r * cols + c].cp : 0 },
      real: (Int(cur.row), Int(cur.col)))
  }

  private func transmitShutdownAck() {
    lock.lock()
    let base = sent[0]
    let inst = Instruction(
      oldNum: base.num, newNum: sent[sent.count - 1].num, ackNum: MoshTransport.shutdownNum,
      throwawayNum: base.num, diff: [])
    lock.unlock()
    for _ in 0..<3 {
      transmit(inst)
    }
  }
}
