# Scene stills made with gpt-image-2.5 edits, using real device renders of the app as references.
import base64, json, os, sys, uuid, urllib.request, concurrent.futures as cf
KEY = os.environ["OPENAI_API_KEY"]
DEVICE = ("The phone is EXACTLY the foldable device in the reference images: a tall slab that folds in half across its middle. "
          "Its inner screen shows the Iris app exactly as in the first reference (white background, 'I love you' at the top, a grid of "
          "rounded keys: ABCD, EFGH, IJKLM, NOPQu, RSTUV, WXYZ, black Space/Delete/Start over keys, and a column of light-blue word keys 'I', 'you', 'the'). "
          "Its back has a black outer display on the upper half that shows the white words 'I love you' with a small Iris logo, and a cream-colored lower half with a two-lens camera, exactly as in the second reference. ")
STYLE = (" Shot like an Apple product film: restrained, premium, soft natural window light, shallow depth of field, subtle film grain, "
         "true-to-life skin tones, dignified and tender, not clinical. Absolutely no brand logos, no watermarks, no extra text besides the app UI.")
SCENES = {
 "s_problem": (None, "1536x1024", "An older man with ALS sits in a modern power wheelchair by a large window in a warm, lived-in home. His wife sits beside "
   "him, speaking to him softly, holding his hand. He looks at her with love but cannot answer. Quiet, emotional, cinematic. No phone in the scene."),
 "s_wide": (["inner", "outer"], "1536x1024", "Side-view wide shot at a small round wooden table in a sunlit living room. On the left, an older man seated in a modern "
   "power wheelchair, head supported, looking down at the phone with focus. On the right, facing him across the table, his adult daughter leans in, reading the "
   "outer screen and smiling with emotion. Between them on the table the phone stands half-folded like a tiny laptop at about 100 degrees: the lower half lies flat, "
   "the upper half stands up. The inner screen faces the man; the black outer display on the back of the upright half faces the daughter and shows 'I love you'. " + DEVICE),
 "s_inner": (["inner"], "1536x1024", "Over-the-shoulder shot from behind an older man seated in a modern power wheelchair, his gaze on the phone standing "
   "half-folded on his wheelchair tray a comfortable distance in front of him. The inner screen is sharp and readable, showing the Iris keyboard exactly as in "
   "the reference with 'I love you' typed at the top. Out of focus across the room, a woman sits facing him. " + DEVICE),
 "s_outer": (["outer"], "1536x1024", "Over-the-shoulder shot from behind a woman in her fifties sitting across a table from an older man in a wheelchair. "
   "Between them the phone stands half-folded; she reads its black outer display, which faces her and shows 'I love you' in white with a small Iris logo, "
   "exactly as in the reference. Beyond the phone, softly out of focus, the man looks at her with a gentle smile. Her hand is raised to her mouth, moved. " + DEVICE),
 "s_inner2": (["inner"], "1536x1024", "Over-the-shoulder shot from behind an older man seated in a modern power wheelchair. On his wheelchair tray, a comfortable "
   "distance in front of him, stands ONE single phone (only one device in the whole image), unfolded flat and propped up in a slim stand, facing him. Its screen is sharp "
   "and readable, showing the Iris keyboard exactly as in the reference with 'I love you' typed at the top. Out of focus across the room, a woman sits facing him, smiling. "
   "The phone is EXACTLY the device in the reference image, with its inner screen showing the Iris app exactly as in the reference."),
}
def gen(name):
    refs, size, prompt = SCENES[name]
    out = f"assets/img/{name}.png"
    prompt = prompt + STYLE
    if not refs:
        body = json.dumps({"model": "gpt-image-2.5-sunburst", "prompt": prompt, "size": size, "quality": "high"}).encode()
        req = urllib.request.Request("https://api.openai.com/v1/images/generations", body,
                                     {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    else:
        b = uuid.uuid4().hex; parts = []
        def field(k, v): parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        for k, v in [("model", "gpt-image-2.5-sunburst"), ("prompt", prompt), ("size", size), ("quality", "high")]:
            field(k, v)
        for r in refs:
            parts.append(f'--{b}\r\nContent-Disposition: form-data; name="image[]"; filename="{r}.png"\r\nContent-Type: image/png\r\n\r\n'.encode()
                         + open(f"assets/ref/{r}.png", "rb").read() + b"\r\n")
        parts.append(f"--{b}--\r\n".encode())
        req = urllib.request.Request("https://api.openai.com/v1/images/edits", b"".join(parts),
                                     {"Authorization": f"Bearer {KEY}", "Content-Type": f"multipart/form-data; boundary={b}"})
    try:
        d = json.load(urllib.request.urlopen(req, timeout=400))
        open(out, "wb").write(base64.b64decode(d["data"][0]["b64_json"]))
        return name, "ok"
    except urllib.error.HTTPError as e:
        return name, e.read().decode()[:400]
names = sys.argv[1:] or list(SCENES)
with cf.ThreadPoolExecutor(8) as ex:
    for r in ex.map(gen, names): print(*r, flush=True)
