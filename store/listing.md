# fosforo — App Store listing (draft)

Fields as App Store Connect names them, with their limits. English (U.S.)
is the primary language.

## Name (30)

fosforo

## Subtitle (30)

Terminal with SSH and Mosh

## Promotional text (170)

A real terminal for iPad and iPhone: a built-in Unix-like shell, SSH and
Mosh clients, keys guarded by the Secure Enclave, and nothing collected.

## Description (4000)

fosforo is a terminal emulator for iPad and iPhone, made for people who
live on the command line.

A SHELL OF ITS OWN
fosforo starts in rocchetto, a small Unix-like shell built into the app:
pipes, redirects, variables, functions, history and Tab completion, with
ls, grep, sed, sort, find, wc and sixty more commands. It works offline,
with no account and no server.

SSH AND MOSH
The ssh and mosh commands are the app's own clients. Mosh keeps a session
alive across network changes and sleep. ssh-keygen and ssh-copy-id are
there too.

KEYS THAT STAY ON THE DEVICE
Private keys can be kept encrypted by a key that lives in this device's
Secure Enclave. A copied key file is useless elsewhere, and opening it
asks for Face ID, Touch ID or the passcode.

A REAL TERMINAL
- Full-screen programs such as vim, tmux and htop render as they should,
  on a Metal renderer.
- Box drawing, blocks, braille and Powerline glyphs are drawn from
  geometry, so ANSI art has no seams.
- IBM 3270 is the default font; Japanese, Chinese and color emoji come from
  the system.
- Several sessions per window, search in the scrollback, copy mode, and
  links you can open.
- A key bar over the on-screen keyboard, and full hardware keyboard
  support on the iPad, menu bar included.

YOURS TO SHAPE
Configuration and themes are Filo scripts you can read and edit. Files
come in from the Files app, and the iCloud Drive folder appears in the
shell as ~/iCloud.

PRIVATE BY DESIGN
fosforo collects nothing: no analytics, no tracking, no accounts. It
connects only to the machines you tell it to.

fosforo is open source (MIT): github.com/crgimenes/fosforo

## Keywords (100, comma-separated, no spaces after commas)

terminal,ssh,mosh,shell,console,unix,command line,sysadmin,server,vt100,ansi,keys,remote

## URLs

- Support URL: https://github.com/crgimenes/fosforo/issues
- Marketing URL (optional): https://crg.eti.br/projects/fosforo/
- Privacy Policy URL: https://crg.eti.br/projects/fosforo/#privacy

## Category

- Primary: Developer Tools
- Secondary: Utilities

## Copyright

2026 Cesar Gimenes

## App Privacy (nutrition label)

Data Not Collected. fosforo has no analytics, crash reporting, advertising
or accounts; what the person types, their files and keys stay on the
device (and in their own iCloud Drive, when they choose to use it).

## Age rating

Every content question "None"; no unrestricted web access (there is no
browser); no user-generated content shared through the app. Expected:
4+.

## Export compliance (CRG decides)

fosforo implements SSH and Mosh itself (AES-GCM and AES-CTR, AES-128-OCB
for Mosh, Curve25519 and ML-KEM key exchange, Ed25519, ECDSA and RSA
signatures): encryption beyond what the operating system provides,
used to secure communication channels. The likely answer is "uses
non-exempt encryption" under the mass-market treatment, with the annual
self-classification report, as other SSH clients do. Once decided, the
answer can go into Info.plist as ITSAppUsesNonExemptEncryption so App
Store Connect stops asking per build.

## App Review notes

fosforo is a terminal emulator. It opens in rocchetto, a shell built into
the app, which works offline with no account or server: try `help`,
`ls /bin`, `uname -a`, `seq 5 | wc -l`, or `edt notes.txt` (a text editor).

The shell's commands and the scripts the person writes are Filo programs
that run inside the app's interpreter on the device. The app does not
download executable code or change its features remotely; everything it
runs ships in the binary or is written by the user, as in other shell and
scripting apps.

SSH and Mosh connect only to servers the person names. [Demo server: CRG
decides — host, user and password, or none.]

Protected SSH keys ask for Face ID, Touch ID or the passcode; this is the
NSFaceIDUsageDescription prompt.

## Screenshots

In `store/screenshots/`, opaque PNG at the exact sizes App Store Connect
asks for (simulators renamed "iPhone" and "iPad" so the prompt is short):

- iPhone 6.9" (1320 × 2868): `iphone-1-shell.png` (pipelines over the
  warriors), `iphone-2-corewar.png` (Core War, Paper against Scanner).
- iPad 13" (2064 × 2752): `ipad-1-shell.png` (Gohan's greeting, the
  commands, a pipeline), `ipad-2-corewar.png` (three warriors, the side
  panel with each one's code).

Still to make: an SSH session (needs the demo server) and the phosphor
theme.
