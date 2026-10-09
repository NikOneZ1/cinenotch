# CineNotch before/after video

A Remotion project: the island footage is recorded from the app itself, everything around it
(the Mac screen, cursor, captions, the iris transition, titles) is animated here.

## Footage

Each version plays the same scripted scene on a drawn test video and records only the island
window, with transparency (`Sources/CineNotch/Support/DemoScript.swift`):

```bash
open -W -n build/CineNotch.app --args --debug-notch --debug-demo --debug-record /tmp/new.mov
```

The recordings are HEVC with alpha. Convert them to 60 fps WebM with alpha for `public/`
(`old.webm`, `new.webm`): decode to a PNG sequence with AVFoundation, then

```bash
ffmpeg -framerate 60 -i %05d.png -c:v libvpx-vp9 -pix_fmt yuva420p -b:v 0 -crf 26 -auto-alt-ref 0 public/new.webm
```

`old.webm` was recorded from the version before the redesign, which isn't in git.

## Preview and render

```bash
npm run dev                                                      # Remotion Studio
npx remotion render BeforeAfter out/cinenotch-before-after.mp4 --crf=16
```
