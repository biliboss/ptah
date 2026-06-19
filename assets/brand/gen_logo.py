#!/usr/bin/env python3
"""Gera logo do Ptah via Gemini image models (generateContent). Key via env GEMINI_KEY."""
import os, json, base64, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
KEY = os.environ["GEMINI_API_KEY"].strip()
PROMPT = (
    "Minimalist flat vector logo mark, app icon, of Ptah — the ancient Egyptian god "
    "of creative speech (Memphite theology: he creates the world by speaking). "
    "A stylized mummiform deity shown in profile with a straight ceremonial beard, "
    "merged with clean concentric sound waves emanating forward from the mouth, "
    "evoking spoken voice becoming form. Geometric, bold, modern tech brand mark. "
    "Palette: lapis blue and gold on deep charcoal. Centered, balanced, NO text, "
    "NO letters, no watermark. Square, crisp, suitable as a terminal app icon."
)
MODELS = ["gemini-3-pro-image-preview", "gemini-3.1-flash-image", "gemini-2.5-flash-image"]
body = {
    "contents": [{"parts": [{"text": PROMPT}]}],
    "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]},
}

for model in MODELS:
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={KEY}"
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                headers={"Content-Type": "application/json"})
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        d = json.load(resp)
    except urllib.error.HTTPError as e:
        print(f"[{model}] HTTP {e.code}: {e.read()[:300].decode(errors='replace')}")
        continue
    n = 0
    for cand in d.get("candidates", []):
        for part in cand.get("content", {}).get("parts", []):
            img = part.get("inlineData") or part.get("inline_data")
            if img and img.get("data"):
                n += 1
                fn = f"ptah-{model}-{n}.png"
                open(fn, "wb").write(base64.b64decode(img["data"]))
                print(f"[{model}] saved {fn}")
    if n:
        print(f"[{model}] OK — {n} image(s)")
        break
    else:
        print(f"[{model}] sem imagem; resp: {json.dumps(d)[:300]}")
