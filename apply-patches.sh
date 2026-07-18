#!/usr/bin/env sh
set -eu

repo_root=${1:-.}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

python3 "$script_dir/apply_audio_language_patch.py" "$repo_root"

echo "Applied preferred Spanish/Latin audio-track support to $repo_root"
