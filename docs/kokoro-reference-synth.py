#!/usr/bin/env python3
"""Experimento Kokoro PT-BR — inferência ONNX direta (bypass kokoro-onnx wrapper).

Modelo onnx-community: input_ids int64[1,L], style float[1,256], speed float[1].
Vozes .bin = float32 (510,256): style row = voz[len(ids)] (convenção Kokoro).
Fonemização PT-BR via espeak-ng (Tokenizer.phonemize lang='pt-br').
"""
import sys, time, glob, os
import numpy as np
import soundfile as sf
import onnxruntime as ort
from kokoro_onnx.tokenizer import Tokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
TEXT = os.environ.get("KOKORO_TEXT") or (
    "Oi! Esse é um teste de voz, com calma. "
    "Escuta bem e me diz qual soa mais natural pra você. "
    "Hoje o dia está bonito, e a gente combina o almoço lá pelas duas horas."
)
SPEED = float(os.environ.get("KOKORO_SPEED", "0.85"))  # <1 = mais calmo
SR = 24000

tok = Tokenizer()
sess = ort.InferenceSession(os.path.join(HERE, "kokoro-v1.0.onnx"))

phon = tok.phonemize(TEXT, lang="pt-br")
ids = tok.tokenize(phon)
print(f"[fonemas pt-br] {phon}")
print(f"[tokens] {len(ids)}")
ids_full = [0, *ids, 0]  # pad bos/eos
input_ids = np.array([ids_full], dtype=np.int64)

for b in sorted(glob.glob(os.path.join(HERE, "*.bin"))):
    voice = os.path.splitext(os.path.basename(b))[0]
    ref = np.fromfile(b, dtype=np.float32).reshape(-1, 256)
    style = ref[len(ids)][np.newaxis, :].astype(np.float32)  # [1,256]
    t = time.time()
    wav = sess.run(None, {
        "input_ids": input_ids,
        "style": style,
        "speed": np.array([SPEED], dtype=np.float32),
    })[0]
    dt = time.time() - t
    wav = wav.squeeze()
    out = os.path.join(HERE, "out", f"{voice}.wav")
    sf.write(out, wav, SR)
    dur = len(wav) / SR
    print(f"[{voice}] infer={dt:.2f}s  audio={dur:.2f}s  RTF={dt/dur:.2f}  -> {out}")
