# Melotunes Reaper Scripts

A collection of Reaper scripts built and maintained by
[melotunesmusic.de](https://melotunesmusic.de).

## Installation

1. Install [ReaPack](https://reapack.com) if you don't already have it.
2. In Reaper, open **Extensions → ReaPack → Import repositories…** and paste:

       https://raw.githubusercontent.com/m3lotunes/reaper-scripts/main/index.xml

3. Open **Browse packages**, find the scripts you want and install them.

## Scripts

### CuePort Sync

Reaper integration for [CuePort](https://cueport.app), the studio platform that
sits around your DAW. It reads from CuePort; the only thing it writes back is a
reply you type yourself.

- **Every comment as project markers** on the ruler — the artist's, the
  studio's, threads and all — with a hover tooltip showing the full text. One
  pin per thread. Optional: turn them off and the ruler stays yours, the
  comments are still there on the waveform and in the list.
- **Waveform of the active version** in the window, with the comments pinned to
  it and a live play cursor. Click or drag to move the DAW cursor.
- **Comment list** in a column beside it, replies indented under what they
  answer, scrolling inside itself however many there are. Hover a pin to light
  its comment and scroll to it, or a comment to light its pin; click a row to
  jump there, or press Reply and answer from the DAW.
- **Version switcher**: press the kind you want in the picker (*Instrumental*,
  *Mix Master*), then its versions sit as pills above the waveform. Switching
  takes the waveform, the comments and the markers with it, and clears a loaded
  A/B reference along with its audio.
- **A/B compare** plays the CuePort version straight to your hardware outputs,
  past the project master, against your DAW mix under one transport.
- **Loudness of the active version** — integrated LUFS, true peak and dynamic
  range, as measured by CuePort when the mix was uploaded.
- **Cover art** of the production, in the picker and in the header.
- **Device-code pairing**: no passwords in the script, no tokens to copy.
- **A floating pill** on the transport for sync, change production and open the
  window, from anywhere in Reaper.
- **Self-updating**: it looks at its own file on GitHub once a day, 200 bytes,
  and installs what it finds at the press of a button — through ReaPack when
  ReaPack manages the copy, by replacing the file when it does not. It restarts
  itself into the new version afterwards.

Needs Reaper 6.68+, ReaImGui and curl; SWS and JS_ReaScriptAPI are recommended.
The script has a Dependencies page that says what is missing and what each one
is for.

See [CuePort Sync/](CuePort%20Sync/) for the full description, the settings and
what exactly it touches in your project.

## License

MIT — Copyright (c) 2026 melotunesmusic. See [LICENSE](LICENSE). Each script
carries the notice in its own header too, because ReaPack hands users the
script file on its own.

Bundled third-party work is listed in the per-script README (for CuePort Sync:
rxi/json.lua under MIT, and the Inter typeface under the SIL OFL 1.1).
