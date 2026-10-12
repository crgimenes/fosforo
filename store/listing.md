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

- No ads
- No subscriptions
- No telemetry
- Just a good terminal

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
- On the iPad, draw over the terminal with Apple Pencil and share the
  picture.

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

Data Not Collected: nothing reaches the author or a partner. fosforo has
no analytics, crash reporting, advertising or accounts. It does send data
off the device, but only where the person sends it: SSH and Mosh to the
servers they name, and ~/iCloud to their own iCloud Drive. The policy
(web/index.html, #privacy) says what happens to keys: plain files in
~/.ssh until `key protect`, out of backups, and sealed without a presence
check on a device with no passcode. Settings > About > Privacy Policy
opens it in the app.

## Age rating

Answer the questionnaire as it stands when submitting; the rating is
whatever those answers give. What the app is, for the answers: there is
no browser and no content of its own beyond the help and the bundled
programs; nothing a person writes is shared through the app; SSH and
Mosh reach any server the person names, whose content the app does not
control.

## Export compliance (decided 2026-10-08)

fosforo implements SSH and Mosh itself (AES-GCM and AES-CTR, AES-128-OCB
for Mosh, Curve25519 and ML-KEM key exchange, Ed25519, ECDSA and RSA
signatures): standard algorithms, beyond the system's, securing the
person's own connections.

Answered in App Store Connect for builds 13 and 15: "standard encryption
algorithms instead of, or in addition to, the operating system's", with
the app not available in France (no ANSSI declaration). With those
answers App Store Connect classed the build as needing no documentation
and suggested the key: `ITSAppUsesNonExemptEncryption` = false in
assets/Info-iOS.plist, in place since build 16, which then went through
without the question. False here records that exemption, not an absence
of cryptography. Territories: 173 (France and mainland China out; China
needs an ICP number). Revisit if the algorithms or the territories
change.

## App Review notes

fosforo is a terminal emulator. It opens in rocchetto, a shell built into
the app, which works offline with no account or server: try `help`,
`ls /bin`, `uname -a`, `seq 5 | wc -l`, or `edt notes.txt` (a text editor).

The shell's commands are Filo programs shipped in the app; scripts the
person writes, or brings in through Files or iCloud Drive, run in the same
interpreter on the device, with the app's sandbox. The app has no
mechanism of its own to download code or change its features; what the
person runs on a server over SSH or Mosh runs there, not on the device.

SSH and Mosh connect only to servers the person names. A demo server
for review: `fosforo.crg.eti.br`, user `review` (no sudo, no forwarding;
SSH and Mosh). Its password goes only in App Store Connect's sign-in
field for the reviewer, never in this file.

To check the rest: `ssh review@fosforo.crg.eti.br` (answer yes to the
host key, then the password), `exit`, then `mosh review@fosforo.crg.eti.br`;
`config` opens Settings (servers, keys, Privacy Policy); Files shows the
app's folder, and a key opened from Files is offered for ~/.ssh;
`ssh-keygen -t ed25519` makes a key, `key protect id_ed25519` seals it.

Protected SSH keys ask for Face ID, Touch ID or the passcode; this is the
NSFaceIDUsageDescription prompt.

## Screenshots

In `store/screenshots/`, opaque PNG at the exact sizes App Store Connect
asks for (simulators renamed "iPhone" and "iPad" so the prompt is short):

- iPhone 6.9" (1320 × 2868): `iphone-1-shell.png` (pipelines in the
  built-in shell), `iphone-3-ssh-htop.png` (htop over SSH).
- iPad 13" (2064 × 2752): `ipad-1-shell.png` (Gohan's greeting, the
  commands, a pipeline).

The iOS build has no Core War, so its shots are gone, and
`iphone-1-shell.png` (its pipelines run over the warriors) needs
retaking. Still to make: an iPad SSH session, the new key bar, and the
phosphor theme.
