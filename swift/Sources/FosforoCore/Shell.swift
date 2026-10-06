import Darwin
import Foundation

/// The user's login shell and the environment a terminal hands it.
public enum Shell {
  /// The login shell and its argv, "-zsh" style so it reads the profile files
  /// as Terminal.app and iTerm2 do.
  public static func login() -> (executable: String, argv: [String]) {
    var path = "/bin/zsh"
    if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
      let s = String(cString: shell)
      if !s.isEmpty {
        path = s
      }
    }
    let name = (path as NSString).lastPathComponent
    return (path, ["-" + name])
  }

  /// Whether a foreground process is a shell waiting at its prompt (nothing
  /// that closing the window would cut short). "-zsh" is a login shell.
  public static func isShell(_ name: String) -> Bool {
    var n = (name as NSString).lastPathComponent
    if n.hasPrefix("-") {
      n.removeFirst()
    }
    let own = (login().executable as NSString).lastPathComponent
    return n == own || ["sh", "bash", "zsh", "fish", "tcsh", "csh", "ksh", "dash"].contains(n)
  }

  /// A path as the shell takes it on a command line: untouched when it is
  /// plain, in single quotes otherwise (a quote inside becomes '\'').
  public static func quoted(_ path: String) -> String {
    let plain =
      !path.isEmpty
      && path.unicodeScalars.allSatisfy {
        $0.properties.isAlphabetic || $0.properties.numericType != nil
          || "_-./+:@%=,".unicodeScalars.contains($0)
      }
    if plain {
      return path
    }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Inherited environment with the terminal's identity. An app launched
  /// from Finder has no LANG, and a shell without it falls back to the C
  /// locale: no UTF-8 in ls, no accents at the prompt.
  public static func environment(base: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String]
  {
    var env = base
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "fosforo"
    if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil {
      env["LANG"] = Shell.lang()
    }
    return env
  }

  /// A UTF-8 locale the system has, as iTerm2 picks one: the current
  /// locale, then each preferred language with its region, then en_US. A
  /// name macOS makes up (en_BR) but has no locale for would have perl
  /// warn and Python refuse to start a program.
  static func lang(
    locale: String = Locale.current.identifier, preferred: [String] = Locale.preferredLanguages,
    installed: (String) -> Bool = {
      FileManager.default.fileExists(atPath: "/usr/share/locale/\($0)")
    }
  ) -> String {
    var candidates = [String(locale.split(separator: "@")[0])]
    for p in preferred {
      let parts = p.split(whereSeparator: { $0 == "-" || $0 == "_" })
      if parts.count >= 2 {
        candidates.append("\(parts[0])_\(parts[parts.count - 1])")
      }
    }
    candidates.append("en_US")
    for c in candidates where installed(c + ".UTF-8") {
      return c + ".UTF-8"
    }
    return "en_US.UTF-8"
  }
}
