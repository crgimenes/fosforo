import CFosforo
import Foundation

/// The status bar under the grid: one row of cells made of colored pieces,
/// the left ones cut to leave room for the right ones.
public enum StatusLine {
  public struct Piece: Sendable {
    public var text: String
    public var color: UInt32  // a vt color: VT_COLOR_INDEX(n) follows the palette
    public var tag: Int  // nonzero: a button, reported with the columns it landed on

    public init(_ text: String, color: UInt32, tag: Int = 0) {
      self.text = text
      self.color = color
      self.tag = tag
    }
  }

  /// background: a vt color for the whole row (rgb(_:)); 0 keeps the
  /// screen's.
  public static func cells(left: [Piece], right: [Piece], cols: Int, background: UInt32 = 0)
    -> [vt_cell]
  {
    layout(left: left, right: right, cols: cols, background: background).cells
  }

  public static func layout(left: [Piece], right: [Piece], cols: Int, background: UInt32 = 0)
    -> (cells: [vt_cell], buttons: [(cols: Range<Int>, tag: Int)])
  {
    var blank = vt_cell()
    blank.bg = background
    var row = [vt_cell](repeating: blank, count: max(cols, 0))
    var buttons: [(cols: Range<Int>, tag: Int)] = []
    let rightWidth = right.reduce(0) { $0 + width($1.text) }
    var col = 0
    for p in left {
      let start = col
      col = put(p, into: &row, at: col, limit: cols - rightWidth - 1)
      if p.tag != 0 && col > start {
        buttons.append((start..<col, p.tag))
      }
    }
    col = max(col, cols - rightWidth)
    for p in right {
      let start = col
      col = put(p, into: &row, at: col, limit: cols)
      if p.tag != 0 && col > start {
        buttons.append((start..<col, p.tag))
      }
    }
    return (row, buttons)
  }

  static func width(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { $0 + Int(vt_width($1.value)) }
  }

  private static func put(_ p: Piece, into row: inout [vt_cell], at start: Int, limit: Int) -> Int {
    var col = start
    for s in p.text.unicodeScalars {
      let w = Int(vt_width(s.value))
      guard w > 0 else { continue }
      guard col >= 0, col + w <= min(limit, row.count) else { break }
      row[col].cp = s.value
      row[col].fg = p.color
      row[col].flags = UInt8(w == 2 ? VT_CELL_WIDE : 0)
      if w == 2 {
        row[col + 1].flags = UInt8(VT_CELL_WIDE_TAIL)
      }
      col += w
    }
    return col
  }

  public static func color(_ index: Int) -> UInt32 {
    (1 << 24) | UInt32(index & 0xFF)
  }

  /// A vt color that is this exact 0xRRGGBB, outside the palette.
  public static func rgb(_ value: UInt32) -> UInt32 {
    (2 << 24) | (value & 0xFF_FFFF)
  }
}

/// The branch checked out where `path` is, read from .git/HEAD without
/// running git: a branch name, or the short hash when detached.
public enum GitBranch {
  public static func at(_ path: String) -> String? {
    status(path)?.name
  }

  /// The branch and whether its last commit is not the one the remote has
  /// (never pushed, or pushed before the newest commits). Nothing walks
  /// the history, so a branch behind the remote shows the same mark until
  /// it is pulled.
  public static func status(_ path: String) -> (
    name: String, unpushed: Bool, repo: String, tips: String
  )? {
    var dir = URL(fileURLWithPath: path)
    while true {
      if let git = gitDir(dir.appendingPathComponent(".git")) {
        return head(git)
      }
      let up = dir.deletingLastPathComponent()
      if up.path == dir.path {
        return nil
      }
      dir = up
    }
  }

