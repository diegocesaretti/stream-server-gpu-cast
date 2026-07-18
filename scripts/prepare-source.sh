#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:-$repo_root/.work/stream-server}"
upstream_commit="$(tr -d '\r\n' < "$repo_root/UPSTREAM_COMMIT")"

rm -rf "$destination"
mkdir -p "$(dirname "$destination")"
git clone --filter=blob:none https://github.com/perpetus/stream-server.git "$destination"
git -C "$destination" checkout --detach "$upstream_commit"
cp "$repo_root/overrides/server/src/routes/casting.rs" \
   "$destination/server/src/routes/casting.rs"

echo "Prepared patched source at $destination"
echo "Upstream commit: $upstream_commit"
