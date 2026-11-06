# smol-vid

A small native macOS app for shrinking videos, the sibling of [smol-pdf](https://github.com/jansim/smol-pdf).

Drop a video onto the window or the Dock icon, pick a compression profile and press **Compress**.
The window shows the original next to the compressed file, with both sizes and how much was saved.
Drop several files or a whole folder to compress them all at once.
Earlier files are one click away in the history sidebar.

smol-vid compresses with [ffmpeg](https://ffmpeg.org), which it doesn't bundle: install it with
Homebrew (`brew install ffmpeg`). The Homebrew cask installs it for you.

## Features

- **Profiles**: Lossless, Low, Medium, High, Maximum, plus your own changes to them (codec, quality,
  maximum resolution and frame rate, hardware encoding, audio bitrate, and removing audio, metadata,
  chapters and subtitles).
- **H.264 or HEVC**: H.264 plays everywhere; HEVC is about half the size at the same quality and
  plays on every Mac and iPhone from the last years. Both are encoded at a constant quality, so a
  simple clip gets small and a busy one stays sharp.
- **Never larger than needed**: videos are only ever scaled down, by their shorter side, so portrait
  videos from a phone are limited the same way as landscape ones. Frame rates are only lowered.
  Audio that is already AAC at a lower bitrate is kept as it is.
- **Lossless really is lossless**: the streams are copied as they are; only what you remove goes.
- **Keeps the original** when compression wouldn't make the file smaller.
- **Any format ffmpeg reads**: MP4, MOV, MKV, WebM, AVI, ... Re-encoded videos are written as MP4
  (QuickTime movies stay `.mov`), with text subtitles, chapters and metadata kept unless removed.
- **Batches**: drop several files or folders onto the window or the Dock icon (folders are searched
  recursively) and they're listed with what compressing each one saved.
- **Progress**: see how far compression is, with the time remaining once a run will take longer than
  10 seconds. Cancel it at any time; files not done yet stay as they were.
- **Output**: next to the original with a suffix, into a folder, or replace the original
  (the original goes to the Trash).
- **Before and after**: the original and the result side by side with their names, sizes,
  resolutions and lengths. Select either one and press Space to Quick Look it (even when the original
  is in the Trash), or drag it out like any file.
- **Compare**: play both side by side, in sync, and switch which one you hear.
- **History**: every compressed file is listed in the sidebar; select one to show it again.
- **Command-line tool** `smolvid` with the same profiles, for batches and folders.

## Install

smol-vid needs macOS 14 or later and ffmpeg. Releases are universal: they run on Apple silicon and
Intel Macs.

### With Homebrew

```sh
brew install --cask jansim/tools/smol-vid
```

This installs ffmpeg if you don't have it yet, puts the latest release of smol-vid in Applications and
the command-line tool `smolvid` on your `PATH`. Use the full name `jansim/tools/smol-vid` the first
time: installing a cask by its full name is how you tell Homebrew to trust it. Homebrew 6 and later
won't load casks from other taps until you trust them. The cask always points at the newest release,
so a plain `brew upgrade` does not notice new ones; `brew upgrade --greedy smol-vid` fetches it.
`brew uninstall --cask --zap smol-vid` removes it, including its settings and history.

### By hand

Install ffmpeg (`brew install ffmpeg`), download `smol-vid.zip` from the
[latest release](https://github.com/jansim/smol-vid/releases/latest), unzip it and move smol-vid to
Applications. The command-line tool is inside the app (see [Command line](#command-line)). It is also
in the release on its own, as `smolvid-cli.tar.gz`.

smol-vid looks for ffmpeg and ffprobe in `/opt/homebrew/bin`, `/usr/local/bin` and `/opt/local/bin`
(Homebrew and MacPorts), then on `PATH`. To use another ffmpeg, set `SMOL_FFMPEG` to its path
(ffprobe must be next to it), e.g. `launchctl setenv SMOL_FFMPEG /path/to/ffmpeg` for the app.

### "Apple could not verify smol-vid"

Apple only notarizes apps for members of its paid developer program, so smol-vid is signed ad hoc
and not notarized. When you download it with a browser, macOS refuses to open it the first time.
To open it anyway:

- Try to open it once. Then go to **System Settings → Privacy & Security**, click **Open Anyway** next
  to the message about smol-vid, and confirm. Or:
- Remove the quarantine flag that the browser put on the download:
  `xattr -dr com.apple.quarantine /Applications/smol-vid.app` (and
  `xattr -d com.apple.quarantine smolvid` for the separate command-line tool).

The Homebrew cask removes the quarantine flag for you after installing. If you would rather not
trust a prebuilt app, build it from source.

## Build

Requires macOS 14 or later, Xcode 16 or later (Swift 6 toolchain), and ffmpeg for running it and the
tests.

```sh
scripts/build-app.sh && open build/smol-vid.app
```

`ARCHS="arm64 x86_64" scripts/build-app.sh` builds universal binaries. Pushing a tag such as `v1.2`
builds them with that version, runs the command-line tool on a test video and publishes the zipped
app (`smol-vid.zip`) and the command-line tool (`smolvid-cli.tar.gz`) in a GitHub release. The Homebrew
cask, in [jansim/homebrew-tools](https://github.com/jansim/homebrew-tools), always installs the latest
release, so it needs no update.

For development, `swift run SmolVidApp` starts the app without bundling, and `swift test` runs the
tests (they generate their videos with ffmpeg, and are skipped without it). The core library and the
command-line tool also build on Linux.

The icon is drawn by `scripts/make-icon.swift`:
`swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`.

## Command line

The Homebrew cask puts `smolvid` on your `PATH`. Otherwise it is at
`/Applications/smol-vid.app/Contents/Resources/smolvid` (or use `swift run smolvid …` in a checkout):

```sh
smolvid -p high ~/Movies/holiday            # a folder, recursively
smolvid -c hevc -q 50 -r 720 -f 30 clip.mov  # custom codec, quality, resolution, frame rate
smolvid -p lossless -x metadata,subtitles in.mkv   # copy the streams, strip extras
smolvid -x audio -v screen-recording.mov     # no sound; show the ffmpeg command and what changed
smolvid -o ~/Desktop/small *.mp4             # write into a folder
smolvid --help
```

## How it works

The core (`Sources/SmolVidCore`) reads each file with ffprobe, then runs ffmpeg with arguments made for
that file and the profile (`smolvid -v` prints them):

| Setting | ffmpeg |
| --- | --- |
| H.264 | `libx264`, preset medium, CRF 18 (quality 100%) to 34 (0%), 8-bit 4:2:0 |
| HEVC | `libx265`, preset fast, CRF 20 to 36, 8 or 10 bit like the source, tagged `hvc1` for Apple's players |
| Hardware encoding | `h264_videotoolbox` / `hevc_videotoolbox` at constant quality (`-q:v`) |
| Maximum resolution | scales the shorter side down after rotation; sizes are kept even |
| Maximum frame rate | `-fpsmax` |
| Audio | AAC at the bitrate per stereo pair, unless it is AAC at a lower bitrate already (then copied) |
| Lossless | `-c copy` of all streams but data streams (timecodes, telemetry), in the same container |
| Removing | metadata `-map_metadata -1`, chapters `-map_chapters -1`, audio and subtitles by not mapping them |

MP4 and MOV files are written with `+faststart`, so they start playing before they are fully
downloaded. Apple's metadata in QuickTime movies (such as where a video was taken) is kept. Progress
comes from ffmpeg's `-progress` output; cancelling stops ffmpeg at once and discards its output.

Videos are compressed one at a time: the encoders already use all cores.

Code layout:

| Path | Contents |
| --- | --- |
| `Sources/SmolVidCore` | Compression API on top of ffmpeg, profiles, output naming (no UI) |
| `Sources/SmolVidApp` | SwiftUI app |
| `Sources/smolvid` | Command-line tool |
| `Tests/SmolVidCoreTests` | Tests using videos generated with ffmpeg |
| `scripts/` | App bundling, icon generation, a test video for smoke tests |

## Known limitations

- ffmpeg must be installed separately; smol-vid only finds it in the folders above or via `SMOL_FFMPEG`.
- Re-encoding keeps the first video stream; picture-based subtitles (DVD, Blu-ray) and attachments are
  dropped. Lossless keeps everything except data streams.
- HDR videos are re-encoded without their HDR metadata, so colors may look flatter. Use Lossless for them.
- Hardware encoding at constant quality needs an Apple silicon Mac.
- Quick Look, the sidebar's thumbnails and the comparison use macOS's own players, which can't play
  some formats (such as WebM) as originals. The before-and-after view takes their frame with ffmpeg.

## Licenses

smol-vid is MIT-licensed. It doesn't include ffmpeg; it runs the one you installed, under that one's
license (LGPL or GPL, depending on how it was built).
