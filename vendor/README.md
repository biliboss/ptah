# vendor/ — libpiper FFI (v0.6+)

This directory holds vendored C/C++ code that agent-tts links against. It is
intentionally **not committed** (gitignored under `vendor/piper1-gpl/`). This
README is the reproduction recipe.

## What lives here

```
vendor/piper1-gpl/                 cloned source @ tag v1.4.2
vendor/piper1-gpl/libpiper/        the C library we link
vendor/piper1-gpl/libpiper/dist/   the artifacts the Zig build expects
  └── lib/  libpiper.dylib + libonnxruntime.1.22.0.dylib + libonnxruntime.dylib
  └── share/espeak-ng-data/        runtime data dir consumed by piper_create()
```

## Reproduction recipe

Prereqs: macOS arm64, Xcode CLT, Homebrew.

```bash
brew install cmake espeak-ng
```

(espeak-ng on the host is **not** what libpiper uses — libpiper builds its own
static espeak-ng. The brew package is here because Piper's CMake expects a few
tools to be on PATH during the external project bootstrap.)

### 1. Clone pinned tag

```bash
cd 99-development/agent-tts/vendor
git clone https://github.com/OHF-Voice/piper1-gpl.git
cd piper1-gpl
git checkout v1.4.2
```

Tag v1.4.2 is the latest stable as of 2026-06-03. Newer tags may rebase the
public C API in `libpiper/include/piper.h` — re-check `src/piper.zig` before
bumping.

### 2. Build at a SHORT path (gotcha)

`espeak-ng` defines `N_PATH_HOME = 160` (chars) on POSIX. The default vault
build dir already exceeds that, so the espeak data-compilation step truncates
filenames at ~160 chars and fails opaquely with "Bad vowel file" / "Failed to
open …phsource/r3/r_tr" errors.

Workaround: build under `/tmp/piper-build`:

```bash
mkdir -p /tmp/piper-build
# symlink so consumers find build/ at the conventional location
ln -sfn /tmp/piper-build libpiper/build

cd /tmp/piper-build
cmake -S /Users/$USER/.obsidian/.claude/worktrees/.../agent-tts/vendor/piper1-gpl/libpiper \
      -DCMAKE_BUILD_TYPE=Release
cmake --build . --target piper -j
```

(Adjust the absolute path to your vault location.)

This downloads onnxruntime 1.22.0 (~14MB), builds espeak-ng static (~10min on
M4), then links `libpiper.dylib` against both.

### 3. Stage artifacts into dist/

`build.zig` expects everything at `vendor/piper1-gpl/libpiper/dist/`:

```bash
cd <agent-tts>/vendor/piper1-gpl/libpiper
mkdir -p dist/lib dist/share
cp /tmp/piper-build/libpiper.dylib dist/lib/
cp lib/onnxruntime-osx-arm64-1.22.0/lib/libonnxruntime.1.22.0.dylib dist/lib/
cp lib/onnxruntime-osx-arm64-1.22.0/lib/libonnxruntime.dylib dist/lib/
cp -R /tmp/piper-build/espeak_ng-install/share/espeak-ng-data dist/share/
```

After this, `zig build -Dwith-piper=true` from `99-development/agent-tts/`
links cleanly and the binary resolves `@rpath/libpiper.dylib` to
`dist/lib/libpiper.dylib` at runtime.

### 4. Download voice model

Default voice: `pt_BR-faber-medium` (Pt-BR mono).

```bash
mkdir -p ~/.cache/agent-tts/voices
cd ~/.cache/agent-tts/voices
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx.json
```

~63MB. The `.onnx.json` ships alongside — libpiper reads voice config (sample
rate, phoneme map, speaker count) from it when `config_path == NULL`.

### 5. Smoke test

```bash
cd 99-development/agent-tts
zig build -Doptimize=ReleaseFast -Dwith-piper=true
./zig-out/bin/agent-tts piper-test "Olá mundo, este é um teste do motor Piper." /tmp/v06-test.wav
afplay /tmp/v06-test.wav
```

Expected stdout looks like:

```
[piper-test] init=<X>ms synth+wav=<Y>ms out=/tmp/v06-test.wav
```

## Licenses (read before shipping)

