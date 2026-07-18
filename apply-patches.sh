#!/usr/bin/env sh
set -eu

repo_root=${1:-.}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

git -C "$repo_root" apply --check "$script_dir/patches/0001-prefer-audio-languages.patch"
git -C "$repo_root" apply "$script_dir/patches/0001-prefer-audio-languages.patch"

echo "Applied preferred Spanish/Latin audio-track patch to $repo_root"
