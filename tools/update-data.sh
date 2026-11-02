#!/usr/bin/env bash
# Pull the upstream BIOS databases and regenerate tools/data/*.txt, then rebuild the script.
# Needs: git, jq, python3.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(mktemp -d); trap 'rm -rf "$src"' EXIT
mkdir -p "$here/data"
cd "$src"
git clone -q --depth 1 https://github.com/libretro/libretro-core-info.git coreinfo
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/libretro/libretro-database.git lrdb
git -C lrdb sparse-checkout set dat
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/stenzek/duckstation.git ds
git -C ds sparse-checkout set src/core
git clone -q --depth 1 https://github.com/RetroDECK/components.git rdcomp

python3 -I "$here/ra.py" coreinfo lrdb/dat/System.dat > "$here/data/ra.txt"
python3 -I "$here/ds.py" ds/src/core/bios.cpp > ds_bios.txt
for f in rdcomp/*/component_manifest.json rdcomp/archive_later/*/component_manifest.json; do
  jq -r --arg c "$(basename "$(dirname "$f")")" '[.. | objects | select(has("bios")) | .bios] | flatten | .[] | objects | select(has("filename"))
    | [$c, (.system|if type=="array" then join(",") else tostring end), .filename,
       (.md5|if type=="array" then join(",") else (.//"") end), (.paths|if type=="array" then join(",") else (.//"") end),
       (.required//""), (.description//"")] | @tsv' "$f" 2>/dev/null || true
done > rd_bios.tsv
python3 -I "$here/known.py" lrdb/dat/System.dat ds_bios.txt rd_bios.tsv > "$here/data/known.txt"
echo "data: $(wc -l < "$here/data/known.txt") known hashes, $(wc -l < "$here/data/ra.txt") core firmware rows"
bash "$here/build.sh"
