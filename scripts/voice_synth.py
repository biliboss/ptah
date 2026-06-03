#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# voice_synth.py — agent-tts v1.4 cloned-voice synthesis sidecar.
#
# Reads text from stdin, loads the XTTS-v2 conditioning latents from a
# `.npz` produced by `voice_clone.py`, synthesizes Portuguese (default) or
# the language given via --lang, and writes raw s16le PCM to stdout at the
# rate given via --rate (default 22050 to match Faber's pipeline).
#
# Called from `src/daemon.zig::synthClonedViaSidecar`. Process boundary is
# the licensing wall: Coqui TTS is MPL-2.0, but it runs out-of-process so
# the parent Zig binary stays dual MIT/Apache.
#
# Latency note: cold start of XTTS-v2 on Apple Silicon CPU is ~6-10s.
# First-sample latency for short utterances after warm is ~500-900ms.
# For v1.4 we accept that — Faber stays the snappy default; cloned is
# opt-in for personal voice.

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Match voice_clone.py — XTTS-v2 still re-prompts for the CPML license if
# the model dir was deleted between runs. Headless opt-in.
os.environ.setdefault("COQUI_TOS_AGREED", "1")

DEFAULT_RATE = 22050


def fail(msg: str, code: int = 2) -> None:
    print(f"[voice_synth] error: {msg}", file=sys.stderr)
    sys.exit(code)


def main() -> int:
    ap = argparse.ArgumentParser(description="agent-tts XTTS-v2 voice synthesis sidecar")
    ap.add_argument("--embedding", required=True, help="path to embedding.npz")
    ap.add_argument("--rate", type=int, default=DEFAULT_RATE, help="output sample rate (Hz)")
    ap.add_argument("--lang", default="pt", help="ISO language code (default: pt)")
    ap.add_argument(
        "--model",
        default="tts_models/multilingual/multi-dataset/xtts_v2",
        help="Coqui TTS model name (must match voice_clone.py)",
    )
    ap.add_argument(
        "--device",
        default=os.environ.get("AGENT_TTS_DEVICE", "cpu"),
        help="torch device (cpu/mps/cuda); default cpu, override via AGENT_TTS_DEVICE",
    )
    args = ap.parse_args()

    embedding_path = Path(args.embedding).expanduser().resolve()
    if not embedding_path.exists():
        fail(f"embedding not found: {embedding_path}")

    text = sys.stdin.read().strip()
    if not text:
        fail("empty text on stdin")

    try:
        import numpy as np
        import torch
        from TTS.api import TTS
    except ImportError as e:
        fail(
            "Coqui TTS not installed. Run `scripts/setup-voice-clone.sh` first.\n"
            f"  underlying: {e}",
            code=3,
        )

    print(f"[voice_synth] loading model on {args.device}", file=sys.stderr)
    tts = TTS(model_name=args.model, progress_bar=False).to(args.device)
    inner = tts.synthesizer.tts_model

    with np.load(str(embedding_path), allow_pickle=True) as data:
        gpt_cond_latent = torch.from_numpy(data["gpt_cond_latent"]).to(args.device)
        speaker_embedding = torch.from_numpy(data["speaker_embedding"]).to(args.device)

    print(f"[voice_synth] synth lang={args.lang} chars={len(text)}", file=sys.stderr)
    out = inner.inference(
        text=text,
        language=args.lang,
        gpt_cond_latent=gpt_cond_latent,
        speaker_embedding=speaker_embedding,
        # Reasonable defaults — match Coqui's standard demo. Tune via env
        # AGENT_TTS_TEMPERATURE if needed.
        temperature=float(os.environ.get("AGENT_TTS_TEMPERATURE", "0.7")),
    )

    # `out["wav"]` is float32 in [-1, 1] at the model's native rate (24000Hz
    # for XTTS-v2). Resample to --rate if it differs, then convert to s16le.
    wav = np.asarray(out["wav"], dtype=np.float32)
    model_rate = int(getattr(inner.config, "audio", {}).get("sample_rate", 24000)) \
        if hasattr(inner, "config") else 24000

    if model_rate != args.rate:
        try:
            from scipy.signal import resample_poly
            from math import gcd
            g = gcd(args.rate, model_rate)
            wav = resample_poly(wav, args.rate // g, model_rate // g).astype(np.float32)
        except ImportError:
            # Cheap linear resample fallback — quality drop is small for
            # 24000→22050 (close ratio) and beats hard-failing on scipy.
            ratio = args.rate / model_rate
            n_out = int(len(wav) * ratio)
            idx = np.linspace(0, len(wav) - 1, n_out)
            wav = np.interp(idx, np.arange(len(wav)), wav).astype(np.float32)

    # Clip + scale to s16 to avoid overflow on loud frames.
    pcm = np.clip(wav, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype(np.int16)
    sys.stdout.buffer.write(pcm.tobytes())
    sys.stdout.buffer.flush()
    print(f"[voice_synth] OK — wrote {len(pcm)} samples @ {args.rate}Hz", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
