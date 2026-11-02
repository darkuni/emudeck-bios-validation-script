#!/usr/bin/env bash
# Builds a fake Steam Deck home (EmuDeck layout) full of deliberate mistakes, swaps a few
# real reference hashes for the hashes of dummy files (no real BIOS needed), runs the
# checker and asserts that every mistake is caught. Needs: bash, md5sum, zip.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
H=$work/home; mkdir -p "$H"
bash "$here/make-mock-deck.sh" "$H"
m(){ printf '%s' "FAKE-$1" | md5sum | cut -c1-32; }
sed -e "s/490f666e1afb15b7362b406ed1cea246/$(m us5501)/g" -e "s/32736f17079d0b2b7024407c39bd3050/$(m eu5502)/g" \
    -e "s/8dd7d5296a650fac7319bce665a6a53c/$(m jp5500)/g" -e "s/8db2fbbac7413bf3e7154c1e0715e565/$(m ps2good)/g" \
    -e "s/85ec9ca47d8f6807718151cbcca8b964/$(m sat101)/g" -e "s/3240872c70984b6cbfda1586cab68dbe/$(m mpr17933)/g" \
    -e "s/ca30b50f880eb660a320674ed365ef7a/$(m fds)/g"     -e "s/11526d58d4c524daef7d5d677dc6b004/$(m neocdz)/g" \
    -e "s/196a5f59a13382c185636e691d6c323d/$(m mcpx11)/g" "$here/../deck-bios-check.sh" > "$work/t.sh"
out=$(HOME=$H bash "$work/t.sh" --no-color 2>&1); rc=$?
fail=0
expect(){ if grep -qF -- "$1" <<<"$out"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }
expect "regions covered: US ✔  EU ✔  JP ✔"
expect "wrong filename case: found bios/SCPH5502.BIN"
expect "but the right file is here: bios/ps1 jp.bin"
expect "bios_CD_U.bin is the WRONG file - it is actually: Saturn sega_101"
expect "but the right file is here: bios/saturn/mpr-17933.bin"
expect "ROMVER 0200AC20040614"
expect "MCPX boot ROM is the WRONG file"
expect "inside a SUB-folder"
expect "must be named exactly prod.keys"
expect "keys.txt MISSING and you have 1 encrypted"
expect "PS3 firmware NOT installed"
expect "Windows download junk"
expect "compressed BIOS"
expect "broken symlink: bios/eden/keys"
expect "no neogeo.zip next to them"
expect "Sega CD (genesis_plus_gx_libretro)"
[[ $rc == 1 ]] && echo "PASS  exit code 1" || { echo "FAIL  exit code $rc"; fail=1; }
# settings.sh with quotes in the middle of the value (real-world EmuDeck format)
Q=$work/q; mkdir -p "$Q/Emu Virtual/Emulation/bios" "$Q/.config/EmuDeck"
printf 'emulationPath="%s/Emu Virtual"/Emulation\nbiosPath="$emulationPath/bios"  # c\nromsPath="%s/Emu Virtual"/Emulation/roms\n' "$Q" "$Q" > "$Q/.config/EmuDeck/settings.sh"
qout=$(HOME=$Q bash "$work/t.sh" --no-color 2>&1)
if grep -qF "BIOS:    $Q/Emu Virtual/Emulation/bios" <<<"$qout" && ! grep -q "folder missing" <<<"$qout"; then echo "PASS  quoted settings.sh paths"; else echo "FAIL  quoted settings.sh paths"; echo "$qout" | head; fail=1; fi
((fail)) && { echo; echo "$out"; exit 1; }
echo "all checks passed"
