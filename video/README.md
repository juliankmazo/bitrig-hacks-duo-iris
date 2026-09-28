# Iris launch films

Three cuts of the Iris launch film, built with [HyperFrames](https://hyperframes.heygen.com) (HTML + GSAP, rendered to MP4).

| Cut | Folder | Render |
|---|---|---|
| **Look.** 16:9, 78 s (the main one) | `a-look/` | `renders/iris-a-look-v2.mp4` |
| **Three words.** 4:5, 34 s | `b-three-words/` | `renders/iris-b-three-words.mp4` |
| **Four hours.** 16:9, 45 s | `c-four-hours/` | `renders/iris-c-four-hours.mp4` |

`build.py` writes every cut's `index.html`: all timing, copy and layout live there. Edit it, run `python3 build.py`, then render.

## Assets

- `assets/img/`: stills from `gpt-image-2.5` (`tools/gen_images.py`, and `tools/gen_scenes.py` for the two-person scenes, which use the real device renders in `assets/ref/` as references so the phone shows the real app).
- `assets/vo/`: Grok TTS voice lines with word timestamps (`tools/gen_vo.py`). Ara narrates A, Eve B, Leo C; the phone speaking "I love you" is the Grok voice named Iris.
- `assets/music/` (gitignored): piano/pad beds synthesized in code (`tools/music.py`, seeded, so it is reproducible).
- `assets/clips/` (gitignored), built from the sources in `source/` (gitignored):
  - `source/demo.mov`: the demo screen recording (Device Hub + webcam). `tools/crop_demo.py` crops `screen.mp4` and `face.mp4`.
  - `source/screenshots-and-videos-for-render/`: Device Hub 3D renders. `tools/clean_renders.py opening|rotation` turns the grey backdrop black and removes the "iPhone" label and the mouse cursor.

## Rebuild from scratch

Keys live in `../../.env` (`OPENAI_API_KEY`, `SPACEXAI_API_KEY`). Run everything from `video/`:

```sh
set -a; source ../../.env; set +a
python3 tools/gen_vo.py a10              # one line, or no args for all
uv run tools/music.py bed_a 90 0         # name, seconds, pulse(0/1)
uv run tools/crop_demo.py
uv run tools/clean_renders.py opening && uv run tools/clean_renders.py rotation
python3 build.py
cd a-look && npx hyperframes snapshot --at 12,30,60 && npx hyperframes render -q high -o ../renders/iris-a-look-v2.mp4
```

For X, master the audio after rendering (the files in `renders/` already are):

```sh
ffmpeg -i in.mp4 -c:v copy -af loudnorm=I=-15:TP=-1.5:LRA=11 -ar 48000 -c:a aac -b:a 256k -movflags +faststart out.mp4
```

If `npx hyperframes` can't find Chrome, point it at the downloaded headless shell with `HYPERFRAMES_BROWSER_PATH`.
