# Welcome to fosforo

This is your home (`~`). The files here are yours, and the Files app sees
them too. `~/iCloud` is the app's folder in iCloud Drive.

## Getting help

    help              every command, in a pager (q leaves, /word searches)
    help | grep ssh   just the lines about one thing
    config            servers, keys, font and theme, on a settings screen

## Connecting to a server

    ssh user@host         a shell on another machine
    mosh user@host        the same, and it survives sleep and network changes
    key                   this device's public key, for the server's
                          ~/.ssh/authorized_keys
    ssh-copy-id user@host puts that key on the server for you

A host you name in `config` (or in `~/.ssh/config`) is reached by its name:
`ssh lab`.

## Files

    ls, cd, cat, less, cp, mv, rm, mkdir   as on any Unix
    edt notes.txt                          the text editor (^S saves, ^Q quits)

## Changing things

    edt ~/.config/fosforo/init.filo   colors, font, the start screen and more

Swipe sideways to change sessions; a two-finger tap opens a new one. On the
iPad, the Apple Pencil draws over the terminal, and the drawing can be shared.

You can delete this file; it will not come back.
