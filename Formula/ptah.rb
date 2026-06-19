# Homebrew formula for ptah — Pt-BR TTS CLI for macOS.
#
# Tap install path (placeholder — biliboss/tap is NOT yet published):
#   brew tap biliboss/tap https://github.com/biliboss/homebrew-tap
#   brew install biliboss/tap/ptah
#
# When the real tap repo lands, drop this formula into its `Formula/`
# directory unchanged. Until the v1.0 release tarball is published and
# its sha256 computed, `url` + `sha256` below are placeholders — `brew
# install` from this file will FAIL until they are replaced. The
# universal Mach-O artifact ships as `ptah-universal` from
# `zig build universal` (see ../README.md).
#
# Audit:
#   brew audit --strict --new ptah
#
class Ptah < Formula
  desc "Pt-BR TTS CLI for macOS — Kokoro Dora, daemon + queue"
  homepage "https://github.com/biliboss/ptah"
  # placeholder until v1.0 release tarball lands — version 1.0.0 is in the URL.
  url "https://github.com/biliboss/ptah/releases/download/v1.0.0/ptah-1.0.0-universal.tar.gz"
  # placeholder — compute with `shasum -a 256 <tarball>` on the real release
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  # The shipped binary is a universal Mach-O (arm64 + x86_64) built with
  # `zig build universal`. `lipo -info` should report two architectures.
  depends_on macos: :ventura # Kokoro / espeak-ng baseline; bump if needed.
  depends_on "sqlite"

  def install
    bin.install "ptah"
  end

  def caveats
    <<~EOS
      To start the daemon at login:
        ptah daemon install

      To remove it:
        ptah daemon uninstall

    EOS
  end

  test do
    assert_match "ptah #{version}", shell_output("#{bin}/ptah --version")
  end
end
