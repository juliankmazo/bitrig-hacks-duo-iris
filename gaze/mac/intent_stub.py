"""Minimal intent server stub for IrisGaze: answers `suggest` with 3 uppercase words, prints captions.

uv run --python 3.12 intent_stub.py [--port 8765]
"""

import argparse
import asyncio
import json

from websockets.asyncio.server import serve

WORDS = "i you the to and it is that of in my me we what not be do have this for on are with your can was help " \
        "please thank feel pain water now here good okay how when where why who time day home more need want".split()


async def handler(ws):
    async for raw in ws:
        msg = json.loads(raw)
        if msg.get("type") == "suggest":
            prefix = msg["text"].split(" ")[-1].lower()
            words = [w.upper() for w in WORDS if w.startswith(prefix) and w != prefix][:3]
            await ws.send(json.dumps({"type": "words", "id": msg["id"], "source": "local", "words": words,
                                      "phrases": ["I NEED HELP"] if not prefix else []}))
            print("suggest", msg["id"], repr(msg["text"]), "->", words, flush=True)
        elif msg.get("type") == "caption":
            print("caption", "FINAL" if msg.get("final") else "live ", repr(msg["text"]), flush=True)


async def main(port: int) -> None:
    async with serve(handler, "127.0.0.1", port):
        print(f"intent stub on ws://127.0.0.1:{port}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    asyncio.run(main(ap.parse_args().port))
