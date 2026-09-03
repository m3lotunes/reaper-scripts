# CuePort Sync

Reaper integration for [CuePort](https://cueport.app). The comments on a
production — the artist's and the studio's, threads and all — are pulled into
your Reaper project as native project markers, with a hover tooltip showing the
full comment. You can answer them from the DAW, and switch between every
version the studio has uploaded.

[CuePort](https://cueport.app) is the studio platform that sits around your
DAW — artists, productions, versions, files, sessions and feedback. Every
artist gets their own login and hears new versions there, leaves comments
pinned to the exact second on the waveform and uploads covers or stems; every
upload becomes a version, a production runs through six steps from lyrics to
paid, and Spotify stats pull themselves in daily. The mixing stays in your DAW.
This script is the Reaper end of it: it reads from CuePort, and the only thing
it ever writes back is a reply you type yourself, or the removal of one you ask
it twice to remove.

## Features

- **Code pairing** with the CuePort studio portal — no passwords in the
  script. You generate a short pairing code in the portal and type it into the
  plugin; the code is tied to your studio the moment it is made, so there is no
  separate approval step. Once paired, the badge in the
  header names the **studio** rather than saying `CONNECTED` — which studio this
  device is attached to is the question worth answering before anything is
  uploaded, and a name that is not yours is meant to be noticed.
- **Production picker** grouped by artist with an inline search filter. Built
  like the rest: section labels over cards, the search row on one, the
  production you would go back to on another, and the list itself in the same
  recessed well the comment column uses, sized to the room the window has
  rather than to a fixed box. The disclosure arrows beside each artist are drawn, not
  typed: an arrow glyph lands in whatever font the platform picks for it.
- **Send a render straight to CuePort** — a button in the production view opens
  a page with the two things you actually choose (bounds, and whether the source
  is the master mix, the selected tracks through it, or stems), and two ways out
  at the bottom: render one now, or take a file that is already there. What it
  becomes is written at the top before anything happens — `Love in the Dark →
  Mix Master v4`. Every upload is a **new version**; nothing is ever replaced,
  exactly as in the browser.
  Format, bit depth, sample rate and channel count are fixed at FLAC 24 bit,
  project rate, stereo — that is the file CuePort wants, and the same one the
  studio portal makes out of a WAV. **Your render settings are borrowed, not
  taken:** all twenty-one fields are written down first and put back straight
  afterwards, whether the render worked or not. If REAPER should die in the
  middle of one, the next start puts them back — into that project and no other.
  With **Time selection** the script measures rather than asks: a selection that
  is not there is stated as a fact instead of being a dialog you learn to click
  away, and one that does not start at 0:00 offers to move the ruler with it,
  because otherwise every comment lands quietly askew by the offset.
  Afterwards the file itself is checked, not the settings — a mono plugin at the
  end of the master chain makes a mono file without any setting saying so. The
  waveform and the length go up with it, so the artist gets a player with
  something drawn in it rather than an empty one. Whether the artist is told at
  all is a switch on the page: CuePort sends no mail for a new version by
  itself, and from the DAW nothing would reach them otherwise.
- **Cover art** — the artwork a production carries in CuePort, shown as a tile
  in the picker list and large in the corner of the production header, with the
  loudness figures to its left. It is drawn rounded and sits on a soft shadow,
  so it reads as lifted off the card rather than pasted onto it. A production
  without one gets the CuePort music glyph, drawn rather than loaded, so it
  scales and follows the theme color.
  Covers are cached in an `artwork` folder inside the REAPER resource path,
  never in your project folder, and signing out deletes them. The download runs
  in the background: everything missing goes out in one request while the window
  keeps its frame rate, and each cover appears as it lands. Replace a cover in
  the portal and the next sync picks it up — the local filename carries a hash
  of the file, so a new cover is simply a file the script does not have yet.
  (One limit worth knowing: a replacement with both the same filename and the
  same byte count is indistinguishable to that hash. Signing out clears the
  cache if you ever hit it.) On Windows the download still blocks for its
  duration; see *Under the hood*.
- **Project markers** carrying a uniform color so you can spot CuePort markers
  at a glance. Your own markers stay untouched. They exist while the script
  does: quitting takes them back off the ruler, and starting it again on a
  bound project puts them straight back — the comments they are made from are
  cached in the project itself, so that costs no request. The render start
  marker is left alone, since that one is the ruler origin you set by hand.

  Both are optional. **Settings → Project markers** switches the comment markers
  off if you would rather keep the ruler to yourself — the pins on the waveform
  and the comment list still show every comment, because they read from the
  project rather than from the ruler. The render start marker has its own switch
  and is on by default; with it off, Set and Clear go on working exactly as
  before and the marker returns the moment you switch it back.
- **Hover tooltip** shows the author + timestamp + full comment text when you
  move the mouse near a marker.
- **Waveform** in the main window, always open and inside the production card
  rather than in a box of its own: both are about the same track, so a hairline
  separates them instead of a border. It reads as a recess — darker than the
  card around it, no shadow of its own. Transport and clock share one line
  under it, and on a narrow docker the clock drops to a line of its own instead
  of pushing the row past the edge. It draws the active
  version's waveform with the artist comments overlaid as markers — hover a
  marker to read the comment. The dot of a pin and the arrow of the play cursor
  are centred on their own vertical lines, which needs the lines to be drawn as
  rectangles: AddLine quietly shifts what it strokes by half a pixel and nothing
  drawn beside it does. Shows the live DAW play/edit cursor; click or
  drag the strip to move the DAW cursor (and seek playback) to that spot, and
  use the built-in Play/Pause + Stop buttons. Falls back gracefully when no
  waveform or track length is stored for the version yet.
- **Comment list** in a column of its own on the left, switched on in
  **Settings → Window** and remembered across sessions. It shows the whole
  conversation: the artist's remarks, the studio's, and every reply indented
  under the comment it answers with a note of which side wrote it. (Up to
  v1.28.0 the script was handed the artist's opening remarks only — studio
  comments and replies were filtered out before they got here, so a thread you
  could read in the browser was half missing in the DAW.) A thread gets **one**
  pin on the ruler and on the strip, not one per line: a reply carries its
  parent's timestamp, so a pin each would stack two on the same pixel.
  A comment with no timestamp is listed too, without a pin — there is nowhere
  on the strip to put it, but somebody wrote it.

  The column **scrolls inside itself**: it takes the height the window has, so
  thirty comments make it scroll rather than making the window taller. Hovering
  a pin out on the waveform brings its comment into view — once per pin, so it
  does not fight you while you scroll by hand. The highlight works
  both ways: hovering a pin in the waveform lights the comment it belongs to,
  and hovering a comment lights its pin out on the strip — same colour, same
  larger dot — so a mark on the strip and the sentence behind it are one glance
  apart. The tooltip stays with the mouse and does not follow the second one. Clicking a row moves the cursor to that pin. Same border and shadow as
  the other cards, and a gradient of its own running the full height: a card is
  opaque and hides the window's wash, so a column that wants depth has to carry
  it itself. Only its top edge reaches the surface the other cards sit on and
  everything below falls away, so it reads as recessed rather than laid on top. On a narrow
  window the column steps aside rather than squeezing the waveform down to
  something you cannot aim at; it returns when there is room, and the setting is
  not touched. It belongs to the production screen and shows up nowhere else:
  Settings, About and the picker are not about a track, so it steps aside there
  as well. None of it changes the size of the window.
- **Reply from the DAW.** Hover a comment, press **Reply** in its top-right
  corner and the caret is already in the box; type, send. It
  arrives in CuePort as an ordinary threaded reply — same shape both portals
  write, so the artist sees it under the comment it answers — signed with the
  name of whoever paired this machine, and the artist's page is told about it
  while it is open. The control hangs off the row rather than sitting at the
  foot of the list: a reply needs a comment to reply to, and a Reply under every
  line turns a column of remarks into a column of buttons. Sending is queued for
  the next frame rather than done in the click (the request blocks for as long
  as curl takes), and a reply that fails to send goes back into the box with the
  text still in it instead of being swallowed. The control is painted only while
  the row is lit — permanently visible it would cover the end of the header line
  it sits on — but its hit area is always there, which is what lets a click
  finish: ImGui reports a window as un-hovered while an item is held down, so a
  control that exists only while the row is lit disappears between press and
  release and the click is cancelled. Clicking it does not also jump the edit
  cursor to that comment.
- **Who spoke, at a glance.** A comment's pin on the waveform and its timestamp
  in the list carry the colour of the side that wrote it: amber for the artist,
  purple for the studio — the same reading cueport.app's own player gives. Only
  the timestamp is tinted, not the whole line: it is the part that also exists
  out on the strip, so colouring it is what ties the two together.
- **Delete a reply.** The small **×** at the right edge of an answer removes it
  in CuePort. It asks first: one press turns it into **Sure?**, and only the
  second press sends anything. That is deliberate — it is the one action here
  that cannot be undone, on a control that appears under the mouse rather than
  being aimed at. An armed control keeps asking even when you move the mouse
  away, because a question that disappears when you look away has not been
  answered. Pressing Reply instead disarms it.

  **Only answers.** The comment a thread starts with cannot be removed from
  here — it is usually the artist's, and taking it away would take the
  conversation with it; the server refuses it as well, not just the interface.
  After a delete the thread is fetched again rather than patched from a guess,
  so the column and the markers say what the server says. A reply belonging to
  another studio cannot be reached, and the answer for it is word-for-word the
  answer for an id that does not exist, so it cannot be used to find out what
  exists elsewhere.

- **Version switcher.** A production is not one file: it holds the instrumental,
  the mix, and every version of both. Until v1.28.0 the script opened exactly
  one of them — the newest mixmaster — and offered no way to any other, so
  checking a note left on the instrumental meant going to the browser for it.

  The two questions are asked in the order you would ask them. **In the picker**
  each production shows the kinds it holds — *Instrumental*, *Mix Master* —
  as pills you can press: press one and that is what opens, rather than the mix
  that used to open no matter what was in there. Pressing the row itself opens
  the newest mix, as before. **In the production card**, above the waveform,
  both kinds are always shown as a switch — it is what says which kind you are
  looking at, so it is there even when there is only one, and the kind a
  production has nothing of is dim and cannot be pressed. Under it, the versions
  of the open kind as a row of pills with the open one filled in. Everything
  reads left to right the way it was made: *Instrumental* before *Mix Master*,
  `v1 v2 v3` oldest first. The pills wrap onto another line rather than running
  past the card edge, and what the studio called the open version is a dim line
  underneath. Your choice is remembered per project — two `.rpp` files bound to
  the same production may well be working on different versions of it.

  Switching moves everything with it: the waveform, the loudness figures, the
  comments and the markers on the ruler. A loaded A/B reference is taken down
  and its audio deleted (see below) — the new one is loaded when you press the
  button, not behind your back. If the new version cannot be fetched, the script
  goes back to naming the one whose pins are still on the ruler — a header
  claiming a version that none of what you see belongs to is worse than a
  version that did not change.
- **Loudness of the active version** in the corner of the production card:
  integrated LUFS, true peak and dynamic range, as measured by CuePort when the
  mix was uploaded (`GET /reaper/comments` returns them alongside the peaks).
  Empty for versions with no analysis, which is every version uploaded before
  CuePort measured — an absence, not an error, so it says nothing.
- **A/B compare** loads the active CuePort version into a hidden reference
  track and toggles playback between it and your DAW mix under one synced
  transport. The reference **bypasses the project master** and plays straight
  to hardware outputs 1/2, so the finished bounce is heard untouched. The track
  is temporary — removed on production switch, the "Remove" button, or script
  exit. The *audio* is not: quitting the script keeps it, so reopening on the
  same project reuses the file rather than downloading the version again.
  "Remove", logging out and switching production are the explicit "done with
  it" and delete it. (Press **Sync comments** once first so the version is
  known.) **Switching version takes the reference down and deletes its audio**,
  rather than quietly downloading the new one: an automatic reload on every
  switch would leave a file per version sitting next to the project for a
  comparison nobody asked for. Load it again for the version you switched to.
  Saving the project while A/B is loaded is safe: the downloaded audio lives in
  a `CuePort A-B` folder next to the `.rpp`, so re-opening finds it, and the
  leftover reference track is swept out on load.

  **Where the audio goes, and what Settings shows.** A saved project keeps it
  beside the `.rpp`; a project that has never been saved has no folder to use,
  so it goes to a shared cache under the Reaper resource path instead. Settings
  reports both. Only the shared cache has a clear button, and that asymmetry is
  the point: a file beside a project is deleted by itself once that project has
  been saved without the reference track in it, whereas nothing can ever tell
  the shared cache that its files are finished with — there is no project whose
  saving would say so.
- **Hamburger menu** in the header carrying the whole navigation: Production
  (back to the current version and its player), Sync comments, Change
  production, Settings, About, Dependencies, Log out and Quit. The screens hold
  their content and nothing else, so there is exactly one place to look for a
  way somewhere. The panel is positioned by hand — right-aligned under the
  hamburger and clamped to the window — because a popup left to itself opens
  wherever it likes, which put it outside the script window and over Reaper's
  arrange view. Its height is left to ImGui so it always fits its rows and
  never scrolls. The row for the screen you are on is marked, not hidden. While
  it is open the panel sits flush against the hamburger and the two read as one
  shape. The join is painted over everything else, last of all, from inside the
  panel: a clip rectangle that *replaces* the current one (rather than narrowing
  it) lets the panel draw upwards over the button. Building it from two halves —
  each window rubbing out its own share of the seam — does not work, because
  whatever is drawn afterwards shows through again. The patch covers exactly the
  button plus the corner radius, and it carries the button's hover state, which
  would otherwise be buried underneath it. It stops level with that corner and
  the rows start below it — reach any further and the first row's hover
  highlight loses its top edge under the patch.

  The shape carries **one** outline, not one per box. Two borders never land on
  exactly the same pixel, and every edge that still looked frayed came from
  that: the corner where the button starts, the break where the panel's top
  edge runs into it, the step down the right-hand side. So the button draws
  only its surface while the menu is open; the panel leaves its top-right
  corner square, because the button is flush right and continues that line; and
  the button's share of the outline is a single open stroke — up the left edge,
  round the top, down the right — painted over the join along with the surface.
  Open, because the button has no bottom: it runs into the panel.

  The panel carries the same depth as the cards — the top-down gradient over
  its surface and a shadow ring underneath — with both starting below the join,
  so nothing crosses the seam that makes the button and the panel one shape.
- **Floating pill** with a popup menu for one-click sync / change project /
  open the main window.
- **Per-project binding** stored in the `.rpp` via `SetProjExtState`, so every
  project keeps its own CuePort production link. Logging out clears the lot —
  comments, markers, waveform, loudness figures, the A/B reference and this
  binding: logged out means disconnected, so the project stops claiming a
  production too. Only the project that is open can be reached that way; another
  tab keeps its binding until it is opened and logged out from as well.
- **Auto-start** option so the script runs whenever Reaper starts, with a
  **Start in background** switch that decides whether it opens the main window
  or stays behind the pill. The switch is the only thing that decides: until
  v1.18.4 auto-start forced hidden regardless of it, so turning it off did
  nothing. An existing auto-start setup that never touched the switch has it
  written on once, so it keeps behaving as it did.
- **Fixed header** — the wordmark, connection badge, menu button and close box
  stay in place while the content below scrolls in its own region. The wordmark
  is the one piece of branding in the window, so it is larger than a heading and
  sits on a shadow (the glyphs drawn twice, once offset and dark — the toolkit
  has no text shadow), with a soft light behind the mark. On a narrow docker the
  badge is dropped rather than letting the right-hand group overlap the
  wordmark; the menu button and the close box always stay. The content keeps
  the same margin on the left and on the right, the scrollbar shows only when
  there is something to scroll, and it appears *inside* the right-hand margin
  instead of claiming a strip of its own. Nothing shifts sideways when it turns
  up, and it never touches the content.
- **No title bar.** Reaper's strip above the header carried a collapse arrow,
  the script name a second time and a close box; the header already says all of
  that. Closing is an X beside the menu button, and like the old one it hides
  the window rather than ending the script — the hover tooltip and the pill keep
  running. The header doubles as the drag handle
  (`ConfigVar_WindowsMoveFromTitleBarOnly` is set to 0 so ImGui allows it).
  Docked, none of this applies: there the docker draws the tab.
- **Dockable, resizable** main window — drag it into any Reaper docker (or use
  the button in Settings); the docked position is remembered between sessions.
  While floating it can be made as large as you like, but not smaller than it
  needs: the height floor is whatever the content measured (below it the
  scrollbar comes back), and the width floor is 890px — enough for the comment
  column to stay open beside a waveform still wide enough to aim at, which the
  older floor of 668 was not. The height floor is capped so a long screen can
  never demand more room than a laptop display has — and only the production
  screen builds it at all. Settings, About, login and pairing are pages that
  scroll; any of them rebuilding the floor would drag the window taller the
  moment it opened and leave it that way, since a floor only holds downwards.
  The picker is out too, for its own reason: its list *is* the window by
  construction, so feeding its height back would have the two chase each other.
  The frame a screen change lands on is skipped as well — a window that resizes
  to its own content is handed the size worked out from the frame before, so
  that first frame still carries the height of the page you just left.
- **Picking a production syncs it** right away, so the player holds its current
  version without pressing Sync first. Until a render start is set, the button
  that sets it pulses — without it the comment timestamps cannot land in the
  right place. "Set" means *CuePort's own marker is on the ruler*, not "Reaper
  reports some offset": a project template can carry an offset nobody asked
  for. Once it is down, a green check appears beside the label and the button
  stops pulsing; the offset itself is behind the "?" next to it, rather than as
  a permanent line of status under the card.
  Neither button touches the network: moving the ruler origin re-places
  the comment markers, and the comments for that are already cached in the
  project, so it is local work.
  (Until v1.10.2 both re-fetched the whole comment list from the server
  mid-click — the wait people noticed. v1.10.2 still did it for productions
  with *no* comments, because an empty list was read as "never synced".) Only
  a missing cache — a project that has genuinely never synced — falls back to
  a real sync.
- **Attach the pill to the transport** — the quick-access pill
  can be drawn straight onto Reaper's transport and dragged around inside it;
  click for the menu, right-click to detach. Requires JS_ReaScriptAPI.
- **Keeps itself up to date** — a once-a-day, 200-byte look at its own file on
  GitHub, and one button to install what it finds. Through ReaPack when ReaPack
  manages this copy, by replacing the file when it does not, and either way the
  script restarts itself into the new version. Switchable off in Settings.

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
2. Open CuePort in your browser, generate a pairing code while logged in to
   your studio, and type it into the plugin's **Connect** field. The code is
   tied to your studio the moment it is made, so there is no separate approval
   step. (The old browser-approval way is still on the same screen as **Classic
   browser approval**, for a studio whose plugin has not updated yet.)
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

Open the main window → top-right **hamburger** → **Settings**. The groups are
laid out as tiles: two columns while the window is wide, stacked once it is
narrow. A tile's content never changes with the width, only where it sits.
Logging out and quitting are in the menu, not on this screen.

- **Startup** — toggle auto-start (adds/removes a block in
  `~/Library/Application Support/REAPER/Scripts/__startup.lua`), and
  **Start in background** to keep the main window closed on launch.
- **Updates** — whether to ask GitHub once a day for the current version
  number. On by default. It sends nothing but a request for a public file: no
  token, no ids, nothing about you.
- **Window** — one button that flips with the state: **Dock in Reaper** while
  floating, **Undock window** while docked.

  Undocking by hand is possible too, but a Reaper docker has *two* drag
  handles and they do different things. Click the small arrow at the top left
  of the docker to reveal the tab bar, then drag the **CuePort Sync** tab out:
  that undocks this window. Dragging the arrow itself moves the whole docker,
  which leaves the window inside it — Reaper calls the result a *floating
  docker*, and the window is still a docker child, so the script keeps
  reporting "docked". That is correct, not a glitch.
  Below the docking control, **Comment list** switches the column beside the
  waveform on and off. It lives here rather than in the menu: the menu is for
  things you do, this is a choice about the layout that stays put.
- **Project markers** — what the script is allowed to put on your ruler.
  **Comment markers** turns the one-marker-per-comment set on and off; with it
  off nothing else changes, the waveform pins and the comment list still carry
  every comment. **Render start marker** hides just that marker, leaving the
  ruler origin exactly where it is. Both take effect on the spot and neither
  costs a request: switching back on rebuilds from what is already stored in
  the project.
- **Quick access** — toggle the floating pill and, with JS_ReaScriptAPI
  installed, attach it straight to the transport.
- **Diagnostics** — the version, the instance id and the raw docking reading
  (script state and ImGui dock id), plus a way through to the Dependencies
  page.

### About

Reachable from the menu, and the place to point anyone who asks what this is:
what CuePort is and what it is not (your DAW keeps the mixing), how the script
works, **exactly what it writes into your project** — the same list as above,
including which of it is a named undo step — what leaves the machine, the
no-warranty notice in plain words, and the licences of everything bundled, with
links to the source and to the terms and privacy policy for the CuePort service
itself.

On a wide window it is two columns, each a stack of cards; which card goes into
which column is worked out from the heights the previous frame came out at, so
it stays balanced when the text is edited rather than leaving a hole beside a
short card.

### Dependencies

Also from the menu: one row per dependency with a status badge — installed,
required, or optional — and a line saying what each one is actually for, so
"do I need SWS?" is answered on the page rather than guessed. Anything missing
that has a download page gets a link. Reaper reads its extensions once at
startup, so an install only shows up after a restart; curl is a program rather
than an extension and can be re-checked on the spot, which is what the button
there does.

At the top of the same page sits the update panel. It says which version is
running and where this copy came from — a ReaPack package, a file installed by
hand, or a machine without ReaPack at all — because that decides how an update
is installed. Once a day the script reads 200 bytes from its own file on GitHub
to learn the current version number; the request runs detached, so nothing
about it makes you wait, and **Settings → Updates** switches it off.

When there is something newer, one button does it. A ReaPack-managed copy is
handed back to ReaPack, which updates that one repository and leaves every
other one alone, so ReaPack's own records stay correct. Anything else has its
file replaced directly, with the previous version kept as a `.bak` beside it.
A package you pinned in ReaPack is left alone and says so instead.

Before a single byte is replaced the new file is checked three ways: its byte
count against what the server said, its version line, and whether it compiles
at all — `load` builds the chunk without running any of it, so a download that
stopped halfway fails here rather than in the slot the script runs from.

Afterwards the script restarts itself into the new version — and comes back
with the window open, even if you normally start it in the background: you
pressed a button and should see what it did.

While a download or a ReaPack run is in progress the window dims, a large arc
turns in the middle of it, and nothing underneath can be pressed — half a
window that reacts and half that does not is worse than one that plainly waits.
A check is exempt: 200 bytes are over before anyone notices, and locking the
window for them would be theatre.

When there is something to install, the header says so right behind the
wordmark and on its line — plain text and a small **Open** button, no box — and
pressing it goes straight to this page. It is the first thing to go when the
window narrows; the badge, the menu and the close box all outrank it. It also notices
when something *else* changed its file — an update through ReaPack's own
browser, for instance — and offers the restart then too; without that you would
keep running the old version until the next time Reaper starts.

## Under the hood

- One self-contained Lua file, ~6500 lines including a small inline JSON
  parser and the MIT licence in its header. The version history is not in it:
  it lives in `index.xml`, which is what ReaPack shows.
- HTTP via `curl` through `reaper.ExecProcess` (cross-platform).
- UI via ReaImGui. The main window is dockable (its dock id is persisted in
  global `ExtState`); the floating pill and modal dialogs stay non-dockable for
  a tool-like feel.
- Typography ships with the script: `Inter-Regular.ttf` and
  `Inter-SemiBold.ttf` (SIL Open Font License, see `Inter-LICENSE.txt`) are
  loaded through `ImGui_CreateFontFromFile`, so the interface looks the same on
  every machine. A generic family name resolves to Arial on one box and
  Helvetica on the next. If the files are missing — a checkout without them, or
  a ReaPack update that has not fetched them yet — the script falls back to an
  installed Inter and then to `sans-serif`.
- Depth is built, not borrowed: ImGui has no shadow primitive and no blur, and
  its one gradient call cannot round its corners. At load the script rasterises
  a 64px texture whose alpha falls off smoothly from an opaque centre
  (`CreateImageFromSize` + `Image_SetPixels_Array`), then nine-slices it for
  card shadows and stretches it for the backdrop glow. Everything here needs
  ReaImGui 0.10; without it each function returns quietly and the window looks
  exactly as it did before.
- Cover art downloads detached. `ExecProcess` with a negative timeout starts a
  process and returns at once, but then there is no exit code and no output to
  read, so the script writes a two-line launcher: curl redirected to a file,
  then a sentinel file. A poll four times a second waits for that sentinel,
  reads the status codes out of the file and moves the finished `.part` files
  into place. Only one download runs at a time; a request that arrives during
  one is remembered and repeated as soon as the slot frees. Windows keeps the
  old blocking call on purpose — the `cmd.exe` quoting around a batch file in a
  path with spaces is not something the author can test, and a launcher that
  silently never runs would mean covers that never appear at all.
- Markers carry a uniform color; comment metadata (author, text) is cached
  in `ProjExtState`, not in the marker name, so the ruler stays clean.
- The waveform is drawn from the `peaks` + `duration` that ship with
  `GET /reaper/comments`; it's also cached in `ProjExtState` so the block
  renders on reopen without a re-sync.
- A/B compare downloads the active version via `GET /reaper/audio` (curl) and
  plays it from a hidden track that bypasses the master (`B_MAINSEND=0`) with a
  hardware-output send to outs 1/2. A/B is a mute-swap between that reference
  and the master, under one transport.
- Reaper saves hidden tracks like any other, so a project saved while A/B is
  loaded keeps the reference — and with it the path to the audio. Three rules
  keep that from turning into a "media not found" prompt on reopen:
  1. the audio is written to `<project dir>/CuePort A-B/cueport_ab_<version
     id>.<ext>` (shared cache under the resource path for projects that have
     never been saved), not to a temp file that gets cleaned up;
  2. removing the reference only deletes that audio when no save has captured
     it — otherwise the file is kept and dropped after the project has been
     saved again without the track;
  3. a reference track whose `P_EXT:cueport_ab_ref` stamp is from another run
     is a leftover from such a save — it is removed on load and the master
     mute is restored from the `ab_master_muted` project flag.
- Keying the file by version id means a new CuePort version never A/Bs against
  stale audio, and a file still on disk is reused instead of re-downloaded.
- Dock state comes from the ImGui dock id alone (0 = undocked, -1..-16 = a
  Reaper docker, > 0 = an ImGui dockspace). Measured against Reaper's own
  `DockIsChildOfDock` in a real session: docked reads id -1 / Reaper index 0,
  floating reads id 0 / Reaper index -1. The two agree, so a second opinion was
  removed again rather than kept walking the window list twice a second. The id
  also covers the case Reaper cannot see: docked inside another ImGui window.
- Single-instance guard using a short-lived heartbeat in global `ExtState`.

## Working on the script

This section is the *why*. The working checklist — release steps, the rules for
adding an assertion, the ImGui traps this UI has already fallen into — lives in
the development repo, together with the harnesses. **This package ships the
script, not the workbench**, so the paths below refer to that repo rather than
to what ReaPack installed for you.

The whole file is one Lua chunk, and Lua caps a function at **200 local
variables in scope**. Every top-level `local function` spends one of those, so
related things are grouped into tables rather than kept as loose locals:

| Table  | Holds |
|--------|-------|
| `K`    | constants (ext-state keys, track names, action ids, pill colors) |
| `AB`   | the A/B reference: download, build, remove, cleanup |
| `Pill` | the transport pill — its state *and* its behaviour |
| `UI`   | everything that draws |

Going over the cap is not a subtle failure: Reaper refuses to load the script
with `too many local variables`. Current usage is 111 of 200 — count the
top-level `local`s yourself rather than trusting that number, it ages.

Fourteen checks, all quick and all worth running after any edit. They live in the
development repo, run on every push there, and a release goes out through a
script that refuses to publish unless every one of them is green:

```sh
luacheck "CuePort Sync/cueport_sync.lua"   # 0 warnings is the baseline
lua5.4 test/test-ab-lifecycle.lua       # 279 assertions on the A/B, version, comment, marker, artwork and logout lifecycles
lua5.4 test/test-visibility.lua         # 25 assertions: never running-but-unreachable, the startup switch, the window after a restart
lua5.4 test/test-docking.lua            # 48 assertions: dock state, the control, window sizing, no title bar
lua5.4 test/test-ui-balance.lua         # 4411 assertions: every screen leaves ImGui's stacks clean
lua5.4 test/test-narrow.lua             # 48 assertions: nothing is wider than the window
lua5.4 test/test-update.lua             # 119 assertions: version compare, the three pre-replace checks, both install routes, restart
lua5.4 test/test-render.lua             # 180 assertions: the render pass, the settings borrowed and put back, the upload page
lua5.4 test/test-render-probe.lua       # 39 assertions: the render probe reads without changing anything
lua5.4 test/test-peaks-probe.lua        # 25 assertions: the peaks probe, and that it removes the track it needs
lua5.4 test/test-probe-enums.lua        # 26 assertions: the enum probe writes nothing at all
lua5.4 test/test-probe-trackmanager.lua # 51 assertions: the track-manager probe cleans up and restores the selection
lua5.4 test/test-url-safety.lua         # 52 assertions: what reaches the shell, and where the temporary files live
lua5.4 test/test-windows-curl.lua       # 14 assertions: real curl, a real config file (runs on POSIX too)
lua5.4 test/test-pairing-claim.lua      # 13 assertions: code pairing — the claim call, token stored, screen, error path
```

`test-url-safety.lua` covers the seam where this script talks to the operating
system. `ExecProcess` hands its line to a real shell rather than an argument
array, so everything written into one is quoted: the pairing URL has to look
like an http(s) address before it is opened at all, and is quoted even then;
paths get single quotes on Unix (where `$`, a backtick and a backslash would
still be live inside double ones) and double quotes on Windows (where `cmd.exe`
does not treat single ones as quoting at all). The proof is not a claim about
strings: the harness hands the line it built to a real `/bin/sh` and checks the
path arrives character for character. Temporary files live under Reaper's own
resource path with a per-run random component, so two running Reapers cannot
overwrite each other's.

One more runs on a platform none of us has. `test/test-windows-curl.lua`
takes the config-file escaper and the path quoter straight out of the script,
checks that all three callers use the escaper, and then drives the **real** curl
against a **real** config file holding a path with a backslash in it, and a
command line holding a path with a space. The counterprobe is built in: the
unescaped and the unquoted path both have to fail, otherwise the diagnosis
behind them is wrong and the rest proves nothing. It runs anywhere, but it is meant for the `windows-curl`
workflow, which runs it on a Windows machine with the system `curl.exe`.

And one runs **Reaper itself** on that machine. The `windows-reaper` workflow
(manual only — it downloads and installs Reaper) drops
`test/reaper-probe-startup.lua` in as `__startup.lua`, starts Reaper, and
lets it walk one real request stage by stage: `GetResourcePath`, the config
file, `ExecProcess` starting `curl.exe`, the exit code and output it hands
back, and whether the answer landed in the file the script named. Then it quits
Reaper so the job ends. Without a device token a `401` with a JSON body is the
pass — the point is the chain, not the answer. Measured on Windows
10.0.26100 with Reaper 7.78: it does.

What that still does not cover is audio (a runner has no device) and how any of
it looks. Those need a person with Reaper on Windows.

The update flow has since been walked there by hand (20 Aug 2026) and works.
That settles the one thing no runner could: `Upd.finishInstall` renames the
**running** file out of the way, and Windows locks open files, so Reaper
evidently keeps no handle on a loaded Lua script. Audio and appearance on
Windows are still unverified.

`luacheck` matters more than usual here. In a single chunk, a call to a
function that no longer exists under that name does not raise at load time — it
silently becomes a read of an undefined global. That is exactly what luacheck
reports, which makes it the safety net for renames.

`test/test-ab-lifecycle.lua` loads the real script against a stand-in Reaper
API with a real filesystem underneath and drives load → save → remove → reopen.
Both share `test/fake-reaper.lua`, a stand-in for Reaper's script host with
a project model and a real filesystem underneath. They are the only parts with
runtime coverage; the drawing code is checked statically only.

`test-narrow.lua` guards a trap the stack-balance harness cannot see: a control
with a fixed width does not shrink with the window, so on a narrow window its
row runs past the edge. Content wider than its window is content ImGui lets the
user drag sideways — with no horizontal scrollbar to hint at why. The harness
models just enough layout to add row widths up (a cursor per region, SameLine
continuing a line, text measured at 7 px per character) and asserts that no row
outgrows its region at 380 px (the floating minimum) and at 300 px (a docker
can be narrower). It is not pixel-accurate ImGui and is not meant to be; it
catches the class of bug, and it reproduces the reported one on v1.7.8 while
agreeing that the settings screen was fine.

`test-visibility.lua` guards a specific trap: both pill variants return early
without a token, so a token-less instance whose window is hidden shows nothing
at all while its defer loop keeps running. Reaper then reports "script is
already running" on the next launch, and terminating it only starts another
invisible one. Any change to logout or to the start-hidden logic should keep
those assertions green.

## What it changes in your project

The script writes to the project it is pointed at, so here is the list. All of
it happens only when you ask for it, and nothing else in the project is
touched. The same list is on the script's own **About** screen.

| What | When |
|---|---|
| Project markers `CP @author: time`, one per comment thread | **Sync comments** — the previous set is removed and the current one written, so switching version replaces them with that version's; nothing at all if you switched them off in Settings |
| A marker `CP: Render start` | **Set render start**, unless you switched that marker off in Settings; clearing it takes it away |
| The project time offset | **Set render start** and **Clear** — this one happens either way, the switch above only hides the marker |
| A track `CuePort A/B`, hidden from the track panel and mixer, with one item and a hardware-output send | while the A/B reference is loaded |
| One audio file in a folder `CuePort A-B` next to the `.rpp` | same; removed once the project has been saved without the reference in it |
| The bound production, which version of it you are looking at, and a cache of that version's comments and waveform, in the project's extension data | on binding, on switching version and on sync — this marks the project modified |
| The edit cursor | when you click the waveform or a comment |
| The render settings | while a render for CuePort runs — all twenty-one fields are written down first and put back straight afterwards, and a crash mid-render is repaired at the next start |
| One audio file `cueport_render_...` beside the `.rpp` | for each render sent to CuePort; it stays unless you turn **Keep the render** off, and the A/B cleanup does not touch it |
| One empty track, for a fraction of a second | to read the waveform off the finished render — there is no way to read peaks from a file that is not in the project; it is removed again in the same undo step |

Syncing markers, setting or clearing the render start, reading the waveform and
removing the A/B track are named undo steps. Inserting the A/B track is not — use **Remove**
rather than Undo for that one.

**Which host it talks to.** CuePort, and nothing else — with one exception,
which the badge in the header shows as `PREVIEW` for as long as it applies. If
CuePort answers like a version older than this script (no version list with the
comments), the rest of the session goes to CuePort's preview worker, which is
the same company, the same account and the same database — the device token is
valid on either. It exists for the window where the script is ahead of what is
deployed. Production is asked first on every sync, so the moment the release
catches up the second call stops happening and the badge goes back to
`CONNECTED`.

Nothing from your project is uploaded unless you press the upload button, and
then it is the one rendered file, its length and its waveform. What leaves the machine is a device
token, the id of the production you picked and the version you are looking at;
what comes back is the comment list, the list of versions, the waveform, the
track length and, for A/B, the audio of that version. The two things the script
sends are a reply you typed yourself, when you press Send, and the id of a reply
you asked twice to delete.

## Licence

CuePort Sync is MIT — Copyright (c) 2026 melotunesmusic. The full text is in
the header of `cueport_sync.lua` and in the `LICENSE` file installed alongside
it. It is provided as is, without warranty of any kind.

Bundled third-party work:

- JSON parsing is based on [rxi/json.lua](https://github.com/rxi/json.lua) —
  MIT, Copyright (c) 2020 rxi.
- The [Inter](https://rsms.me/inter/) typeface — SIL Open Font License 1.1,
  full text in `Inter-LICENSE.txt`.

The terms and the privacy policy for the CuePort **service** are a separate
matter and live at [cueport.app](https://cueport.app) —
[terms](https://cueport.app/legal/agb/),
[privacy](https://cueport.app/legal/datenschutz/).