- **libpiper** (OHF-Voice/piper1-gpl): **GPL-3.0**. Linking agent-tts against
  libpiper.dylib makes the combined binary GPL-3.0 when distributed. v1.0 brew
  tap distribution must inherit GPL or ship libpiper as a separate optional
  install. v0.6 does NOT distribute anything — local dev only.
- **espeak-ng** (vendored static): GPL-3.0. Same boat.
- **ONNX Runtime** (Microsoft): MIT. Permissive, no impact.
- **pt_BR-faber-medium voice model**: see the HuggingFace repo
  [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) for the
  trained-model license. The Faber dataset is itself permissive but always
  re-verify before redistributing.

Net: as long as v0.6 stays on your machine, GPL is not a concern. The first
public distribution (brew tap or otherwise) must pick a story — either
agent-tts goes GPL or the libpiper path becomes a separate user-installed
package.

## Why not just `brew install piper`?

There is no Homebrew formula for libpiper (the C library). The Homebrew
`piper-tts` formula is the Python CLI. We need the C ABI to do FFI, so we
build from source.

---

# v0.7+: `vendor/zaudio/` — miniaudio Zig wrapper

Source: [`zig-gamedev/zaudio`](https://github.com/zig-gamedev/zaudio)
Pinned commit: `e5b89fde58be72de359089e9b8f5c4d5126fb159`
(`Update miniaudio to v0.11.25`, miniaudio v0.11.25)

The exact SHA lives in `vendor/zaudio/COMMIT`. We vendor `src/zaudio.zig`,
`src/zaudio.c`, and `libs/miniaudio/{miniaudio.h, miniaudio.c}` directly into
the build (~100k LoC total — miniaudio is a single-header lib). Wired in
`build.zig` via `configureExe`.

## Reproduction recipe

```bash
cd /tmp
git clone --depth=1 https://github.com/zig-gamedev/zaudio.git zaudio-probe
cd zaudio-probe
git fetch --depth=1 origin e5b89fde58be72de359089e9b8f5c4d5126fb159
git checkout e5b89fde58be72de359089e9b8f5c4d5126fb159

# Copy required sources into vendor/zaudio/
cd <agent-tts>
mkdir -p vendor/zaudio/src vendor/zaudio/libs/miniaudio
cp /tmp/zaudio-probe/src/zaudio.zig vendor/zaudio/src/
cp /tmp/zaudio-probe/src/zaudio.c vendor/zaudio/src/
cp /tmp/zaudio-probe/libs/miniaudio/miniaudio.h vendor/zaudio/libs/miniaudio/
cp /tmp/zaudio-probe/libs/miniaudio/miniaudio.c vendor/zaudio/libs/miniaudio/
cp /tmp/zaudio-probe/LICENSE vendor/zaudio/LICENSE
echo "e5b89fde58be72de359089e9b8f5c4d5126fb159" > vendor/zaudio/COMMIT
```

## In-tree patches

After copying, apply the **Zig 0.16 compat patch** in
`vendor/zaudio/src/zaudio.zig` (~line 3160):

`std.Thread.Mutex` (used for `mem_mutex` in the malloc/realloc callback path)
was removed in Zig 0.16 and replaced by `std.Io.Mutex` (which needs an io
context — we don't carry one in the global allocator callbacks). We swap in a
hand-rolled `std.atomic.Value(bool)` spin lock. Contention is negligible in
practice: mem callbacks fire from the device thread plus a few engine-create
paths, never hot.

See the `AGENT-TTS PATCH (v0.7)` comment block in that file for the exact
diff. When upstream zaudio catches up to Zig 0.16 / `std.Io.Mutex` (track via
their `minimum_zig_version` field), drop this vendoring entirely and switch
to `zig fetch --save` in `build.zig.zon`.

## Why not use `build.zig.zon`?

Tried `zig fetch --save https://github.com/zig-gamedev/zaudio/archive/<commit>.tar.gz`
first. Upstream's `build.zig` calls `miniaudio_lib.linkLibC()` — an API
removed in Zig 0.16. Module-level `link_libc = true` is the new spelling.
Forking just to flip that one call seemed worse than vendoring the leaf
sources we already understood.

## License

zaudio + miniaudio are MIT. No GPL concern (unlike libpiper). When v1.0
distributes the binary, the LICENSE file at `vendor/zaudio/LICENSE` must be
included alongside (already vendored).
