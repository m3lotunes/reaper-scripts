# CuePort Sync

Reaper integration for [CuePort](https://cueport.app). Artist feedback on the
active version of a production is pulled into your Reaper project as native
project markers, with a hover tooltip showing the full comment.

## Features

- **Device-code pairing** with the CuePort studio portal — no passwords in the
  script, no manual tokens to copy around.
- **Production picker** grouped by artist with an inline search filter.
- **Project markers** carrying a uniform color so you can spot CuePort markers
  at a glance. Your own markers stay untouched.
- **Hover tooltip** shows the author + timestamp + full comment text when you
  move the mouse near a marker.
- **Floating pill** with a popup menu for one-click sync / change project /
  open the main window.
- **Per-project binding** stored in the `.rpp` via `SetProjExtState`, so every
  project keeps its own CuePort production link.
- **Auto-start** option so the script runs in the background whenever Reaper
  starts.

## Requirements

| Extension | Required? | Install |
| --- | --- | --- |
| Reaper 6.68+ | required | <https://reaper.fm> |
| ReaImGui | required | `Extensions → ReaPack → Browse packages → ReaImGui` |
| curl | required | bundled with Win 10+, macOS and Linux |
| SWS Extension | recommended | <https://www.sws-extension.org> |
| JS_ReaScriptAPI | recommended | `Extensions → ReaPack → Browse packages → js_ReaScriptAPI` |

If ReaImGui or curl are missing, the script shows a clear message box at
launch with installation hints. SWS and JS_ReaScriptAPI are optional — the
hover tooltip works best with SWS; otherwise a JS_ReaScriptAPI fallback is
used.

## Usage

1. Run the action **Script: cueport_sync.lua** (use Reaper's Actions list).
2. Click **Connect to CuePort** — your browser opens, log in to the studio
   portal, approve the pairing code.
3. Pick a production from the list. The choice is stored inside the open
   `.rpp` so the next Reaper launch with that file remembers the binding.
4. Click **Sync comments**. CuePort markers appear on the ruler.
5. Hover a marker to read the full comment. Click the floating pill for
   quick actions at any time.

## Timing note

The rendered mix must start at **0:00** on the Reaper timeline so the marker
timestamps line up with the audio. (A configurable anchor is planned for a
later version.)

## Settings

Open the main window → top-right **Settings** button:

- **API** — switch between the production and preview workers.
- **Startup** — toggle auto-start (adds/removes a block in
  `~/Library/Application Support/REAPER/Scripts/__startup.lua`).
- **Quick access** — toggle the floating pill.
- **Diagnostics** — check required and recommended dependencies.
- **Account** — log out / quit the script.

## Under the hood

- One self-contained Lua file, ~2000 lines including a small inline JSON
  parser.
- HTTP via `curl` through `reaper.ExecProcess` (cross-platform).
- UI via ReaImGui; non-dockable windows for a tool-like feel.
- Markers carry a uniform color; comment metadata (author, text) is cached
  in `ProjExtState`, not in the marker name, so the ruler stays clean.
- Single-instance guard using a short-lived heartbeat in global `ExtState`.
