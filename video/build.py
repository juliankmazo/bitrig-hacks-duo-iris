"""Generates the three Iris launch-film compositions (HyperFrames HTML).

Each option is a list of timed pieces; this script turns them into a standalone
composition with one paused GSAP timeline. Run: python3 build.py
"""
import json

SCREEN = "assets/clips/screen.mp4"  # inner display crop, 1320x1880, source-time = demo recording time
FACE = "assets/clips/face.mp4"      # webcam crop, 1192x668

# Source-recording moments (seconds) read off the demo capture.
SRC_I, SRC_PICKER, SRC_IL, SRC_LOVE, SRC_YOU, SRC_CHEER = 98.0, 102.0, 105.0, 113.5, 121.5, 122.5

BASE_CSS = """
@font-face { font-family: "Inter"; src: url("assets/fonts/inter.woff2") format("woff2"); font-weight: 100 900; }
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { margin: 0; width: __W__px; height: __H__px; overflow: hidden; background: #000; }
#root { position: relative; width: 100%; height: 100%; overflow: hidden; background: #000;
  font-family: "Inter", sans-serif; color: #f5f5f7; -webkit-font-smoothing: antialiased; }
.clip { position: absolute; inset: 0; }
.fade, .kb { position: absolute; inset: 0; }
.fade { opacity: 0; }
.kb img { width: 100%; height: 100%; object-fit: cover; display: block; }
.shade { position: absolute; inset: 0; background: radial-gradient(ellipse at center, rgba(0,0,0,0) 40%, rgba(0,0,0,.55) 100%); }
.shade-b { position: absolute; inset: 0; background: linear-gradient(180deg, rgba(0,0,0,0) 55%, rgba(0,0,0,.7) 100%); }
.sub { display: flex; align-items: flex-end; justify-content: center; padding-bottom: __SUBPAD__px; pointer-events: none; z-index: 60; }
.sub span { display: block; max-width: __SUBW__px; text-align: center; font-size: __SUBSIZE__px; font-weight: 500; line-height: 1.3;
  letter-spacing: -0.01em; color: rgba(255,255,255,.95); text-shadow: 0 1px 10px rgba(0,0,0,.5); opacity: 0;
  background: rgba(0,0,0,.42); padding: 8px 22px; border-radius: 14px; -webkit-backdrop-filter: blur(12px); backdrop-filter: blur(12px); }
.title { display: flex; align-items: center; justify-content: center; z-index: 40; }
.title .t { display: block; opacity: 0; text-align: center; font-weight: 600; letter-spacing: -0.045em; line-height: 1.02; }
.grad { background: linear-gradient(180deg, #ffffff 0%, #c9cff9 100%); -webkit-background-clip: text; background-clip: text; color: transparent; }
.eyebrow { font-size: 26px; font-weight: 500; letter-spacing: 0.01em; color: #a1a1a6; }
.layer { position: absolute; opacity: 0; }
.device { border-radius: __DR__px; padding: __DP__px; background: linear-gradient(145deg, #3a3a3e 0%, #121214 45%, #2b2b2f 100%);
  box-shadow: 0 0 0 1.5px #4a4a50 inset, 0 40px 120px rgba(0,0,0,.6), 0 0 160px rgba(120,130,255,.10); }
.screen { position: relative; width: 100%; height: 100%; border-radius: __SR__px; overflow: hidden; background: #fff; }
.screen video { position: absolute; top: -0.6%; left: -0.6%; width: 101.2%; height: 101.2%; object-fit: cover; }
.cam { border-radius: 26px; overflow: hidden; background: #111; box-shadow: 0 30px 90px rgba(0,0,0,.55); }
.cam video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.cam-label { position: absolute; left: 18px; bottom: 16px; display: flex; align-items: center; gap: 10px; font-size: 20px; font-weight: 500;
  color: #fff; background: rgba(0,0,0,.45); padding: 7px 14px; border-radius: 999px; z-index: 2; }
.cam-label i { display: block; width: 10px; height: 10px; border-radius: 50%; background: #ff453a; }
.grain { position: absolute; inset: -50%; z-index: 90; pointer-events: none; opacity: .07; mix-blend-mode: overlay;
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='220' height='220'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>"); }
"""


