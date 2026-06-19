# vendor/ — Ptah native dependencies

> **macOS-only by design.** Ptah is a Pt-BR TTS CLI for macOS (Apple Silicon).
> Cross-platform builds are intentionally out of scope.

Ptah's **Kokoro** engine links two C dependencies. They are binaries, kept out
of git (`.gitignore`), and reproduced locally with the recipe below. Audio
playback uses macOS-native **`afplay`** — there is no vendored audio library.

## What lives here

```
vendor/onnxruntime/      ONNX Runtime 1.22.0 (osx-arm64) — Kokoro inference
  ├── include/           onnxruntime_c_api.h
  └── lib/               libonnxruntime.dylib
```

espeak-ng (the phonemizer) is **not** vendored — it comes from Homebrew.

## Reproduction recipe

Prereqs: macOS arm64, Xcode CLT, Homebrew, Zig 0.16+.

### 1. ONNX Runtime

```bash
curl -fsSL -o /tmp/ort.tgz \
  https://github.com/microsoft/onnxruntime/releases/download/v1.22.0/onnxruntime-osx-arm64-1.22.0.tgz
mkdir -p vendor/onnxruntime
tar xzf /tmp/ort.tgz -C vendor/onnxruntime --strip-components=1
```

### 2. espeak-ng

```bash
brew install espeak-ng
```

`build.zig` links it from `/opt/homebrew/opt/espeak-ng` (headers + `libespeak-ng.dylib`
+ `share/espeak-ng-data`).

### 3. Kokoro model + voice

The Kokoro model (`assets/kokoro-v1.0.onnx`, ~310 MB) is gitignored and fetched
on demand; the Dora voice pack (`assets/pf_dora.bin`) is committed.

```bash
bash scripts/fetch-kokoro.sh   # downloads the model into assets/
```

### 4. Build

```bash
zig build                 # builds the `ptah` binary
zig build kokoro-probe    # synthesises a test phrase (engine smoke)
```

## Licenses

ONNX Runtime — MIT. espeak-ng — GPL-3.0-or-later (linking it makes the
distributed Ptah binary inherit GPL-3.0-or-later). Kokoro model + voices —
Apache-2.0. Ptah's own source is MIT OR Apache-2.0.
