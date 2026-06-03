# Homebrew formula for agent-tts — Pt-BR TTS CLI for macOS.
#
# Tap install path (placeholder — gabriel/tap is NOT yet published):
#   brew tap gabriel/tap https://github.com/gabriel/homebrew-tap
#   brew install gabriel/tap/agent-tts
#
# When the real tap repo lands, drop this formula into its `Formula/`
# directory unchanged. Until the v1.0 release tarball is published and
# its sha256 computed, `url` + `sha256` below are placeholders — `brew
# install` from this file will FAIL until they are replaced. The
# universal Mach-O artifact ships as `agent-tts-universal` from
# `zig build universal` (see ../README.md).
#
# Audit:
#   brew audit --strict --new agent-tts
#
class AgentTts < Formula
  desc "Pt-BR TTS CLI for macOS — daemon + queue + libpiper"
  homepage "https://github.com/gabriel/agent-tts"
  # placeholder until v1.0 release tarball lands — version 1.0.0 is in the URL.
  url "https://github.com/gabriel/agent-tts/releases/download/v1.0.0/agent-tts-1.0.0-universal.tar.gz"
  # placeholder — compute with `shasum -a 256 <tarball>` on the real release
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  # The shipped binary is a universal Mach-O (arm64 + x86_64) built with
  # `zig build universal`. `lipo -info` should report two architectures.
  depends_on macos: :ventura # libpiper / espeak-ng baseline; bump if needed.
  depends_on "sqlite"

  def install
    bin.install "agent-tts"
  end

  def caveats
    <<~EOS
      To start the daemon at login:
        agent-tts daemon install

      To remove it:
        agent-tts daemon uninstall

      Optional libpiper engine: build from source with
        zig build -Doptimize=ReleaseFast -Dwith-piper=true
      after building libpiper.dylib (see vendor/README.md in the repo).
    EOS
  end

  test do
    assert_match "agent-tts #{version}", shell_output("#{bin}/agent-tts --version")
  end
end
