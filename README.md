# LyricsOverlay

Floating, time-synced lyrics for Apple Music on macOS. A small always-on-top panel shows the previous, current, and next lyric line while you work in other apps. It follows you across Spaces and over full-screen apps, and hides itself while Music is the front app.

Native Swift/AppKit, single source file, no dependencies.

## Build & install

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/capple217/LyricsOverlay.git
cd LyricsOverlay
bash build.sh install    # builds, signs (ad hoc), copies to ~/Applications, launches
```

`bash build.sh` without `install` just builds into `build/LyricsOverlay.app`.

On first launch with a song playing, macOS asks whether LyricsOverlay may control Music. Click **OK**. If you denied it, enable it in System Settings › Privacy & Security › Automation › LyricsOverlay › Music, then relaunch.

## Using it

The app has no Dock icon. Everything is controlled from the speech-bubble icon in the menu bar, or by right-clicking the overlay.

| Setting | What it does |
|---|---|
| Show Lyrics Overlay | Master on/off |
| Click-Through (Lock Position) | Clicks pass through the panel to the window underneath |
| Hide When Paused / Hide While Music Is in Front | Both on by default |
| Show Lyrics Earlier / Later | Timing offset in 0.25 s steps, if lyrics lead or lag the song |
| Text Size | Small / Medium / Large |
| Background Opacity | Slider from 0% (text only) to 100% (frosted glass); the text itself stays fully opaque |
| Text Color | Light (white on dark glass) or Dark (black on light glass) |
| High-Contrast Outline | Outlines every glyph in the opposite colour so text reads on any background |
| Reload Lyrics | Re-fetch the current song's lyrics, bypassing the cache |
| Launch at Login | Works best once the app is in ~/Applications |

Drag the panel to move it. Its position and all settings persist across launches.

## How it works

| Piece | Details |
|---|---|
| Playback state | AppleScript to Music every 0.5 s, plus an immediate re-poll on Music's `com.apple.Music.playerInfo` distributed notification. Position is interpolated between polls so line changes land on time. |
| Lyrics | [LRCLIB](https://lrclib.net), free with no API key. Exact match (title, artist, album, duration) first, then search, then a search with a cleaned title and the primary artist. |
| Cache | `~/Library/Caches/LyricsOverlay/`. Only successful lookups are cached. |
| Overlay | Non-activating `NSPanel` with `canJoinAllSpaces` + `fullScreenAuxiliary`, so it never steals focus. |

Apple Music's own synced lyrics aren't exposed to third-party apps, so coverage depends on LRCLIB. If only unsynced lyrics exist, the overlay estimates the current line from song progress and labels it "unsynced (estimated)".

## Troubleshooting

- **No permission prompt / stuck on the permission message after a rebuild.** Each rebuild gets a new ad-hoc signature, so macOS may treat it as a new app. Reset and relaunch:
  `tccutil reset AppleEvents com.capple217.LyricsOverlay`
- **Nothing shows up.** Run the binary from Terminal to see errors:
  `pkill -x LyricsOverlay; ~/Applications/LyricsOverlay.app/Contents/MacOS/LyricsOverlay`
- **"No lyrics found".** LRCLIB has no entry for that song. Use **Reload Lyrics** if you were offline.
