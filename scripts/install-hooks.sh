#!/usr/bin/env bash
# Install Ptah's tiered local-CI git hooks into .git/hooks/.
# Run once per clone: `bash scripts/install-hooks.sh`.
# Tiers (by speed): pre-commit (fast: fmt+guards) · pre-push (slow: build+test)
# · post-commit (log, optimistic). pre-commit/pre-push BLOCK; post-commit never does.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
for h in pre-commit pre-push post-commit; do
  install -m 0755 "scripts/hooks/$h" ".git/hooks/$h"
  echo "  ✓ .git/hooks/$h"
done
echo "✓ Ptah local CI installed (pre-commit · pre-push · post-commit)"
