# fosforo

A terminal emulator for macOS, iPadOS and iOS. MIT.

On the Mac it is a terminal and nothing else: your login shell on a pty,
the system's ssh and git. On the iPad and iPhone the shell is `rocchetto`, built
in, with the app's own SSH and Mosh clients behind the `ssh` and `mosh`
commands. The same C core and Metal renderer draw both.

## Layout

- `vt/` — the terminal core in C11: VT parser, cell grid with scrollback
  and reflow, input encoding (keys, mouse, focus, bracketed paste). No I/O,
  no global state. `build/vtdump` renders a byte stream for inspection.
- `glyph/` — box drawing, blocks, shades, braille and Powerline glyphs drawn
  from geometry, so ANSI art has no seams between cells.
- `pty/` — spawning the shell on a pseudo-terminal (macOS).
- `config/` — the Filo configuration engine (`init.filo`, themes, hooks).
- `rochost/` — the host that runs `rocchetto` in-process on iOS.
- `swift/` — SwiftPM: `FosforoCore` (session, viewport, status bar, search),
  `FosforoRender` (glyph atlas, Metal, config), `FosforoSSH`, `FosforoMosh`,
  and the two apps, `fosforo` (AppKit) and `fosforo-ios` (UIKit).

Needs `../filo-term` (UTF-8 decoder) and `../clang_filo` (Filo) beside this
repository; the iOS build also needs `../rocchetto`.

## Build

```sh
make qa          # everything: C with ASan/UBSan, clang-tidy, cppcheck,
                 # clang-format; Swift lint, warnings as errors, tests
make app         # build/fosforo.app (ad hoc signed)
make ios-sim     # build/fosforo-sim.app for the simulator
make ios-device  # install on the paired devices (DEVICE=name for one)
make icons       # the app icon from assets/kamon.svg
```

## Configuration

`~/.config/fosforo/init.filo` is a Filo script; the documented default is
written on first run. `(set Key value)` overrides a default: font, rows and
columns, scrollback, colors, the status bar, the bell (`"flash"`, `"sound"`
or `"none"`), whether programs may set the clipboard (`Clipboard`,
`"allow"` or `"deny"`; the status bar says when one did), what
Option+arrows send (`OptionArrows`: `"xterm"`, as iTerm2, for tmux's
`M-Left`/`M-Right`, or `"word"`, ESC b/ESC f as Terminal.app), key repeat on
the iPad. Themes are files in
`~/.config/fosforo/themes/`, chosen with `(theme "name")`; `default` and
`phosphor` are written as examples. Reload Config (⌘R) applies the file to
every open window.

Hooks: set a function on `on-open`, `on-close`, `on-bell`, `on-title`,
`on-prompt`, `on-focus`, `on-blur` or `on-notify` and it runs when the event
happens, with one string argument. It may `set` anything from the config,
switch the `theme`, or `notify`. Nothing runs for an event without a
handler.

```lisp
(set on-blur (fn (arg) (theme "phosphor")))
(set on-focus (fn (arg) (theme "default")))
```

## The window

Several sessions per window, one shown at a time: ⌘T new (in the directory
of the session in front), ⌘W close, ⌘←/⌘→ and ⌘1–9 to switch, a two-finger
sideways swipe on the trackpad. The
status bar at the bottom shows `n/N`, where the shell is (`ssh user@host`,
or the directory and git branch here, with `↑N`/`↓N` against the upstream),
the grid size and the title.

- ⌘F searches the scrollback; Return gives the keyboard back with the
  matches still lit, ⌘G/⇧⌘G step, Esc closes.
- ⇧⌘C enters copy mode: arrows or `hjkl` move, Space anchors a selection
  that follows, Return copies, Esc leaves.
- ⌘↑/⌘↓ jump between prompts (see shell integration), ⌘K clears the
  screen and the history, ⌘+/⌘−/⌘0 change the font, a pinch does the same.
- Double-click selects a word, triple-click a line (the whole line when it
  wrapped over several rows); dragging past an edge scrolls. ⌘-click opens a link. Files dropped on the window paste their
  paths.
- BEL flashes the screen (one flash per 100 ms, however many BELs). OSC 9
  and OSC 777 become notifications when the session is not the one in
  front; clicking one brings that session back. Closing with a program
  still running asks first.

On the iPad the same lives in the menu bar, the touch menu and the key bar
over the on-screen keyboard; a pinch zooms the picture. "Open in fosforo"
from the Files app imports a file into `~`, or a private key into `~/.ssh`,
after asking. `~/iCloud` is the app's folder in iCloud Drive; a file not
downloaded yet is listed by its name and comes down when first read.

## Shell integration

For zsh, in `~/.zshrc`: prompt marks for ⌘↑/⌘↓, the directory for the
status bar, and a notification for commands that took more than ten
seconds.

```sh
_fosforo_prompt() { printf '\e]133;A\a\e]7;file://%s%s\a' "$HOST" "${PWD// /%20}" }
_fosforo_start() { _fosforo_t0=$SECONDS }
_fosforo_done() {
  (( ${+_fosforo_t0} )) || return
  local d=$(( SECONDS - _fosforo_t0 )); unset _fosforo_t0
  (( d >= 10 )) && printf '\e]777;notify;done in %ds;%s\a' "$d" "$history[$HISTCMD]"
}
precmd_functions+=(_fosforo_prompt _fosforo_done)
preexec_functions+=(_fosforo_start)
```

Terminals that do not know the sequences ignore them.

## SSH and Mosh on the iPad and iPhone

Inside `rocchetto`: `ssh [-vAN] [-p port] [-l user] [-i file] [-o option=value] [-J [user@]jump[:port]] [-L|-R|-D spec] [user@]host`
(`-o` takes the `~/.ssh/config` keys read here, before the file's;
`-J`, or `ProxyJump` in the config, reaches the host through the jump
host's tunnel; a second `ssh` to a host already connected shares its
connection and opens at once; `-L [bind:]port:host:hostport` and `-R`
carry TCP ports either way, `-D [bind:]port` is a SOCKS proxy through the
host, `-A` lets the host ask this device to sign with its keys, which
never leave it, and `-N` keeps only the forwards, until Ctrl-C;
`LocalForward`, `RemoteForward`, `DynamicForward` and `ForwardAgent` in
the config do the same), `mosh [--server path] [user@]host`, `ssh-copy-id`, `ssh-keygen -R host`, `ssh-keygen -t
ed25519|ecdsa [-b bits] [-f file] [-N passphrase] [-C comment]` (a new
pair in `~/.ssh`, as on a computer), and `key` to show the
device's key, `key list`, `key paste NAME`, `key fetch host:path`,
`key protect NAME` (encrypted for this device, Face ID to use) and
`key unprotect NAME`. `~/.ssh/config`, `known_hosts` and OpenSSH or PEM
keys work as on a computer. Nothing is moved, deleted or encrypted without
a command and a confirmation. `pbcopy` and `pbpaste` reach the device's
clipboard (`echo hi | pbcopy`, `pbpaste | wc`); in a Filo script,
`(pbcopy "hi")` and `(pbpaste)`.

## License

MIT. The 3270 font is BSD-3-Clause (see the credits in the app).