class Comp:
    def __init__(self, cid, w, h, dur):
        self.cid, self.w, self.h, self.dur = cid, w, h, dur
        self.html, self.js, self.css = [], [], []
        self.n = 0

    def uid(self, p):
        self.n += 1
        return f"{p}{self.n}"

    # A full-bleed still with Ken Burns and a crossfade in.
    def still(self, src, start, dur, z=1, scale=(1.03, 1.11), x=(0, 0), fade_in=1.0, shade="shade", pos="center"):
        i = self.uid("still")
        self.html.append(f'<div id="{i}" class="clip" data-start="{start}" data-duration="{dur}" data-track-index="1" style="z-index:{z}">'
                         f'<div class="fade"><div class="kb"><img src="{src}" alt="" style="object-position:{pos}"></div><div class="{shade}"></div></div></div>')
        self.js.append(f'tl.fromTo("#{i} .fade",{{opacity:0}},{{opacity:1,duration:{fade_in},ease:"power1.inOut"}},{start});')
        self.js.append(f'tl.fromTo("#{i} .kb",{{scale:{scale[0]},xPercent:{x[0]}}},{{scale:{scale[1]},xPercent:{x[1]},duration:{dur},ease:"none"}},{start});')
        return i

    # A subtitle line (for muted autoplay on X).
    def sub(self, text, start, dur):
        i = self.uid("sub")
        self.html.append(f'<div id="{i}" class="clip sub" data-start="{start:.2f}" data-duration="{dur:.2f}" data-track-index="5"><span>{text}</span></div>')
        self.js.append(f'tl.fromTo("#{i} span",{{opacity:0,y:8}},{{opacity:1,y:0,duration:.35,ease:"power2.out"}},{start:.2f});')
        self.js.append(f'tl.to("#{i} span",{{opacity:0,duration:.3}},{start + dur - .3:.2f});')

    # A VO line with its subtitle.
    def vo(self, name, start, text=None, vol=1.25, sub_extra=0.35):
        meta = json.load(open(f"assets/vo/{name}.json"))
        d = meta["duration"]
        self.html.append(f'<audio id="vo-{name}" src="assets/vo/{name}.mp3" data-start="{start:.2f}" data-duration="{d:.2f}" data-track-index="8" data-volume="{vol}"></audio>')
        if text:
            self.sub(text, start + 0.05, d + sub_extra)
        return start + d

    def audio(self, i, src, start, dur, vol, lane=None, fade_out=None):
        extra = f" data-automation='{json.dumps({'version': 1, 'lanes': [{'target': 'volume', 'points': lane}]})}'" if lane else ""
        fo = f' data-fade-out="{fade_out}"' if fade_out else ""
        self.html.append(f'<audio id="{i}" src="{src}" data-start="{start}" data-duration="{dur}" data-track-index="9" data-volume="{vol}"{extra}{fo}></audio>')

    # A timed <video> segment placed inside a (non-timed) container element.
    def seg(self, container_html_list, src, start, dur, media_start, rate=1.0):
        i = self.uid("v")
        container_html_list.append(f'<video id="{i}" src="{src}" data-start="{start:.3f}" data-duration="{dur:.3f}" data-media-start="{media_start:.3f}" '
                                   f'data-playback-rate="{rate}" data-track-index="2" muted playsinline></video>')
        return start + dur

    # A non-timed layer, shown/hidden by the timeline.
    def layer(self, i, style, inner, t_in, t_out, klass="layer", y_from=30, d_in=0.9, d_out=0.6, scale_from=None):
        self.html.append(f'<div id="{i}" class="{klass}" style="{style}">{inner}</div>')
        frm = f"opacity:0,y:{y_from}" + (f",scale:{scale_from}" if scale_from else "")
        to = "opacity:1,y:0" + (",scale:1" if scale_from else "")
        self.js.append(f'tl.fromTo("#{i}",{{{frm}}},{{{to},duration:{d_in},ease:"power3.out"}},{t_in:.2f});')
        if t_out is not None:
            self.js.append(f'tl.to("#{i}",{{opacity:0,duration:{d_out},ease:"power2.in"}},{t_out:.2f});')

    # Centered title card on black (or over whatever is beneath).
    def title(self, inner_html, start, dur, size, z=40, y_from=24, extra_style=""):
        i = self.uid("title")
        self.html.append(f'<div id="{i}" class="clip title" data-start="{start:.2f}" data-duration="{dur:.2f}" data-track-index="4" style="z-index:{z}">'
                         f'<div class="t" style="font-size:{size}px;{extra_style}">{inner_html}</div></div>')
        self.js.append(f'tl.fromTo("#{i} .t",{{opacity:0,y:{y_from},filter:"blur(12px)"}},{{opacity:1,y:0,filter:"blur(0px)",duration:1.1,ease:"power3.out"}},{start + .05:.2f});')
        self.js.append(f'tl.to("#{i} .t",{{opacity:0,duration:.5,ease:"power2.in"}},{start + dur - .5:.2f});')
        return i

    def black(self, start, dur, z=30, fade=0.6):
        i = self.uid("black")
        self.html.append(f'<div id="{i}" class="clip" data-start="{start:.2f}" data-duration="{dur:.2f}" data-track-index="3" style="z-index:{z}"><div class="fade" style="background:#000"></div></div>')
        self.js.append(f'tl.fromTo("#{i} .fade",{{opacity:0}},{{opacity:1,duration:{fade},ease:"power1.inOut"}},{start:.2f});')

    def write(self, path, title, extra_css="", sub=(64, 1300, 34), device=(64, 14, 50)):
        css = (BASE_CSS.replace("__W__", str(self.w)).replace("__H__", str(self.h))
               .replace("__SUBPAD__", str(sub[0])).replace("__SUBW__", str(sub[1])).replace("__SUBSIZE__", str(sub[2]))
               .replace("__DR__", str(device[0])).replace("__DP__", str(device[1])).replace("__SR__", str(device[2]))) + extra_css
        doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width={self.w}, height={self.h}" />
