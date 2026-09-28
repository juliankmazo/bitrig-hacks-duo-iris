import base64, json, os, sys, urllib.request, concurrent.futures as cf
KEY = os.environ["OPENAI_API_KEY"]
STYLE = (" Shot like an Apple product film: restrained, minimal, premium, soft natural light, "
         "shallow depth of field, subtle film grain, true-to-life color. Absolutely no logos, "
         "no brand marks, no text, no watermarks, no UI text.")
PROMPTS = {
 "eye_macro": ("1536x1024", "Extreme macro photograph of a human eye, iris with rich hazel and deep blue fibers, "
   "a tiny soft reflection of a glowing grid of rounded rectangles in the pupil, near-black background, dramatic side light."),
 "duo_hero": ("1536x1024", "A sleek unbranded foldable smartphone standing half-open like a book (about 110 degrees), "
   "on a seamless matte black surface, thin aluminum frame with a soft rim light tracing its edges, inner screens glowing "
   "with a soft white light, reflection on the floor, lots of negative space, centered product hero shot."),
 "duo_tray": ("1536x1024", "A warm, quiet living room at golden hour. On a white wheelchair tray table sits a sleek unbranded "
   "foldable smartphone standing half-open like a book, its inner screen glowing softly. Out of focus in the background, "
   "an older man seated in a wheelchair by the window and a woman sitting across from him, leaning in, attentive and tender. "
   "Faces soft and not the focus. Hopeful, dignified mood."),
 "hands": ("1536x1024", "Close-up of an elderly man's hand resting on a blanket on his lap, a younger woman's hand gently "
   "placed on top of it, warm window light from the left, linen textures, intimate and tender, dark soft background."),
 "window": ("1536x1024", "A quiet sunlit room in the early morning, sheer white curtains glowing, dust particles in a beam "
   "of light, an empty armchair, calm and still, minimalist, lots of negative space."),
 "glass_iris": ("1536x1024", "Abstract 3D render: a luminous ring shaped like an iris, made of frosted glass and fine radial "
   "light fibers, glowing soft blue to violet, floating in the center of a pure black void, subtle caustics, elegant and minimal."),
 "gaze_portrait": ("1536x1024", "Cinematic close-up portrait of a woman in her sixties with silver hair, calm and focused, eyes "
   "looking slightly down and to the right at a softly glowing screen out of frame, the screen light gently illuminating her "
   "face, dark background, emotional and dignified."),
 "duo_tray_v": ("1024x1536", "Vertical shot: on a white wheelchair tray table in a warm sunlit living room sits a sleek unbranded "
   "foldable smartphone standing half-open like a book, inner screen glowing softly. Behind it, softly out of focus, an older "
   "man in a wheelchair and the hand of a loved one resting on his shoulder. Hopeful, dignified."),
}
def gen(name, size, prompt):
    out = f"assets/img/{name}.png"
    if os.path.exists(out): return name, "exists"
    body = json.dumps({"model": "gpt-image-2.5-sunburst", "prompt": prompt + STYLE, "size": size, "quality": "high"}).encode()
    req = urllib.request.Request("https://api.openai.com/v1/images/generations", body,
        {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    try:
        d = json.load(urllib.request.urlopen(req, timeout=300))
        open(out, "wb").write(base64.b64decode(d["data"][0]["b64_json"]))
        return name, "ok"
    except urllib.error.HTTPError as e:
        return name, e.read().decode()[:300]
names = sys.argv[1:] or list(PROMPTS)
with cf.ThreadPoolExecutor(8) as ex:
    for r in ex.map(lambda n: gen(n, *PROMPTS[n]), names): print(*r, flush=True)
