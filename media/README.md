# media

Screen recordings of CuePort Sync, as GIFs, for the forum thread and the
READMEs. They are **not** part of the package — ReaPack only fetches the files
listed as `<source>` in `index.xml`, so nothing here is installed with the
script.

| File | Shows | Size |
| --- | --- | --- |
| `cueport-markers-in-reaper.gif` | The window over the project, with the comments as markers on the Reaper ruler and a hover tooltip on one of them | 13.8 s, 1472×1113 |
| `cueport-markers-short.gif` | The same, second half only: markers in the project and the tooltips | 6.7 s, 1100×801 |
| `cueport-sync-demo.gif` | The script window while a version plays: the waveform with comment pins, the two-way highlight with the comment list | 9.3 s, 1758×1250 (no downscale) |

Made from a QuickTime screen recording with a two-pass palette, no dithering
(flat UI colors band less without it) and `stats_mode=diff`, which optimises
the palette for the parts that move.

Scale as little as you can get away with. Downscaling a retina capture to 60%
is what turns crisp text into mush; the window clip is not scaled at all and
the other one only to two thirds. A palette per frame (`paletteuse=new=1`) was
measured and dropped: 19 MB instead of 1.5, and no visible difference on flat
UI colors.

```sh
ffmpeg -i in.mov -vf "crop=W:H:X:Y,fps=15,scale=1100:-1:flags=lanczos+accurate_rnd,palettegen=stats_mode=diff" pal.png
ffmpeg -i in.mov -i pal.png -lavfi "crop=W:H:X:Y,fps=15,scale=1100:-1:flags=lanczos+accurate_rnd[x];[x][1:v]paletteuse=dither=none:diff_mode=rectangle" -loop 0 out.gif
```