  /// .git is a directory, or a file pointing to one (worktrees, submodules).
  private static func gitDir(_ git: URL) -> URL? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) else {
      return nil
    }
    if isDir.boolValue {
      return git
    }
    guard let text = try? String(contentsOf: git, encoding: .utf8),
      let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ")
    else {
      return nil
    }
    let target = String(line.dropFirst("gitdir: ".count))
    return target.hasPrefix("/")
      ? URL(fileURLWithPath: target)
      : git.deletingLastPathComponent().appendingPathComponent(target)
  }

  private static func head(_ gitDir: URL) -> (
    name: String, unpushed: Bool, repo: String, tips: String
  )? {
    guard
      let text = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
    else {
      return nil
    }
    let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard head.hasPrefix("ref: refs/heads/") else {
      return head.count >= 7 ? (String(head.prefix(7)), false, gitDir.path, head) : nil  // detached
    }
    let name = String(head.dropFirst("ref: refs/heads/".count))
    // a worktree keeps its HEAD apart; refs and config are the repository's
    var common = gitDir
    if let c = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8)
    {
      let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
      common = t.hasPrefix("/") ? URL(fileURLWithPath: t) : gitDir.appendingPathComponent(t)
    }
    let local = sha("refs/heads/" + name, in: common)
    let remote = upstream(of: name, in: common).flatMap { sha($0, in: common) }
    // tips: the two commits the counts depend on, so they are asked again
    // the moment a commit, push, fetch or pull moves either one
    let tips = (local ?? "") + " " + (remote ?? "")
    guard let local, let remote else {
      return (name, true, gitDir.path, tips)
    }
    return (name, local != remote, gitDir.path, tips)
  }

  /// A ref's commit, from its own file or from packed-refs.
  private static func sha(_ ref: String, in common: URL) -> String? {
    if let text = try? String(contentsOf: common.appendingPathComponent(ref), encoding: .utf8) {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard
      let packed = try? String(
        contentsOf: common.appendingPathComponent("packed-refs"), encoding: .utf8)
    else {
      return nil
    }
    for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
      return String(line.prefix { $0 != " " })
    }
    return nil
  }

  /// refs/remotes/REMOTE/BRANCH from the [branch "name"] section of config.
  private static func upstream(of name: String, in common: URL) -> String? {
    guard
      let config = try? String(contentsOf: common.appendingPathComponent("config"), encoding: .utf8)
    else {
      return nil
    }
    var inside = false
    var remote: String?
    var merge: String?
    for raw in config.split(separator: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        inside = line == "[branch \"\(name)\"]"
        continue
      }
      guard inside, let eq = line.firstIndex(of: "=") else { continue }
      let key = line[..<eq].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      if key == "remote" { remote = value }
      if key == "merge" { merge = value }
    }
    guard let remote, let merge, merge.hasPrefix("refs/heads/") else { return nil }
    return "refs/remotes/\(remote)/" + merge.dropFirst("refs/heads/".count)
  }
}

/// What the status bar shows for a session, on its own band so it is never
/// taken for a prompt: n/N and where the shell is (ssh user@host, or the
/// directory and branch here) on the left, the title on the right. Colors
/// are palette indexes, so the bar follows the theme.
public final class StatusBar {
  private var branch:
    (path: String, value: (name: String, unpushed: Bool, repo: String, tips: String)?, at: Date)?
  private var buttons: [(cols: Range<Int>, tag: Int)] = []
  static let branchTTL = 2.0  // a checkout elsewhere shows up within this

  public init() {}

  /// With a finder, the bar is the search: its text and which match of
  /// how many.
  /// notice: a short word from the app (a program set the clipboard),
  /// shown on the right ahead of the title while it lasts.
  public func cells(
    _ s: Session, position: (index: Int, count: Int), cols: Int, rows: Int = 0,
    finder: Finder? = nil, copying: Bool = false, notice: String? = nil,
    background: UInt32 = 0
  ) -> [vt_cell] {
    let session = StatusLine.Piece(
      "\(position.index)/\(position.count) ", color: StatusLine.color(14))
    if let f = finder {
      let count = "\(f.matches.count)\(f.truncated ? "+" : "")"  // + : older ones not counted
      let at = f.current.map { "\($0 + 1)/\(count)" } ?? "0/0"
      let yellow = StatusLine.color(11)
      let laid = StatusLine.layout(
        left: [
          StatusLine.Piece(" find: ", color: yellow, tag: StatusBar.field),
          StatusLine.Piece(
            f.text + (f.editing ? "_" : " "), color: StatusLine.color(f.editing ? 15 : 7),
            tag: StatusBar.field),
        ],
        right: [
          StatusLine.Piece(at + " ", color: yellow),
          StatusLine.Piece(" ‹ ", color: yellow, tag: StatusBar.older),
          StatusLine.Piece(" › ", color: yellow, tag: StatusBar.newer),
          StatusLine.Piece(" × ", color: yellow, tag: StatusBar.close),
          StatusLine.Piece("  ", color: 0), session,
        ], cols: cols, background: background)
      buttons = laid.buttons
      return laid.cells
    }
    buttons = []
    let st = s.status()
    let sep = StatusLine.Piece(" │ ", color: StatusLine.color(8))
    var left = [
      StatusLine.Piece(" \(position.index)/\(position.count)", color: StatusLine.color(14))
    ]
    if copying {
      left += [sep, StatusLine.Piece("COPY", color: StatusLine.color(11))]
    }
    if let l = st.label {
      left += [sep, StatusLine.Piece(l, color: StatusLine.color(11))]
    }
    if let dir = st.directory {
      let home = NSHomeDirectory()
      let shown = st.local && dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
      left += [sep, StatusLine.Piece(shown, color: StatusLine.color(13))]
      if st.local, let b = branch(dir) {
        left += [sep, StatusLine.Piece("\u{E0A0} " + b.name, color: StatusLine.color(10))]
        #if os(macOS)
          let counts = GitCounts.shared.counts(repo: b.repo, tips: b.tips)
        #else
          let counts: (ahead: Int, behind: Int)? = nil
        #endif
        if let c = counts {
          if c.ahead > 0 {
            left.append(StatusLine.Piece(" ↑\(c.ahead)", color: StatusLine.color(11)))
          }
          if c.behind > 0 {
            left.append(StatusLine.Piece(" ↓\(c.behind)", color: StatusLine.color(11)))
          }
        } else if b.unpushed {
          left.append(StatusLine.Piece(" ↑", color: StatusLine.color(11)))  // not on the remote yet
        }
      }
    }
    var right: [StatusLine.Piece] = []
    if let n = notice {
      right.append(StatusLine.Piece(n, color: StatusLine.color(11)))
      right.append(sep)
    }
    if rows > 0 {
      right.append(StatusLine.Piece("\(cols)×\(rows)", color: StatusLine.color(8)))  // the grid
    }
    if !st.title.isEmpty {
      if !right.isEmpty {
        right.append(sep)
      }
      right.append(StatusLine.Piece(st.title, color: StatusLine.color(15)))
    }
    if !right.isEmpty {
      right.append(StatusLine.Piece(" ", color: 0))
    }
    return StatusLine.cells(left: left, right: right, cols: cols, background: background)
  }

