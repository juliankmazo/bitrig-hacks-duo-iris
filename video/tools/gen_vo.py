import base64, json, os, sys, urllib.request, concurrent.futures as cf
KEY = os.environ["SPACEXAI_API_KEY"]
# (voice, speed, text) per line; lines are generated separately so the edit can place each one.
LINES = {
 # Option A: "Look."  warm, calm narrator
 "a1": ("ara", 0.92, "Most people living with ALS will lose the ability to speak."),
 "a2": ("ara", 0.92, "The devices that give that voice back [pause] can cost fifteen thousand dollars."),
 "a3": ("ara", 0.92, "We thought it should only take a phone."),
 "a4": ("ara", 0.92, "This is Iris."),
 "a5": ("ara", 0.92, "Iris turns iPhone Duo into a voice you control with your eyes."),
 "a6": ("ara", 0.92, "First, it learns where you look."),
 "a7": ("ara", 0.92, "Then, just hold your gaze on a key to type."),
 "a8": ("ara", 0.92, "It predicts the words you mean, [pause] so every glance says more."),
 "a9": ("ara", 0.92, "Iris. [pause] Speak with your eyes."),
 "a10": ("ara", 0.92, "Iris. [pause] Speak with your eyes. [long-pause] Say what matters."),
 # Option B: "Three words."  intimate, sparse
 "b1": ("eve", 0.9, "<soft>No hands.</soft>"),
 "b2": ("eve", 0.9, "<soft>No voice.</soft>"),
 "b3": ("eve", 0.9, "<soft>Just your eyes.</soft>"),
 "b4": ("eve", 0.9, "Iris. [pause] Say what matters."),
 # Option C: "Built in four hours"  confident builder energy
 "c1": ("leo", 1.0, "Four hours. [pause] One question."),
 "c2": ("leo", 1.0, "What if someone with ALS could type with nothing but their eyes, [pause] on a phone?"),
 "c3": ("leo", 1.0, "Meet Iris, for iPhone Duo."),
 "c4": ("leo", 1.0, "Sixteen targets, and it learns your gaze."),
 "c5": ("leo", 1.0, "Big keys. Grouped letters. Hold your gaze to select."),
 "c6": ("leo", 1.0, "Word prediction turns a few glances into whole words."),
 "c7": ("leo", 1.0, "Three words to test it."),
 "c8": ("leo", 1.0, "Iris. [pause] Built at Bitrig Hacks."),
 # The app's voice, speaking what was typed
 "app_love": ("iris", 0.9, "I love you."),
}
def gen(name):
    voice, speed, text = LINES[name]
    body = json.dumps({"text": text, "voice_id": voice, "language": "en", "speed": speed, "with_timestamps": True,
                       "output_format": {"codec": "mp3", "sample_rate": 44100, "bit_rate": 192000}}).encode()
    req = urllib.request.Request("https://api.x.ai/v1/tts", body,
        {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=120)
        ct = r.headers.get("content-type", ""); data = r.read()
        if "json" in ct:
            d = json.loads(data)
            audio = d.get("audio") or d.get("audio_base64") or d.get("data")
            open(f"assets/vo/{name}.mp3", "wb").write(base64.b64decode(audio))
            json.dump({k: v for k, v in d.items() if k not in ("audio", "audio_base64", "data")}, open(f"assets/vo/{name}.json", "w"))
            return name, "ok json", list(d.keys())
        open(f"assets/vo/{name}.mp3", "wb").write(data)
        return name, "ok raw", ct
    except urllib.error.HTTPError as e:
        return name, "ERR", e.read().decode()[:300]
names = sys.argv[1:] or list(LINES)
with cf.ThreadPoolExecutor(6) as ex:
    for r in ex.map(gen, names): print(*r, flush=True)
