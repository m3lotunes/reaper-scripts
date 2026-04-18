# CuePort Sync — Reaper Integration

Reaper-Script, das Top-Level-Kommentare des Artists aus [CuePort](https://cueport.app)
als Empty-Items auf einer "Artist Comments"-Spur im Reaper-Projekt anlegt.

## Installation via ReaPack

1. **ReaPack installieren** (falls noch nicht vorhanden): <https://reapack.com>
2. In Reaper: `Extensions → ReaPack → Import repositories...`
3. Repository-URL einfügen:

   **Preview (Testing, aktueller Branch):**
   ```
   https://claude-reaper-artist-comment.studio-manager.pages.dev/reaper/index-preview.xml
   ```

   **Production (nach Merge auf main):**
   ```
   https://cueport.app/reaper/index.xml
   ```

4. `Extensions → ReaPack → Browse packages` → Suche `CuePort` → `Install`
5. Reaper neu starten
6. ReaImGui installieren (falls noch nicht): Browse packages → `ReaImGui` → Install

## Usage

1. **Action ausführen:** `Actions → Show action list → CuePort Sync`
2. **Ersteinrichtung:** Klick auf "Mit CuePort verbinden" → Browser-Dialog bestätigen
3. **Pro Projekt:** Produktion aus Liste wählen → Binding in `.rpp` gespeichert
4. **Tagesbetrieb:** Ein Klick auf "Kommentare synchronisieren"

## Preview-Worker testen

Aktuell zeigt das Script auf den **Production-Worker** (`melotunes-upload`). Für
den Preview-Test:

1. Script starten → unten auf "Einstellungen" klicken
2. Haken bei "Preview-Worker verwenden"
3. Token wird separat für Preview gespeichert (prod-Token bleibt erhalten)

## Wichtiger Hinweis zum Timing

Das Script platziert Kommentare am absoluten `comment.timestamp` auf der Reaper-
Timeline. Damit die Positionen stimmen, muss der Audio-Render im Reaper-Projekt
bei **0:00** starten. Falls du einen Count-In oder Pre-Roll hast, verschiebe
den Render so, dass der erste Sample bei 0:00 liegt — oder warte auf Phase 2
(Anchor-Marker).

## Troubleshooting

- **"ReaImGui nicht installiert"** → via ReaPack installieren (Browse packages → ReaImGui)
- **"curl failed"** → curl fehlt im System. Windows 10+/macOS/Linux haben es
  normalerweise. Falls nicht: <https://curl.se/download.html>
- **"Token nicht mehr gültig"** → im Studio-Portal (Integrationen) wurde der
  Token widerrufen. Einfach neu verbinden.
- **Kommentare am falschen Ort** → der Render startet nicht bei 0:00. Siehe oben.

## Architektur

- Single-file Lua-Script, ~950 Zeilen inkl. JSON-Parser
- HTTP via `curl` through `reaper.ExecProcess` (cross-platform, keine Extra-Deps)
- GUI via ReaImGui
- Token pro Preview/Prod getrennt, persistent in globalem `ExtState`
- Produktions-Binding im Projekt via `ProjExtState` (überlebt `.rpp`-Save/Load)
- Diff-Sync via `P_EXT:cueport_feedback_id` auf jedem Item — manuell angelegte
  Items auf der Comments-Spur werden **nicht** angetastet