  static let older = 1
  static let newer = 2
  static let close = 3
  static let field = 4

  /// What a click or tap on column `col` of the bar asks for.
  public func action(at col: Int) -> Finder.Action {
    switch buttons.first(where: { $0.cols.contains(col) })?.tag {
    case StatusBar.older: return .older
    case StatusBar.newer: return .newer
    case StatusBar.close: return .close
    case StatusBar.field: return .edit
    default: return .none
    }
  }

  private func branch(_ path: String) -> (name: String, unpushed: Bool, repo: String, tips: String)?
  {
    let now = Date()
    if let b = branch, b.path == path, now.timeIntervalSince(b.at) < StatusBar.branchTTL {
      return b.value
    }
    let value = GitBranch.status(path)
    branch = (path, value, now)
    return value
  }
}

#if os(macOS)
  /// Commits ahead of and behind the upstream, counted by git itself, in the
  /// background when the branch or upstream commit moves (a failed count is
  /// retried every 10 s): the bar shows the last answer it got, never waits
  /// for one. Without git on the machine there are no counts (git is looked
  /// for by path, never through the /usr/bin stub that offers to install
  /// the developer tools).
  final class GitCounts: @unchecked Sendable {
    static let shared = GitCounts()
    static let git = [
      "/opt/homebrew/bin/git", "/usr/local/bin/git",
      "/Library/Developer/CommandLineTools/usr/bin/git",
      "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }
    static let every = 10.0
    private let lock = NSLock()
    private var cache: [String: (ahead: Int, behind: Int, tips: String, at: Date)] = [:]
    private var running: Set<String> = []

    /// repo: the .git directory (a worktree's own). nil before the first
    /// answer, without git, or when the branch has no upstream.
    func counts(repo: String, tips: String) -> (ahead: Int, behind: Int)? {
      guard let git = GitCounts.git else { return nil }
      lock.lock()
      let known = cache[repo]
      let stale =
        known.map {
          $0.tips != tips || $0.ahead < 0 && Date().timeIntervalSince($0.at) >= GitCounts.every
        } ?? true
      let start = stale && !running.contains(repo)
      if start {
        running.insert(repo)
      }
      lock.unlock()
      if start {
        DispatchQueue.global(qos: .utility).async { [self] in
          let got = GitCounts.ask(git, repo: repo)
          lock.lock()
          running.remove(repo)
          cache[repo] = (got?.ahead ?? -1, got?.behind ?? -1, tips, Date())
          lock.unlock()
        }
      }
      guard let known, known.ahead >= 0, known.tips == tips else { return nil }
      return (known.ahead, known.behind)
    }

    private static func ask(_ git: String, repo: String) -> (ahead: Int, behind: Int)? {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: git)
      p.arguments = [
        "--git-dir", repo, "rev-list", "--left-right", "--count", "@{upstream}...HEAD",
      ]
      p.environment = [
        "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "PATH": "/usr/bin:/bin",
      ]
      let out = Pipe()
      p.standardOutput = out
      p.standardError = FileHandle.nullDevice
      do {
        try p.run()
      } catch {
        return nil
      }
      // rev-list is local and quick; one that hangs is cut, not waited for
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        if p.isRunning {
          p.terminate()
        }
      }
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      guard p.terminationStatus == 0 else { return nil }
      let parts = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
      guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
        return nil
      }
      return (ahead, behind)
    }
  }
#endif