<title>{title}</title>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
<style>{css}</style>
</head>
<body>
<div id="root" data-composition-id="{self.cid}" data-start="0" data-duration="{self.dur}" data-width="{self.w}" data-height="{self.h}">
{chr(10).join(self.html)}
<div class="grain"></div>
</div>
<script>
const tl = gsap.timeline({{ paused: true }});
{chr(10).join(self.js)}
window.__timelines["{self.cid}"] = tl;
</script>
</body>
</html>
"""
        open(path, "w").write(doc)
        print("wrote", path)


def device_html(i, w, h, segs_html, left, top, radius=64, pad=14):
    return (f'<div id="{i}" class="layer device" style="left:{left}px;top:{top}px;width:{w}px;height:{h}px;border-radius:{radius}px;padding:{pad}px">'
            f'<div class="screen">{"".join(segs_html)}</div></div>')


def cam_html(i, w, h, segs_html, left, top, label="Eye tracking · live"):
    lab = f'<div class="cam-label"><i></i>{label}</div>' if label else ""
    return (f'<div id="{i}" class="layer cam" style="left:{left}px;top:{top}px;width:{w}px;height:{h}px">'
            f'{"".join(segs_html)}{lab}</div>')


def show(c, i, t_in, t_out, y_from=40, scale_from=None, d_in=1.0):
    frm = f"opacity:0,y:{y_from}" + (f",scale:{scale_from}" if scale_from else "")
    to = "opacity:1,y:0" + (",scale:1" if scale_from else "")
    c.js.append(f'tl.fromTo("#{i}",{{{frm}}},{{{to},duration:{d_in},ease:"power3.out"}},{t_in:.2f});')
    if t_out is not None:
        c.js.append(f'tl.to("#{i}",{{opacity:0,duration:.6,ease:"power2.in"}},{t_out:.2f});')


def typing_segments(c, target, src, t0, plan):
    """plan: list of (duration, media_start, rate). Returns end time and a function mapping source time -> global time."""
    t = t0
    spans = []
    for k, (dur, ms, rate) in enumerate(plan):
        # the last segment runs past the cut so the device can fade out over live footage
        c.seg(target, src, t, dur + (1.0 if k == len(plan) - 1 else 0), ms, rate)
        spans.append((t, dur, ms, rate))
        t += dur

    def g(src_time):
        for st, dur, ms, rate in spans:
            if ms <= src_time <= ms + dur * rate:
                return st + (src_time - ms) / rate
        raise ValueError(src_time)
    return t, g


# ---------------------------------------------------------------- Option A: "Look."  16:9, ~78 s
OPENING = "assets/clips/opening.mp4"    # Device Hub 3D render: outer screen, spin, unfold to Calibrate (1236x1248, black stage)
ROTATION = "assets/clips/rotation.mp4"  # Device Hub 3D render: inner "I love you" turns to the outer display


def render_stage(c, i, src, start, dur, media_start, rate=1.0, z=34, push=(1.0, 1.06), d_in=0.7):
    """A device render on the black stage, centered and full height, with a slow push-in."""
    v = []
    c.seg(v, src, start, dur + 0.8, media_start, rate)
    c.html.append(f'<div id="{i}" class="layer" style="left:431px;top:0;width:1058px;height:1080px;z-index:{z}">'
                  f'<div class="push" style="position:absolute;inset:0">{"".join(v).replace("<video ", "<video style=\"position:absolute;inset:0;width:100%;height:100%;object-fit:contain\" ", 1)}</div></div>')
    show(c, i, start, start + dur, y_from=0, d_in=d_in)
    c.js.append(f'tl.fromTo("#{i} .push",{{scale:{push[0]}}},{{scale:{push[1]},duration:{dur},ease:"none"}},{start});')


def option_a():
    c = Comp("look", 1920, 1080, 80)
    # 1. The problem
    c.still("assets/img/s_problem.png", 0, 6.2, z=1, scale=(1.02, 1.1), fade_in=1.6)
    c.vo("a1", 0.8, "Most people living with ALS will lose the ability to speak.")
    c.still("assets/img/hands.png", 5.4, 7.6, z=2, scale=(1.08, 1.0), x=(0, -2))
    c.vo("a2", 5.9, "The devices that give that voice back can cost fifteen thousand dollars.")
    c.title('<span class="grad">$15,000</span><div style="margin-top:26px;font-size:34px;font-weight:500;letter-spacing:-0.01em;color:#e5e5ea">for an eye-gaze communication device</div>',
            9.55, 3.1, 200, z=41)
    # 2. The turn: the real device, closed, showing Iris on its outer screen
    render_stage(c, "openA", OPENING, 12.4, 8.4, 10.3, 1.0, push=(0.96, 1.05))
    c.vo("a3", 12.9, "We thought it should only take a phone.")
    c.vo("a4", 17.0, "This is Iris.")
    # 3. In the world: the inner screen faces him, the outer screen faces her
    c.still("assets/img/s_inner2.png", 20.6, 3.6, z=35, scale=(1.04, 1.12), x=(0, -1.5), fade_in=0.8)
    c.still("assets/img/s_wide.png", 23.8, 3.6, z=36, scale=(1.1, 1.02), fade_in=0.7)
    c.vo("a5", 21.1, "Iris turns iPhone Duo into a voice you control with your eyes.")
    # unfold to the Calibrate screen
    render_stage(c, "unfoldA", OPENING, 27.2, 2.4, 18.6, 1.0, z=37, push=(1.0, 1.08), d_in=0.5)
    c.vo("a6", 27.5)

    # 4. Demo: device left, words + camera right
    D_W, D_H = 640, 912
    segs, cams = [], []
    t_dev = 29.5
    # calibration, fast-forward
    t = c.seg(segs, SCREEN, t_dev, 7.2, 8.0, 10)
    c.seg(cams, FACE, t_dev, 7.2, 8.0, 10)
    # typing, near real time
    plan = [(4.0, 94.0, 1.5), (4.0, 101.2, 1.25), (5.0, 107.5, 1.3), (6.0, 116.5, 1.0)]
    t_end, g = typing_segments(c, segs, SCREEN, t, plan)
    typing_segments(c, cams, FACE, t, plan)
    c.html.append(device_html("devA", D_W, D_H, segs, 250, 84))
    c.js.append('tl.set("#devA",{zIndex:50},0);')
    show(c, "devA", t_dev, t_end + 0.1, y_from=60, scale_from=0.94, d_in=1.3)
    c.html.append(cam_html("camA", 560, 314, cams, 1120, 640))
    c.js.append('tl.set("#camA",{zIndex:50},0);')
    show(c, "camA", t_dev + 0.5, t_end + 0.1)
    # right-column headlines
    heads = [("It learns where you look.", "16-point gaze calibration", t_dev + 0.4, t),
             ("Hold your gaze to type.", "Dwell on a key to select it", t, t + 5.2),
             ("It predicts what you mean.", "Word suggestions from a few glances", t + 5.2, t_end + 0.1)]
    for k, (h, e, a, b) in enumerate(heads):
        c.layer(f"headA{k}", "left:1120px;top:170px;width:780px;z-index:51",
                f'<div class="eyebrow" style="margin-bottom:14px">{e}</div><div style="font-size:60px;font-weight:600;letter-spacing:-0.04em;line-height:1.05;white-space:nowrap">{h}</div>',
                a, b - 0.5 if k < 2 else b, d_in=0.9)
    c.vo("a7", t + 0.3)
    c.vo("a8", t + 5.5)
    # the sentence, echoed large as it is typed
    words = [("I", g(SRC_I)), ("love", g(SRC_LOVE)), ("you", g(SRC_YOU))]
    c.html.append('<div id="echoA" class="layer" style="left:1120px;top:410px;width:760px;z-index:51;opacity:1;font-size:112px;font-weight:600;letter-spacing:-0.05em;white-space:nowrap">'
                  + " ".join(f'<span id="w{k}" class="grad" style="display:inline-block;opacity:0">{w}</span>' for k, (w, _) in enumerate(words)) + '</div>')
    for k, (_, tw) in enumerate(words):
        c.js.append(f'tl.fromTo("#w{k}",{{opacity:0,y:30,filter:"blur(10px)"}},{{opacity:1,y:0,filter:"blur(0px)",duration:.7,ease:"power3.out"}},{tw:.2f});')
    c.js.append(f'tl.to("#echoA",{{opacity:0,duration:.5}},{t_end:.2f});')

    # 5. Climax: the app speaks, the phone turns to the partner, then the reaction
    t_c = t_end + 0.3
    c.title('<span class="grad">I love you.</span>', t_c, 2.2, 170, z=55)
    c.vo("app_love", t_c + 0.5, vol=1.4)
    t_r = t_c + 2.0
    render_stage(c, "rotA", ROTATION, t_r, 5.0, 2.2, 2.0, z=56, push=(1.0, 1.04), d_in=0.5)
    c.layer("rotCap1", "left:96px;top:440px;width:520px;font-size:46px;font-weight:600;letter-spacing:-0.04em;line-height:1.1;z-index:57",
            '<span class="grad">Inside, you write it.</span>', t_r + 0.3, t_r + 4.6, y_from=16)
    c.layer("rotCap2", "left:96px;top:506px;width:520px;font-size:46px;font-weight:600;letter-spacing:-0.04em;line-height:1.1;color:#86868b;z-index:57",
            "Outside, they read it.", t_r + 2.2, t_r + 4.6, y_from=16)
    t_o = t_r + 5.0
    c.still("assets/img/s_outer.png", t_o, 3.2, z=58, scale=(1.03, 1.1), fade_in=0.6)
    cheer = []
    t_ch = t_o + 3.0
    c.seg(cheer, FACE, t_ch, 3.8, SRC_CHEER - 0.4, 1.0)
    c.html.append(cam_html("cheerA", 1280, 718, cheer, 320, 181, label=None))
    c.js.append('tl.set("#cheerA",{zIndex:60},0);')
    show(c, "cheerA", t_ch, t_ch + 3.0, y_from=30, scale_from=1.04, d_in=0.8)
    c.layer("cheerCap", "left:0;right:0;top:930px;text-align:center;font-size:30px;font-weight:500;color:#a1a1a6;z-index:61",
            "Typed with eyes only, on the first try.", t_ch + 0.6, t_ch + 3.0)

    # 6. End card: both taglines
    t_e = t_ch + 3.6
    c.layer("endRing", "left:835px;top:200px;width:250px;height:250px;z-index:62",
            '<img src="assets/img/glass_iris.png" style="width:375px;height:250px;object-fit:cover;margin-left:-62px;display:block;border-radius:50%">',
            t_e, None, scale_from=0.8, d_in=1.4)
    c.layer("endWord", "left:0;right:0;top:470px;text-align:center;font-size:132px;font-weight:600;letter-spacing:-0.05em;z-index:62",
            '<span class="grad">Iris</span>', t_e + 0.3, None)
    c.layer("endTag", "left:0;right:0;top:640px;text-align:center;font-size:44px;font-weight:500;letter-spacing:-0.02em;color:#d2d2d7;z-index:62",
            "Speak with your eyes.", t_e + 1.9, None)
    c.layer("endTag2", "left:0;right:0;top:708px;text-align:center;font-size:44px;font-weight:500;letter-spacing:-0.02em;color:#86868b;z-index:62",
            "Say what matters.", t_e + 4.6, None)
    c.layer("endFoot", "left:0;right:0;top:960px;text-align:center;font-size:24px;font-weight:500;color:#6e6e73;z-index:62",
            "Eye-typing for ALS on iPhone Duo  ·  Built in 4 hours at Bitrig Hacks", t_e + 5.4, None, y_from=10)
    c.vo("a10", t_e + 0.2)
    c.dur = round(t_e + 8.4, 2)
    c.black(12.2, c.dur - 12.2, z=30, fade=0.5)  # black stage from the device reveal on

    c.audio("musicA", "assets/music/bed_a.wav", 0, c.dur, 1,
            lane=[{"t": 0, "v": 0.28}, {"t": t_end - 5.5, "v": 0.28}, {"t": t_end - 4.5, "v": 0.5}, {"t": t_c + 0.3, "v": 0.5},
                  {"t": t_c + 0.5, "v": 0.2}, {"t": t_c + 1.8, "v": 0.2}, {"t": t_r + 0.3, "v": 0.5}, {"t": t_e + 0.3, "v": 0.34},
                  {"t": c.dur, "v": 0.34}], fade_out=3)
    c.write("a-look/index.html", "Iris · Look")


def end_card(c, t_e, w, h, ring_top, word_size, word_top, tag, tag_top, foot, foot_top, ring=250):
    left = (w - ring) // 2
    c.layer("endRing", f"left:{left}px;top:{ring_top}px;width:{ring}px;height:{ring}px;z-index:58",
            f'<img src="assets/img/glass_iris.png" style="width:{ring * 1.5:.0f}px;height:{ring}px;object-fit:cover;margin-left:-{ring * .25:.0f}px;display:block;border-radius:50%">',
            t_e, None, scale_from=0.8, d_in=1.4)
    c.layer("endWord", f"left:0;right:0;top:{word_top}px;text-align:center;font-size:{word_size}px;font-weight:600;letter-spacing:-0.05em;z-index:58",
            '<span class="grad">Iris</span>', t_e + 0.3, None)
    c.layer("endTag", f"left:0;right:0;top:{tag_top}px;text-align:center;font-size:44px;font-weight:500;letter-spacing:-0.02em;color:#d2d2d7;z-index:58",
            tag, t_e + 1.7, None)
    c.layer("endFoot", f"left:40px;right:40px;top:{foot_top}px;text-align:center;font-size:24px;font-weight:500;color:#6e6e73;z-index:58",
            foot, t_e + 2.4, None, y_from=10)


# ---------------------------------------------------------------- Option B: "Three words."  4:5, ~33 s
def option_b():
    W, H = 1080, 1350
    c = Comp("threewords", W, H, 34)
    c.still("assets/img/eye_macro.png", 0, 7.6, z=1, scale=(1.18, 1.32), fade_in=1.4, pos="46% 50%")
    for k, (name, text, t) in enumerate([("b1", "No hands.", 0.9), ("b2", "No voice.", 2.9), ("b3", "Just your eyes.", 4.9)]):
        c.vo(name, t, vol=1.35)
        c.title(f'<span class="grad">{text}</span>', t - 0.05, (1.95 if k < 2 else 2.6), 104, z=42)
    c.black(7.2, 30, z=30, fade=0.5)

    segs, cams = [], []
    t0 = 7.6
    t = c.seg(segs, SCREEN, t0, 1.8, 10.0, 10)
    c.seg(cams, FACE, t0, 1.8, 10.0, 10)
    plan = [(2.6, 95.0, 1.5), (2.6, 101.8, 1.5), (3.4, 108.0, 2.0), (4.5, 117.5, 1.0)]
    t_end, g = typing_segments(c, segs, SCREEN, t, plan)
    typing_segments(c, cams, FACE, t, plan)
    D_W, D_H = 640, 912
    c.html.append(device_html("devB", D_W, D_H, segs, (W - D_W) // 2, 96))
    c.js.append('tl.set("#devB",{zIndex:50},0);')
    show(c, "devB", t0, t_end + 0.1, y_from=60, scale_from=0.94, d_in=1.1)
    c.html.append(f'<div id="camB" class="layer cam" style="left:{(W + D_W) // 2 - 150}px;top:40px;width:250px;height:250px;border-radius:50%;border:4px solid #1c1c1e">{"".join(cams)}</div>')
    c.js.append('tl.set("#camB",{zIndex:52},0);')
    show(c, "camB", t0 + 0.4, t_end + 0.1, y_from=20, scale_from=0.8)
    for k, (lab, a, b) in enumerate([("Calibrating", t0 + 0.2, t), ("Typing with eye gaze", t, t_end + 0.1)]):
        c.layer(f"labB{k}", f"left:0;right:0;top:1040px;text-align:center;z-index:51", f'<span class="eyebrow" style="font-size:28px">{lab}</span>', a, b - 0.3, y_from=10, d_in=0.6)
    words = [("I", g(SRC_I)), ("love", g(SRC_LOVE)), ("you", g(SRC_YOU))]
    c.html.append('<div id="echoB" class="layer" style="left:0;right:0;top:1100px;text-align:center;z-index:51;opacity:1;font-size:120px;font-weight:600;letter-spacing:-0.05em;white-space:nowrap">'
                  + " ".join(f'<span id="bw{k}" class="grad" style="display:inline-block;opacity:0">{w}</span>' for k, (w, _) in enumerate(words)) + '</div>')
    for k, (_, tw) in enumerate(words):
        c.js.append(f'tl.fromTo("#bw{k}",{{opacity:0,y:30,filter:"blur(10px)"}},{{opacity:1,y:0,filter:"blur(0px)",duration:.7,ease:"power3.out"}},{tw:.2f});')
    c.js.append(f'tl.to("#echoB",{{opacity:0,duration:.5}},{t_end:.2f});')

    t_c = t_end + 0.3
    c.title('<span class="grad">I love you.</span>', t_c, 2.5, 150, z=55)
    c.vo("app_love", t_c + 0.5, vol=1.4)
    cheer = []
    t_ch = t_c + 2.3
    c.seg(cheer, FACE, t_ch, 3.8, SRC_CHEER - 0.4, 1.0)
    c.html.append(cam_html("cheerB", 980, 1100, cheer, 50, 110, label=None))
    c.js.append('tl.set("#cheerB",{zIndex:56},0);')
    show(c, "cheerB", t_ch, t_ch + 3.0, y_from=30, scale_from=1.04, d_in=0.8)

    t_e = t_ch + 3.6
    end_card(c, t_e, W, H, 300, 150, 590, "Say what matters.", 780, "Eye-typing for ALS on iPhone Duo · Built at Bitrig Hacks", 1220, ring=260)
    c.vo("b4", t_e + 0.2)
    c.dur = round(t_e + 5.4, 2)
    c.audio("musicB", "assets/music/bed_b.wav", 0, c.dur, 1,
            lane=[{"t": 0, "v": 0.3}, {"t": t_end - 5, "v": 0.3}, {"t": t_end - 4, "v": 0.5}, {"t": t_c + 0.3, "v": 0.5},
                  {"t": t_c + 0.5, "v": 0.2}, {"t": t_c + 1.8, "v": 0.2}, {"t": t_ch + 0.2, "v": 0.55}, {"t": t_e + 0.3, "v": 0.36},
                  {"t": c.dur, "v": 0.36}], fade_out=2.5)
    c.write("b-three-words/index.html", "Iris · Three words", sub=(80, 900, 34))


# ---------------------------------------------------------------- Option C: "Four hours."  16:9, ~44 s
def option_c():
    W, H = 1920, 1080
    c = Comp("fourhours", W, H, 45)
    # cold open: kinetic type on black
    c.vo("c1", 0.4)
    c.title('<span class="grad">Four hours.</span>', 0.45, 2.0, 180, z=42)
    c.title('<span class="grad">One question.</span>', 2.45, 1.6, 180, z=42)
    c.still("assets/img/gaze_portrait.png", 3.9, 5.6, z=2, scale=(1.05, 1.14), x=(0, -2), fade_in=0.7)
    c.vo("c2", 4.1, "What if someone with ALS could type with nothing but their eyes, on a phone?")
    c.still("assets/img/duo_hero.png", 9.3, 3.4, z=3, scale=(1.14, 1.04), fade_in=0.6)
    c.vo("c3", 9.6)
    c.layer("meetC", "left:150px;top:400px;width:440px;z-index:45",
            '<div class="grad" style="font-size:150px;font-weight:700;letter-spacing:-0.055em;line-height:1">Iris</div><div style="font-size:44px;font-weight:600;letter-spacing:-0.02em;color:#86868b;margin-top:14px">for iPhone Duo</div>',
            10.2, 12.4, d_in=0.8)
    c.black(12.5, 40, z=30, fade=0.35)

    segs, cams = [], []
    t0 = 12.6
    t = c.seg(segs, SCREEN, t0, 5.0, 8.0, 10)
    c.seg(cams, FACE, t0, 5.0, 8.0, 10)
    c.vo("c4", t0 + 0.2)
    plan = [(4.8, 93.8, 1.5), (3.0, 101.5, 1.25), (3.4, 108.0, 1.9), (4.6, 117.4, 1.0)]
    t_end, g = typing_segments(c, segs, SCREEN, t, plan)
    typing_segments(c, cams, FACE, t, plan)
    D_W, D_H = 640, 912
    c.html.append(device_html("devC", D_W, D_H, segs, 1030, 84))
    c.js.append('tl.set("#devC",{zIndex:50},0);')
    show(c, "devC", t0, t_end + 0.1, y_from=60, scale_from=0.94, d_in=0.9)
    c.html.append(cam_html("camC", 400, 224, cams, 150, 790, label="Webcam gaze"))
    c.js.append('tl.set("#camC",{zIndex:52},0);')
    show(c, "camC", t0 + 0.4, t_end + 0.1)

    big = "font-size:220px;font-weight:700;letter-spacing:-0.06em;line-height:1"
    lab = "font-size:40px;font-weight:600;letter-spacing:-0.02em;color:#86868b;margin-top:10px"
    c.layer("c16", "left:150px;top:220px;width:760px;z-index:51",
            f'<div class="grad" style="{big}">16</div><div style="{lab}">glances to calibrate</div>', t0 + 0.3, t - 0.3)
    # feature beats synced to the VO words
    t5 = t + 0.1
    c.vo("c5", t5, None)
    feats = [("Big keys.", t5 + 0.16), ("Grouped letters.", t5 + 1.48), ("Hold your gaze to select.", t5 + 2.99)]
    for k, (txt, tf) in enumerate(feats):
        c.layer(f"featC{k}", f"left:150px;top:{220 + k * 100}px;width:820px;z-index:51",
                f'<div style="font-size:72px;font-weight:700;letter-spacing:-0.045em;line-height:1.1;white-space:nowrap" class="grad">{txt}</div>', tf, t5 + 4.9, y_from=24, d_in=0.6)
    t6 = t5 + 5.0
    c.vo("c6", t6, None)
    c.layer("predC", "left:150px;top:220px;width:820px;z-index:51",
            f'<div style="{lab};margin:0 0 18px">Word prediction</div><div class="grad" style="font-size:84px;font-weight:700;letter-spacing:-0.045em;line-height:1.08">A few glances. Whole words.</div>',
            t6 + 0.1, g(SRC_YOU) - 4.3, d_in=0.7)
    t7 = g(SRC_YOU) - 3.8
    c.vo("c7", t7, None)
    words = [("I", g(SRC_I)), ("love", g(SRC_LOVE)), ("you", g(SRC_YOU))]
    c.layer("testC", "left:150px;top:470px;width:820px;z-index:51",
            f'<div style="{lab};margin:0 0 18px">Three words to test it</div>', t7, t_end + 0.1, d_in=0.6)
    c.html.append('<div id="echoC" class="layer" style="left:150px;top:560px;width:860px;z-index:51;opacity:1;font-size:120px;font-weight:700;letter-spacing:-0.055em;white-space:nowrap">'
                  + " ".join(f'<span id="cw{k}" class="grad" style="display:inline-block;opacity:0">{w}</span>' for k, (w, _) in enumerate(words)) + '</div>')
    for k, (_, tw) in enumerate(words):
        c.js.append(f'tl.fromTo("#cw{k}",{{opacity:0,y:30,filter:"blur(10px)"}},{{opacity:1,y:0,filter:"blur(0px)",duration:.6,ease:"power3.out"}},{tw:.2f});')
    c.js.append(f'tl.to("#echoC",{{opacity:0,duration:.4}},{t_end:.2f});')

    t_c = t_end + 0.25
    c.title('<span class="grad">I love you.</span>', t_c, 2.4, 180, z=55)
    c.vo("app_love", t_c + 0.45, vol=1.4)
    cheer = []
    t_ch = t_c + 2.2
    c.seg(cheer, FACE, t_ch, 3.8, SRC_CHEER - 0.4, 1.0)
    c.html.append(cam_html("cheerC", 1280, 718, cheer, 320, 181, label=None))
    c.js.append('tl.set("#cheerC",{zIndex:56},0);')
    show(c, "cheerC", t_ch, t_ch + 3.0, y_from=30, scale_from=1.04, d_in=0.7)
    c.layer("cheerCapC", "left:0;right:0;top:930px;text-align:center;font-size:30px;font-weight:500;color:#a1a1a6;z-index:57",
            "First try. Eyes only.", t_ch + 0.5, t_ch + 3.0)

    t_e = t_ch + 3.6
    end_card(c, t_e, W, H, 180, 140, 450, "Built at Bitrig Hacks.", 640, "Eye-typing for ALS on iPhone Duo  ·  Built in 4 hours", 960, ring=240)
    c.vo("c8", t_e + 0.1)
    c.dur = round(t_e + 5.6, 2)
    c.audio("musicC", "assets/music/bed_c.wav", 0, c.dur, 1,
            lane=[{"t": 0, "v": 0.3}, {"t": t_end - 4, "v": 0.3}, {"t": t_end - 3, "v": 0.45}, {"t": t_c + 0.3, "v": 0.45},
                  {"t": t_c + 0.45, "v": 0.18}, {"t": t_c + 1.7, "v": 0.18}, {"t": t_ch + 0.2, "v": 0.5}, {"t": t_e + 0.3, "v": 0.34},
                  {"t": c.dur, "v": 0.34}], fade_out=2.5)
    c.write("c-four-hours/index.html", "Iris · Four hours")


if __name__ == "__main__":
    option_a()
    option_b()
    option_c()
