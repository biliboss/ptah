#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# voice_clone.py — agent-tts v1.4 voice cloning sidecar.
#
# Loads a reference WAV (20-120s, mono preferred), extracts the XTTS-v2
# speaker conditioning latents + speaker embedding, and writes them to a
# `.npz` archive consumed by `voice_synth.py`.
#
# Runtime: `uv run --with TTS scripts/voice_clone.py ...`
# Fallback: `python3 scripts/voice_clone.py ...` (assumes venv with `TTS`).
#
# Coqui TTS is MPL-2.0; running it as a separate process keeps the parent
# Zig binary's dual MIT/Apache license unchanged.
#
# Pin notes:
#   - coqui-tts >= 0.24.0 (PyPI `coqui-tts` — the maintained community fork
#     after the original `TTS` package was abandoned upstream). The legacy
#     `TTS` package on PyPI is the same code at the last upstream release;
#     either works for v1.4.
#   - PyTorch 2.x. CPU works; MPS (Apple Silicon) is faster but optional.
#   - Model: `tts_models/multilingual/multi-dataset/xtts_v2`
#     (~1.8 GB download on first run — cached to ~/Library/Application
#     Support/tts/ on macOS or ~/.local/share/tts/ on Linux).

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import wave
from pathlib import Path

# XTTS-v2 prompts for CPML license acceptance on first download. We run
# headless from a Zig parent that pipes stdin as EOF, so the prompt would
# raise EOFError. Setting `COQUI_TOS_AGREED` is Coqui's documented
# non-interactive opt-in — equivalent to `brew install` agreeing to upstream
# licenses on the user's behalf for personal use. Real production users
# should read https://coqui.ai/cpml before commercial use.
os.environ.setdefault("COQUI_TOS_AGREED", "1")

SLUG_RE = re.compile(r"^[a-z0-9-]+$")
MIN_S = 20.0
MAX_S = 120.0


def fail(msg: str, code: int = 2) -> None:
    print(f"[voice_clone] error: {msg}", file=sys.stderr)
    sys.exit(code)


def wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as w:
        frames = w.getnframes()
        rate = w.getframerate()
        if rate == 0:
            return 0.0
        return frames / float(rate)


def main() -> int:
    ap = argparse.ArgumentParser(description="agent-tts XTTS-v2 voice cloning sidecar")
    ap.add_argument("--sample", required=True, help="reference WAV (20-120s mono)")
    ap.add_argument("--out", required=True, help="output .npz archive path")
    ap.add_argument(
        "--model",
        default="tts_models/multilingual/multi-dataset/xtts_v2",
        help="Coqui TTS model name (default: XTTS-v2 multilingual)",
    )
    ap.add_argument(
        "--device",
        default=os.environ.get("AGENT_TTS_DEVICE", "cpu"),
        help="torch device (cpu/mps/cuda); default cpu, override via AGENT_TTS_DEVICE",
    )
    args = ap.parse_args()

    sample = Path(args.sample).expanduser().resolve()
    out = Path(args.out).expanduser().resolve()
    if not sample.exists():
        fail(f"sample not found: {sample}")
    if not sample.suffix.lower() == ".wav":
        fail(f"sample must be .wav: {sample}")

    dur = wav_duration(sample)
    if dur < MIN_S:
        fail(f"sample too short ({dur:.1f}s) — need at least {MIN_S:.0f}s")
    if dur > MAX_S:
        fail(f"sample too long ({dur:.1f}s) — max {MAX_S:.0f}s")

    out.parent.mkdir(parents=True, exist_ok=True)

    # Heavy imports gated behind arg validation — keeps `--help` snappy and
    # avoids paying torch's ~3-4s startup cost on bad input.
    try:
        import numpy as np
        import torch
        from TTS.api import TTS  # coqui-tts / TTS package — both expose this.
    except ImportError as e:
        fail(
            "Coqui TTS not installed. Run `scripts/setup-voice-clone.sh` first.\n"
            f"  underlying: {e}",
            code=3,
        )

    print(f"[voice_clone] loading model {args.model} on {args.device}", file=sys.stderr)
    tts = TTS(model_name=args.model, progress_bar=False).to(args.device)

    # XTTS-v2 exposes `get_conditioning_latents` on the underlying model.
    # The Coqui Python API wraps it as `tts.synthesizer.tts_model`.
    model = getattr(tts, "synthesizer", None)
    if model is None or getattr(model, "tts_model", None) is None:
        fail("loaded model does not look like XTTS-v2 — wrong model name?")
    inner = model.tts_model

    print(f"[voice_clone] extracting speaker latents from {sample.name}", file=sys.stderr)
    gpt_cond_latent, speaker_embedding = inner.get_conditioning_latents(
        audio_path=str(sample),
    )

    np.savez(
        str(out),
        gpt_cond_latent=gpt_cond_latent.detach().cpu().numpy(),
        speaker_embedding=speaker_embedding.detach().cpu().numpy(),
        model_name=np.array(args.model),
        version=np.array(1),
    )

    # Best-effort metadata next to the embedding (Zig sidecar writes the
    # canonical metadata.json; this is just a breadcrumb if the Python script
    # is invoked standalone).
    meta = out.with_name("clone-info.json")
    meta.write_text(
        json.dumps(
            {
                "sample": str(sample),
                "duration_seconds": round(dur, 2),
                "model": args.model,
                "device": args.device,
            },
            indent=2,
        )
    )

    print(f"[voice_clone] OK — wrote {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
