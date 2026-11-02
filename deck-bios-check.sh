#!/usr/bin/env bash
# =============================================================================
#  deck-bios-check.sh  -  BIOS / firmware / keys checker for the Steam Deck
# =============================================================================
#  Works with EmuDeck, RetroDECK, or any folder you point it at (--bios).
#
#  What it does (read-only unless you ask for a fix script):
#    * Finds your BIOS folder(s) from EmuDeck / RetroDECK settings
#    * MD5-hashes everything in the BIOS tree once, then for every emulator /
#      RetroArch core you actually have installed it checks:
#        - present + correct hash            -> OK
#        - present but wrong hash            -> tells you what the file REALLY is
#        - wrong upper/lower case filename   -> Linux is case-sensitive, fix given
#        - right file, wrong name/folder     -> finds it by hash, fix given
#        - missing                           -> tells you whether you NEED it
#    * "Need" is decided by your ROM folders: if roms/segacd has games and no
#      Sega CD BIOS is usable, that is a hard NEED. If the folder is empty it
#      only tells you what you'd need later.
#    * Special checks: Switch keys+firmware (yuzu forks + Ryujinx), PS3 firmware
#      (RPCS3, reads installed version), Vita3K firmware + fonts, xemu (MCPX,
#      flash, HDD image, reads xemu.toml), Cemu keys.txt, Dolphin IPL, melonDS,
#      Flycast, Neo Geo zip contents, RMG 64DD, shadPS4 modules.
#    * Hygiene scan: zipped BIOS that should be extracted, Windows
#      Zone.Identifier junk, 0-byte files, broken EmuDeck symlinks, etc.
#
#  Data sources (embedded below, no network needed at runtime):
#    libretro System.dat + libretro-core-info firmware tables, DuckStation's
#    PS1/PS2 BIOS database, EmuDeck checkBIOS.sh hash lists + wiki, RetroDECK
#    component manifests.
#
#  Usage:  bash deck-bios-check.sh [options]
#    --bios DIR          check this BIOS folder (skips EmuDeck/RetroDECK detection)
#    --roms DIR          ROM root used to decide what you NEED (with --bios)
#    --frontend NAME     only check: emudeck | retrodeck
#    --all               check every system/core, even ones not installed
#    -v, --verbose       also list optional files
#    --unknown           list files in the BIOS folder that match nothing known
#    --fix-script FILE   write the suggested fix commands to FILE (never run)
#    --max-hash-mb N     skip hashing files bigger than N MiB (default 64)
#    --no-color          plain output      --ascii   no unicode symbols
#    -h, --help
#
#  Exit code: 0 = nothing blocking, 1 = something you NEED is missing, 2 = error
# =============================================================================

VERSION="1.0.1"
set -u
shopt -s nullglob extglob

if ((BASH_VERSINFO[0] < 4)); then
  echo "This script needs bash 4 or newer." >&2; exit 2
fi

# ----------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------
OPT_BIOS="" OPT_ROMS="" OPT_FRONTEND="" OPT_ALL=0 OPT_VERBOSE=0 OPT_UNKNOWN=0
OPT_FIXSCRIPT="" OPT_MAXMB=64 OPT_COLOR=1 OPT_ASCII=0

usage() { sed -n '/^#  Usage:/,/^#  Exit code/p' "$0" | sed -E 's/^# ?//'; }

while (($#)); do
  case "$1" in
    --bios) OPT_BIOS="${2:-}"; shift ;;
    --roms) OPT_ROMS="${2:-}"; shift ;;
    --frontend) OPT_FRONTEND="${2,,}"; shift ;;
    --all) OPT_ALL=1 ;;
    -v|--verbose) OPT_VERBOSE=1 ;;
    --unknown) OPT_UNKNOWN=1 ;;
    --fix-script) OPT_FIXSCRIPT="${2:-}"; shift ;;
    --max-hash-mb) OPT_MAXMB="${2:-64}"; shift ;;
    --no-color) OPT_COLOR=0 ;;
    --ascii) OPT_ASCII=1 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done
[[ -t 1 ]] || OPT_COLOR=0

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if ((OPT_COLOR)); then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[34m' C_C=$'\e[36m'
  C_M=$'\e[35m' C_D=$'\e[2m' C_BOLD=$'\e[1m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_M="" C_D="" C_BOLD="" C_0=""
fi
if ((OPT_ASCII)); then
  S_OK="[ OK ]" S_BAD="[NEED]" S_WARN="[WARN]" S_INFO="[info]" S_FIX="[FIX ]" S_OPT="[ -- ]" S_DOT="*"
else
  S_OK="✔" S_BAD="✘" S_WARN="⚠" S_INFO="•" S_FIX="↪" S_OPT="·" S_DOT="•"
fi

NEEDS=() WARNS=() FIXES=()
CNT_OK=0 CNT_NEED=0 CNT_WARN=0

hdr()   { PENDING=""; printf '\n%s%s== %s ==%s%s\n' "$C_BOLD" "$C_B" "$1" "$C_0" "$( ((NOTINST)) && printf ' %s(not installed - shown because of --all)%s' "$C_D" "$C_0")"; }
PENDING=""
sub()   { PENDING=$(printf '\n  %s%s%s%s' "$C_BOLD" "$1" "$C_0" "${2:+ $C_D$2$C_0}"); }
subnow(){ sub "$@"; pflush; }
pflush(){ [[ -n $PENDING ]] && { printf '%s\n' "$PENDING"; PENDING=""; }; return 0; }
l_ok()  { pflush; printf '    %s%s%s %s\n' "$C_G" "$S_OK" "$C_0" "$1"; }
l_bad() { pflush; printf '    %s%s %s%s\n' "$C_R" "$S_BAD" "$1" "$C_0"; }
l_warn(){ pflush; printf '    %s%s%s %s\n' "$C_Y" "$S_WARN" "$C_0" "$1"; }
l_info(){ pflush; printf '    %s%s %s%s\n' "$C_D" "$S_INFO" "$1" "$C_0"; }
l_opt() { pflush; printf '    %s%s %s%s\n' "$C_D" "$S_OPT" "$1" "$C_0"; }
l_fix() { pflush; printf '      %s%s %s%s\n' "$C_C" "$S_FIX" "$1" "$C_0"; }
l_sub() { pflush; printf '      %s%s%s\n' "$C_D" "$1" "$C_0"; }

# Needs are recorded per system key (rom folder). If ANY emulator/core for that
# system turns out to be ready, the other emulators' gaps become warnings.
declare -A SAT PNEED CORE_HAS CORE_FAIL
CUR_KEY=""
NOTINST=0
add_need() {
  if ((NOTINST)); then add_warn "$1  (emulator not installed)"; return; fi
  local k=${2:-$CUR_KEY}; k=${k:-_}; PNEED[$k]+="$1"$'\n'
}
mark_ok()  { local k; for k in ${1//,/ }; do SAT[$k]=1; done; }
resolve_needs() {
  local k line
  for k in "${!PNEED[@]}"; do
    while IFS= read -r line; do
      [[ -z $line ]] && continue
      if [[ $k != _ && -n ${SAT[${k%%,*}]:-} ]]; then add_warn "$line  (not blocking: another emulator for this system is ready)"
      else NEEDS+=("$line"); ((CNT_NEED++)); fi
    done <<<"${PNEED[$k]}"
  done
  PNEED=()
}
add_warn() { WARNS+=("$1"); ((CNT_WARN++)); }
add_fix()  { local f; for f in "${FIXES[@]}"; do [[ $f == "$1" ]] && return; done; FIXES+=("$1"); }

q() { printf '%q' "$1"; }                       # shell-quote for fix commands
short() {                                       # shorten paths for display
  local p=$1
  [[ -n ${BIOS:-} && $p == "$BIOS"/* ]] && { printf 'bios/%s' "${p#"$BIOS"/}"; return; }
  [[ $p == "$HOME"/* ]] && { printf '~/%s' "${p#"$HOME"/}"; return; }
  printf '%s' "$p"
}
fsize() { stat -Lc %s -- "$1" 2>/dev/null || echo 0; }
human() { local b=$1; if ((b>=1048576)); then printf '%d MiB' $((b/1048576)); elif ((b>=1024)); then printf '%d KiB' $((b/1024)); else printf '%d B' "$b"; fi; }
expand_path() {                                  # expand ~ and $HOME in config values
  local p=$1
  p=${p/#\~/$HOME}; p=${p//\$HOME/$HOME}; p=${p//\$\{HOME\}/$HOME}
  printf '%s' "$p"
}
glob_esc() { local s=$1; s=${s//\\/\\\\}; s=${s//\[/\\[}; s=${s//\]/\\]}; s=${s//\*/\\*}; s=${s//\?/\\?}; printf '%s' "$s"; }
in_list() { local n=$1; shift; local x; for x; do [[ $x == "$n" ]] && return 0; done; return 1; }

# ----------------------------------------------------------------------------
# Embedded data: known hashes  (md5|TAG|REGION|description)
#   TAG: PS1 PS2 SAT SCD DC DCF NDS DSI GC XBOX XBOXBAD FDS GB GBC GBA LIB
# ----------------------------------------------------------------------------
declare -A K_TAG K_REG K_DESC
load_known() {
  local h t r d
  while IFS='|' read -r h t r d; do
    [[ -z $h || $h == \#* ]] && continue
    K_TAG[$h]=$t; K_REG[$h]=$r; K_DESC[$h]=$d
  done <<'@@KNOWN_END@@'
d407fcf70b56acb84b8c77c93b0e5327|DC|ALL|Dreamcast BIOS (alt revision)
93a9766f14159b403178ac77417c6b68|DC|ALL|Dreamcast BIOS (alt revision)
e10c53c2f8b90bab96ead2d368858623|DC|ALL|Dreamcast BIOS (dc_boot.bin)
0a93f7940c455905bea6e392dfde92a4|DCF|ALL|Dreamcast flash (dc_flash.bin)
559dae4ea78eb9d67702c56c1d791e81|DSI|ALL|DSi ARM7 BIOS (dsi_bios7.bin)
87b665fce118f76251271c3732532777|DSI|ALL|DSi ARM9 BIOS (dsi_bios9.bin)
ca30b50f880eb660a320674ed365ef7a|FDS|ALL|Famicom Disk System BIOS (disksys.rom)
32fbbd84168d3482956eb3c5051637f5|GB|ALL|Game Boy boot ROM (gb_bios.bin)
a860e8c0b6d573d191e4ec7db1b1e4f6|GBA|ALL|Game Boy Advance BIOS (gba_bios.bin)
dbfce9db9deaa2567f6a84fde55f9680|GBC|ALL|Game Boy Color boot ROM (gbc_bios.bin)
fc924a7c879b661abc37cec4f018fdf3|GC|US|GameCube IPL NTSC v1.0
019e39822a9ca3029124f74dd4d55ac4|GC|US|GameCube IPL NTSC v1.1
b17148254a5799684c7d783206504926|GC|US|GameCube IPL NTSC v1.2
0cdda509e2da83c85bfe423dd87346cc|GC|EU|GameCube IPL PAL v1.0
339848a0b7c2124cf155276c1e79cbd0|GC|EU|GameCube IPL PAL v1.1
db92574caab77a7ec99d4605fd6f2450|GC|EU|GameCube IPL PAL v1.2
1f118b8735fcf40c20b38c3184eebfd9|GC|-|Nintendo - GameCube: dolphin-emu/Sys/codehandler.bin
561532ad496f644897952d2cef5bb431|GC|-|Nintendo - GameCube: gc-dvd-20010608.bin
b953eb1a8fc9922b3f7051c1cdc451f1|GC|-|Nintendo - GameCube: gc-dvd-20010831.bin
413154dd0e2c824c9b18b807fd03ec4e|GC|-|Nintendo - GameCube: gc-dvd-20020402.bin
c03f6bbaf644eb9b3ee261dbe199eb42|GC|-|Nintendo - GameCube: gc-dvd-20020823.bin
8970fc987ab89a7f64da9f8a8c4333ff|LIB|-|3DO Company, The - 3DO: 3do_arcade_saot.bin
8639fd5e549bd6238cfee79e3e749114|LIB|-|3DO Company, The - 3DO: goldstar.bin
b8dc97f778a6245c58e064b0312e8281|LIB|-|3DO Company, The - 3DO: panafz1-kanji.bin
f47264dd47fe30f73ab3c010015c155b|LIB|-|3DO Company, The - 3DO: panafz1.bin
1477bda80dc33731a65468c1f5bcbee9|LIB|-|3DO Company, The - 3DO: panafz10-norsa.bin
51f2f43ae2f3508a14d9f56597e2d3ce|LIB|-|3DO Company, The - 3DO: panafz10.bin
cf11bbb5a16d7af9875cca9de9a15e09|LIB|-|3DO Company, The - 3DO: panafz10e-anvil-norsa.bin
a48e6746bd7edec0f40cff078f0bb19f|LIB|-|3DO Company, The - 3DO: panafz10e-anvil.bin
428577250f43edc902ea239c50d2240d|LIB|-|3DO Company, The - 3DO: panafz10ja-anvil-kanji.bin
c23fb5d5e6bb1c240d02cf968972be37|LIB|-|3DO Company, The - 3DO: panafz1j-kanji.bin
f6c71de7470d16abe4f71b1444883dc8|LIB|-|3DO Company, The - 3DO: panafz1j-norsa.bin
a496cfdded3da562759be3561317b605|LIB|-|3DO Company, The - 3DO: panafz1j.bin
35fa1a1ebaaeea286dc5cd15487c13ea|LIB|-|3DO Company, The - 3DO: sanyotry.bin
a993f85b88ac4350cf4d41554e87fe4f|LIB|-|Amstrad - CPC: ep128emu/roms/cpc464.rom
b96280dc6c95a48857b4b8eb931533ae|LIB|-|Amstrad - CPC: ep128emu/roms/cpc6128.rom
5a384a2310f472c7857888371c00ed66|LIB|-|Amstrad - CPC: ep128emu/roms/cpc664.rom
25629dfe870d097469c217b95fdc1c95|LIB|-|Amstrad - CPC: ep128emu/roms/cpc_amsdos.rom
9d2ff2333e23910cf56f7f785609d36a|LIB|-|Arcade: aes.zip
f81298afd68a1a24a49a1a2d9f087964|LIB|-|Arcade: fbneo/bubsys.zip
df6f8a3d83c028a5cb9f2f2be60773f3|LIB|-|Arcade: fbneo/cchip.zip
2f2f8de3827ae1faf2495e497ca95232|LIB|-|Arcade: fbneo/channelf.zip
94915714a814a84f7c292e6db71f3ad2|LIB|-|Arcade: fbneo/coleco.zip
b7e1189b341bf6a8e270017c096d21b0|LIB|-|Arcade: fbneo/decocass.zip
c26bf1744cb7f6ffe441f463870321f8|LIB|-|Arcade: fbneo/fdsbios.zip
37fc4e050b53a1ef2c2e7f3042553025|LIB|-|Arcade: fbneo/hiscore.dat
4a56d56e2219c5e2b006b66a4263c01c|LIB|-|Arcade: fbneo/isgsm.zip
5904b0de768d1d506e766aa7e18994c1|LIB|-|Arcade: fbneo/midssio.zip
25a8912d7bf3cdad9beaa6d5cc14ea38|LIB|-|Arcade: fbneo/msx.zip
ad9af7a9560cad74f1644328213748f6|LIB|-|Arcade: fbneo/namcoc69.zip
aa569a303793510b2b4173480148de4b|LIB|-|Arcade: fbneo/namcoc70.zip
17516c33298e52424ffb58afc2ad208c|LIB|-|Arcade: fbneo/namcoc75.zip
62d56b126e78f3d82faa4ee8a92c3e82|LIB|-|Arcade: fbneo/neocdz.zip
5bc25f80395a68790a69b7eb3e57b897|LIB|-|Arcade: fbneo/ngp.zip
bfacf1a68792d5348f93cf724d2f1dda|LIB|-|Arcade: fbneo/nmk004.zip
87cc944eef4c671aa2629a8ba48a08e0|LIB|-|Arcade: fbneo/pgm.zip
3f956c4e7008804cb47cbde49bd5b908|LIB|-|Arcade: fbneo/skns.zip
1a524bfa489cec90c941e6587d553a56|LIB|-|Arcade: fbneo/spec128.zip
b2fed9c6a9e54af7d90b6f2b3516fcf9|LIB|-|Arcade: fbneo/spec1282a.zip
4698414be3369fff17bf6d3111734c6c|LIB|-|Arcade: fbneo/spectrum.zip
79ae0d2bb1901b7e606b6dc339b79a97|LIB|-|Arcade: fbneo/ym2608.zip
00dad01abdbf8ea9e79ad2fe11bdb182|LIB|-|Arcade: neogeo.zip
0bac0c6a50104045d902df4503a4c30b|LIB|-|Atari - 400-800: ATARIBAS.ROM
eb1f32f5d9f382db1bbfb8d7f9cb343a|LIB|-|Atari - 400-800: ATARIOSA.ROM
a3e8d617c95d08031fe1b20d541434b2|LIB|-|Atari - 400-800: ATARIOSB.ROM
06daac977823773a3eea3422fd26a703|LIB|-|Atari - 400-800: ATARIXL.ROM
b7a2a04677d34f069eeb643d5238bf86|LIB|-|Atari - 400-800: BB01R4_OS.ROM
d7eb37aec6960cba36bc500e0e5d00bc|LIB|-|Atari - 400-800: XEGAME.ROM
281f20ea4320404ec820fb7ec0693b38|LIB|-|Atari - 5200: 5200.rom
397bb566584be7b9764e7a68974c4263|LIB|-|Atari - 7800: 7800 BIOS (E).rom
0763f1ffb006ddbe32e52d497ee848ae|LIB|-|Atari - 7800: 7800 BIOS (U).rom
fcd403db69f54290b51035d82f835e7b|LIB|-|Atari - Lynx: lynxboot.img
c1c57ce48e8ee4135885cee9e63a68a2|LIB|-|Atari - ST: tos.img
3b1ef759d8e3fb4071582efd33dd05f9|LIB|-|Coleco - ColecoVision: bioscv.rom
2c66f5911e5b42b8ebe113403548eee7|LIB|-|Coleco - ColecoVision: colecovision.rom
85ad74194e87c08904327de1a9443b7a|LIB|-|Commodore - Amiga: kick33180.A500
82a21c1890cae844b3df741f2762d48d|LIB|-|Commodore - Amiga: kick34005.A500
89da1838a24460e4b93f4f0c5d92d48d|LIB|-|Commodore - Amiga: kick34005.CDTV
dc10d7bdd1b6f450773dfb558477c230|LIB|-|Commodore - Amiga: kick37175.A500
465646c9b6729f77eea5314d1f057951|LIB|-|Commodore - Amiga: kick37350.A600
b7cc148386aa631136f510cd29e42fc3|LIB|-|Commodore - Amiga: kick39106.A1200
9b8bdd5a3fd32c2a5a6f5b1aefc799a5|LIB|-|Commodore - Amiga: kick39106.A4000
5f8924d013dd57a89cf349f4cdedc6b1|LIB|-|Commodore - Amiga: kick40060.CD32
bb72565701b1b6faece07d68ea5da639|LIB|-|Commodore - Amiga: kick40060.CD32.ext
e40a5dfb3d017ba8779faba30cbd1c8e|LIB|-|Commodore - Amiga: kick40063.A600
646773759326fbac3b2311fd8c8793ee|LIB|-|Commodore - Amiga: kick40068.A1200
9bdedde6a4f33555b4a270c8ca53297d|LIB|-|Commodore - Amiga: kick40068.A4000
1b1e985ea5325a1f46eb7fd9681707bf|LIB|-|Commodore - C128: vice/JiffyDOS_1541-II.bin
41c6cc528e9515ffd0ed9b180f8467c0|LIB|-|Commodore - C128: vice/JiffyDOS_1571_repl310654.bin
20b6885c6dc2d42c38754a365b043d71|LIB|-|Commodore - C128: vice/JiffyDOS_1581.bin
cbbd1bbcb5e4fd8046b6030ab71fc021|LIB|-|Commodore - C128: vice/JiffyDOS_C128.bin
be09394f0576cf81fa8bacf634daf9a2|LIB|-|Commodore - C128: vice/JiffyDOS_C64.bin
bfff32b6144c1d706109accb6e6b1113|LIB|-|DOS: CM32L_CONTROL.ROM
08cdcfa0ed93e9cb16afa76e6ac5f0a4|LIB|-|DOS: CM32L_PCM.ROM
5626206284b22c2734f3e9efefcd2675|LIB|-|DOS: MT32_CONTROL.ROM
89e42e386e82e0cacb4a2704a03706ca|LIB|-|DOS: MT32_PCM.ROM
7253a9fabc089044b3b8e9156b07d6f9|LIB|-|DOS: bass.dll
0b00a4ab6b68960efa49272d416b040d|LIB|-|DOS: bassmidi.dll
19addeb0da536c753797ed59b44d5ba3|LIB|-|DOS: libbass.dylib
255fb8ab523b179320f08f44db36a9fa|LIB|-|DOS: libbass.so
ea143b23779d01152633442abb1e0c67|LIB|-|DOS: libbassmidi.dylib
3a48c08c224c32f2f4829b960e95f73b|LIB|-|DOS: libbassmidi.so
a2e891e330d146c4046c2b622fc31462|LIB|-|Dinothawr: Dinothawr.zip
635a978fd40db9a18ee44eff449fc126|LIB|-|EPOCH/YENO Super Cassette Vision: upd7801g.s01
fe4627d1e3a1535874085050733263e7|LIB|-|Elektronika - BK-0010/BK-0011(M): bk/B11M_BOS.ROM
dc52f365d56fa1951f5d35b1101b9e3f|LIB|-|Elektronika - BK-0010/BK-0011(M): bk/B11M_EXT.ROM
946f6f23ded03c0e26187f0b3ca75993|LIB|-|Elektronika - BK-0010/BK-0011(M): bk/BAS11M_0.ROM
1e6637f32aa7d1de03510030cac40bcf|LIB|-|Elektronika - BK-0010/BK-0011(M): bk/BAS11M_1.ROM
3fa774326d75410a065659aea80252f0|LIB|-|Elektronika - BK-0010/BK-0011(M): bk/BASIC10.ROM
5015228eeeb238e65da8edcd1b6dfac7|LIB|-|Elektronika - BK-0010/BK-0011(M): bk/DISK_327.ROM
5737f972e8638831ab71e9139abae052|LIB|-|Elektronika - BK-0010/BK-0011(M): bk/FOCAL10.ROM
95f8c41c6abf7640e35a6a03cecebd01|LIB|-|Elektronika - BK-0010/BK-0011(M): bk/MONIT10.ROM
8e18edce4a7acb2c33cc0ab18f988482|LIB|-|Enterprise - 64/128: ep128emu/roms/basic20.rom
e972fe42b398c9ff1d93ff014786aec6|LIB|-|Enterprise - 64/128: ep128emu/roms/basic21.rom
6af0402906944fd134004b85097c8524|LIB|-|Enterprise - 64/128: ep128emu/roms/brd.rom
12cfc9c7e48c8a16c2e09edbd926d467|LIB|-|Enterprise - 64/128: ep128emu/roms/epd19hft.rom
a68ebcbc73a4d2178d755b7755bf18fe|LIB|-|Enterprise - 64/128: ep128emu/roms/epfileio.rom
ddff70c014d1958dc75378b6c9aab6f8|LIB|-|Enterprise - 64/128: ep128emu/roms/exdos13.rom
5ad3baaad3b5156d6b60b34229a676fb|LIB|-|Enterprise - 64/128: ep128emu/roms/exos20.rom
f36f24cbb87745fbd2714e4df881db09|LIB|-|Enterprise - 64/128: ep128emu/roms/exos21.rom
55af78f877a21ca45eb2df68a74fcc60|LIB|-|Enterprise - 64/128: ep128emu/roms/exos24uk.rom
22167938f142c222f40992839aa21a06|LIB|-|Enterprise - 64/128: ep128emu/roms/hun.rom
653daaf7b9b29c2c4e577f489580f247|LIB|-|Enterprise - 64/128: ep128emu/roms/zt19hfnt.rom
228540b6be83ae2acd7569c8ff0f91d0|LIB|-|Enterprise - 64/128: ep128emu/roms/zt19uk.rom
3082dc488d32f30a612761b99074199b|LIB|-|Enterprise - 64/128: zt18hfnt.rom
ac9804d4c0e9d07e33472e3726ed15c3|LIB|-|Fairchild Channel F: sl31253.bin
da98f4bb3242ab80d76629021bb27585|LIB|-|Fairchild Channel F: sl31254.bin
95d339631d867c8f1d15a5f2ec26069d|LIB|-|Fairchild Channel F: sl90025.bin
ecae5c55d75a2fe0871d0ebd95663628|LIB|-|Galaksija: galaksija/CHRGEN.BIN
c7ce14d6a81062db862f3ce5afedcfb6|LIB|-|Galaksija: galaksija/ROM1.BIN
b406d05922dac2eaf3c2e68157b1b468|LIB|-|Galaksija: galaksija/ROM2.BIN
72ae1b47820fcc93cc0df9c428d0face|LIB|-|Id Software - Doom: prboom.wad
ccd92e7156ce2f0ce14c88ffb68a16eb|LIB|-|J2ME: freej2me-lr.jar
4da74084fc1b1bd3d776ed8d3ee648de|LIB|-|J2ME: freej2me-sdl.jar
29a92d0867da2917275b7c6c805d256f|LIB|-|J2ME: freej2me.jar
8e98b0c8e5c96c191a8b2a9d29d0454b|LIB|-|J2ME: squirreljme-0.3.0-fast.jar
cf849d4b36cd8b7782de7887d318182a|LIB|-|J2ME: squirreljme.jar
66223be1497460f1e60885eeb35e03cc|LIB|-|MacII: MacII.ROM
f1071cdb0b6b10dde94d3bc8a6146387|LIB|-|Magnavox - Odyssey2: c52.bin
c500ff71236068e0dc0d0603d265ae76|LIB|-|Magnavox - Odyssey2: g7400.bin
279008e4a0db2dc5f1c048853b033828|LIB|-|Magnavox - Odyssey2: jopac.bin
562d5ebf9e030a40d6fabfc2f33139fd|LIB|-|Magnavox - Odyssey2: o2rom.bin
62e761035cb657903761800f4437b8af|LIB|-|Mattel - Intellivision: exec.bin
0cd5946c6473e42e8e4c2137785e427f|LIB|-|Mattel - Intellivision: grom.bin
74b0f217fa0e2b8bb5a2f8e2ecc69da3|LIB|-|Microsoft - MSX: CARTS.SHA
85b38e4128bbc300e675f55b278683a8|LIB|-|Microsoft - MSX: CYRILLIC.FNT
80dcd1ad1a4cf65d64b7ba10504e8190|LIB|-|Microsoft - MSX: DISK.ROM
c0a94965701431e0df29949189e424dd|LIB|-|Microsoft - MSX: Databases/msxromdb.xml
6f69cc8b5ed761b03afd78000dfb0e19|LIB|-|Microsoft - MSX: FMPAC.ROM
af8537262df8df267072f359399a7635|LIB|-|Microsoft - MSX: FMPAC16.ROM
c83e50e9f33b8dd893c414691822740d|LIB|-|Microsoft - MSX: ITALIC.FNT
febe8782b466d7c3b16de6d104826b34|LIB|-|Microsoft - MSX: KANJI.ROM
aa95aea2563cd5ec0a0919b44cc17d47|LIB|-|Microsoft - MSX: MSX.ROM
ec3a01c91f24fbddcbcab0ad301bc9ef|LIB|-|Microsoft - MSX: MSX2.ROM
2183c2aff17cf4297bdb496de78c2e8a|LIB|-|Microsoft - MSX: MSX2EXT.ROM
6d8c0ca64e726c82a4b726e9b01cdf1e|LIB|-|Microsoft - MSX: MSX2P.ROM
7c8243c71d8f143b2531f01afa6a05dc|LIB|-|Microsoft - MSX: MSX2PEXT.ROM
6418d091cd6907bbcf940324339e43bb|LIB|-|Microsoft - MSX: MSXDOS2.ROM
364a1a579fe5cb8dba54519bcfcdac0d|LIB|-|Microsoft - MSX: Machines/Shared Roms/MSX.rom
403cdea1cbd2bb24fae506941f8f655e|LIB|-|Microsoft - MSX: PAINTER.ROM
279efd1eae0d358eecd4edc7d9adedf3|LIB|-|Microsoft - MSX: RS232.ROM
6d2cb14fc3e1f65ceb135633d1694122|LIB|-|NEC - PC Engine - TurboGrafx 16 - SuperGrafx: gecard.pce
2b7ccb3d86baa18f6402c176f3065082|LIB|-|NEC - PC Engine - TurboGrafx 16 - SuperGrafx: syscard1.pce
3cdd6614a918616bfc41c862e889dd79|LIB|-|NEC - PC Engine - TurboGrafx 16 - SuperGrafx: syscard2.pce
94279f315e8b52904f65ab3108542afe|LIB|-|NEC - PC Engine - TurboGrafx 16 - SuperGrafx: syscard2u.pce
38179df8f4ac870017db21ebcbf53114|LIB|-|NEC - PC Engine - TurboGrafx 16 - SuperGrafx: syscard3.pce
0754f903b52e3b3342202bdafb13efa5|LIB|-|NEC - PC Engine - TurboGrafx 16 - SuperGrafx: syscard3u.pce
793f86784e5608352a5d7f03f03e0858|LIB|-|NEC - PC-8801: quasi88/disk.rom
4f984e04a99d56c4cfe36115415d6eb8|LIB|-|NEC - PC-8801: quasi88/n88.rom
e28fe3f520bea594350ea8fb00395370|LIB|-|NEC - PC-8801: quasi88/n88_0.rom
a8e298da7ac947669bcb1ff25cee0a83|LIB|-|NEC - PC-8801: quasi88/n88_1.rom
9d03154fd9abfc28c4e6d4dc705e6e23|LIB|-|NEC - PC-8801: quasi88/n88_2.rom
e1791f8154f1cdf22b576a1a365b6e1f|LIB|-|NEC - PC-8801: quasi88/n88_3.rom
2e548679423370262f36cbde38a22789|LIB|-|NEC - PC-8801: quasi88/n88jisho.rom
d81c6d5d7ad1a4bbbd6ae22a01257603|LIB|-|NEC - PC-8801: quasi88/n88knj1.rom
898a3b7b6c3326e8b2069765bca2b944|LIB|-|NEC - PC-8801: quasi88/n88knj2.rom
2ff07b8769367321128e03924af668a0|LIB|-|NEC - PC-8801: quasi88/n88n.rom
d94546e70f17fd899be8df3544ab6cbb|LIB|-|NEC - PC-98: np2kai/2608_BD.WAV
08c54a0c1f774a5538a848a6665a34b4|LIB|-|NEC - PC-98: np2kai/2608_HH.WAV
465ea0768b27da404aec45dfc501404b|LIB|-|NEC - PC-98: np2kai/2608_RIM.WAV
d71004351c8bbfdad53b18222c061d49|LIB|-|NEC - PC-98: np2kai/2608_SD.WAV
96a4ead13f364734f79b0c58af2f0e1f|LIB|-|NEC - PC-98: np2kai/2608_TOM.WAV
593cff6597ab9380d822b8f824fd2c28|LIB|-|NEC - PC-98: np2kai/2608_TOP.WAV
38d32748ae49d1815b0614970849fd40|LIB|-|NEC - PC-98: np2kai/FONT.ROM
cd237e16e7e77c06bb58540e9e9fca68|LIB|-|NEC - PC-98: np2kai/bios.rom
7da1e5b7c482d4108d22a5b09631d967|LIB|-|NEC - PC-98: np2kai/font.bmp
72ea51443070f0e9212bfc9b793ee28e|LIB|-|NEC - PC-98: np2kai/itf.rom
524473c1a5a03b17e21d86a0408ff827|LIB|-|NEC - PC-98: np2kai/sound.rom
430e9745f9235c515bc8e652d6ca3004|LIB|-|NEC - PC-FX: fx-scsi.rom
08e36edbea28a017f79f8d4f7ff9b6d7|LIB|-|NEC - PC-FX: pcfx.rom
5885bc9a64bf80d4530b9b9b978ff587|LIB|-|NEC - PC-FX: pcfxga.rom
e2fb7c7220e3a7838c2dd7e401a7f3d8|LIB|-|NEC - PC-FX: pcfxv101.bin
7f98d77d7a094ad7d069b74bd553ec98|LIB|-|Nintendo - Famicom Disk System: gamegenie.nes
8d3d9f294b6e174bc7b1d2fd1c727530|LIB|-|Nintendo - Nintendo 64DD: 64DD_IPL.bin
7bfe8c0540ed4bd6a0f1e2a0f0118ced|LIB|-|Nintendo - Nintendo Entertainment System: NstDatabase.xml
1e4fb124a3a886865acb574f388c803d|LIB|-|Nintendo - Pokemon Mini: bios.min
4ed9648505ab33a4daec93707b16caba|LIB|-|Nintendo - Satellaview: BS-X (En) (DRM-Free).bin
33b62505da6ca4525e3839db4e1a7bca|LIB|-|Nintendo - Satellaview: BS-X (En).bin
fed4d8242cfbed61343d53d48432aced|LIB|-|Nintendo - Satellaview: BS-X.bin
d3a44ba7d42a74d3ac58cb9c14c6a5ca|LIB|-|Nintendo - SuFami Turbo: STBIOS.bin
b15ddb15721c657d82c5bab6db982ee9|LIB|-|Nintendo - Super Game Boy: SGB1.sfc
8ecd73eb4edf7ed7e81aef1be80031d5|LIB|-|Nintendo - Super Game Boy: SGB2.sfc
e0430bca9925fb9882148fd2dc2418c1|LIB|-|Nintendo - Super Game Boy: sgb2_bios.bin
d574d4f9c12f305074798f54c091a8b4|LIB|-|Nintendo - Super Game Boy: sgb_bios.bin
037ac4296b6b6a5c47c440188d3c72e3|LIB|-|Nintendo - Super Nintendo Entertainment System: cx4.data.rom
3d81b45fa0c2aa8b852dfb1ece7c0971|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp1.data.rom
ae209fbe789fbf11a48aea5ab1197321|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp1.program.rom
1e3f568634a7d8284020dddc0ae905bc|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp1b.data.rom
d10f446888e097cbf500f3f663cf4f6d|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp1b.program.rom
e9417e29223b139c3c4b635a2a3b8744|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp2.data.rom
aa6e5922a3ed5ded54f24247c11143c5|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp2.program.rom
0a81210c0a940b997dd9843281008ee6|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp3.data.rom
d99ca4562818d49cee1f242705bba6f8|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp3.program.rom
ee4990879eb68e3cbca239c5bc20303d|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp4.data.rom
a151023b948b90ffc23a5b594bb6fef2|LIB|-|Nintendo - Super Nintendo Entertainment System: dsp4.program.rom
254d70762b6f59f99c27c395aba7d07d|LIB|-|Nintendo - Super Nintendo Entertainment System: st010.data.rom
1d70019179a59a566a0bb5d3f2845544|LIB|-|Nintendo - Super Nintendo Entertainment System: st010.program.rom
10bd3f4aa949737ab9836512c35bcc29|LIB|-|Nintendo - Super Nintendo Entertainment System: st011.data.rom
95222ebf1c0c2990bcf25db43743f032|LIB|-|Nintendo - Super Nintendo Entertainment System: st011.program.rom
49c898b60d0f15e90d0ba780dd12f366|LIB|-|Nintendo - Super Nintendo Entertainment System: st018.data.rom
dda40ccd57390c96e49d30a041f9a9e7|LIB|-|Nintendo - Super Nintendo Entertainment System: st018.program.rom
9da101cd2317830649a31f8fa46debec|LIB|-|Palm OS: bootloader-dbvz.rom
abed11421f47bbf3f654af618e0c6a8a|LIB|-|Palm OS: palmos40-en-m500.rom
83cb1d1c76e568b916dc2e7c0bf669f6|LIB|-|Palm OS: palmos41-en-m515.rom
a46861541c63b20aba7bf172b0d853e1|LIB|-|Palm OS: palmos52-en-t3.rom
c2fae3ff41cc4f94be0fdaed1523ea99|LIB|-|Palm OS: palmos60-en-t3.rom
2969341396aa61e0143dc2351aaa6ef6|LIB|-|Philips - CD-i: cdi200.rom
ac0d468be366779c9df633be98da250a|LIB|-|Philips - CD-i: cdi220b.rom
801c529739b83e1490b897f2d3ffbb3a|LIB|-|Philips - CD-i: cdimono1.zip
709acce6e9c4043b851ea7429b8e7eff|LIB|-|Philips - CD-i: same_cdi/bios/cdibios.zip
c59f92647701428bc453976740eb75cf|LIB|-|Philips - CD-i: same_cdi/bios/cdimono1.zip
97aa5f47030cd9fdb679d4fafbb0e332|LIB|-|Philips - CD-i: same_cdi/bios/cdimono2.zip
53ba3bf7443187a657baa272d01d3771|LIB|-|Philips - CD-i: vmpega.rom
fc7599f3f871578fe9a0453662d1c966|LIB|-|SNK - NeoGeo CD: neocd/000-lo.lo
5c2366f25ff92d71788468ca492ebeca|LIB|-|SNK - NeoGeo CD: neocd/front-sp1.bin
f39572af7584cb5b3f70ae8cc848aba2|LIB|-|SNK - NeoGeo CD: neocd/neocd.bin
8834880c33164ccbe6476b559f3e37de|LIB|-|SNK - NeoGeo CD: neocd/neocd_f.rom
043d76d5f0ef836500700c34faef774d|LIB|-|SNK - NeoGeo CD: neocd/neocd_sf.rom
f6325a33c6d63ea4b9162a3fa8c32727|LIB|-|SNK - NeoGeo CD: neocd/neocd_st.rom
971ee8a36fb72da57aed01758f0a37f5|LIB|-|SNK - NeoGeo CD: neocd/neocd_sz.rom
de3cf45d227ad44645b22aa83b49f450|LIB|-|SNK - NeoGeo CD: neocd/neocd_t.rom
11526d58d4c524daef7d5d677dc6b004|LIB|-|SNK - NeoGeo CD: neocd/neocd_z.rom
e255264d85d5765013b1b2fa8109dd53|LIB|-|SNK - NeoGeo CD: neocd/ng-lo.rom
122aee210324c72e8a11116e6ef9c0d0|LIB|-|SNK - NeoGeo CD: neocd/top-sp1.bin
08ca8b2dba6662e8024f9e789711c6fc|LIB|-|SNK - NeoGeo CD: neocd/uni-bioscd.rom
66bf2aeb1b870eac603925601e48af82|LIB|-|SNK - NeoGeo CD: neocdz.zip
a17e0e0150155400d8cced329563d9c8|LIB|-|ScummVM: scummvm.zip
dbb97c34404b753724a66fe0108a32e1|LIB|-|ScummVM: scummvm/extra/Roland_SC-55.sf2
f1925ac548f9551d9d8f648dbc92c897|LIB|-|ScummVM: scummvm/extra/access.dat
73cf5bd61896442a990e363f284a0bc2|LIB|-|ScummVM: scummvm/extra/achievements.dat
fc5886ea5388f20eae299bb408da5bcc|LIB|-|ScummVM: scummvm/extra/cryo.dat
474e9a57b74c368acc8d19e8d63e3288|LIB|-|ScummVM: scummvm/extra/cryomni3d.dat
2647b6dff6d117b217dd9896cd25b34e|LIB|-|ScummVM: scummvm/extra/drascula.dat
f2e88b2faec499a4914c3a0bcffc7db1|LIB|-|ScummVM: scummvm/extra/encoding.dat
65025f90c134e4538efd306e36341aa1|LIB|-|ScummVM: scummvm/extra/fonts.dat
30ca162d03b65f46997fa43e1093839e|LIB|-|ScummVM: scummvm/extra/freescape.dat
32b777b824f02b1e1259903740964058|LIB|-|ScummVM: scummvm/extra/grim-patch.lab
7857da7e56a11e0749fb45100c323b3c|LIB|-|ScummVM: scummvm/extra/hadesch_translations.dat
0856a20f18b3319c92b710ef80d886cd|LIB|-|ScummVM: scummvm/extra/hugo.dat
21a57f79886e46f410cfb50186ed8d77|LIB|-|ScummVM: scummvm/extra/kyra.dat
75a83c781ac7024fc9c1b6f7ecc5b936|LIB|-|ScummVM: scummvm/extra/lure.dat
d97f2965013b343dd3d4fdbbc7192f15|LIB|-|ScummVM: scummvm/extra/macgui.dat
d855abc95d2b7c03b748631c08603ebb|LIB|-|ScummVM: scummvm/extra/macventure.dat
fc20f5064386a19d39bd5f9df0a542fa|LIB|-|ScummVM: scummvm/extra/mm.dat
9eb7b7e7cc7dad1fe08be6e73d749abe|LIB|-|ScummVM: scummvm/extra/monkey4-patch.m4b
3cfb16d7bab4d77606b3b1274b8ae870|LIB|-|ScummVM: scummvm/extra/mort.dat
54e9056211f2fff255b6f66a3fe39a8d|LIB|-|ScummVM: scummvm/extra/myst3.dat
e482c84f583783b4b9dea5374aa232da|LIB|-|ScummVM: scummvm/extra/nancy.dat
dfaab12ffb265646f31f51b6904246d1|LIB|-|ScummVM: scummvm/extra/neverhood.dat
4f5b513b52c4ef6fb1c46e984760a3b7|LIB|-|ScummVM: scummvm/extra/queen.tbl
9d00157b1cebd6368cbf88135c098f40|LIB|-|ScummVM: scummvm/extra/sky.cpt
f6af52d51152447f43cf3cf9a50bc144|LIB|-|ScummVM: scummvm/extra/supernova.dat
aaaf8792af40c80122d7dbecaf1dee20|LIB|-|ScummVM: scummvm/extra/teenagent.dat
4b2fb71201dc3795cff45df6200a1918|LIB|-|ScummVM: scummvm/extra/titanic.dat
891022a4e2917bb54b5cdc9a46f5b3df|LIB|-|ScummVM: scummvm/extra/tony.dat
730f63ea46169f56bb4f9fa0637baef0|LIB|-|ScummVM: scummvm/extra/toon.dat
420ef1f96eee6dc15395330f28923be2|LIB|-|ScummVM: scummvm/extra/ultima.dat
bf51a61f07625ea20e891058afaa892c|LIB|-|ScummVM: scummvm/extra/vkeybd_default.zip
46ab65cb137a4fc8710a8f3b9455e50e|LIB|-|ScummVM: scummvm/extra/wintermute.zip
17150a7a6ed5c4d5c0384b95c5fce479|LIB|-|ScummVM: scummvm/theme/gui-icons.dat
9cbffee094a6bfa1765e2f6ba15a268e|LIB|-|ScummVM: scummvm/theme/residualvm.zip
57aaebd10238ffe3863192254629aaa9|LIB|-|ScummVM: scummvm/theme/scummclassic.zip
b470c7205246a0bb4718ca0a27d25055|LIB|-|ScummVM: scummvm/theme/scummmodern.zip
15600f0b0274f2ab4dd0c181e4ae3e95|LIB|-|ScummVM: scummvm/theme/scummremastered.zip
f073f17187d0bfa3e7ebb7f328847969|LIB|-|ScummVM: scummvm/theme/shaders.dat
1ca707498f9024c292ca745c5727a751|LIB|-|ScummVM: scummvm/theme/translations.dat
7a11bfe0cc72886d032e386db68f890c|LIB|-|Sega - Dreamcast-based Arcade: dc/airlbios.zip
85254fbe320ca82a768ec2c26bb08def|LIB|-|Sega - Dreamcast-based Arcade: dc/awbios.zip
547f3d12aed389058ca06148f1cca0ed|LIB|-|Sega - Dreamcast-based Arcade: dc/f355bios.zip
1028615bcac4c31634a3364ce5c04044|LIB|-|Sega - Dreamcast-based Arcade: dc/f355dlx.zip
f4011d3116500354edf7302a90402711|LIB|-|Sega - Dreamcast-based Arcade: dc/hod2bios.zip
526eda1e2a7920c92c88178789d71d84|LIB|-|Sega - Dreamcast-based Arcade: dc/naomi.zip
c50072cbab75673e1b1a6b94355e6fa8|LIB|-|Sega - Dreamcast-based Arcade: dc/naomi2.zip
672e104c3be3a238301aceffc3b23fd6|LIB|-|Sega - Game Gear: bios.gg
840481177270d5642a14ca71ee72844c|LIB|-|Sega - Master System - Mark III: bios.sms
24a519c53f67b00640d0048ef7089105|LIB|-|Sega - Master System - Mark III: bios_J.sms
a0028b3043f9d59ceeb03da5b073b30d|LIB|-|Sega - Mega Drive - Genesis: areplay.bin
d3293ebaaa7f4eb2a6766b68a0fb4609|LIB|-|Sega - Mega Drive - Genesis: bios_MD.bin
e8af7fe115a75c849f6aab3701e7799b|LIB|-|Sega - Mega Drive - Genesis: ggenie.bin
ff4a3572475236e859e3e9ac5c87d1f1|LIB|-|Sega - Mega Drive - Genesis: rom.db
4ea493ea4e9f6c9ebfccbdb15110367e|LIB|-|Sega - Mega Drive - Genesis: sk.bin
b4e76e416b887f4e7413ba76fa735f16|LIB|-|Sega - Mega Drive - Genesis: sk2chip.bin
eeeea1cd29c6e0e8b094790ae969bfa7|LIB|-|Sharp - X1: xmil/IPLROM.X1
851e4a5936f17d13f8c39a980cf00d77|LIB|-|Sharp - X1: xmil/IPLROM.X1T
cc78d4f4900f622bd6de1aed7f52592f|LIB|-|Sharp - X68000: iplromco.dat
0617321daa182c3f3d6f41fd02fb3275|LIB|-|Sharp - X68000: iplromxv.dat
cb0a5cfcf7247a7eab74bb2716260269|LIB|-|Sharp - X68000: keropi/cgrom.dat
7fd4caabac1d9169e289f0f7bbf71d8e|LIB|-|Sharp - X68000: keropi/iplrom.dat
f373003710ab4322642f527f567e020a|LIB|-|Sharp - X68000: keropi/iplrom30.dat
b4d2692115a9f2924df92a3cbfb358fb|LIB|-|Sinclair - ZX Spectrum: 128-0.rom
6e09e5d3c4aef166601669feaaadc01c|LIB|-|Sinclair - ZX Spectrum: 128-1.rom
c1231a70b8129311216acb7479b031d5|LIB|-|Sinclair - ZX Spectrum: 128-spanish-0.rom
4f341936594cbcab75cfa62ce96e3682|LIB|-|Sinclair - ZX Spectrum: 128-spanish-1.rom
4c42a2f075212361c3117015b107ff68|LIB|-|Sinclair - ZX Spectrum: 48.rom
78e61a2a02121873c1756b21fd1398b1|LIB|-|Sinclair - ZX Spectrum: disciple.rom
e6db6b9f6ad15012851115a7bc4b31d8|LIB|-|Sinclair - ZX Spectrum: disk_plus3.szx
85fede415f4294cc777517d7eada482e|LIB|-|Sinclair - ZX Spectrum: ep128emu/roms/zx128.rom
a249565f03b98d004ee7f019570069cd|LIB|-|Sinclair - ZX Spectrum: fuse/128p-0.rom
b9fda5b6a747ff037365b0e2d8c4379a|LIB|-|Sinclair - ZX Spectrum: fuse/256s-0.rom
643861ad34831b255bf2eb64e8b6ecb8|LIB|-|Sinclair - ZX Spectrum: fuse/256s-1.rom
d8ad507b1c915a9acfe0d73957082926|LIB|-|Sinclair - ZX Spectrum: fuse/256s-2.rom
ce0723f9bc02f4948c15d3b3230ae831|LIB|-|Sinclair - ZX Spectrum: fuse/256s-3.rom
d5869034604dbfd2c1d54170e874fd0a|LIB|-|Sinclair - ZX Spectrum: fuse/gluck.rom
0da70a5d2a0e733398e005b96b7e4ba6|LIB|-|Sinclair - ZX Spectrum: fuse/trdos.rom
5c11c61a2dd2ca4bf39328d9ff42d289|LIB|-|Sinclair - ZX Spectrum: if1-1.rom
31b704ae925305e74f50699271fddd9a|LIB|-|Sinclair - ZX Spectrum: if1-2.rom
4ed7af4636308b8a48d7a35e6c5b546b|LIB|-|Sinclair - ZX Spectrum: plus2-0.rom
b3db95931cc844efaeb82db9c171b9f3|LIB|-|Sinclair - ZX Spectrum: plus2-1.rom
9833b8b73384dd5fa3678377ff00a2bb|LIB|-|Sinclair - ZX Spectrum: plus3-0.rom
0f711ceb5ab801b4701989982e0f334c|LIB|-|Sinclair - ZX Spectrum: plus3-1.rom
3b6dd659d5e4ec97f0e2f7878152c987|LIB|-|Sinclair - ZX Spectrum: plus3-2.rom
a148bcc575e51389e84fdf5d555c3196|LIB|-|Sinclair - ZX Spectrum: plus3-3.rom
bc123f625e245c225f92ef05933ed134|LIB|-|Sinclair - ZX Spectrum: plus3e-0.rom
617364264c587d20c9fc4746c29679f2|LIB|-|Sinclair - ZX Spectrum: plus3e-1.rom
c363e95dcd0a90e6e7f847e6e47e0179|LIB|-|Sinclair - ZX Spectrum: plus3e-2.rom
42e5de16fb5e50082bb954ec7ce45851|LIB|-|Sinclair - ZX Spectrum: plusd.rom
fb3f86eb1e5a695d9c50c124e7cfb875|LIB|-|Sinclair - ZX Spectrum: se-0.rom
88de4a3129086f34bb9ca559acc51e6c|LIB|-|Sinclair - ZX Spectrum: se-1.rom
c54aa8f374b0971f51546c29d5d1eba1|LIB|-|Sinclair - ZX Spectrum: speccyboot-1.4.rom
8942b43b73ed4eb7f32bd1741709a4dc|LIB|-|Sinclair - ZX Spectrum: tape_128.szx
fec97eb9ea1b017cae84de78508feb4a|LIB|-|Sinclair - ZX Spectrum: tape_16.szx
116f732bbae4e49d625aaf2f311474d0|LIB|-|Sinclair - ZX Spectrum: tape_2048.szx
0b0f267b95d556318bb652af2e8dc25c|LIB|-|Sinclair - ZX Spectrum: tape_2068.szx
ee2ae810711594db3a134a7432baabff|LIB|-|Sinclair - ZX Spectrum: tape_48.szx
bd7698603bd9079d337cdedfb04942d9|LIB|-|Sinclair - ZX Spectrum: tape_pentagon.szx
166d4aa1a5aa4fbd99cc963b4e7c19cc|LIB|-|Sinclair - ZX Spectrum: tape_plus2.szx
445d4817d5557bb363a216fbd6eeaa84|LIB|-|Sinclair - ZX Spectrum: tape_plus2a.szx
0dc8828ac1db2e0efa915ac55191e96f|LIB|-|Sinclair - ZX Spectrum: tape_plus3.szx
bf07537f028bbcb3309464bd30da779c|LIB|-|Sinclair - ZX Spectrum: tape_plus3e.szx
c10e677d3deb5a445689d3a599880745|LIB|-|Sinclair - ZX Spectrum: tape_scorpion.szx
2518f9334bef8c44804a4185085579b5|LIB|-|Sinclair - ZX Spectrum: tape_se.szx
1d360c09d370bb52a9a44b30cc7c59e6|LIB|-|Sinclair - ZX Spectrum: tape_ts2068.szx
9dd7ecf784a6c04265c073c236f5fadb|LIB|-|Sinclair - ZX Spectrum: tc2048.rom
55d462fccc6c536037404ef4ced08bec|LIB|-|Sinclair - ZX Spectrum: tc2068-0.rom
575d203c6e15e679fba0b73f854ec7a2|LIB|-|Sinclair - ZX Spectrum: tc2068-1.rom
866855cc330b9b95cc69135fb7b41d38|LIB|-|Sony - PlayStation Portable: PPSSPP/ppge_atlas.zim
d4448d09bbfde687c04f9e3310e023ab|LIB|-|Texas Instruments TI-83: ti83.rom
8011181f810b5ec4e9d6a03f0e14257a|LIB|-|Texas Instruments TI-83: ti83plus.rom
c6ff8204c5c81b7be34614dbbd690c8b|LIB|-|Texas Instruments TI-83: ti83se.rom
5ce95a26ceed5bec73995d83568da9cf|LIB|-|Videoton - TV Computer: ep128emu/roms/tvc22_ext.rom
8c54285f541930cde766069942bad0f2|LIB|-|Videoton - TV Computer: ep128emu/roms/tvc22_sys.rom
88dc7876d584f90e4106f91444ab23b7|LIB|-|Videoton - TV Computer: ep128emu/roms/tvc_dos12d.rom
a2cf86ba8e7fc58b242137fe59036832|LIB|-|Videoton - TV Computer: ep128emu/roms/tvcfileio.rom
73f04397cbb2dafcf2047b19a856153a|LIB|-|Vircon32: Vircon32Bios.v32
c011b428819eea4a80b455c245a5a04d|LIB|-|Wolfenstein 3D: ecwolf.pk3
df692a80a5b1bc90728bc3dfc76cd948|NDS|ALL|NDS ARM7 BIOS (bios7.bin)
a392174eb3e572fed6447e956bde4b25|NDS|ALL|NDS ARM9 BIOS (bios9.bin)
145eaef5bd3037cbc247c213bb3da1b3|NDS|ALL|NDS firmware (common dump)
e45033d9b0fa6b0de071292bba7c9d13|NDS|ALL|NDS firmware (libretro reference dump)
ca5cfc321f916756e3f0effbfaeba13b|PS1|JP|DTL-H1100 (v2.2 03-06-96 D)
81bbe60ba7a3d1cea1d48c14cbcc647b|PS1|ALL|PS3 PS1 BIOS (ps1_rom.bin, region-free)
c53ca5908936d412331790f4426c6c33|PS1|ALL|PSP PS1 BIOS (psxonpsp660.bin, region-free)
2118230527a9f51bd9216e32fa912842|PS1|?|PlayStation BIOS (in EmuDeck's known list, region unknown)
81328b966e6dcf7ea1e32e55e1c104bb|PS1|?|PlayStation BIOS (in EmuDeck's known list, region unknown)
fbb5f59ec332451debccf1e377017237|PS1|?|PlayStation BIOS (in EmuDeck's known list, region unknown)
8abc1b549a4a80954addc48ef02c4521|PS1|JP|SCPH-100 (v4.3 03-11-00 J)
239665b1a3dade1b5a52c06338011044|PS1|JP|SCPH-1000, DTL-H1000 (v1.0)
476d68a94ccec3b9c8303bbd1daf2810|PS1|JP|SCPH-1000R (v4.5 05-25-00 J)
924e392ed05558ffdb115408c263dccf|PS1|US|SCPH-1001, 5003, DTL-H1201, H3001 (v2.2 12-04-95 A)
dc2b9bf8da62ec93e868cfd29f0d067d|PS1|US|SCPH-1001, DTL-H1001 (v2.0 05-07-95 A)
da27e8b6dab242d8f91a9b25d80c63b8|PS1|US|SCPH-1001, DTL-H1101 (v2.1 07-17-95 A)
54847e693405ffeb0359c6287434cbef|PS1|EU|SCPH-1002, DTL-H1002 (v2.0 05-10-95 E)
417b34706319da7cf001e76e40136c23|PS1|EU|SCPH-1002, DTL-H1102 (v2.1 07-17-95 E)
e2110b8a2b97a8e0b857a45d32f7e187|PS1|EU|SCPH-1002, DTL-H1202, H3002 (v2.2 12-04-95 E)
9a09ab7e49b422c007e6d54d7c49b965|PS1|US|SCPH-101 (v4.4 03-24-00 A)
6e3735ff4c7dc899ee98981385f6f3d0|PS1|US|SCPH-101 (v4.5 05-25-00 A)
b10f5e0e3d9eb60e5159690680b1e774|PS1|EU|SCPH-102 (v4.4 03-24-00 E)
de93caec13d1a141a40a79f5c86168d6|PS1|EU|SCPH-102 (v4.5 05-25-00 E)
849515939161e62f6b866f6853006780|PS1|JP|SCPH-3000, DTL-H1000H (v1.1 01-22-95)
cba733ceeff5aef5c32254f1d617fa62|PS1|JP|SCPH-3500 (v2.1 07-17-95 J)
57a06303dfa9cf9351222dfcbb4a29d9|PS1|JP|SCPH-5000, DTL-H1200, H3000 (v2.2 12-04-95 J)
8dd7d5296a650fac7319bce665a6a53c|PS1|JP|SCPH-5500 (v3.0 09-09-96 J)
490f666e1afb15b7362b406ed1cea246|PS1|US|SCPH-5501, 5503, 7003 (v3.0 11-18-96 A)
32736f17079d0b2b7024407c39bd3050|PS1|EU|SCPH-5502, 5552 (v3.0 01-06-97 E)
8e4c14f567745eff2f0408c8129f72a6|PS1|JP|SCPH-7000, 7500, 9000 (v4.0 08-18-97 J)
b84be139db3ee6cbd075630aa20a6553|PS1|JP|SCPH-7000W (v4.1 11-14-97 A)
1e68c231d0896b7eadcad1d7d8e76129|PS1|US|SCPH-7001, 7501, 7503, 9001, 9003, 9903 (v4.1 12-16-97 A)
b9d9a0286c33dc6b7237bb13cd46fdee|PS1|EU|SCPH-7002, 7502, 9002 (v4.1 12-16-97 E)
eb201d2d98251a598af467d4347bb62f|PS1|-|Sony - PlayStation: scph5000.bin
1c6cd089e6c83da618fbf2a081eb4888|PS2|JP|PS2, DESR-5000/DESR-5100/DESR-7000/DESR-7100 (v5.0 10/28/03 J)
1ad977bb539fc9448a08ab276a836bbc|PS2|JP|PS2, DESR-5500/DESR-5700/DESR-7500/DESR-7700 (v5.0 09/17/04 J)
32f2e4d5ff5ee11072a6bc45530f5765|PS2|JP|PS2, DTL-H10000 (v5.0 01/17/00 T)
acf9968c8f596d2b15f42272082513d1|PS2|JP|PS2, DTL-H10000 (v5.0 02/17/00 T)
d3f1853a16c2ec18f3cd1ae655213308|PS2|JP|PS2, DTL-H10000 (v5.0 02/24/00 T)
bb6bbc850458fff08af30e969ffd0175|PS2|JP|PS2, DTL-H30000 (v5.0 01/18/01 J)
63e6fd9b3c72e0d7b920e80cf76645cd|PS2|US|PS2, DTL-H30001 (v5.0 07/27/00 A)
91c87cb2f2eb6ce529a2360f80ce2457|PS2|EU|PS2, DTL-H30002 (v5.0 09/02/00 E)
0bf988e9c7aaa4c051805b0fa6eb3387|PS2|US|PS2, DTL-H30101 (v5.0 12/28/00 A)
3016b3dd42148a67e2c048595ca4d7ce|PS2|EU|PS2, DTL-H30102 (v5.0 09/02/00 E)
6f9a6feb749f0533aaae2cc45090b0ed|PS2|EU|PS2, DTL-H30102 (v5.0 12/28/00 E)
54ecde087258557e2ddb5c3ddb004028|PS2|JP|PS2, DTL-H50000 (v5.0 02/06/03 J)
eb960de68f0c0f7f9fa083e9f79d0360|PS2|US|PS2, DTL-H50001 (v5.0 03/25/03 A)
ab9d49ad40ae49f19856ad187777b1b3|PS2|US|PS2, DTL-H50001 (v5.0 06/23/03 A)
666018ffec65c5c7e04796081295c6c7|PS2|EU|PS2, DTL-H50002 (v5.0 02/27/03 E)
240d4c5ddd4b54069bdc4a3cd2faf99d|PS2|JP|PS2, DTL-H50009 (v5.0 02/24/03 J)
63ead1d74893bf7f36880af81f68a82d|PS2|EU|PS2, DTL-H70002 (v5.0 06/14/04 E)
bf0078ba5e19d57eae18047407f3b6e5|PS2|JP|PS2, DTL-H75000 (v5.0 06/20/05 J)
9959ad7a8685cad66206e7752ca23f8b|PS2|US|PS2, DTL-H75000A (v5.0 06/20/05 A)
21fe4cad111f7dc0f9af29477057f88d|PS2|US|PS2, DTL-H90000 (v5.0 09/05/06 A)
5e2014472c88f74f7547d8c2c60eca45|PS2|JP|PS2, DTL-H90000 (v5.0 09/05/06 J)
93ea3bcee4252627919175ff1b16a1d9|PS2|EU|PS2, KDL-22PX300 (v5.0 04/15/10 E)
acf4730ceb38ac9d8c7d8e21f2614600|PS2|JP|PS2, SCPH-10000 (v5.0 01/17/00 T)
b1459d7446c69e3e97e6ace3ae23dd1c|PS2|JP|PS2, SCPH-10000/SCPH-15000 (v5.0 02/17/00 T)
f63bc530bd7ad7c026fcd6f7bd0d9525|PS2|JP|PS2, SCPH-18000 (GH-003) (v5.0 10/27/00 J)
cee06bd68c333fc5768244eae77e4495|PS2|JP|PS2, SCPH-18000 (GH-008) (v5.0 10/27/00 J)
d8f485717a5237285e4d7c5f881b7f32|PS2|JP|PS2, SCPH-18000 (v5.0 10-27-00 J)
ab55cceea548303c22c72570cfd4dd71|PS2|JP|PS2, SCPH-30000 (v5.0 04/27/01 J)
815ac991d8bc3b364696bead3457de7d|PS2|JP|PS2, SCPH-30000/SCPH-35000 (v5.0 01/18/01 J)
a20c97c02210f16678ca3010127caf36|PS2|US|PS2, SCPH-30001 (v5.0 07/27/00 A)
8db2fbbac7413bf3e7154c1e0715e565|PS2|US|PS2, SCPH-30001 (v5.0 09/02/00 A)
8accc3c49ac45f5ae2c5db0adc854633|PS2|US|PS2, SCPH-30001/SCPH-35001 (v5.0 12/28/00 A)
b107b5710042abe887c0f6175f6e94bb|PS2|US|PS2, SCPH-30001R (v5.0 04/27/01 A)
18bcaadb9ff74ed3add26cdf709fff2e|PS2|US|PS2, SCPH-30001R (v5.0 07/04/01 A)
7200a03d51cacc4c14fcdfdbc4898431|PS2|US|PS2, SCPH-30001R (v5.0 10/04/01 A)
b7fa11e87d51752a98b38e3e691cbf17|PS2|EU|PS2, SCPH-30002/SCPH-30003/SCPH-30004 (v5.0 09/02/00 E)
838544f12de9b0abc90811279ee223c8|PS2|EU|PS2, SCPH-30002/SCPH-30003/SCPH-30004/SCHP-35002/SCPH-35003/SCPH-35004 (v5.0 12/28/00 E)
491209dd815ceee9de02dbbc408c06d6|PS2|EU|PS2, SCPH-30002R/SCPH-30003R/SCPH-30004R (v5.0 07/04/01 E)
8359638e857c8bc18c3c18ac17d9cc3c|PS2|EU|PS2, SCPH-30002R/SCPH-30003R/SCPH-30004R (v5.0 10/04/01 E)
71f50ef4f4e17c163c78908e16244f7d|PS2|EU|PS2, SCPH-30003 (v5.0 09-02-00 E)
352d2ff9b3f68be7e6fa7e6dd8389346|PS2|JP|PS2, SCPH-30005R/SCPH-30006R/SCPH-30007R (v5.0 07/30/01 J)
72da56fccb8fcd77bba16d1b6f479914|PS2|JP|PS2, SCPH-37000/SCPH-39000 (v5.0 04/26/02 J)
d5ce2c7d119f563ce04bc04dbc3a323e|PS2|US|PS2, SCPH-39001 (v5.0 02/07/02 A)
0d2228e6fd4fb639c9c39d077a9ec10c|PS2|EU|PS2, SCPH-39002/SCPH-39003/SCPH-39004 (v5.0 03/19/02 E)
315a4003535dfda689752cb25f24785c|PS2|JP|PS2, SCPH-39005/SCPH-39006/SCPH-39007 (v5.0 04/26/02 J)
5b1f47fbeb277c6be2fccdd6344ff2fd|PS2|EU|PS2, SCPH-39008 (v5.0 04/26/02 E)
00da1b177096cfd2532c8fa22b43e667|PS2|JP|PS2, SCPH-50000 (v5.0 08/22/03 J)
312ad4816c232a9606e56f946bc0678a|PS2|JP|PS2, SCPH-50000/SCPH-55000 (v5.0 02/06/03 J)
8aa12ce243210128c5074552d3b86251|PS2|US|PS2, SCPH-50001 (v5.0 03/25/03 A)
35461cecaa51712b300b2d6798825048|PS2|US|PS2, SCPH-50001/SCPH-50010 (v5.0 06/23/03 A)
6e69920fa6eef8522a1d688a11e41bc6|PS2|EU|PS2, SCPH-50002/SCPH-50003/SCPH-50004 (v5.0 02/27/03 E)
bd6415094e1ce9e05daabe85de807666|PS2|EU|PS2, SCPH-50002/SCPH-50003/SCPH-50004 (v5.0 06/23/03 E)
afde410bd026c16be605a1ae4bd651fd|PS2|EU|PS2, SCPH-50004 (v5.0 08/22/03 E)
50d5b97b57d8c9b6534adcb46c2027d4|PS2|JP|PS2, SCPH-50005 (v5.0 06/23/03 J)
2e70ad008d4ec8549aada8002fdf42fb|PS2|JP|PS2, SCPH-50006/SCPH-50007 (v5.0 06/23/03 J)
b53d51edc7fc086685e31b811dc32aad|PS2|EU|PS2, SCPH-50008 (v5.0 06/23/03 E)
1b6e631b536247756287b916f9396872|PS2|JP|PS2, SCPH-50009 (v5.0 06/23/03 J)
81f4336c1de607dd0865011c0447052e|PS2|US|PS2, SCPH-50011 (v5.0 03/29/04 A)
463d87789c555a4a7604e97d7db545d1|PS2|JP|PS2, SCPH-55000 (v5.0 06/23/03 J)
0eee5d1c779aa50e94edd168b4ebf42e|PS2|JP|PS2, SCPH-70000 (v5.0 06/14/04 J)
d333558cc14561c1fdc334c75d5f37b7|PS2|US|PS2, SCPH-70001/SCPH-70011/SCPH-70012 (v5.0 06/14/04 A)
7ebb4fc5eab6f79a27d76ac9aad392b2|PS2|EU|PS2, SCPH-70002 (v5.0 06/14/04 E)
dc752f160044f2ed5fc1f4964db2a095|PS2|EU|PS2, SCPH-70002/SCPH-70003/SCPH-70004/SCPH-70008 (v5.0 06/14/04 E)
3e3e030c0f600442fa05b94f87a1e238|PS2|JP|PS2, SCPH-70005/SCPH-70006/SCPH-70007 (v5.0 06/14/04 J)
eb4f40fcf4911ede39c1bbfe91e7a89a|PS2|JP|PS2, SCPH-75000 (v5.0 06/20/05 J)
929a14baca1776b00869f983aa6e14d2|PS2|US|PS2, SCPH-75001/SCPH-75010 (v5.0 06/20/05 A)
573f7d4a430c32b3cc0fd0c41e104bbd|PS2|EU|PS2, SCPH-75002/SCPH-75003/SCPH-75004/SCPH-75008 (v5.0 06/20/05 E)
df63a604e8bff5b0599bd1a6c2721bd0|PS2|JP|PS2, SCPH-75006 (v5.0 06/20/05 J)
5b1ba4bb914406fae75ab8e38901684d|PS2|JP|PS2, SCPH-77000 (v5.0 02/10/06 J)
cb801b7920a7d536ba07b6534d2433ca|PS2|US|PS2, SCPH-77001/SCPH-77010 (v5.0 02/10/06 A)
af60e6d1a939019d55e5b330d24b1c25|PS2|EU|PS2, SCPH-77002/SCPH-77003/SCPH-77004/SCPH-77008 (v5.0 02/10/06 E)
549a66d0c698635ca9fa3ab012da7129|PS2|JP|PS2, SCPH-77006/SCPH-77007 (v5.0 02/10/06 J)
5de9d0d730ff1e7ad122806335332524|PS2|JP|PS2, SCPH-79000/SCPH-90000 (v5.0 09/05/06 J)
40c11c063b3b9409aa5e4058e984e30c|PS2|US|PS2, SCPH-79001/SCPH-79010/SCPH-90001 (v5.0 09/05/06 A)
80bbb237a6af9c611df43b16b930b683|PS2|EU|PS2, SCPH-79002/SCPH-79003/SCPH-79004/SCPH-79008/SCPH-90002/SCPH-90003/SCPH-90004 (v5.0 09/05/06 E)
c37bce95d32b2be480f87dd32704e664|PS2|JP|PS2, SCPH-79006/SCPH-79007/SCPH-90006/SCPH-90007 (v5.0 09/05/06 J)
80ac46fa7e77b8ab4366e86948e54f83|PS2|JP|PS2, SCPH-90000 (v5.0 02/20/08 J)
21038400dc633070a78ad53090c53017|PS2|US|PS2, SCPH-90001/SCPH-90010 (v5.0 02/20/08 A)
dc69f0643a3030aaa4797501b483d6c4|PS2|EU|PS2, SCPH-90002/SCPH-90003/SCPH-90004/SCPH-90008 (v5.0 02/20/08 E)
30d56e79d89fbddf10938fa67fe3f34e|PS2|JP|PS2, SCPH-90005/SCPH-90006/SCPH-90007 (v5.0 02/20/08 J)
d3e81e95db25f5a86a7b7474550a2155|PS2|-|Sony - PlayStation 2: pcsx2/bios/ps2-0250j-20100415.bin
526291c9c9bae8b184b0e5f4bfa94eb9|PS2|-|Sony - PlayStation 2: pcsx2/resources/GameIndex.yaml
07b562a3f0c4b9a55834df9bbc9bd0c3|PS2|ASIA|ps2-0190h-20030623.bin (RetroDECK list)
0c13357c01a25a886db2356bbe73d9f0|PS2|RU|ps2-0190r-20030623.bin (RetroDECK list)
3ea3202e2634cb47cb90f3a05c015010|SAT|JP|Hi-Saturn BIOS
0306c0e408d6682dd2d86324bd4ac661|SAT|?|Saturn BIOS (in EmuDeck's known list, region unknown)
3240872c70984b6cbfda1586cab68dbe|SAT|US/EU|Saturn mpr-17933 (US/EU v1.00)
cb2cebc1b6e573b7c44523d037edcd45|SAT|US/EU|Saturn mpr-18100
74570fed4d44b2682b560c8cd44b8b6a|SAT|JP|Saturn sega1003 (JP v1.003)
af5828fdff51384f99b3c4926be27762|SAT|JP|Saturn sega_100 / saturn_bios (JP v1.00)
f273555d7d91e8a5a6bfd9bcf066331c|SAT|JP|Saturn sega_100a (JP v1.00a)
85ec9ca47d8f6807718151cbcca8b964|SAT|JP|Saturn sega_101 (JP v1.01)
0e92c1e02862dfeb4cdef7f4414b14a9|SAT|-|Sega - Saturn: kronos/stvbios.zip
255113ba943c92a54facd25a10fd780c|SAT|-|Sega - Saturn: mpr-18811-mx.ic1
1cd19988d1d72a3e7caa0b73234c96b4|SAT|-|Sega - Saturn: mpr-19367-mx.ic1
ac4e4b6522e200c0d23d371a8cecbfd3|SAT|JP|V-Saturn BIOS
9b562ebf2d095bf1dabadbc1881f519a|SCD|EU|Mega-CD EU BIOS (alt)
e66fa1dc5820d254611fdcdba0662372|SCD|EU|Mega-CD EU BIOS (bios_CD_E)
683a8a9e273662561172468dfa2858eb|SCD|JP|Mega-CD JP BIOS (alt)
278a9397d192149e84e820ac621a8edd|SCD|JP|Mega-CD JP BIOS (bios_CD_J)
310a9081d2edf2d316ab38813136725e|SCD|US|Sega CD US BIOS (alt)
baca1df271d7c11fe50087c0358f4eb5|SCD|US|Sega CD US BIOS (alt)
2efd74e3232ff260e371b99f84024f7f|SCD|US|Sega CD US BIOS (bios_CD_U)
bc6ae4e1db01a2f349d9af392bf7e2bd|SCD|?|Sega CD/Mega-CD BIOS (in EmuDeck's known list, region unknown)
29ad9ce848b49d0f9cefc294137f653c|SCD|?|Sega CD/Mega-CD BIOS (in EmuDeck's known list, region unknown)
cc049159d7e744c15eee080c241273b4|SCD|?|Sega CD/Mega-CD BIOS (in EmuDeck's known list, region unknown)
a3ddcc8483b0368141adfd99d9a1e466|SCD|?|Sega CD/Mega-CD BIOS (in EmuDeck's known list, region unknown)
bdeb4c47da613946d422d97d98b21cda|SCD|?|Sega CD/Mega-CD BIOS (in EmuDeck's known list, region unknown)
96ea588d647f2ab1f291279fc691663c|SCD|?|Sega CD/Mega-CD BIOS (in EmuDeck's known list, region unknown)
854b9150240a198070150e4566ae1290|SCD|?|Sega CD/Mega-CD BIOS (in EmuDeck's known list, region unknown)
b10c0a97abc57b758497d3fae6ab35a4|SCD|?|Sega CD/Mega-CD BIOS (in EmuDeck's known list, region unknown)
ecc837c31d77b774c6e27e38f828aa9a|SCD|?|Sega CD/Mega-CD BIOS (in EmuDeck's known list, region unknown)
d49c52a4102f6df7bcf8d0617ac475ed|XBOX|ALL|Xbox MCPX 1.0 boot ROM (mcpx_1.0.bin)
196a5f59a13382c185636e691d6c323d|XBOXBAD|ALL|Xbox MCPX 1.1 boot ROM - xemu needs MCPX 1.0, not 1.1
@@KNOWN_END@@
}

# ----------------------------------------------------------------------------
# Embedded data: libretro core firmware (core|system|path|R/O|md5s|description)
# generated from libretro-core-info + System.dat
# ----------------------------------------------------------------------------
RA_TABLE=$(cat <<'@@RA_END@@'
FreeIntvTSOverlay_libretro|Intellivision|exec.bin|R|62e761035cb657903761800f4437b8af|exec.bin (Intellivision Exec BIOS)
FreeIntvTSOverlay_libretro|Intellivision|grom.bin|R|0cd5946c6473e42e8e4c2137785e427f|grom.bin (Intellivision Graphic Rom BIOS)
a5200_libretro|Atari 5200|5200.rom|O|281f20ea4320404ec820fb7ec0693b38|5200.rom (5200 BIOS)
amiberry_libretro|Amiga|kick34005.A500|O|82a21c1890cae844b3df741f2762d48d|A500 Kickstart v1.3 r34.5
amiberry_libretro|Amiga|kick37350.A600|O|465646c9b6729f77eea5314d1f057951|A600 Kickstart v2.05 r37.350
amiberry_libretro|Amiga|kick40068.A1200|O|646773759326fbac3b2311fd8c8793ee|A1200 Kickstart v3.1 r40.68
amiberry_libretro|Amiga|kick33180.A500|O|85ad74194e87c08904327de1a9443b7a|A500 Kickstart v1.2 r33.180
amiberry_libretro|Amiga|kick40068.A4000|O|9bdedde6a4f33555b4a270c8ca53297d|A4000 Kickstart v3.1 r40.68
amiberry_libretro|Amiga|kick40060.CD32|O|5f8924d013dd57a89cf349f4cdedc6b1|CD32 Kickstart v3.1 r40.60
amiberry_libretro|Amiga|kick40060.CD32.ext|O|bb72565701b1b6faece07d68ea5da639|CD32 Extended-ROM r40.60
armsx2_libretro|Sony PlayStation 2|pcsx2/bios|R||'pcsx2/bios' folder (any valid PS2 BIOS dump, e.g. scph39001.bin)
armsx2_libretro|Sony PlayStation 2|pcsx2/resources|R||'pcsx2/resources' folder (shaders, GameIndex.yaml, fonts)
atari800_libretro|Atari 8-bit Family|5200.rom|O|281f20ea4320404ec820fb7ec0693b38|5200.rom (Atari 5200 BIOS)
atari800_libretro|Atari 8-bit Family|ATARIBAS.ROM|O|0bac0c6a50104045d902df4503a4c30b|ATARIBAS.ROM (Atari BASIC)
atari800_libretro|Atari 8-bit Family|ATARIOSA.ROM|O|eb1f32f5d9f382db1bbfb8d7f9cb343a|ATARIOSA.ROM (Atari 400/800 OS A)
atari800_libretro|Atari 8-bit Family|ATARIOSB.ROM|O|a3e8d617c95d08031fe1b20d541434b2|ATARIOSB.ROM (Atari 400/800 OS B)
atari800_libretro|Atari 8-bit Family|ATARIXL.ROM|O|06daac977823773a3eea3422fd26a703|ATARIXL.ROM (Atari XL/XE OS)
atari800_libretro|Atari 8-bit Family|BB01R4_OS.ROM|O|b7a2a04677d34f069eeb643d5238bf86|BB01R4_OS.ROM (Atari XL/XE/XEGS OS v4)
atari800_libretro|Atari 8-bit Family|XEGAME.ROM|O|d7eb37aec6960cba36bc500e0e5d00bc|XEGAME.ROM (Atari XEGS Missile Command)
bbkemu_libretro|BBK Electronic Dictionary|BBKEmu/A4980/8.BIN|O||8.BIN (Font ROM)
bbkemu_libretro|BBK Electronic Dictionary|BBKEmu/A4980/E.BIN|O||E.BIN (OS ROM)
beetle_saturn_libretro|Saturn|sega_101.bin|R|85ec9ca47d8f6807718151cbcca8b964|sega_101.bin (Saturn JP BIOS)
beetle_saturn_libretro|Saturn|mpr-17933.bin|R|3240872c70984b6cbfda1586cab68dbe|mpr-17933.bin (Saturn US/EU BIOS)
beetle_saturn_libretro|Saturn|mpr-18811-mx.ic1|O|255113ba943c92a54facd25a10fd780c|mpr-18811-mx.ic1 (The King of Fighters '95 ROM Cartridge)
beetle_saturn_libretro|Saturn|mpr-19367-mx.ic1|O|1cd19988d1d72a3e7caa0b73234c96b4|mpr-19367-mx.ic1 (Ultraman: Hikari no Kyojin Densetsu ROM Cartridge)
bk_libretro|BK-0010/BK-0011(M)|bk/B11M_BOS.ROM|O|fe4627d1e3a1535874085050733263e7|bk/B11M_BOS.ROM
bk_libretro|BK-0010/BK-0011(M)|bk/B11M_EXT.ROM|O|dc52f365d56fa1951f5d35b1101b9e3f|bk/B11M_EXT.ROM
bk_libretro|BK-0010/BK-0011(M)|bk/BAS11M_0.ROM|O|946f6f23ded03c0e26187f0b3ca75993|bk/BAS11M_0.ROM
bk_libretro|BK-0010/BK-0011(M)|bk/BAS11M_1.ROM|O|1e6637f32aa7d1de03510030cac40bcf|bk/BAS11M_1.ROM
bk_libretro|BK-0010/BK-0011(M)|bk/DISK_327.ROM|O|5015228eeeb238e65da8edcd1b6dfac7|bk/DISK_327.ROM
bk_libretro|BK-0010/BK-0011(M)|bk/BASIC10.ROM|O|3fa774326d75410a065659aea80252f0|bk/BASIC10.ROM
bk_libretro|BK-0010/BK-0011(M)|bk/FOCAL10.ROM|O|5737f972e8638831ab71e9139abae052|bk/FOCAL10.ROM
bk_libretro|BK-0010/BK-0011(M)|bk/MONIT10.ROM|O|95f8c41c6abf7640e35a6a03cecebd01|bk/MONIT10.ROM
blastem_libretro|Sega 8/16-bit (Various)|rom.db|O|ff4a3572475236e859e3e9ac5c87d1f1|rom.db (ROM feature database)
blastem_libretro|Sega 8/16-bit (Various)|bios_CD_U.bin|O|2efd74e3232ff260e371b99f84024f7f|bios_CD_U.bin (Sega CD US BIOS, required for Sega CD games)
blastem_libretro|Sega 8/16-bit (Various)|bios_CD_E.bin|O|e66fa1dc5820d254611fdcdba0662372|bios_CD_E.bin (Mega-CD EU BIOS, required for Sega CD games)
blastem_libretro|Sega 8/16-bit (Various)|bios_CD_J.bin|O|278a9397d192149e84e820ac621a8edd|bios_CD_J.bin (Mega-CD JP BIOS, required for Sega CD games)
blastem_libretro|Sega 8/16-bit (Various)|32X_M_BIOS.bin|O||32X_M_BIOS.bin (32X Master SH2 BIOS, required for 32X games)
blastem_libretro|Sega 8/16-bit (Various)|32X_S_BIOS.bin|O||32X_S_BIOS.bin (32X Slave SH2 BIOS, required for 32X games)
blastem_libretro|Sega 8/16-bit (Various)|32X_G_BIOS.bin|O||32X_G_BIOS.bin (32X 68000 BIOS)
blastem_libretro|Sega 8/16-bit (Various)|bios_MD.bin|O|d3293ebaaa7f4eb2a6766b68a0fb4609|bios_MD.bin (Mega Drive TMSS ROM, also read as tmss.md)
blastem_libretro|Sega 8/16-bit (Various)|colecovision.rom|O|2c66f5911e5b42b8ebe113403548eee7|colecovision.rom (ColecoVision BIOS)
blastem_libretro|Sega 8/16-bit (Various)|laseractive_dyw_1322a.bin|O||laseractive_dyw_1322a.bin (LaserActive uPD ROM)
bluemsx_libretro|MSX/SVI/ColecoVision/SG-1000|Databases/msxromdb.xml|R|c0a94965701431e0df29949189e424dd|'Databases' folder
bluemsx_libretro|MSX/SVI/ColecoVision/SG-1000|Machines/Shared Roms/MSX.rom|R||'Machines' folder
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
bsnes-jg_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|cx4.data.rom|O|037ac4296b6b6a5c47c440188d3c72e3|cx4.data.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
bsnes2014_accuracy_libretro|Super Nintendo Entertainment System|sgb.boot.rom|O|d574d4f9c12f305074798f54c091a8b4|sgb.boot.rom (SGB Boot Image)
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|cx4.data.rom|O|037ac4296b6b6a5c47c440188d3c72e3|cx4.data.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
bsnes2014_balanced_libretro|Super Nintendo Entertainment System|sgb.boot.rom|O|d574d4f9c12f305074798f54c091a8b4|sgb.boot.rom (SGB Boot Image)
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
bsnes2014_performance_libretro|Super Nintendo Entertainment System|sgb.boot.rom|O|d574d4f9c12f305074798f54c091a8b4|sgb.boot.rom (SGB Boot Image)
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|cx4.data.rom|O|037ac4296b6b6a5c47c440188d3c72e3|cx4.data.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|SGB1.sfc|O|b15ddb15721c657d82c5bab6db982ee9|SGB1.sfc (SGB Boot Image)
bsnes_hd_beta_libretro|Super Nintendo Entertainment System|SGB2.sfc|O|8ecd73eb4edf7ed7e81aef1be80031d5|SGB2.sfc (SGB Boot Image)
bsnes_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
bsnes_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
bsnes_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
bsnes_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
bsnes_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
bsnes_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
bsnes_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
bsnes_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
bsnes_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
bsnes_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
bsnes_libretro|Super Nintendo Entertainment System|cx4.data.rom|O|037ac4296b6b6a5c47c440188d3c72e3|cx4.data.rom
bsnes_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
bsnes_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
bsnes_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
bsnes_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
bsnes_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
bsnes_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
bsnes_libretro|Super Nintendo Entertainment System|SGB1.sfc|O|b15ddb15721c657d82c5bab6db982ee9|SGB1.sfc (SGB Boot Image)
bsnes_libretro|Super Nintendo Entertainment System|SGB2.sfc|O|8ecd73eb4edf7ed7e81aef1be80031d5|SGB2.sfc (SGB Boot Image)
bsnes_libretro|Super Nintendo Entertainment System|BS-X.bin|O|fed4d8242cfbed61343d53d48432aced|BS-X.bin (BS-X - Sore wa Namae o Nusumareta Machi no Monogatari (Japan) (Rev 1))
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|cx4.data.rom|O|037ac4296b6b6a5c47c440188d3c72e3|cx4.data.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
bsnes_mercury_accuracy_libretro|Super Nintendo Entertainment System|sgb.boot.rom|O|d574d4f9c12f305074798f54c091a8b4|sgb.boot.rom (SGB Boot Image)
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|cx4.data.rom|O|037ac4296b6b6a5c47c440188d3c72e3|cx4.data.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
bsnes_mercury_balanced_libretro|Super Nintendo Entertainment System|sgb.boot.rom|O|d574d4f9c12f305074798f54c091a8b4|sgb.boot.rom (SGB Boot Image)
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
bsnes_mercury_performance_libretro|Super Nintendo Entertainment System|sgb.boot.rom|O|d574d4f9c12f305074798f54c091a8b4|sgb.boot.rom (SGB Boot Image)
cdi2015_libretro|CD-i|cdimono1.zip|R|801c529739b83e1490b897f2d3ffbb3a|cdimono1.zip
desmume2015_libretro|Nintendo DS|firmware.bin|O|e45033d9b0fa6b0de071292bba7c9d13|firmware.bin (NDS Firmware)
desmume2015_libretro|Nintendo DS|bios7.bin|O|df692a80a5b1bc90728bc3dfc76cd948|bios7.bin (ARM7 BIOS)
desmume2015_libretro|Nintendo DS|bios9.bin|O|a392174eb3e572fed6447e956bde4b25|bios9.bin (ARM9 BIOS)
desmume_libretro|Nintendo DS|firmware.bin|O|e45033d9b0fa6b0de071292bba7c9d13|firmware.bin (NDS Firmware)
desmume_libretro|Nintendo DS|bios7.bin|O|df692a80a5b1bc90728bc3dfc76cd948|bios7.bin (ARM7 BIOS)
desmume_libretro|Nintendo DS|bios9.bin|O|a392174eb3e572fed6447e956bde4b25|bios9.bin (ARM9 BIOS)
dolphin_libretro|GameCube / Wii|dolphin-emu/Sys/codehandler.bin|R|1f118b8735fcf40c20b38c3184eebfd9|Dolphin 'Sys' folder with dolphin-emu/Sys/codehandler.bin
dolphin_libretro|GameCube / Wii|dolphin-emu/Sys/GC/JAP/IPL.bin|O|b17148254a5799684c7d783206504926|dolphin-emu/Sys/GC/JAP/IPL.bin (GameCube JP BIOS)
dolphin_libretro|GameCube / Wii|dolphin-emu/Sys/GC/USA/IPL.bin|O|b17148254a5799684c7d783206504926|dolphin-emu/Sys/GC/USA/IPL.bin (GameCube US BIOS)
dolphin_libretro|GameCube / Wii|dolphin-emu/Sys/GC/EUR/IPL.bin|O|db92574caab77a7ec99d4605fd6f2450|dolphin-emu/Sys/GC/EUR/IPL.bin (GameCube EU BIOS)
dosbox_core_libretro|DOS|MT32_CONTROL.ROM|O|5626206284b22c2734f3e9efefcd2675|MT32_CONTROL.ROM (MT-32 Control ROM v1.07)
dosbox_core_libretro|DOS|MT32_PCM.ROM|O|89e42e386e82e0cacb4a2704a03706ca|MT32_PCM.ROM (MT-32 PCM ROM)
dosbox_core_libretro|DOS|CM32L_CONTROL.ROM|O|bfff32b6144c1d706109accb6e6b1113|CM32L_CONTROL.ROM (CM-32L/LAPC-I Control ROM v1.02)
dosbox_core_libretro|DOS|CM32L_PCM.ROM|O|08cdcfa0ed93e9cb16afa76e6ac5f0a4|CM32L_PCM.ROM (CM-32L/CM-64/LAPC-I PCM ROM)
dosbox_core_libretro|DOS|libbass.so|O|255fb8ab523b179320f08f44db36a9fa|libbass.so (BASS Linux library)
dosbox_core_libretro|DOS|libbassmidi.so|O|3a48c08c224c32f2f4829b960e95f73b|libbassmidi.so (BASSMIDI Linux library)
dosbox_core_libretro|DOS|bass.dll|O|7253a9fabc089044b3b8e9156b07d6f9|bass.dll (BASS Windows library)
dosbox_core_libretro|DOS|bassmidi.dll|O|0b00a4ab6b68960efa49272d416b040d|bassmidi.dll (BASSMIDI Windows library)
dosbox_core_libretro|DOS|libbass.dylib|O|19addeb0da536c753797ed59b44d5ba3|libbass.dylib (BASS macOS library)
dosbox_core_libretro|DOS|libbassmidi.dylib|O|ea143b23779d01152633442abb1e0c67|libbassmidi.dylib (BASSMIDI macOS library)
duckstation_libretro|PlayStation|scph5500.bin|R|8dd7d5296a650fac7319bce665a6a53c|scph5500.bin (PS1 JP BIOS)
duckstation_libretro|PlayStation|scph5501.bin|R|490f666e1afb15b7362b406ed1cea246|scph5501.bin (PS1 US BIOS)
duckstation_libretro|PlayStation|scph5502.bin|R|32736f17079d0b2b7024407c39bd3050|scph5502.bin (PS1 EU BIOS)
ecwolf_libretro|Wolfenstein 3D Game Engine|ecwolf.pk3|R|c011b428819eea4a80b455c245a5a04d|ecwolf.pk3 (ECWolf System File)
eka2l1_libretro|Symbian OS / N-Gage|eka2l1/firmware|R||'eka2l1/firmware' folder (a device firmware dump: an RPKG, or a ROM together with its ROFS)
emuscv_libretro|Super Cassette Vision|upd7801g.s01|R|635a978fd40db9a18ee44eff449fc126|upd7801g.s01 (Super Cassette Vision BIOS)
emux_gb_libretro|Game Boy/Game Boy Color|dmg_boot.bin|R|32fbbd84168d3482956eb3c5051637f5|dmg_boot.bin (Game Boy Boot ROM)
emux_sms_libretro|Sega Master System|bios.sms|R|840481177270d5642a14ca71ee72844c|bios.sms (Master System BIOS)
ep128emu_core_libretro|128|ep128emu/roms/exos21.rom|O|f36f24cbb87745fbd2714e4df881db09|exos21.rom (Enterprise 128 Expandible OS 2.1)
ep128emu_core_libretro|128|ep128emu/roms/basic21.rom|O|e972fe42b398c9ff1d93ff014786aec6|basic21.rom (Enterprise 128 BASIC Interpreter v2.1)
ep128emu_core_libretro|128|ep128emu/roms/exdos13.rom|O|ddff70c014d1958dc75378b6c9aab6f8|exdos13.rom (Enterprise 128 Disk Controller v1.3)
ep128emu_core_libretro|128|ep128emu/roms/exos20.rom|O|5ad3baaad3b5156d6b60b34229a676fb|exos20.rom (Enterprise 64 Expandible OS 2.0)
ep128emu_core_libretro|128|ep128emu/roms/basic20.rom|O|8e18edce4a7acb2c33cc0ab18f988482|basic20.rom (Enterprise 64 BASIC Interpreter v2.0)
ep128emu_core_libretro|128|ep128emu/roms/epfileio.rom|O|a68ebcbc73a4d2178d755b7755bf18fe|epfileio.rom (Enterprise 128 Direct File I/O)
ep128emu_core_libretro|128|ep128emu/roms/exos24uk.rom|O|55af78f877a21ca45eb2df68a74fcc60|exos24uk.rom (Enterprise 128 Expandible OS 2.4)
ep128emu_core_libretro|128|ep128emu/roms/hun.rom|O|22167938f142c222f40992839aa21a06|hun.rom (Enterprise 128 Hungarian language extension)
ep128emu_core_libretro|128|ep128emu/roms/epd19hft.rom|O|12cfc9c7e48c8a16c2e09edbd926d467|epd19hft.rom (Enterprise 128 EP-DOS with Hungarian language extension)
ep128emu_core_libretro|128|ep128emu/roms/zt19hfnt.rom|O|653daaf7b9b29c2c4e577f489580f247|zt19hfnt.rom (Enterprise 128 ZozoTools with Hungarian language extension 1.9)
ep128emu_core_libretro|128|ep128emu/roms/brd.rom|O|6af0402906944fd134004b85097c8524|brd.rom (Enterprise 128 German language extension)
ep128emu_core_libretro|128|ep128emu/roms/zt19uk.rom|O|228540b6be83ae2acd7569c8ff0f91d0|zt19uk.rom (Enterprise 128 ZozoTools extension)
ep128emu_core_libretro|128|ep128emu/roms/tvc22_sys.rom|O|8c54285f541930cde766069942bad0f2|tvc22_sys.rom (Videoton TVC system BIOS)
ep128emu_core_libretro|128|ep128emu/roms/tvc22_ext.rom|O|5ce95a26ceed5bec73995d83568da9cf|tvc22_ext.rom (Videoton TVC extension BIOS)
ep128emu_core_libretro|128|ep128emu/roms/tvcfileio.rom|O|a2cf86ba8e7fc58b242137fe59036832|tvcfileio.rom (Videoton TVC Direct File I/O)
ep128emu_core_libretro|128|ep128emu/roms/tvc_dos12d.rom|O|88dc7876d584f90e4106f91444ab23b7|tvc_dos12d.rom (Videoton TVC disk BIOS)
ep128emu_core_libretro|128|ep128emu/roms/cpc464.rom|O|a993f85b88ac4350cf4d41554e87fe4f|cpc464.rom (Amstrad CPC 464 BIOS)
ep128emu_core_libretro|128|ep128emu/roms/cpc664.rom|O|5a384a2310f472c7857888371c00ed66|cpc664.rom (Amstrad CPC 664 BIOS)
ep128emu_core_libretro|128|ep128emu/roms/cpc6128.rom|O|b96280dc6c95a48857b4b8eb931533ae|cpc6128.rom (Amstrad CPC 6128 BIOS)
ep128emu_core_libretro|128|ep128emu/roms/cpc_amsdos.rom|O|25629dfe870d097469c217b95fdc1c95|cpc_amsdos.rom (Amstrad CPC AMSDOS BIOS)
ep128emu_core_libretro|128|ep128emu/roms/zx128.rom|O|85fede415f4294cc777517d7eada482e|zx128.rom (ZX Spectrum 128 BIOS)
ep128emu_core_libretro|128|ep128emu/roms/zx48.rom|O|4c42a2f075212361c3117015b107ff68|zx48.rom (ZX Spectrum 48 BIOS)
fbneo_cps12_libretro|CP System I/II|fbneo/hiscore.dat|O|37fc4e050b53a1ef2c2e7f3042553025|fbneo/hiscore.dat (High Score support database)
fbneo_libretro|Arcade (various)|fbneo/neogeo.zip|O|00dad01abdbf8ea9e79ad2fe11bdb182|fbneo/neogeo.zip (Neo Geo BIOS)
fbneo_libretro|Arcade (various)|fbneo/neocdz.zip|O|62d56b126e78f3d82faa4ee8a92c3e82|fbneo/neocdz.zip (Neo Geo CDZ System BIOS)
fbneo_libretro|Arcade (various)|fbneo/decocass.zip|O|b7e1189b341bf6a8e270017c096d21b0|fbneo/decocass.zip (DECO Cassette System BIOS)
fbneo_libretro|Arcade (various)|fbneo/isgsm.zip|O|4a56d56e2219c5e2b006b66a4263c01c|fbneo/isgsm.zip (ISG Selection Master Type 2006 System BIOS)
fbneo_libretro|Arcade (various)|fbneo/midssio.zip|O|5904b0de768d1d506e766aa7e18994c1|fbneo/midssio.zip (Midway SSIO Sound Board Internal ROM)
fbneo_libretro|Arcade (various)|fbneo/nmk004.zip|O|bfacf1a68792d5348f93cf724d2f1dda|fbneo/nmk004.zip (NMK004 Internal ROM)
fbneo_libretro|Arcade (various)|fbneo/pgm.zip|O|87cc944eef4c671aa2629a8ba48a08e0|fbneo/pgm.zip (PGM System BIOS)
fbneo_libretro|Arcade (various)|fbneo/skns.zip|O|3f956c4e7008804cb47cbde49bd5b908|fbneo/skns.zip (Super Kaneko Nova System BIOS)
fbneo_libretro|Arcade (various)|fbneo/ym2608.zip|O|79ae0d2bb1901b7e606b6dc339b79a97|fbneo/ym2608.zip (YM2608 Internal ROM)
fbneo_libretro|Arcade (various)|fbneo/cchip.zip|O|df6f8a3d83c028a5cb9f2f2be60773f3|fbneo/cchip.zip (C-Chip Internal ROM)
fbneo_libretro|Arcade (various)|fbneo/bubsys.zip|O|f81298afd68a1a24a49a1a2d9f087964|fbneo/bubsys.zip (Bubble System BIOS)
fbneo_libretro|Arcade (various)|fbneo/namcoc69.zip|O|ad9af7a9560cad74f1644328213748f6|fbneo/namcoc69.zip (Namco C69 BIOS)
fbneo_libretro|Arcade (various)|fbneo/namcoc70.zip|O|aa569a303793510b2b4173480148de4b|fbneo/namcoc70.zip (Namco C70 BIOS)
fbneo_libretro|Arcade (various)|fbneo/namcoc75.zip|O|17516c33298e52424ffb58afc2ad208c|fbneo/namcoc75.zip (Namco C75 BIOS)
fbneo_libretro|Arcade (various)|fbneo/coleco.zip|O|94915714a814a84f7c292e6db71f3ad2|fbneo/coleco.zip (ColecoVision System BIOS)
fbneo_libretro|Arcade (various)|fbneo/fdsbios.zip|O|c26bf1744cb7f6ffe441f463870321f8|fbneo/fdsbios.zip (FDS System BIOS)
fbneo_libretro|Arcade (various)|fbneo/msx.zip|O|25a8912d7bf3cdad9beaa6d5cc14ea38|fbneo/msx.zip (MSX1 System BIOS)
fbneo_libretro|Arcade (various)|fbneo/ngp.zip|O|5bc25f80395a68790a69b7eb3e57b897|fbneo/ngp.zip (NeoGeo Pocket BIOS)
fbneo_libretro|Arcade (various)|fbneo/spectrum.zip|O|4698414be3369fff17bf6d3111734c6c|fbneo/spectrum.zip (ZX Spectrum BIOS)
fbneo_libretro|Arcade (various)|fbneo/spec128.zip|O|1a524bfa489cec90c941e6587d553a56|fbneo/spec128.zip (ZX Spectrum 128 BIOS)
fbneo_libretro|Arcade (various)|fbneo/spec1282a.zip|O|b2fed9c6a9e54af7d90b6f2b3516fcf9|fbneo/spec1282a.zip (ZX Spectrum 128 +2a BIOS)
fbneo_libretro|Arcade (various)|fbneo/channelf.zip|O|2f2f8de3827ae1faf2495e497ca95232|fbneo/channelf.zip (Fairchild Channel F BIOS)
fbneo_libretro|Arcade (various)|fbneo/hiscore.dat|O|37fc4e050b53a1ef2c2e7f3042553025|fbneo/hiscore.dat (High Score support database)
fbneo_neogeo_libretro|Neo Geo|fbneo/neogeo.zip|O|00dad01abdbf8ea9e79ad2fe11bdb182|fbneo/neogeo.zip (Neo Geo BIOS)
fbneo_neogeo_libretro|Neo Geo|fbneo/neocdz.zip|O|62d56b126e78f3d82faa4ee8a92c3e82|fbneo/neocdz.zip (Neo Geo CDZ System BIOS)
fbneo_neogeo_libretro|Neo Geo|fbneo/hiscore.dat|O|37fc4e050b53a1ef2c2e7f3042553025|fbneo/hiscore.dat (High Score support database)
fceumm_libretro|Nintendo Entertainment System|disksys.rom|O|ca30b50f880eb660a320674ed365ef7a|disksys.rom (Family Computer Disk System BIOS)
fceumm_libretro|Nintendo Entertainment System|nes.pal|O||nes.pal (custom NES Palette)
fceumm_libretro|Nintendo Entertainment System|gamegenie.nes|O|7f98d77d7a094ad7d069b74bd553ec98|gamegenie.nes (Game Genie add-on cartridge)
fixgb_libretro|Game Boy/Game Boy Color|gbc_bios.bin|O|dbfce9db9deaa2567f6a84fde55f9680|gbc_bios.bin (Game Boy Color BIOS)
fixnes_libretro|Nintendo Entertainment System|disksys.rom|O|ca30b50f880eb660a320674ed365ef7a|disksys.rom (Family Computer Disk System BIOS)
flycast_gles2_libretro|Sega Dreamcast|dc/dc_boot.bin|O|e10c53c2f8b90bab96ead2d368858623|dc/dc_boot.bin (Dreamcast BIOS)
flycast_gles2_libretro|Sega Dreamcast|dc/naomi.zip|O|526eda1e2a7920c92c88178789d71d84|dc/naomi.zip (Naomi Bios from MAME)
flycast_gles2_libretro|Sega Dreamcast|dc/naomi2.zip|O|c50072cbab75673e1b1a6b94355e6fa8|dc/naomi2.zip (Naomi2 Bios from MAME)
flycast_gles2_libretro|Sega Dreamcast|dc/hod2bios.zip|O|f4011d3116500354edf7302a90402711|dc/hod2bios.zip (Naomi The House of the Dead 2 Bios from MAME)
flycast_gles2_libretro|Sega Dreamcast|dc/f355dlx.zip|O|1028615bcac4c31634a3364ce5c04044|dc/f355dlx.zip (Naomi Ferrari F355 Challenge deluxe Bios from MAME)
flycast_gles2_libretro|Sega Dreamcast|dc/f355bios.zip|O|547f3d12aed389058ca06148f1cca0ed|dc/f355bios.zip (Naomi Ferrari F355 Challenge twin/deluxe Bios from MAME)
flycast_gles2_libretro|Sega Dreamcast|dc/airlbios.zip|O|7a11bfe0cc72886d032e386db68f890c|dc/airlbios.zip (Naomi Airline Pilots deluxe Bios from MAME)
flycast_gles2_libretro|Sega Dreamcast|dc/awbios.zip|O|85254fbe320ca82a768ec2c26bb08def|dc/awbios.zip (Atomiswave BIOS from MAME)
flycast_libretro|Sega Dreamcast|dc/dc_boot.bin|O|e10c53c2f8b90bab96ead2d368858623|dc/dc_boot.bin (Dreamcast BIOS)
flycast_libretro|Sega Dreamcast|dc/naomi.zip|O|526eda1e2a7920c92c88178789d71d84|dc/naomi.zip (Naomi Bios from MAME)
flycast_libretro|Sega Dreamcast|dc/naomi2.zip|O|c50072cbab75673e1b1a6b94355e6fa8|dc/naomi2.zip (Naomi2 Bios from MAME)
flycast_libretro|Sega Dreamcast|dc/hod2bios.zip|O|f4011d3116500354edf7302a90402711|dc/hod2bios.zip (Naomi The House of the Dead 2 Bios from MAME)
flycast_libretro|Sega Dreamcast|dc/f355dlx.zip|O|1028615bcac4c31634a3364ce5c04044|dc/f355dlx.zip (Naomi Ferrari F355 Challenge deluxe Bios from MAME)
flycast_libretro|Sega Dreamcast|dc/f355bios.zip|O|547f3d12aed389058ca06148f1cca0ed|dc/f355bios.zip (Naomi Ferrari F355 Challenge twin/deluxe Bios from MAME)
flycast_libretro|Sega Dreamcast|dc/airlbios.zip|O|7a11bfe0cc72886d032e386db68f890c|dc/airlbios.zip (Naomi Airline Pilots deluxe Bios from MAME)
flycast_libretro|Sega Dreamcast|dc/awbios.zip|O|85254fbe320ca82a768ec2c26bb08def|dc/awbios.zip (Atomiswave BIOS from MAME)
fmsx_libretro|MSX|MSX.ROM|R|aa95aea2563cd5ec0a0919b44cc17d47|MSX.ROM (MSX BIOS)
fmsx_libretro|MSX|MSX2.ROM|R|ec3a01c91f24fbddcbcab0ad301bc9ef|MSX2.ROM (MSX2 BIOS)
fmsx_libretro|MSX|MSX2EXT.ROM|R|2183c2aff17cf4297bdb496de78c2e8a|MSX2EXT.ROM (MSX2 ExtROM)
fmsx_libretro|MSX|MSX2P.ROM|R|6d8c0ca64e726c82a4b726e9b01cdf1e|MSX2P.ROM (MSX2+ BIOS)
fmsx_libretro|MSX|MSX2PEXT.ROM|R|7c8243c71d8f143b2531f01afa6a05dc|MSX2PEXT.ROM (MSX2+ ExtROM)
fmsx_libretro|MSX|DISK.ROM|O|80dcd1ad1a4cf65d64b7ba10504e8190|DISK.ROM (DiskROM/BDOS)
fmsx_libretro|MSX|FMPAC.ROM|O|6f69cc8b5ed761b03afd78000dfb0e19|FMPAC.ROM (FMPAC BIOS)
fmsx_libretro|MSX|MSXDOS2.ROM|O|6418d091cd6907bbcf940324339e43bb|MSXDOS2.ROM (MSX-DOS 2)
fmsx_libretro|MSX|PAINTER.ROM|O|403cdea1cbd2bb24fae506941f8f655e|PAINTER.ROM (Yamaha Painter)
fmsx_libretro|MSX|KANJI.ROM|O|febe8782b466d7c3b16de6d104826b34|KANJI.ROM (Kanji Font)
freechaf_libretro|Channel F|sl31253.bin|R|ac9804d4c0e9d07e33472e3726ed15c3|sl31253.bin
freechaf_libretro|Channel F|sl31254.bin|R|da98f4bb3242ab80d76629021bb27585|sl31254.bin
freechaf_libretro|Channel F|sl90025.bin|R|95d339631d867c8f1d15a5f2ec26069d|sl90025.bin
freeintv_libretro|Intellivision|exec.bin|R|62e761035cb657903761800f4437b8af|exec.bin
freeintv_libretro|Intellivision|grom.bin|R|0cd5946c6473e42e8e4c2137785e427f|grom.bin
freej2me_libretro|J2ME|freej2me-lr.jar|R|ccd92e7156ce2f0ce14c88ffb68a16eb|freej2me-lr.jar
freej2me_plus_libretro|J2ME|freej2me_plus-lr.jar|R||freej2me_plus-lr.jar (Main Application)
fuse_libretro|ZX Spectrum (various)|fuse/128p-0.rom|O|a249565f03b98d004ee7f019570069cd|128p-0.rom (Pentagon machines)
fuse_libretro|ZX Spectrum (various)|fuse/128p-1.rom|O|6e09e5d3c4aef166601669feaaadc01c|128p-1.rom (Pentagon machines)
fuse_libretro|ZX Spectrum (various)|fuse/trdos.rom|O|0da70a5d2a0e733398e005b96b7e4ba6|trdos.rom (Pentagon machines)
fuse_libretro|ZX Spectrum (various)|fuse/gluck.rom|O|d5869034604dbfd2c1d54170e874fd0a|gluck.rom (Pentagon 512K / 1024)
fuse_libretro|ZX Spectrum (various)|fuse/256s-0.rom|O|b9fda5b6a747ff037365b0e2d8c4379a|256s-0.rom (Scorpion 256K)
fuse_libretro|ZX Spectrum (various)|fuse/256s-1.rom|O|643861ad34831b255bf2eb64e8b6ecb8|256s-1.rom (Scorpion 256K)
fuse_libretro|ZX Spectrum (various)|fuse/256s-2.rom|O|d8ad507b1c915a9acfe0d73957082926|256s-2.rom (Scorpion 256K)
fuse_libretro|ZX Spectrum (various)|fuse/256s-3.rom|O|ce0723f9bc02f4948c15d3b3230ae831|256s-3.rom (Scorpion 256K)
galaksija_libretro|Galaksija|galaksija/CHRGEN.BIN|O|ecae5c55d75a2fe0871d0ebd95663628|CHRGEN.BIN (Character ROM)
galaksija_libretro|Galaksija|galaksija/ROM1.BIN|O|c7ce14d6a81062db862f3ce5afedcfb6|ROM1.BIN (Base ROM)
galaksija_libretro|Galaksija|galaksija/ROM2.BIN|O|b406d05922dac2eaf3c2e68157b1b468|ROM2.BIN (Extensions)
gambatte_libretro|Game Boy/Game Boy Color|gb_bios.bin|O|32fbbd84168d3482956eb3c5051637f5|gb_bios.bin (Game Boy BIOS)
gambatte_libretro|Game Boy/Game Boy Color|gbc_bios.bin|O|dbfce9db9deaa2567f6a84fde55f9680|gbc_bios.bin (Game Boy Color BIOS)
gearboy_libretro|Game Boy/Game Boy Color/Super Game Boy|dmg_boot.bin|O|32fbbd84168d3482956eb3c5051637f5|dmg_boot.bin (Game Boy boot ROM)
gearboy_libretro|Game Boy/Game Boy Color/Super Game Boy|cgb_boot.bin|O|dbfce9db9deaa2567f6a84fde55f9680|cgb_boot.bin (Game Boy Color boot ROM)
gearcoleco_libretro|ColecoVision / ADAM|colecovision.rom|R|2c66f5911e5b42b8ebe113403548eee7|colecovision.rom (ColecoVision / ADAM OS-7 BIOS)
gearcoleco_libretro|ColecoVision / ADAM|eos.rom|O||eos.rom (required for ADAM)
gearcoleco_libretro|ColecoVision / ADAM|writer.rom|O||writer.rom (required for ADAM)
geargrafx_libretro|PC Engine/SuperGrafx/CD/LaserActive|syscard3.pce|O|38179df8f4ac870017db21ebcbf53114|syscard3.pce (Super CD-ROM2 System V3.xx)
geargrafx_libretro|PC Engine/SuperGrafx/CD/LaserActive|syscard2.pce|O|3cdd6614a918616bfc41c862e889dd79|syscard2.pce (CD-ROM System V2.xx)
geargrafx_libretro|PC Engine/SuperGrafx/CD/LaserActive|syscard1.pce|O|2b7ccb3d86baa18f6402c176f3065082|syscard1.pce (CD-ROM System V1.xx)
geargrafx_libretro|PC Engine/SuperGrafx/CD/LaserActive|gexpress.pce|O|6d2cb14fc3e1f65ceb135633d1694122|gexpress.pce (Game Express CD Card)
geargrafx_libretro|PC Engine/SuperGrafx/CD/LaserActive|pac-n1.bin|O||pac-n1.bin (LaserActive PAC-N1, Japan)
geargrafx_libretro|PC Engine/SuperGrafx/CD/LaserActive|pce-lp1.bin|O||pce-lp1.bin (LaserActive PCE-LP1, Japan)
geargrafx_libretro|PC Engine/SuperGrafx/CD/LaserActive|pac-n10.bin|O||pac-n10.bin (LaserActive PAC-N10, USA)
gearlynx_libretro|Lynx|lynxboot.img|R|fcd403db69f54290b51035d82f835e7b|lynxboot.img (Lynx Boot Image)
gearsystem_libretro|Sega 8-bit (MS/GG/SG-1000)|bios.sms|O|840481177270d5642a14ca71ee72844c|bios.sms (Master System BIOS)
gearsystem_libretro|Sega 8-bit (MS/GG/SG-1000)|bios.gg|O|672e104c3be3a238301aceffc3b23fd6|bios.gg (Game Gear BIOS)
geartowns_libretro|FM Towns|geartowns/FMT_SYS.ROM|R||FMT_SYS.ROM (FM Towns System ROM)
geartowns_libretro|FM Towns|geartowns/FMT_DOS.ROM|R||FMT_DOS.ROM (FM Towns OS ROM)
geartowns_libretro|FM Towns|geartowns/FMT_FNT.ROM|R||FMT_FNT.ROM (FM Towns Font ROM)
geartowns_libretro|FM Towns|geartowns/FMT_DIC.ROM|R||FMT_DIC.ROM (FM Towns Dictionary ROM)
geartowns_libretro|FM Towns|geartowns/FMT_F20.ROM|O||FMT_F20.ROM (FM Towns 20-dot Font ROM)
geartowns_libretro|FM Towns|geartowns/fmtowns/fmt_sys.rom|O||fmtowns/fmt_sys.rom (FM Towns Model 1/2 set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtowns/fmt_dos.rom|O||fmtowns/fmt_dos.rom (FM Towns Model 1/2 set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtowns/fmt_fnt.rom|O||fmtowns/fmt_fnt.rom (FM Towns Model 1/2 set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtowns/fmt_dic.rom|O||fmtowns/fmt_dic.rom (FM Towns Model 1/2 set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtowns.zip|O||fmtowns.zip (FM Towns Model 1/2 set, MAME zip)
geartowns_libretro|FM Towns|geartowns/fmtownsux/fmt_sys_a.rom|O||fmtownsux/fmt_sys_a.rom (FM Towns II UX set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsux/fmt_dos_a.rom|O||fmtownsux/fmt_dos_a.rom (FM Towns II UX set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsux/fmt_fnt.rom|O||fmtownsux/fmt_fnt.rom (FM Towns II UX set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsux/fmt_dic.rom|O||fmtownsux/fmt_dic.rom (FM Towns II UX set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsux/mytownsux.rom|O||fmtownsux/mytownsux.rom (FM Towns II UX set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsux.zip|O||fmtownsux.zip (FM Towns II UX set, MAME zip)
geartowns_libretro|FM Towns|geartowns/fmtmarty/mrom.m36|O||fmtmarty/mrom.m36 (FM Towns Marty set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtmarty/mrom.m37|O||fmtmarty/mrom.m37 (FM Towns Marty set, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtmarty.zip|O||fmtmarty.zip (FM Towns Marty set, MAME zip)
geartowns_libretro|FM Towns|geartowns/fmtownshr/fmthr_sys.rom|O||fmtownshr/fmthr_sys.rom (FM Towns II HR set for the HG, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownshr/fmt_dos.rom|O||fmtownshr/fmt_dos.rom (FM Towns II HR set for the HG, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownshr/fmt_fnt.rom|O||fmtownshr/fmt_fnt.rom (FM Towns II HR set for the HG, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownshr/fmt_dic.rom|O||fmtownshr/fmt_dic.rom (FM Towns II HR set for the HG, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownshr/mytownshr.rom|O||fmtownshr/mytownshr.rom (FM Towns II HR set for the HG, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownshr.zip|O||fmtownshr.zip (FM Towns II HR set for the HG, MAME zip)
geartowns_libretro|FM Towns|geartowns/fmtownsftv/fmt_sys.rom|O||fmtownsftv/fmt_sys.rom (FM Towns II Fresh TV set, the HG's second choice, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsftv/fmt_dos.rom|O||fmtownsftv/fmt_dos.rom (FM Towns II Fresh TV set, the HG's second choice, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsftv/fmt_fnt.rom|O||fmtownsftv/fmt_fnt.rom (FM Towns II Fresh TV set, the HG's second choice, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsftv/fmt_dic.rom|O||fmtownsftv/fmt_dic.rom (FM Towns II Fresh TV set, the HG's second choice, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsftv/fmt_f20.rom|O||fmtownsftv/fmt_f20.rom (FM Towns II Fresh TV set, the HG's second choice, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsftv/mytownsftv.rom|O||fmtownsftv/mytownsftv.rom (FM Towns II Fresh TV set, the HG's second choice, MAME names)
geartowns_libretro|FM Towns|geartowns/fmtownsftv.zip|O||fmtownsftv.zip (FM Towns II Fresh TV set, the HG's second choice, MAME zip)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|bios_MD.bin|O|d3293ebaaa7f4eb2a6766b68a0fb4609|bios_MD.bin (Mega Drive startup ROM)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|bios_CD_E.bin|O|e66fa1dc5820d254611fdcdba0662372|bios_CD_E.bin (MegaCD EU BIOS)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|bios_CD_U.bin|O|2efd74e3232ff260e371b99f84024f7f|bios_CD_U.bin (SegaCD US BIOS)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|bios_CD_J.bin|O|278a9397d192149e84e820ac621a8edd|bios_CD_J.bin (MegaCD JP BIOS)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|bios_E.sms|O|840481177270d5642a14ca71ee72844c|bios_E.sms (MasterSystem EU BIOS)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|bios_U.sms|O|840481177270d5642a14ca71ee72844c|bios_U.sms (MasterSystem US BIOS)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|bios_J.sms|O|24a519c53f67b00640d0048ef7089105|bios_J.sms (MasterSystem JP BIOS)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|bios.gg|O|672e104c3be3a238301aceffc3b23fd6|bios.gg (GameGear BIOS)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|sk.bin|O|4ea493ea4e9f6c9ebfccbdb15110367e|sk.bin (Sonic & Knuckles ROM)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|sk2chip.bin|O|b4e76e416b887f4e7413ba76fa735f16|sk2chip.bin (Sonic & Knuckles UPMEM ROM)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|areplay.bin|O|a0028b3043f9d59ceeb03da5b073b30d|areplay.bin (Action Replay ROM)
genesis_plus_gx_libretro|Sega 8/16-bit (Various)|ggenie.bin|O|e8af7fe115a75c849f6aab3701e7799b|ggenie.bin (Game Genie ROM)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|bios_MD.bin|O|d3293ebaaa7f4eb2a6766b68a0fb4609|bios_MD.bin (Mega Drive startup ROM)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|bios_CD_E.bin|O|e66fa1dc5820d254611fdcdba0662372|bios_CD_E.bin (MegaCD EU BIOS)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|bios_CD_U.bin|O|2efd74e3232ff260e371b99f84024f7f|bios_CD_U.bin (SegaCD US BIOS)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|bios_CD_J.bin|O|278a9397d192149e84e820ac621a8edd|bios_CD_J.bin (MegaCD JP BIOS)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|bios_E.sms|O|840481177270d5642a14ca71ee72844c|bios_E.sms (MasterSystem EU BIOS)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|bios_U.sms|O|840481177270d5642a14ca71ee72844c|bios_U.sms (MasterSystem US BIOS)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|bios_J.sms|O|24a519c53f67b00640d0048ef7089105|bios_J.sms (MasterSystem JP BIOS)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|bios.gg|O|672e104c3be3a238301aceffc3b23fd6|bios.gg (GameGear BIOS)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|sk.bin|O|4ea493ea4e9f6c9ebfccbdb15110367e|sk.bin (Sonic & Knuckles ROM)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|sk2chip.bin|O|b4e76e416b887f4e7413ba76fa735f16|sk2chip.bin (Sonic & Knuckles UPMEM ROM)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|areplay.bin|O|a0028b3043f9d59ceeb03da5b073b30d|areplay.bin (Action Replay ROM)
genesis_plus_gx_wide_libretro|Sega 8/16-bit (Various)|ggenie.bin|O|e8af7fe115a75c849f6aab3701e7799b|ggenie.bin (Game Genie ROM)
geolith_libretro|Neo Geo|aes.zip|R|9d2ff2333e23910cf56f7f785609d36a|aes.zip (Neo Geo AES System ROM)
geolith_libretro|Neo Geo|neogeo.zip|R|00dad01abdbf8ea9e79ad2fe11bdb182|neogeo.zip (Neo Geo MVS System ROM)
geolith_libretro|Neo Geo|neocd.zip|R||neocd.zip (Neo Geo CD System ROM)
geolith_libretro|Neo Geo|neocdz.zip|R|66bf2aeb1b870eac603925601e48af82|neocdz.zip (Neo Geo CDZ System ROM)
geolith_libretro|Neo Geo|irrmaze.zip|O||irrmaze.zip (The Irritating Maze)
gpsp_libretro|Game Boy Advance|gba_bios.bin|R|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (Game Boy Advance BIOS)
handy_libretro|Lynx|lynxboot.img|O|fcd403db69f54290b51035d82f835e7b|lynxboot.img (Lynx Boot Image)
hatari2014_libretro|Atari ST/STE/TT/Falcon|tos.img|R|c1c57ce48e8ee4135885cee9e63a68a2|tos.img (TOS 1.02 US aka Mega TOS)
hatari_libretro|Atari ST/STE/TT/Falcon|tos.img|R|c1c57ce48e8ee4135885cee9e63a68a2|tos.img (TOS 1.02 US aka Mega TOS)
hatarib_libretro|Atari ST/STE/TT/Falcon|tos.img|O|c1c57ce48e8ee4135885cee9e63a68a2|tos.img (Default TOS)
higan_sfc_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
higan_sfc_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
higan_sfc_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
higan_sfc_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
higan_sfc_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
higan_sfc_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
higan_sfc_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
higan_sfc_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
higan_sfc_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
higan_sfc_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
higan_sfc_libretro|Super Nintendo Entertainment System|cx4.data.rom|O|037ac4296b6b6a5c47c440188d3c72e3|cx4.data.rom
higan_sfc_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
higan_sfc_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
higan_sfc_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
higan_sfc_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
higan_sfc_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
higan_sfc_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
higan_sfc_libretro|Super Nintendo Entertainment System|SGB1.sfc/sgb1.boot.rom|O|d574d4f9c12f305074798f54c091a8b4|SGB1.sfc/sgb1.boot.rom (SGB Boot BIOS)
higan_sfc_libretro|Super Nintendo Entertainment System|SGB1.sfc/program.rom|O|b15ddb15721c657d82c5bab6db982ee9|SGB1.sfc/program.rom (SGB Boot Image)
higan_sfc_libretro|Super Nintendo Entertainment System|SGB2.sfc/sgb2.boot.rom|O|e0430bca9925fb9882148fd2dc2418c1|SGB2.sfc/sgb2.boot.rom (SGB Boot BIOS)
higan_sfc_libretro|Super Nintendo Entertainment System|SGB2.sfc/program.rom|O|8ecd73eb4edf7ed7e81aef1be80031d5|SGB2.sfc/program.rom (SGB Boot Image)
holani_libretro|Lynx|lynxboot.img|O|fcd403db69f54290b51035d82f835e7b|lynxboot.img (Lynx Boot Image)
irogb_libretro|Game Boy/Game Boy Color|dmg_boot.bin|O|32fbbd84168d3482956eb3c5051637f5|dmg_boot.bin (DMG-BIOS)
irogb_libretro|Game Boy/Game Boy Color|cgb_bios.bin|O|dbfce9db9deaa2567f6a84fde55f9680|cgb_bios.bin (CGB-BIOS)
jollycv_libretro|ColecoVision/CreatiVision/My Vision|coleco.rom|O|2c66f5911e5b42b8ebe113403548eee7|coleco.rom (ColecoVision BIOS)
jollycv_libretro|ColecoVision/CreatiVision/My Vision|bioscv.rom|O|3b1ef759d8e3fb4071582efd33dd05f9|bioscv.rom (CreatiVision BIOS)
kronos_libretro|Saturn|kronos/saturn_bios.bin|R|af5828fdff51384f99b3c4926be27762|kronos/saturn_bios.bin (Saturn BIOS)
kronos_libretro|Saturn|kronos/stvbios.zip|R|0e92c1e02862dfeb4cdef7f4414b14a9|kronos/stvbios.zip (ST-V BIOS from MAME)
kronos_libretro|Saturn|mpr-18811-mx.ic1|O|255113ba943c92a54facd25a10fd780c|mpr-18811-mx.ic1 (The King of Fighters '95 ROM Cartridge)
kronos_libretro|Saturn|mpr-19367-mx.ic1|O|1cd19988d1d72a3e7caa0b73234c96b4|mpr-19367-mx.ic1 (Ultraman: Hikari no Kyojin Densetsu ROM Cartridge)
mednafen_gba_libretro|Game Boy Advance|gba_bios.bin|O|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (Game Boy Advance BIOS)
mednafen_lynx_libretro|Lynx|lynxboot.img|R|fcd403db69f54290b51035d82f835e7b|lynxboot.img (Lynx Boot Image)
mednafen_pce_fast_libretro|PC Engine/PCE-CD|syscard3.pce|O|38179df8f4ac870017db21ebcbf53114|syscard3.pce (PCE-CD BIOS)
mednafen_pce_fast_libretro|PC Engine/PCE-CD|syscard2.pce|O|3cdd6614a918616bfc41c862e889dd79|syscard2.pce (PCE-CD BIOS)
mednafen_pce_fast_libretro|PC Engine/PCE-CD|syscard1.pce|O|2b7ccb3d86baa18f6402c176f3065082|syscard1.pce (PCE-CD BIOS)
mednafen_pce_fast_libretro|PC Engine/PCE-CD|gexpress.pce|O|6d2cb14fc3e1f65ceb135633d1694122|gexpress.pce (PCE-CD BIOS)
mednafen_pce_libretro|PC Engine/SuperGrafx/CD|syscard3.pce|O|38179df8f4ac870017db21ebcbf53114|syscard3.pce (Super CD-ROM2 System V3.xx)
mednafen_pce_libretro|PC Engine/SuperGrafx/CD|syscard2.pce|O|3cdd6614a918616bfc41c862e889dd79|syscard2.pce (CD-ROM System V2.xx)
mednafen_pce_libretro|PC Engine/SuperGrafx/CD|syscard1.pce|O|2b7ccb3d86baa18f6402c176f3065082|syscard1.pce (CD-ROM System V1.xx)
mednafen_pce_libretro|PC Engine/SuperGrafx/CD|gexpress.pce|O|6d2cb14fc3e1f65ceb135633d1694122|gexpress.pce (Game Express CD Card)
mednafen_pcfx_libretro|PC-FX|pcfx.rom|R|08e36edbea28a017f79f8d4f7ff9b6d7|pcfx.rom (PC-FX BIOS v1.00 - 2 Sep 1994)
mednafen_psx_hw_libretro|PlayStation|scph5500.bin|R|8dd7d5296a650fac7319bce665a6a53c|scph5500.bin (PS1 JP BIOS)
mednafen_psx_hw_libretro|PlayStation|scph5501.bin|R|490f666e1afb15b7362b406ed1cea246|scph5501.bin (PS1 US BIOS)
mednafen_psx_hw_libretro|PlayStation|scph5502.bin|R|32736f17079d0b2b7024407c39bd3050|scph5502.bin (PS1 EU BIOS)
mednafen_psx_hw_libretro|PlayStation|psxonpsp660.bin|O|c53ca5908936d412331790f4426c6c33|psxonpsp660.bin (PSP PS1 BIOS)
mednafen_psx_hw_libretro|PlayStation|ps1_rom.bin|O|81bbe60ba7a3d1cea1d48c14cbcc647b|ps1_rom.bin (PS3 PS1 BIOS)
mednafen_psx_libretro|PlayStation|scph5500.bin|R|8dd7d5296a650fac7319bce665a6a53c|scph5500.bin (PS1 JP BIOS)
mednafen_psx_libretro|PlayStation|scph5501.bin|R|490f666e1afb15b7362b406ed1cea246|scph5501.bin (PS1 US BIOS)
mednafen_psx_libretro|PlayStation|scph5502.bin|R|32736f17079d0b2b7024407c39bd3050|scph5502.bin (PS1 EU BIOS)
mednafen_psx_libretro|PlayStation|psxonpsp660.bin|O|c53ca5908936d412331790f4426c6c33|psxonpsp660.bin (PSP PS1 BIOS)
mednafen_psx_libretro|PlayStation|ps1_rom.bin|O|81bbe60ba7a3d1cea1d48c14cbcc647b|ps1_rom.bin (PS3 PS1 BIOS)
mednafen_saturn_libretro|Saturn|sega_101.bin|R|85ec9ca47d8f6807718151cbcca8b964|sega_101.bin (Saturn JP BIOS)
mednafen_saturn_libretro|Saturn|mpr-17933.bin|R|3240872c70984b6cbfda1586cab68dbe|mpr-17933.bin (Saturn US/EU BIOS)
mednafen_saturn_libretro|Saturn|mpr-18811-mx.ic1|O|255113ba943c92a54facd25a10fd780c|mpr-18811-mx.ic1 (The King of Fighters '95 ROM Cartridge)
mednafen_saturn_libretro|Saturn|mpr-19367-mx.ic1|O|1cd19988d1d72a3e7caa0b73234c96b4|mpr-19367-mx.ic1 (Ultraman: Hikari no Kyojin Densetsu ROM Cartridge)
mednafen_supergrafx_libretro|PC Engine SuperGrafx|syscard3.pce|O|38179df8f4ac870017db21ebcbf53114|syscard3.pce (Super CD-ROM2 System V3.xx)
mednafen_supergrafx_libretro|PC Engine SuperGrafx|syscard2.pce|O|3cdd6614a918616bfc41c862e889dd79|syscard2.pce (CD-ROM System V2.xx)
mednafen_supergrafx_libretro|PC Engine SuperGrafx|syscard1.pce|O|2b7ccb3d86baa18f6402c176f3065082|syscard1.pce (CD-ROM System V1.xx)
mednafen_supergrafx_libretro|PC Engine SuperGrafx|gexpress.pce|O|6d2cb14fc3e1f65ceb135633d1694122|gexpress.pce (Game Express CD Card)
melonds_libretro|Nintendo DS|firmware.bin|O|e45033d9b0fa6b0de071292bba7c9d13|firmware.bin (NDS Firmware)
melonds_libretro|Nintendo DS|bios7.bin|O|df692a80a5b1bc90728bc3dfc76cd948|bios7.bin (ARM7 BIOS)
melonds_libretro|Nintendo DS|bios9.bin|O|a392174eb3e572fed6447e956bde4b25|bios9.bin (ARM9 BIOS)
melonds_libretro|Nintendo DS|dsi_firmware.bin|O||dsi_firmware.bin (DSi Firmware)
melonds_libretro|Nintendo DS|dsi_bios7.bin|O|559dae4ea78eb9d67702c56c1d791e81|dsi_bios7.bin (DSi ARM7 BIOS)
melonds_libretro|Nintendo DS|dsi_bios9.bin|O|87b665fce118f76251271c3732532777|dsi_bios9.bin (DSi ARM9 BIOS)
melonds_libretro|Nintendo DS|dsi_nand.bin|O||dsi_nand.bin (DSi NAND)
melonds_libretro|Nintendo DS|dsi_sd_card.bin|O||dsi_sd_card.bin (DSi SD card)
melondsds_libretro|Nintendo DS|firmware.bin|O|e45033d9b0fa6b0de071292bba7c9d13|firmware.bin (NDS Firmware)
melondsds_libretro|Nintendo DS|bios7.bin|O|df692a80a5b1bc90728bc3dfc76cd948|bios7.bin (ARM7 BIOS)
melondsds_libretro|Nintendo DS|bios9.bin|O|a392174eb3e572fed6447e956bde4b25|bios9.bin (ARM9 BIOS)
melondsds_libretro|Nintendo DS|dsi_firmware.bin|O||dsi_firmware.bin (DSi Firmware)
melondsds_libretro|Nintendo DS|dsi_bios7.bin|O|559dae4ea78eb9d67702c56c1d791e81|dsi_bios7.bin (DSi ARM7 BIOS)
melondsds_libretro|Nintendo DS|dsi_bios9.bin|O|87b665fce118f76251271c3732532777|dsi_bios9.bin (DSi ARM9 BIOS)
melondsds_libretro|Nintendo DS|dsi_nand.bin|O||dsi_nand.bin (DSi NAND)
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|dmg_boot.bin|O|32fbbd84168d3482956eb3c5051637f5|dmg_boot.bin (GB Boot Image)
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|cgb_boot.bin|O|dbfce9db9deaa2567f6a84fde55f9680|cgb_boot.bin (GBC Boot Image)
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|sgb_boot.bin|O|d574d4f9c12f305074798f54c091a8b4|sgb_boot.bin (SGB Boot Image)
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|sgb2_boot.bin|O|e0430bca9925fb9882148fd2dc2418c1|sgb2_boot.bin (SGB2 Boot Image)
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|SGB1.sfc|O|b15ddb15721c657d82c5bab6db982ee9|SGB1.sfc (SGB ROM)
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|SGB2.sfc|O|8ecd73eb4edf7ed7e81aef1be80031d5|SGB2.sfc (SGB2 ROM)
mesen-s_libretro|Super Nintendo Entertainment System / Game Boy / Game Boy Color|BS-X.bin|O|fed4d8242cfbed61343d53d48432aced|BS-X.bin (Satellaview Boot ROM)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|dmg_boot.bin|O|32fbbd84168d3482956eb3c5051637f5|dmg_boot.bin (GB Boot Image)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|cgb_boot.bin|O|dbfce9db9deaa2567f6a84fde55f9680|cgb_boot.bin (GBC Boot Image)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|syscard3.pce|O|38179df8f4ac870017db21ebcbf53114|syscard3.pce (Super CD-ROM2 System V3.xx)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|syscard2.pce|O|3cdd6614a918616bfc41c862e889dd79|syscard2.pce (CD-ROM System V2.xx)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|syscard1.pce|O|2b7ccb3d86baa18f6402c176f3065082|syscard1.pce (CD-ROM System V1.xx)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|gexpress.pce|O|6d2cb14fc3e1f65ceb135633d1694122|gexpress.pce (Game Express CD Card)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|bios.sms|O|840481177270d5642a14ca71ee72844c|bios.sms (Master System BIOS)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|bios.gg|O|672e104c3be3a238301aceffc3b23fd6|bios.gg (Game Gear BIOS)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|gba_bios.bin|O|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (Game Boy Advance BIOS)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|gb_bios.bin|O|32fbbd84168d3482956eb3c5051637f5|gb_bios.bin (Game Boy BIOS)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|gbc_bios.bin|O|dbfce9db9deaa2567f6a84fde55f9680|gbc_bios.bin (Game Boy Color BIOS)
mesen2_libretro|Nintendo Entertainment System / Super Nintendo Entertainment System / Game Boy / Game Boy Color / PC Engine SuperGrafx / PC Engine - TurboGrafx 16 / PC Engine CD - TurboGrafx-CD / WonderSwan / WonderSwan Color|sgb_bios.bin|O|d574d4f9c12f305074798f54c091a8b4|sgb_bios.bin (Super Game Boy BIOS)
mesen_libretro|Nintendo Entertainment System|disksys.rom|O|ca30b50f880eb660a320674ed365ef7a|disksys.rom (Family Computer Disk System BIOS)
mgba_libretro|Game Boy/Game Boy Color/Game Boy Advance|gba_bios.bin|O|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (Game Boy Advance BIOS)
mgba_libretro|Game Boy/Game Boy Color/Game Boy Advance|gb_bios.bin|O|32fbbd84168d3482956eb3c5051637f5|gb_bios.bin (Game Boy BIOS)
mgba_libretro|Game Boy/Game Boy Color/Game Boy Advance|gbc_bios.bin|O|dbfce9db9deaa2567f6a84fde55f9680|gbc_bios.bin (Game Boy Color BIOS)
mgba_libretro|Game Boy/Game Boy Color/Game Boy Advance|sgb_bios.bin|O|d574d4f9c12f305074798f54c091a8b4|sgb_bios.bin (Super Game Boy BIOS)
mgba_splitscreen_libretro|Game Boy Advance (2-4 linked players)|gba_bios.bin|O|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (Game Boy Advance BIOS)
minivmac_libretro|Mac68k|MacII.ROM|R|66223be1497460f1e60885eeb35e03cc|MacII.ROM
mkxp-z_libretro|RPG Maker XP/VX/VX Ace Game Engine|mkxp-z/RTP/Standard|O||mkxp-z/RTP/Standard/... (RPG Maker XP Run Time Package)
mkxp-z_libretro|RPG Maker XP/VX/VX Ace Game Engine|mkxp-z/RTP/RPGVX|O||mkxp-z/RTP/RPGVX/... (RPG Maker VX Run Time Package)
mkxp-z_libretro|RPG Maker XP/VX/VX Ace Game Engine|mkxp-z/RTP/RPGVXAce|O||mkxp-z/RTP/RPGVXAce/... (RPG Maker VX Ace Run Time Package)
mu_libretro|Palm OS|palmos40-en-m500.rom|O|abed11421f47bbf3f654af618e0c6a8a|palmos40-en-m500.rom (Palm OS 4.0)
mu_libretro|Palm OS|palmos41-en-m515.rom|R|83cb1d1c76e568b916dc2e7c0bf669f6|palmos41-en-m515.rom (Palm OS 4.1)
mu_libretro|Palm OS|palmos52-en-t3.rom|O|a46861541c63b20aba7bf172b0d853e1|palmos52-en-t3.rom (Palm OS 5.2.1)
mu_libretro|Palm OS|palmos60-en-t3.rom|O|c2fae3ff41cc4f94be0fdaed1523ea99|palmos60-en-t3.rom (Palm OS 6.0)
mu_libretro|Palm OS|bootloader-dbvz.rom|O|9da101cd2317830649a31f8fa46debec|bootloader-dbvz.rom (MC68VZ328 UART Bootloader)
mupen64plus_next_develop_libretro|Nintendo 64|Mupen64plus/IPL.n64|O|8d3d9f294b6e174bc7b1d2fd1c727530|Mupen64plus/IPL.n64 (64DD BIOS)
mupen64plus_next_gles2_libretro|Nintendo 64|Mupen64plus/IPL.n64|O|8d3d9f294b6e174bc7b1d2fd1c727530|Mupen64plus/IPL.n64 (64DD BIOS)
mupen64plus_next_gles3_libretro|Nintendo 64|Mupen64plus/IPL.n64|O|8d3d9f294b6e174bc7b1d2fd1c727530|Mupen64plus/IPL.n64 (64DD BIOS)
mupen64plus_next_libretro|Nintendo 64|Mupen64plus/IPL.n64|O|8d3d9f294b6e174bc7b1d2fd1c727530|Mupen64plus/IPL.n64 (64DD BIOS)
neocd_libretro|SNK Neo Geo CD|neocd/neocd_f.rom|O|8834880c33164ccbe6476b559f3e37de|neocd/neocd_f.rom (Front Loader BIOS)
neocd_libretro|SNK Neo Geo CD|neocd/neocd_sf.rom|O|043d76d5f0ef836500700c34faef774d|neocd/neocd_sf.rom (Front Loader BIOS (SMKDAN))
neocd_libretro|SNK Neo Geo CD|neocd/front-sp1.bin|O|5c2366f25ff92d71788468ca492ebeca|neocd/front-sp1.bin (Front Loader BIOS (MAME))
neocd_libretro|SNK Neo Geo CD|neocd/neocd_t.rom|O|de3cf45d227ad44645b22aa83b49f450|neocd/neocd_t.rom (Top Loader BIOS))
neocd_libretro|SNK Neo Geo CD|neocd/neocd_st.rom|O|f6325a33c6d63ea4b9162a3fa8c32727|neocd/neocd_st.rom (Top Loader BIOS (SMKDAN))
neocd_libretro|SNK Neo Geo CD|neocd/top-sp1.bin|O|122aee210324c72e8a11116e6ef9c0d0|neocd/top-sp1.bin (Top Loader BIOS (MAME))
neocd_libretro|SNK Neo Geo CD|neocd/neocd_z.rom|O|11526d58d4c524daef7d5d677dc6b004|neocd/neocd_z.rom (CDZ BIOS)
neocd_libretro|SNK Neo Geo CD|neocd/neocd_sz.rom|O|971ee8a36fb72da57aed01758f0a37f5|neocd/neocd_sz.rom (CDZ BIOS (SMKDAN))
neocd_libretro|SNK Neo Geo CD|neocd/neocd.bin|O|f39572af7584cb5b3f70ae8cc848aba2|neocd/neocd.bin (CDZ BIOS (MAME))
neocd_libretro|SNK Neo Geo CD|neocd/ng-lo.rom|O|e255264d85d5765013b1b2fa8109dd53|neocd/ng-lo.rom (Y-ZOOM ROM)
neocd_libretro|SNK Neo Geo CD|neocd/000-lo.lo|O|fc7599f3f871578fe9a0453662d1c966|neocd/000-lo.lo (Y-ZOOM ROM (MAME))
neocd_libretro|SNK Neo Geo CD|neocd/uni-bioscd.rom|O|08ca8b2dba6662e8024f9e789711c6fc|neocd/uni-bioscd.rom (Universe BIOS 3.2)
nestopia_libretro|Nintendo Entertainment System|disksys.rom|O|ca30b50f880eb660a320674ed365ef7a|disksys.rom (Family Computer Disk System BIOS)
noods_libretro|Nintendo DS|firmware.bin|O|e45033d9b0fa6b0de071292bba7c9d13|firmware.bin (NDS Firmware)
noods_libretro|Nintendo DS|bios7.bin|O|df692a80a5b1bc90728bc3dfc76cd948|bios7.bin (ARM7 BIOS)
noods_libretro|Nintendo DS|bios9.bin|O|a392174eb3e572fed6447e956bde4b25|bios9.bin (ARM9 BIOS)
noods_libretro|Nintendo DS|gba_bios.bin|O|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (Game Boy Advance BIOS)
noods_libretro|Nintendo DS|nds_sd_card.bin|O||nds_sd_card.bin (NDS SD card)
np2kai_libretro|PC-98|np2kai/font.bmp|O|7da1e5b7c482d4108d22a5b09631d967|np2kai/font.bmp (needed to display text)
np2kai_libretro|PC-98|np2kai/FONT.ROM|O|38d32748ae49d1815b0614970849fd40|np2kai/FONT.ROM (alt font file)
np2kai_libretro|PC-98|np2kai/bios.rom|O|cd237e16e7e77c06bb58540e9e9fca68|np2kai/bios.rom
np2kai_libretro|PC-98|np2kai/itf.rom|O|72ea51443070f0e9212bfc9b793ee28e|np2kai/itf.rom
np2kai_libretro|PC-98|np2kai/sound.rom|O|524473c1a5a03b17e21d86a0408ff827|np2kai/sound.rom
np2kai_libretro|PC-98|np2kai/2608_BD.WAV|O|d94546e70f17fd899be8df3544ab6cbb|np2kai/2608_BD.WAV (YM2608 rhythm sample)
np2kai_libretro|PC-98|np2kai/2608_SD.WAV|O|d71004351c8bbfdad53b18222c061d49|np2kai/2608_SD.WAV (YM2608 rhythm sample)
np2kai_libretro|PC-98|np2kai/2608_TOP.WAV|O|593cff6597ab9380d822b8f824fd2c28|np2kai/2608_TOP.WAV (YM2608 rhythm sample)
np2kai_libretro|PC-98|np2kai/2608_HH.WAV|O|08c54a0c1f774a5538a848a6665a34b4|np2kai/2608_HH.WAV (YM2608 rhythm sample)
np2kai_libretro|PC-98|np2kai/2608_TOM.WAV|O|96a4ead13f364734f79b0c58af2f0e1f|np2kai/2608_TOM.WAV (YM2608 rhythm sample)
np2kai_libretro|PC-98|np2kai/2608_RIM.WAV|O|465ea0768b27da404aec45dfc501404b|np2kai/2608_RIM.WAV (YM2608 rhythm sample)
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp1.data.rom|O|3d81b45fa0c2aa8b852dfb1ece7c0971|dsp1.data.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp1.program.rom|O|ae209fbe789fbf11a48aea5ab1197321|dsp1.program.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp1b.data.rom|O|1e3f568634a7d8284020dddc0ae905bc|dsp1b.data.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp1b.program.rom|O|d10f446888e097cbf500f3f663cf4f6d|dsp1b.program.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp2.data.rom|O|e9417e29223b139c3c4b635a2a3b8744|dsp2.data.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp2.program.rom|O|aa6e5922a3ed5ded54f24247c11143c5|dsp2.program.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp3.data.rom|O|0a81210c0a940b997dd9843281008ee6|dsp3.data.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp3.program.rom|O|d99ca4562818d49cee1f242705bba6f8|dsp3.program.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp4.data.rom|O|ee4990879eb68e3cbca239c5bc20303d|dsp4.data.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|dsp4.program.rom|O|a151023b948b90ffc23a5b594bb6fef2|dsp4.program.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|cx4.data.rom|O|037ac4296b6b6a5c47c440188d3c72e3|cx4.data.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|st010.data.rom|O|254d70762b6f59f99c27c395aba7d07d|st010.data.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|st010.program.rom|O|1d70019179a59a566a0bb5d3f2845544|st010.program.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|st011.data.rom|O|10bd3f4aa949737ab9836512c35bcc29|st011.data.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|st011.program.rom|O|95222ebf1c0c2990bcf25db43743f032|st011.program.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|st018.data.rom|O|49c898b60d0f15e90d0ba780dd12f366|st018.data.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|st018.program.rom|O|dda40ccd57390c96e49d30a041f9a9e7|st018.program.rom
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|SGB1.sfc/sgb1.boot.rom|O|d574d4f9c12f305074798f54c091a8b4|SGB1.sfc/sgb1.boot.rom (SGB Boot BIOS)
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|SGB1.sfc/program.rom|O|b15ddb15721c657d82c5bab6db982ee9|SGB1.sfc/program.rom (SGB Boot Image)
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|SGB2.sfc/sgb2.boot.rom|O|e0430bca9925fb9882148fd2dc2418c1|SGB2.sfc/sgb2.boot.rom (SGB Boot BIOS)
nside_sfc_balanced_libretro|Super Nintendo Entertainment System|SGB2.sfc/program.rom|O|8ecd73eb4edf7ed7e81aef1be80031d5|SGB2.sfc/program.rom (SGB Boot Image)
nuance_libretro|NUON|nuance/bios.cof|R||bios.cof (NUON main BIOS, shipped with the emulator)
nuance_libretro|NUON|nuance/minibios.cof|R||minibios.cof (NUON minibios for MPEs 0-2)
nuance_libretro|NUON|nuance/minibiosX.cof|R||minibiosX.cof (NUON extended minibios)
numero_libretro|TI83|ti83se.rom|O|c6ff8204c5c81b7be34614dbbd690c8b|ti83se.rom (TI-83 Silver Edition)
numero_libretro|TI83|ti83plus.rom|O|8011181f810b5ec4e9d6a03f0e14257a|ti83plus.rom (TI-83 Plus)
numero_libretro|TI83|ti83.rom|O|d4448d09bbfde687c04f9e3310e023ab|ti83.rom (TI-83)
o2em_libretro|Magnavox Odyssey2 / Philips Videopac+|o2rom.bin|R|562d5ebf9e030a40d6fabfc2f33139fd|o2rom.bin (Odyssey2 BIOS - G7000 model)
o2em_libretro|Magnavox Odyssey2 / Philips Videopac+|c52.bin|R|f1071cdb0b6b10dde94d3bc8a6146387|c52.bin (Videopac French BIOS - G7000 model)
o2em_libretro|Magnavox Odyssey2 / Philips Videopac+|g7400.bin|R|c500ff71236068e0dc0d0603d265ae76|g7400.bin (Videopac+ European BIOS - G7400 model)
o2em_libretro|Magnavox Odyssey2 / Philips Videopac+|jopac.bin|R|279008e4a0db2dc5f1c048853b033828|jopac.bin (Videopac+ French BIOS - G7400 model)
opera_libretro|3DO|panafz1.bin|O|f47264dd47fe30f73ab3c010015c155b|panafz1.bin (Panasonic FZ-1 BIOS)
opera_libretro|3DO|panafz10.bin|O|51f2f43ae2f3508a14d9f56597e2d3ce|panafz10.bin (Panasonic FZ-10 BIOS)
opera_libretro|3DO|panafz10-norsa.bin|O|1477bda80dc33731a65468c1f5bcbee9|panafz10-norsa.bin (Panasonic FZ-10 BIOS [Encryption Check Disabled])
opera_libretro|3DO|panafz10e-anvil.bin|O|a48e6746bd7edec0f40cff078f0bb19f|panafz10e-anvil.bin (Panasonic FZ-10E ANVIL BIOS)
opera_libretro|3DO|panafz10e-anvil-norsa.bin|O|cf11bbb5a16d7af9875cca9de9a15e09|panafz10e-anvil-norsa.bin (Panasonic FZ-10E ANVIL BIOS [Encryption Check Disabled])
opera_libretro|3DO|goldstar.bin|O|8639fd5e549bd6238cfee79e3e749114|goldstar.bin (Goldstar GDO-101M BIOS)
opera_libretro|3DO|sanyotry.bin|O|35fa1a1ebaaeea286dc5cd15487c13ea|sanyotry.bin (Sanyo Try IMP-21J BIOS)
opera_libretro|3DO|3do_arcade_saot.bin|O|8970fc987ab89a7f64da9f8a8c4333ff|3do_arcade_saot.bin (Shootout At Old Tucson BIOS)
opera_libretro|3DO|panafz1-kanji.bin|O|b8dc97f778a6245c58e064b0312e8281|panafz1-kanji.bin (Panasonic FZ-1 Kanji Font ROM)
opera_libretro|3DO|panafz10ja-anvil-kanji.bin|O|428577250f43edc902ea239c50d2240d|panafz10ja-anvil-kanji.bin (Panasonic FZ-10JA Kanji Font ROM)
opera_libretro|3DO|panafz1j.bin|O|a496cfdded3da562759be3561317b605|panafz1j.bin (Panasonic FZ-1J BIOS)
opera_libretro|3DO|panafz1j-norsa.bin|O|f6c71de7470d16abe4f71b1444883dc8|panafz1j-norsa.bin (Panasonic FZ-1J BIOS [Encryption Check Disabled])
opera_libretro|3DO|panafz1j-kanji.bin|O|c23fb5d5e6bb1c240d02cf968972be37|panafz1j-kanji.bin (Panasonic FZ-1J Kanji Font ROM)
parallel_n64_debug_libretro|Nintendo 64|64DD_IPL.bin|O|8d3d9f294b6e174bc7b1d2fd1c727530|64DD_IPL.bin (64DD IPL ROM)
parallel_n64_libretro|Nintendo 64|64DD_IPL.bin|O|8d3d9f294b6e174bc7b1d2fd1c727530|64DD_IPL.bin (64DD IPL ROM)
pcee2_libretro|Sony PlayStation 2|pcsx2/bios|R||'pcsx2/bios' folder (any valid PS2 BIOS dump, e.g. scph39001.bin)
pcee2_libretro|Sony PlayStation 2|pcsx2/resources|R||'pcsx2/resources' folder (shaders, GameIndex.yaml, fonts)
pcsx1_libretro|PlayStation|scph5500.bin|O|8dd7d5296a650fac7319bce665a6a53c|scph5500.bin (PS1 JP BIOS)
pcsx1_libretro|PlayStation|scph5501.bin|O|490f666e1afb15b7362b406ed1cea246|scph5501.bin (PS1 US BIOS)
pcsx1_libretro|PlayStation|scph5502.bin|O|32736f17079d0b2b7024407c39bd3050|scph5502.bin (PS1 EU BIOS)
pcsx2_libretro|Sony PlayStation 2|pcsx2/bios|R||'pcsx2/bios' folder
pcsx2_libretro|Sony PlayStation 2|pcsx2/resources/GameIndex.yaml|O|526291c9c9bae8b184b0e5f4bfa94eb9|pcsx2/resources/GameIndex.yaml (Game Database)
pcsx_rearmed_interpreter_libretro|PlayStation|scph5500.bin|O|8dd7d5296a650fac7319bce665a6a53c|scph5500.bin (PS1 JP BIOS)
pcsx_rearmed_interpreter_libretro|PlayStation|scph5501.bin|O|490f666e1afb15b7362b406ed1cea246|scph5501.bin (PS1 US BIOS)
pcsx_rearmed_interpreter_libretro|PlayStation|scph5502.bin|O|32736f17079d0b2b7024407c39bd3050|scph5502.bin (PS1 EU BIOS)
pcsx_rearmed_libretro|PlayStation|scph5500.bin|O|8dd7d5296a650fac7319bce665a6a53c|scph5500.bin (PS1 JP BIOS)
pcsx_rearmed_libretro|PlayStation|scph5501.bin|O|490f666e1afb15b7362b406ed1cea246|scph5501.bin (PS1 US BIOS)
pcsx_rearmed_libretro|PlayStation|scph5502.bin|O|32736f17079d0b2b7024407c39bd3050|scph5502.bin (PS1 EU BIOS)
pcsx_rearmed_libretro|PlayStation|psxonpsp660.bin|O|c53ca5908936d412331790f4426c6c33|psxonpsp660.bin (PSP PSX Emu BIOS)
pcsx_rearmed_neon_libretro|PlayStation|scph5500.bin|O|8dd7d5296a650fac7319bce665a6a53c|scph5500.bin (PS1 JP BIOS)
pcsx_rearmed_neon_libretro|PlayStation|scph5501.bin|O|490f666e1afb15b7362b406ed1cea246|scph5501.bin (PS1 US BIOS)
pcsx_rearmed_neon_libretro|PlayStation|scph5502.bin|O|32736f17079d0b2b7024407c39bd3050|scph5502.bin (PS1 EU BIOS)
picodrive_libretro|Sega 8/16-bit + 32X (Various)|bios_CD_E.bin|O|e66fa1dc5820d254611fdcdba0662372|bios_CD_E.bin (MegaCD EU BIOS)
picodrive_libretro|Sega 8/16-bit + 32X (Various)|bios_CD_U.bin|O|2efd74e3232ff260e371b99f84024f7f|bios_CD_U.bin (SegaCD US BIOS)
picodrive_libretro|Sega 8/16-bit + 32X (Various)|bios_CD_J.bin|O|278a9397d192149e84e820ac621a8edd|bios_CD_J.bin (MegaCD JP BIOS)
pokemini_libretro|Pokemon Mini|bios.min|O|1e4fb124a3a886865acb574f388c803d|bios.min (Pokemon Mini BIOS)
pokket_libretro|PocketStation|pocketstation.bin|O||pocketstation.bin (PocketStation BIOS)
ppsspp_libretro|PSP|PPSSPP/ppge_atlas.zim|R|866855cc330b9b95cc69135fb7b41d38|ppge_atlas.zim (PPSSPP Data ROM)
prosystem_libretro|Atari 7800|7800 BIOS (U).rom|O||7800 BIOS (U).rom (7800 BIOS)
puae2021_libretro|Amiga|kick33180.A500|O|85ad74194e87c08904327de1a9443b7a|kick33180.A500 / amiga-os-120.rom (A500-A2000 KS v1.2 rev 33.180)
puae2021_libretro|Amiga|kick34005.A500|R|82a21c1890cae844b3df741f2762d48d|kick34005.A500 / amiga-os-130.rom (A500-A2000-CDTV KS v1.3 rev 34.005)
puae2021_libretro|Amiga|kick37175.A500|O|dc10d7bdd1b6f450773dfb558477c230|kick37175.A500 / amiga-os-204.rom (A500+ KS v2.04 rev 37.175)
puae2021_libretro|Amiga|kick37350.A600|O|465646c9b6729f77eea5314d1f057951|kick37350.A600 / amiga-os-205-a600.rom (A600 KS v2.05 rev 37.350)
puae2021_libretro|Amiga|kick40063.A600|O|e40a5dfb3d017ba8779faba30cbd1c8e|kick40063.A600 / amiga-os-310-a600.rom (A600-A2000 KS v3.1 rev 40.063)
puae2021_libretro|Amiga|kick39106.A1200|O|b7cc148386aa631136f510cd29e42fc3|kick39106.A1200 / amiga-os-300-a1200.rom (A1200 KS v3.0 rev 39.106)
puae2021_libretro|Amiga|kick40068.A1200|R|646773759326fbac3b2311fd8c8793ee|kick40068.A1200 / amiga-os-310-a1200.rom (A1200 KS v3.1 rev 40.068)
puae2021_libretro|Amiga|kick39106.A4000|O|9b8bdd5a3fd32c2a5a6f5b1aefc799a5|kick39106.A4000 / amiga-os-300-a4000.rom (A4000 KS v3.0 rev 39.106)
puae2021_libretro|Amiga|kick40068.A4000|O|9bdedde6a4f33555b4a270c8ca53297d|kick40068.A4000 / amiga-os-310-a4000.rom (A4000 KS v3.1 rev 40.068)
puae2021_libretro|Amiga|kick34005.CDTV|O|89da1838a24460e4b93f4f0c5d92d48d|kick34005.CDTV / amiga-os-130-cdtv-ext.rom (CDTV extended ROM v1.0)
puae2021_libretro|Amiga|kick40060.CD32|R|5f8924d013dd57a89cf349f4cdedc6b1|kick40060.CD32 / amiga-os-310-cd32.rom (CD32 KS v3.1 rev 40.060)
puae2021_libretro|Amiga|kick40060.CD32.ext|R|bb72565701b1b6faece07d68ea5da639|kick40060.CD32.ext / amiga-os-310-cd32-ext.rom (CD32 extended ROM rev 40.060)
puae_libretro|Amiga|kick33180.A500|O|85ad74194e87c08904327de1a9443b7a|kick33180.A500 / amiga-os-120.rom (A500-A2000 KS v1.2 rev 33.180)
puae_libretro|Amiga|kick34005.A500|R|82a21c1890cae844b3df741f2762d48d|kick34005.A500 / amiga-os-130.rom (A500-A2000-CDTV KS v1.3 rev 34.005)
puae_libretro|Amiga|kick37175.A500|O|dc10d7bdd1b6f450773dfb558477c230|kick37175.A500 / amiga-os-204.rom (A500+ KS v2.04 rev 37.175)
puae_libretro|Amiga|kick37350.A600|O|465646c9b6729f77eea5314d1f057951|kick37350.A600 / amiga-os-205-a600.rom (A600 KS v2.05 rev 37.350)
puae_libretro|Amiga|kick40063.A600|O|e40a5dfb3d017ba8779faba30cbd1c8e|kick40063.A600 / amiga-os-310-a600.rom (A600-A2000 KS v3.1 rev 40.063)
puae_libretro|Amiga|kick39106.A1200|O|b7cc148386aa631136f510cd29e42fc3|kick39106.A1200 / amiga-os-300-a1200.rom (A1200 KS v3.0 rev 39.106)
puae_libretro|Amiga|kick40068.A1200|R|646773759326fbac3b2311fd8c8793ee|kick40068.A1200 / amiga-os-310-a1200.rom (A1200 KS v3.1 rev 40.068)
puae_libretro|Amiga|kick39106.A4000|O|9b8bdd5a3fd32c2a5a6f5b1aefc799a5|kick39106.A4000 / amiga-os-300-a4000.rom (A4000 KS v3.0 rev 39.106)
puae_libretro|Amiga|kick40068.A4000|O|9bdedde6a4f33555b4a270c8ca53297d|kick40068.A4000 / amiga-os-310-a4000.rom (A4000 KS v3.1 rev 40.068)
puae_libretro|Amiga|kick34005.CDTV|O|89da1838a24460e4b93f4f0c5d92d48d|kick34005.CDTV / amiga-os-130-cdtv-ext.rom (CDTV extended ROM v1.0)
puae_libretro|Amiga|kick40060.CD32|R|5f8924d013dd57a89cf349f4cdedc6b1|kick40060.CD32 / amiga-os-310-cd32.rom (CD32 KS v3.1 rev 40.060)
puae_libretro|Amiga|kick40060.CD32.ext|R|bb72565701b1b6faece07d68ea5da639|kick40060.CD32.ext / amiga-os-310-cd32-ext.rom (CD32 extended ROM rev 40.060)
px68k_libretro|Sharp X68000|keropi/iplrom.dat|R|7fd4caabac1d9169e289f0f7bbf71d8e|iplrom.dat (X68000 BIOS)
px68k_libretro|Sharp X68000|keropi/cgrom.dat|R|cb0a5cfcf7247a7eab74bb2716260269|cgrom.dat (X68000 BIOS 2)
px68k_libretro|Sharp X68000|keropi/iplrom30.dat|O|f373003710ab4322642f527f567e020a|iplrom30.dat (X68000 BIOS 3)
quasi88_libretro|PC-88 series|quasi88/n88.rom|R|4f984e04a99d56c4cfe36115415d6eb8|n88.rom (Main BIOS)
quasi88_libretro|PC-88 series|quasi88/n88_0.rom|R|e28fe3f520bea594350ea8fb00395370|n88_0.rom (Extension BIOS 1)
quasi88_libretro|PC-88 series|quasi88/n88_1.rom|O|a8e298da7ac947669bcb1ff25cee0a83|n88_1.rom (Extension BIOS 2)
quasi88_libretro|PC-88 series|quasi88/n88_2.rom|O|9d03154fd9abfc28c4e6d4dc705e6e23|n88_2.rom (Extension BIOS 3)
quasi88_libretro|PC-88 series|quasi88/n88_3.rom|O|e1791f8154f1cdf22b576a1a365b6e1f|n88_3.rom (Extension BIOS 4)
quasi88_libretro|PC-88 series|quasi88/n88n.rom|O|2ff07b8769367321128e03924af668a0|n88n.rom (N Basic BIOS)
quasi88_libretro|PC-88 series|quasi88/disk.rom|O|793f86784e5608352a5d7f03f03e0858|disk.rom (Sub BIOS)
quasi88_libretro|PC-88 series|quasi88/n88knj1.rom|O|d81c6d5d7ad1a4bbbd6ae22a01257603|n88knj1.rom (Kanji Font 1)
quasi88_libretro|PC-88 series|quasi88/n88knj2.rom|O|898a3b7b6c3326e8b2069765bca2b944|n88knj2.rom (Kanji Font 2)
quasi88_libretro|PC-88 series|quasi88/n88jisho.rom|O|2e548679423370262f36cbde38a22789|n88jisho.rom (Jisho)
retrodream_libretro|Sega Dreamcast|dc/boot.bin|R|e10c53c2f8b90bab96ead2d368858623|boot.bin (Dreamcast BIOS)
retrodream_libretro|Sega Dreamcast|dc/flash.bin|R|0a93f7940c455905bea6e392dfde92a4|flash.bin (Date/Time/Language)
rpcs3_libretro|PlayStation 3|PS3UPDAT.PUP|R||PS3UPDAT.PUP (PS3 system software)
rustynes_libretro|Nintendo Entertainment System|disksys.rom|O|ca30b50f880eb660a320674ed365ef7a|disksys.rom (Family Computer Disk System BIOS)
same_cdi_libretro|CD-i|same_cdi/bios/cdimono1.zip|R|c59f92647701428bc453976740eb75cf|same_cdi/bios/cdimono1.zip
same_cdi_libretro|CD-i|same_cdi/bios/cdimono2.zip|O|97aa5f47030cd9fdb679d4fafbb0e332|same_cdi/bios/cdimono2.zip
same_cdi_libretro|CD-i|same_cdi/bios/cdibios.zip|O|709acce6e9c4043b851ea7429b8e7eff|same_cdi/bios/cdibios.zip
sameboy_libretro|Game Boy/Game Boy Color|dmg_boot.bin|O|32fbbd84168d3482956eb3c5051637f5|dmg_boot.bin (Game Boy boot ROM)
sameboy_libretro|Game Boy/Game Boy Color|cgb_boot.bin|O|dbfce9db9deaa2567f6a84fde55f9680|cgb_boot.bin (Game Boy Color boot ROM)
scummvm_libretro|ScummVM Game Engine|scummvm/theme/scummclassic.zip|O|57aaebd10238ffe3863192254629aaa9|scummclassic.zip
scummvm_libretro|ScummVM Game Engine|scummvm/theme/scummmodern.zip|O|b470c7205246a0bb4718ca0a27d25055|scummmodern.zip
scummvm_libretro|ScummVM Game Engine|scummvm/theme/scummremastered.zip|O|15600f0b0274f2ab4dd0c181e4ae3e95|scummremastered.zip
scummvm_libretro|ScummVM Game Engine|scummvm/theme/residualvm.zip|O|9cbffee094a6bfa1765e2f6ba15a268e|residualvm.zip
scummvm_libretro|ScummVM Game Engine|scummvm/theme/gui-icons.dat|O|17150a7a6ed5c4d5c0384b95c5fce479|gui-icons.dat
scummvm_libretro|ScummVM Game Engine|scummvm/theme/shaders.dat|O|f073f17187d0bfa3e7ebb7f328847969|shaders.dat
scummvm_libretro|ScummVM Game Engine|scummvm/theme/translations.dat|O|1ca707498f9024c292ca745c5727a751|translations.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/achievements.dat|O|73cf5bd61896442a990e363f284a0bc2|achievements.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/encoding.dat|O|f2e88b2faec499a4914c3a0bcffc7db1|encoding.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/freescape.dat|O|30ca162d03b65f46997fa43e1093839e|freescape.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/grim-patch.lab|O|32b777b824f02b1e1259903740964058|grim-patch.lab
scummvm_libretro|ScummVM Game Engine|scummvm/extra/monkey4-patch.m4b|O|9eb7b7e7cc7dad1fe08be6e73d749abe|monkey4-patch.m4b
scummvm_libretro|ScummVM Game Engine|scummvm/extra/myst3.dat|O|54e9056211f2fff255b6f66a3fe39a8d|myst3.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/fonts.dat|O|65025f90c134e4538efd306e36341aa1|fonts.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/macgui.dat|O|d97f2965013b343dd3d4fdbbc7192f15|macgui.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/access.dat|O|f1925ac548f9551d9d8f648dbc92c897|access.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/cryo.dat|O|fc5886ea5388f20eae299bb408da5bcc|cryo.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/cryomni3d.dat|O|474e9a57b74c368acc8d19e8d63e3288|cryomni3d.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/drascula.dat|O|2647b6dff6d117b217dd9896cd25b34e|drascula.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/hadesch_translations.dat|O|7857da7e56a11e0749fb45100c323b3c|hadesch_translations.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/hugo.dat|O|0856a20f18b3319c92b710ef80d886cd|hugo.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/kyra.dat|O|21a57f79886e46f410cfb50186ed8d77|kyra.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/lure.dat|O|75a83c781ac7024fc9c1b6f7ecc5b936|lure.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/macventure.dat|O|d855abc95d2b7c03b748631c08603ebb|macventure.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/mort.dat|O|3cfb16d7bab4d77606b3b1274b8ae870|mort.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/nancy.dat|O|e482c84f583783b4b9dea5374aa232da|nancy.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/neverhood.dat|O|dfaab12ffb265646f31f51b6904246d1|neverhood.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/queen.tbl|O|4f5b513b52c4ef6fb1c46e984760a3b7|queen.tbl
scummvm_libretro|ScummVM Game Engine|scummvm/extra/sky.cpt|O|9d00157b1cebd6368cbf88135c098f40|sky.cpt
scummvm_libretro|ScummVM Game Engine|scummvm/extra/supernova.dat|O|f6af52d51152447f43cf3cf9a50bc144|supernova.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/teenagent.dat|O|aaaf8792af40c80122d7dbecaf1dee20|teenagent.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/titanic.dat|O|4b2fb71201dc3795cff45df6200a1918|titanic.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/tony.dat|O|891022a4e2917bb54b5cdc9a46f5b3df|tony.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/toon.dat|O|730f63ea46169f56bb4f9fa0637baef0|toon.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/ultima.dat|O|420ef1f96eee6dc15395330f28923be2|ultima.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/wintermute.zip|O|46ab65cb137a4fc8710a8f3b9455e50e|wintermute.zip
scummvm_libretro|ScummVM Game Engine|scummvm/extra/mm.dat|O|fc20f5064386a19d39bd5f9df0a542fa|mm.dat
scummvm_libretro|ScummVM Game Engine|scummvm/extra/vkeybd_default.zip|O|bf51a61f07625ea20e891058afaa892c|vkeybd_default.zip
scummvm_libretro|ScummVM Game Engine|scummvm/extra/Roland_SC-55.sf2|O|dbb97c34404b753724a66fe0108a32e1|Roland_SC-55.sf2
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|cgb_boot.bin|O|dbfce9db9deaa2567f6a84fde55f9680|cgb_boot.bin (GBC BIOS)
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|gbc_bios.bin|O|dbfce9db9deaa2567f6a84fde55f9680|gbc_bios.bin (GBC BIOS)
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|cgb0_boot.bin|O||cgb0_boot.bin (GBC BIOS)
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|cgb_agb_boot.bin|O||cgb_agb_boot.bin (GBC BIOS)
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|dmg_rom.bin|O|32fbbd84168d3482956eb3c5051637f5|dmg_rom.bin (DMG BIOS)
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|dmg0_rom.bin|O||dmg0_rom.bin (DMG BIOS)
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|gba_bios.bin|O|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (GBA BIOS)
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|nds7.bin|O|df692a80a5b1bc90728bc3dfc76cd948|nds7.bin (NDS ARM7 BIOS)
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|nds9.bin|O|a392174eb3e572fed6447e956bde4b25|nds9.bin (NDS ARM9 BIOS)
skyemu_libretro|Nintendo - Game Boy/GBA/NDS (SkyEmu)|firmware.bin|O|e45033d9b0fa6b0de071292bba7c9d13|firmware.bin (NDS FIRMWARE)
sm2_libretro|Model 2|sm2-emu/games.xml|R||SM2-Emu game database matching this core
smsplus_libretro|Sega 8-bit|bios.sms|O|840481177270d5642a14ca71ee72844c|bios.sms (Master System BIOS)
smsplus_libretro|Sega 8-bit|BIOS.col|O|2c66f5911e5b42b8ebe113403548eee7|BIOS.col (Colecovision BIOS)
snes9x_libretro|Super Nintendo Entertainment System|BS-X.bin|O|fed4d8242cfbed61343d53d48432aced|BS-X.bin (BS-X - Sore wa Namae o Nusumareta Machi no Monogatari (Japan) (Rev 1))
snes9x_libretro|Super Nintendo Entertainment System|STBIOS.bin|O|d3a44ba7d42a74d3ac58cb9c14c6a5ca|STBIOS.bin (Sufami Turbo (Japan))
squirreljme_libretro|Java ME|squirreljme-0.3.0-fast.jar|O|8e98b0c8e5c96c191a8b2a9d29d0454b|squirreljme-0.3.0-fast.jar (SquirrelJME Class Library, Versioned, Optimized and stripped)
squirreljme_libretro|Java ME|squirreljme-0.3.0.jar|O|8e98b0c8e5c96c191a8b2a9d29d0454b|squirreljme-0.3.0.jar (SquirrelJME Class Library, Versioned)
squirreljme_libretro|Java ME|squirreljme-0.3.0-test.jar|O||squirreljme-0.3.0-test.jar (SquirrelJME Class Library, Versioned, Optimized and stripped with Tests)
squirreljme_libretro|Java ME|squirreljme-0.3.0-slow.jar|O|8e98b0c8e5c96c191a8b2a9d29d0454b|squirreljme-0.3.0-slow.jar (SquirrelJME Class Library, Versioned, Unoptimized with full debugging)
squirreljme_libretro|Java ME|squirreljme-0.3.0-slow-test.jar|O|8e98b0c8e5c96c191a8b2a9d29d0454b|squirreljme-0.3.0-slow-test.jar (SquirrelJME Class Library, Versioned, Unoptimized with full debugging with tests)
squirreljme_libretro|Java ME|squirreljme-fast.jar|O|8e98b0c8e5c96c191a8b2a9d29d0454b|squirreljme-fast.jar (SquirrelJME Class Library, Optimized and stripped)
squirreljme_libretro|Java ME|squirreljme.jar|O|cf849d4b36cd8b7782de7887d318182a|squirreljme.jar (SquirrelJME Class Library)
squirreljme_libretro|Java ME|squirreljme-test.jar|O||squirreljme-test.jar (SquirrelJME Class Library, Optimized and stripped with Tests)
squirreljme_libretro|Java ME|squirreljme-slow.jar|O|8e98b0c8e5c96c191a8b2a9d29d0454b|squirreljme-slow.jar (SquirrelJME Class Library, Unoptimized with full debugging)
squirreljme_libretro|Java ME|squirreljme-slow-test.jar|O|8e98b0c8e5c96c191a8b2a9d29d0454b|squirreljme-slow-test.jar (SquirrelJME Class Library, Unoptimized with full debugging with tests)
swanstation_libretro|PlayStation|psxonpsp660.bin|O|c53ca5908936d412331790f4426c6c33|psxonpsp660.bin (PSP PS1 BIOS)
swanstation_libretro|PlayStation|scph5500.bin|O|8dd7d5296a650fac7319bce665a6a53c|scph5500.bin (PS1 JP BIOS)
swanstation_libretro|PlayStation|scph5501.bin|O|490f666e1afb15b7362b406ed1cea246|scph5501.bin (PS1 US BIOS)
swanstation_libretro|PlayStation|scph5502.bin|O|32736f17079d0b2b7024407c39bd3050|scph5502.bin (PS1 EU BIOS)
swanstation_libretro|PlayStation|ps1_rom.bin|O|81bbe60ba7a3d1cea1d48c14cbcc647b|ps1_rom.bin (PS3 PS1 BIOS)
tempgba_libretro|Game Boy Advance|gba_bios.bin|R|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (Game Boy Advance BIOS)
uae4arm_libretro|Amiga|kick34005.A500|R|82a21c1890cae844b3df741f2762d48d|kick34005.A500 (Amiga 500 BIOS, Kickstart v1.3 Rev. 34.005)
uae4arm_libretro|Amiga|kick40063.A600|R|e40a5dfb3d017ba8779faba30cbd1c8e|kick40063.A600 (Amiga 600 BIOS, Kickstart v3.1 Rev. 40.063)
uae4arm_libretro|Amiga|kick40068.A1200|R|646773759326fbac3b2311fd8c8793ee|kick40068.A1200 (Amiga 1200 BIOS, Kickstart v3.1 Rev. 40.068)
uae4arm_libretro|Amiga|kick34005.CDTV|R|89da1838a24460e4b93f4f0c5d92d48d|kick34005.CDTV (Amiga CDTV extended ROM v1.00 Rev. 34.005)
uae4arm_libretro|Amiga|kick40060.CD32|R|5f8924d013dd57a89cf349f4cdedc6b1|kick40060.CD32 (Amiga CD32 BIOS, Kickstart v3.1 Rev. 40.060)
uae4arm_libretro|Amiga|kick40060.CD32.ext|R|bb72565701b1b6faece07d68ea5da639|kick40060.CD32.ext (Amiga CD32 Extended BIOS, CD32 Extended ROM Rev. 40.060)
vba_next_libretro|Game Boy Advance|gba_bios.bin|O|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (Game Boy Advance BIOS)
vbam_libretro|Game Boy/Game Boy Color/Game Boy Advance|gba_bios.bin|O|a860e8c0b6d573d191e4ec7db1b1e4f6|gba_bios.bin (Game Boy Advance BIOS)
vbam_libretro|Game Boy/Game Boy Color/Game Boy Advance|gb_bios.bin|O|32fbbd84168d3482956eb3c5051637f5|gb_bios.bin (Game Boy BIOS)
vbam_libretro|Game Boy/Game Boy Color/Game Boy Advance|gbc_bios.bin|O|dbfce9db9deaa2567f6a84fde55f9680|gbc_bios.bin (Game Boy Color BIOS)
vice_x128_libretro|C128|vice/JiffyDOS_C128.bin|O|cbbd1bbcb5e4fd8046b6030ab71fc021|vice/JiffyDOS_C128.bin (JiffyDOS C128 Kernal)
vice_x128_libretro|C128|vice/JiffyDOS_C64.bin|O|be09394f0576cf81fa8bacf634daf9a2|vice/JiffyDOS_C64.bin (JiffyDOS C64 Kernal)
vice_x128_libretro|C128|vice/JiffyDOS_1541-II.bin|O|1b1e985ea5325a1f46eb7fd9681707bf|vice/JiffyDOS_1541-II.bin (JiffyDOS 1541 drive BIOS)
vice_x128_libretro|C128|vice/JiffyDOS_1571_repl310654.bin|O|41c6cc528e9515ffd0ed9b180f8467c0|vice/JiffyDOS_1571_repl310654.bin (JiffyDOS 1571 drive BIOS)
vice_x128_libretro|C128|vice/JiffyDOS_1581.bin|O|20b6885c6dc2d42c38754a365b043d71|vice/JiffyDOS_1581.bin (JiffyDOS 1581 drive BIOS)
vice_x64_libretro|C64|vice/JiffyDOS_C64.bin|O|be09394f0576cf81fa8bacf634daf9a2|vice/JiffyDOS_C64.bin (JiffyDOS C64 Kernal)
vice_x64_libretro|C64|vice/JiffyDOS_1541-II.bin|O|1b1e985ea5325a1f46eb7fd9681707bf|vice/JiffyDOS_1541-II.bin (JiffyDOS 1541 drive BIOS)
vice_x64_libretro|C64|vice/JiffyDOS_1571_repl310654.bin|O|41c6cc528e9515ffd0ed9b180f8467c0|vice/JiffyDOS_1571_repl310654.bin (JiffyDOS 1571 drive BIOS)
vice_x64_libretro|C64|vice/JiffyDOS_1581.bin|O|20b6885c6dc2d42c38754a365b043d71|vice/JiffyDOS_1581.bin (JiffyDOS 1581 drive BIOS)
vice_x64dtv_libretro|C64DTV|vice/JiffyDOS_C64.bin|O|be09394f0576cf81fa8bacf634daf9a2|vice/JiffyDOS_C64.bin (JiffyDOS C64 Kernal)
vice_x64dtv_libretro|C64DTV|vice/JiffyDOS_1541-II.bin|O|1b1e985ea5325a1f46eb7fd9681707bf|vice/JiffyDOS_1541-II.bin (JiffyDOS 1541 drive BIOS)
vice_x64dtv_libretro|C64DTV|vice/JiffyDOS_1571_repl310654.bin|O|41c6cc528e9515ffd0ed9b180f8467c0|vice/JiffyDOS_1571_repl310654.bin (JiffyDOS 1571 drive BIOS)
vice_x64dtv_libretro|C64DTV|vice/JiffyDOS_1581.bin|O|20b6885c6dc2d42c38754a365b043d71|vice/JiffyDOS_1581.bin (JiffyDOS 1581 drive BIOS)
vice_x64sc_libretro|C64|vice/JiffyDOS_C64.bin|O|be09394f0576cf81fa8bacf634daf9a2|vice/JiffyDOS_C64.bin (JiffyDOS C64 Kernal)
vice_x64sc_libretro|C64|vice/JiffyDOS_1541-II.bin|O|1b1e985ea5325a1f46eb7fd9681707bf|vice/JiffyDOS_1541-II.bin (JiffyDOS 1541 drive BIOS)
vice_x64sc_libretro|C64|vice/JiffyDOS_1571_repl310654.bin|O|41c6cc528e9515ffd0ed9b180f8467c0|vice/JiffyDOS_1571_repl310654.bin (JiffyDOS 1571 drive BIOS)
vice_x64sc_libretro|C64|vice/JiffyDOS_1581.bin|O|20b6885c6dc2d42c38754a365b043d71|vice/JiffyDOS_1581.bin (JiffyDOS 1581 drive BIOS)
vice_xscpu64_libretro|C64 SuperCPU|vice/JiffyDOS_C64.bin|O|be09394f0576cf81fa8bacf634daf9a2|vice/JiffyDOS_C64.bin (JiffyDOS C64 Kernal)
vice_xscpu64_libretro|C64 SuperCPU|vice/JiffyDOS_1541-II.bin|O|1b1e985ea5325a1f46eb7fd9681707bf|vice/JiffyDOS_1541-II.bin (JiffyDOS 1541 drive BIOS)
vice_xscpu64_libretro|C64 SuperCPU|vice/JiffyDOS_1571_repl310654.bin|O|41c6cc528e9515ffd0ed9b180f8467c0|vice/JiffyDOS_1571_repl310654.bin (JiffyDOS 1571 drive BIOS)
vice_xscpu64_libretro|C64 SuperCPU|vice/JiffyDOS_1581.bin|O|20b6885c6dc2d42c38754a365b043d71|vice/JiffyDOS_1581.bin (JiffyDOS 1581 drive BIOS)
vircon32_libretro|Vircon32|Vircon32Bios.v32|O|73f04397cbb2dafcf2047b19a856153a|Vircon32Bios.v32 (alternative BIOS file)
virtualjaguar_libretro|Jaguar|[BIOS] Atari Jaguar CD (World).j64|O||[BIOS] Atari Jaguar CD (World).j64 (Jaguar CD BIOS, retail - optional override)
virtualjaguar_libretro|Jaguar|[BIOS] Atari Jaguar Developer CD (World).j64|O||[BIOS] Atari Jaguar Developer CD (World).j64 (Jaguar CD BIOS, developer - optional override)
virtualjaguar_libretro|Jaguar|jagboot_m.rom|O||jagboot_m.rom (Jaguar cart boot ROM, Model M - optional override)
virtualjaguar_libretro|Jaguar|jagboot.rom|O||jagboot.rom (Jaguar cart boot ROM, any revision - optional, used when Cart BIOS Type is Custom)
vita3k_libretro|PlayStation Vita|vita3k/PSP2UPDAT.PUP|R||PSP2UPDAT.PUP (PS Vita system firmware)
vita3k_libretro|PlayStation Vita|vita3k/PSP2UPDAT_PREINST.PUP|R||PSP2UPDAT_PREINST.PUP (PS Vita firmware preinst package)
vita3k_libretro|PlayStation Vita|vita3k/PSP2UPDAT_FONT.PUP|O||PSP2UPDAT_FONT.PUP (PS Vita firmware fonts)
wqxemu_libretro|Wenquxing|WQXEmu/nc1020/obj_lu.bin|O||NC1020 obj_lu.bin (System ROM)
wqxemu_libretro|Wenquxing|WQXEmu/nc1020/nc1020.fls|O||NC1020 nc1020.fls (NOR Flash)
wqxemu_libretro|Wenquxing|WQXEmu/pc1000/pc1000.rom|O||PC1000 pc1000.rom (System ROM)
wqxemu_libretro|Wenquxing|WQXEmu/pc1000/pc1000.fls|O||PC1000 pc1000.fls (NOR Flash)
wqxemu_libretro|Wenquxing|WQXEmu/cc800/obj.bin|O||CC800 obj.bin (System ROM)
wqxemu_libretro|Wenquxing|WQXEmu/cc800/cc800.fls|O||CC800 cc800.fls (NOR Flash)
wqxemu_libretro|Wenquxing|WQXEmu/nc2000/nc2000.nor|O||NC2000 nc2000.nor (NOR Flash)
wqxemu_libretro|Wenquxing|WQXEmu/nc2000/nc2000.nand|O||NC2000 nc2000.nand (NAND Flash)
wqxemu_libretro|Wenquxing|WQXEmu/nc2000/nc2000.nand0|O||NC2000 nc2000.nand0 (First NAND Plane)
wqxemu_libretro|Wenquxing|WQXEmu/nc3000/nc3000.nor|O||NC3000 nc3000.nor (NOR Flash)
wqxemu_libretro|Wenquxing|WQXEmu/nc3000/nc3000.nand|O||NC3000 nc3000.nand (NAND Flash)
wqxemu_libretro|Wenquxing|WQXEmu/nc3000/nc3000.nand0|O||NC3000 nc3000.nand0 (Optional First NAND Plane)
x16emu_libretro|Commander X16|x16/rom.bin|R||x16/rom.bin (Commander X16 KERNAL ROM)
x1_libretro|Sharp X1|xmil/IPLROM.X1|O|eeeea1cd29c6e0e8b094790ae969bfa7|xmil/IPLROM.X1 (Sharp X1 IPL ROM)
x1_libretro|Sharp X1|xmil/IPLROM.X1T|O|851e4a5936f17d13f8c39a980cf00d77|xmil/IPLROM.X1T (Sharp X1 8x8 Font ROM)
xemu_libretro|Xbox|xemu/mcpx_1.0.bin|R||xemu/mcpx_1.0.bin (MCPX Boot ROM)
xemu_libretro|Xbox|xemu/Complex_4627v1.03.bin|R||xemu/Complex_4627v1.03.bin (Flash ROM / BIOS)
xemu_libretro|Xbox|xemu/xbox_hdd.qcow2|R||xemu/xbox_hdd.qcow2 (Hard disk image)
xemu_libretro|Xbox|xemu/xbox_eeprom.bin|O||xemu/xbox_eeprom.bin (EEPROM, created when missing)
yabasanshiro_libretro|Saturn|saturn_bios.bin|R|af5828fdff51384f99b3c4926be27762|saturn_bios.bin (Saturn BIOS)
yabause_libretro|Saturn|saturn_bios.bin|O|af5828fdff51384f99b3c4926be27762|saturn_bios.bin (Saturn BIOS)
yaps2_libretro|Sony PlayStation 2|pcsx2/bios|R||'pcsx2/bios' folder (any valid PS2 BIOS dump, e.g. scph39001.bin)
yaps2_libretro|Sony PlayStation 2|pcsx2/resources|R||'pcsx2/resources' folder (shaders, GameIndex.yaml, fonts)
ymir_libretro|Saturn|sega_101.bin|O|85ec9ca47d8f6807718151cbcca8b964|sega_101.bin (Saturn JP BIOS)
ymir_libretro|Saturn|mpr-17933.bin|O|3240872c70984b6cbfda1586cab68dbe|mpr-17933.bin (Saturn US/EU BIOS)
ymir_libretro|Saturn|saturn_bios.bin|O|af5828fdff51384f99b3c4926be27762|saturn_bios.bin (Saturn BIOS)
zcdi_libretro|CD-i|cdi200.rom|O|2969341396aa61e0143dc2351aaa6ef6|cdi200.rom (CD-i BIOS, NTSC)
zcdi_libretro|CD-i|cdi220b.rom|O|ac0d468be366779c9df633be98da250a|cdi220b.rom (CD-i BIOS, PAL)
zcdi_libretro|CD-i|vmpega.rom|O|53ba3bf7443187a657baa272d01d3771|vmpega.rom (Digital Video Cartridge ROM, needed for DVC titles)
@@RA_END@@
)

# ----------------------------------------------------------------------------
# Rules that turn libretro's "required/optional" flags into real-world need.
#   core-regex @ path-regex @ RULE @ rom folders @ note   ('@' separated)
#   RULE: REQ (needed if you have those games), REC (recommended), OPT,
#         ANY:<group> (at least one file of the group), SKIP
#   First matching line wins; unmatched lines fall back to libretro's R/O flag.
# ----------------------------------------------------------------------------
RA_RULES=$(cat <<'@@RULES_END@@'
^swanstation_libretro$@.@ANY:psx@psx@one PS1 BIOS is required (region-matched, or region-free psxonpsp660.bin / ps1_rom.bin)
^(mednafen_psx|mednafen_psx_hw)_libretro$@.@ANY:psx@psx@one PS1 BIOS is required; Beetle uses scph5500 (JP) / scph5501 (US) / scph5502 (EU) per game region
^pcsx_rearmed.*_libretro$@.@REC@psx@PCSX ReARMed has an HLE BIOS, a real one improves compatibility
^mednafen_saturn_libretro$@^(sega_101|mpr-17933)\.bin$@ANY:sat@saturn,saturnjp@sega_101.bin = JP games, mpr-17933.bin = US/EU games
^mednafen_saturn_libretro$@\.ic1$@OPT@saturn,saturnjp@only for KOF95 / Ultraman cartridge games
^kronos_libretro$@stvbios@REQ@stv@ST-V arcade only
^kronos_libretro$@saturn_bios@REQ@saturn,saturnjp@
^kronos_libretro$@\.ic1$@OPT@@
^(yabause|yabasanshiro)_libretro$@saturn_bios@REC@saturn,saturnjp@core has an HLE BIOS
^(genesis_plus_gx|genesis_plus_gx_wide|genesis_plus_gx_expanded|picodrive)_libretro$@bios_CD_@ANY:scd@segacd,megacd,megacdjp@one per region of the Sega CD games you play
^(genesis_plus_gx|genesis_plus_gx_wide|genesis_plus_gx_expanded|picodrive)_libretro$@.@OPT@@
^flycast.*_libretro$@dc_boot\.bin@REC@dreamcast@Flycast has an HLE BIOS; a few games need the real one
^flycast.*_libretro$@dc/naomi\.zip@REQ@naomi@
^flycast.*_libretro$@dc/naomi2\.zip@REQ@naomi2@
^flycast.*_libretro$@dc/awbios\.zip@REQ@atomiswave@
^flycast.*_libretro$@.@OPT@@only for those specific arcade games
^neocd_libretro$@/(neocd_f|neocd_sf|front-sp1|neocd_t|neocd_st|top-sp1|neocd_z|neocd_sz|neocd)\.(rom|bin)$@ANY:loader@neogeocd,neogeocdjp@any one CD loader BIOS
^neocd_libretro$@/(ng-lo\.rom|000-lo\.lo)$@ANY:zoom@neogeocd,neogeocdjp@the Y-ZOOM ROM is mandatory
^neocd_libretro$@.@OPT@@
^mednafen_(pce|pce_fast|supergrafx)_libretro$@syscard3\.pce@REQ@pcenginecd,tg-cd@needed for all CD games (incl. Arcade Card titles)
^mednafen_(pce|pce_fast|supergrafx)_libretro$@.@OPT@@
^(mesen|nestopia|fceumm|bnes)_libretro$@disksys\.rom@REQ@fds@
^(mesen|nestopia|fceumm)_libretro$@.@OPT@@
^mupen64plus_next.*_libretro$@IPL\.n64@REQ@n64dd@
^parallel_n64_libretro$@.@OPT@@
^(melonds|melondsds)_libretro$@/?(bios7|bios9|firmware)\.bin$@REC@nds@built-in FreeBIOS works for most games
^(melonds|melondsds)_libretro$@dsi_@OPT@nds@only for DSi mode / DSiWare
^desmume.*_libretro$@.@OPT@@
^opera_libretro$@^(panafz1|panafz10|panafz10-norsa|panafz10e-anvil|panafz10e-anvil-norsa|goldstar|sanyotry|panafz1j|panafz1j-norsa)\.bin$@ANY:3do@3do@any one 3DO BIOS (panafz10.bin is the usual pick)
^opera_libretro$@.@OPT@@kanji fonts: some Japanese games
^o2em_libretro$@o2rom\.bin@REQ@odyssey2,videopac@
^o2em_libretro$@.@OPT@@Videopac+ / French models only
^freechaf_libretro$@sl9@OPT@@Channel F II only
^freechaf_libretro$@.@REQ@channelf@
^puae.*_libretro$@kick(34005\.A500|40068\.A1200|40060\.CD32(\.ext)?)$@REC@amiga,amiga600,amiga1200,amigacd32,cdtv@PUAE falls back to AROS, but real Kickstarts are far more compatible
^puae.*_libretro$@.@OPT@@
^same_cdi_libretro$@cdimono1\.zip@REQ@cdimono1,cdi@
^same_cdi_libretro$@.@OPT@@
^handy_libretro$@lynxboot@REC@atarilynx@
^mednafen_lynx_libretro$@lynxboot@REQ@atarilynx@
^mednafen_pcfx_libretro$@pcfx\.rom@REQ@pcfx@
^(a5200|atari800)_libretro$@5200\.rom@REQ@atari5200@
^atari800_libretro$@ATARI(XL|OSB|BAS)\.ROM@REC@atari800,atarixe@
^atari800_libretro$@.@OPT@@
^prosystem_libretro$@.@OPT@atari7800@only for the boot screen
^hatari_libretro$@tos\.img@REQ@atarist@
^freeintv_libretro$@.@REQ@intellivision@
^gearcoleco_libretro$@colecovision\.rom@REQ@colecovision@
^gearcoleco_libretro$@.@OPT@@
^bluemsx_libretro$@.@REQ@msx,msx1,msx2,msx2+,msxturbor@copy the Machines + Databases folders from the blueMSX package
^fmsx_libretro$@^MSX2?P?(EXT)?\.ROM$@REQ@msx,msx1,msx2,msx2+@
^fmsx_libretro$@.@OPT@@
^px68k_libretro$@keropi/(iplrom|cgrom)\.dat@REQ@x68000@
^px68k_libretro$@.@OPT@@
^np2kai_libretro$@np2kai/(bios|itf|sound)\.rom@REC@pc98@
^np2kai_libretro$@np2kai/(font\.bmp|FONT\.ROM)@ANY:font@pc98@
^np2kai_libretro$@.@OPT@@
^quasi88_libretro$@quasi88/n88(_0)?\.rom@REQ@pc88@
^quasi88_libretro$@.@OPT@@
^minivmac_libretro$@MacII@REQ@macintosh@
^(snes9x|snes9x2010|bsnes.*|mesen-s)_libretro$@BS-X\.bin@REQ@satellaview@
^(snes9x|snes9x2010|bsnes.*)_libretro$@STBIOS\.bin@REQ@sufami@
^(bsnes.*|mesen-s)_libretro$@SGB[12]\.sfc@OPT@sgb@
^(bsnes.*|mesen-s)_libretro$@(dsp|cx4|st01)@OPT@@only for DSP/ST-chip games (Pilotwings, Super Mario Kart, ...)
^(mgba|gambatte|sameboy|gearboy|gpsp|vbam|vba_next|mesen-s|tgbdual|bsnes.*|snes9x)_libretro$@.@OPT@@boot ROMs only add the boot logo
^dolphin_libretro$@codehandler@REQ@gc,wii@copy the dolphin-emu/Sys folder
^dolphin_libretro$@.@OPT@@
^fbneo_libretro$@.@OPT@@checked in the Arcade section
^fbalpha.*_libretro$@.@OPT@@
^mame.*_libretro$@.@OPT@@
^pcsx2_libretro$@.@SKIP@@checked in the PS2 section
^ppsspp_libretro$@.@REQ@psp@RetroArch Online Updater > Core System Files Downloader
^citra.*_libretro$@.@OPT@n3ds@only for encrypted dumps
^prboom_libretro$@.@REQ@doom@
^pokemini_libretro$@.@OPT@@has a free BIOS built in
@@RULES_END@@
)

# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------
FLATPAKS=""
if command -v flatpak >/dev/null 2>&1; then
  FLATPAKS=$(flatpak list --app --columns=application 2>/dev/null)
fi
fp_installed() {   # $1 = flatpak id
  [[ -n $FLATPAKS ]] && grep -qxF "$1" <<<"$FLATPAKS" && return 0
  [[ -z $FLATPAKS && -d "$HOME/.var/app/$1" ]] && return 0
  return 1
}
appimage() {       # $1.. glob patterns in ~/Applications (case-insensitive)
  local p f
  shopt -s nocaseglob
  for p; do for f in "$HOME"/Applications/$p; do shopt -u nocaseglob; printf '%s' "$f"; return 0; done; done
  shopt -u nocaseglob; return 1
}
ini_get() {        # file key  -> first value of key= (any section), quotes stripped
  [[ -f $1 ]] || return 1
  local v
  v=$(grep -m1 -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null) || return 1
  v=${v#*=}; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
  printf '%s' "$v"
}
yml_get() {        # file key  -> value of "key: value"
  [[ -f $1 ]] || return 1
  local v
  v=$(grep -m1 -E "^[[:space:]]*$2:[[:space:]]*" "$1" 2>/dev/null) || return 1
  v=${v#*:}; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
  printf '%s' "$v"
}
shell_val() {      # file var -> value of a shell assignment, without executing anything
  # handles: var=/x  var="/x"  var='/x'  var="/home/deck/A B"/Emulation  var="$emulationPath/bios"
  [[ -f $1 ]] || return 1
  local v
  v=$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" 2>/dev/null) || return 1
  v=${v#*=}; v=${v%$'\r'}
  v=$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$v")
  v=${v//\"/}; v=${v//\'/}
  local ep=${SV_EMUPATH:-}
  v=${v//\$\{emulationPath\}/$ep}; v=${v//\$emulationPath/$ep}
  expand_path "$v"
}
first_existing() { local f; for f; do [[ -e $f ]] && { printf '%s' "$f"; return 0; }; done; return 1; }

# Contexts: each is "name|bios|roms|storage|saves|xdg-config-root"
CONTEXTS=()
detect_contexts() {
  if [[ -n $OPT_BIOS ]]; then
    local b r
    b=$(realpath -m -- "$(expand_path "$OPT_BIOS")")
    r=${OPT_ROMS:+$(realpath -m -- "$(expand_path "$OPT_ROMS")")}
    [[ -z $r && -d "$(dirname "$b")/roms" ]] && r="$(dirname "$b")/roms"
    CONTEXTS+=("custom|$b|$r|$(dirname "$b")/storage|$(dirname "$b")/saves|$HOME/.config")
    return
  fi
  # EmuDeck
  if [[ -z $OPT_FRONTEND || $OPT_FRONTEND == emudeck ]]; then
    local s bios roms storage saves
    s=$(first_existing "$HOME/.config/EmuDeck/settings.sh" "$HOME/emudeck/settings.sh")
    if [[ -n $s ]]; then
      local emu; emu=$(shell_val "$s" emulationPath); SV_EMUPATH=$emu
      bios=$(shell_val "$s" biosPath)
      roms=$(shell_val "$s" romsPath)
      storage=$(shell_val "$s" storagePath)
      saves=$(shell_val "$s" savesPath)
      [[ -z $bios && -n $emu ]] && bios="$emu/bios"
      [[ -z $roms && -n $emu ]] && roms="$emu/roms"
      [[ -z $storage && -n $emu ]] && storage="$emu/storage"
      [[ -z $saves && -n $emu ]] && saves="$emu/saves"
      # if settings point somewhere that doesn't exist but the default does, say so and use the default
      if [[ ! -d $bios && -d $HOME/Emulation/bios ]]; then
        EMUDECK_NOTE="settings.sh says biosPath=$bios (missing) - falling back to ~/Emulation"
        bios=$HOME/Emulation/bios roms=$HOME/Emulation/roms storage=$HOME/Emulation/storage saves=$HOME/Emulation/saves
      fi
      CONTEXTS+=("EmuDeck|$bios|$roms|$storage|$saves|$HOME/.config")
      EMUDECK_SETTINGS=$s
    elif [[ -d $HOME/Emulation/bios ]]; then
      CONTEXTS+=("EmuDeck|$HOME/Emulation/bios|$HOME/Emulation/roms|$HOME/Emulation/storage|$HOME/Emulation/saves|$HOME/.config")
      EMUDECK_SETTINGS="(settings.sh not found - assumed ~/Emulation)"
    fi
  fi
  # RetroDECK
  if [[ -z $OPT_FRONTEND || $OPT_FRONTEND == retrodeck ]]; then
    local x="$HOME/.var/app/net.retrodeck.retrodeck/config" j c
    bios="" roms="" storage="" saves=""
    j="$x/retrodeck/retrodeck.json"; c="$x/retrodeck/retrodeck.cfg"
    if [[ -f $j ]]; then
      if command -v jq >/dev/null 2>&1; then
        bios=$(jq -r '.paths.bios_path // empty' "$j" 2>/dev/null); roms=$(jq -r '.paths.roms_path // empty' "$j" 2>/dev/null)
        storage=$(jq -r '.paths.storage_path // empty' "$j" 2>/dev/null); saves=$(jq -r '.paths.saves_path // empty' "$j" 2>/dev/null)
      else
        bios=$(grep -oE '"bios_path"[[:space:]]*:[[:space:]]*"[^"]*"' "$j" | sed -E 's/.*"([^"]*)"$/\1/')
        roms=$(grep -oE '"roms_path"[[:space:]]*:[[:space:]]*"[^"]*"' "$j" | sed -E 's/.*"([^"]*)"$/\1/')
        storage=$(grep -oE '"storage_path"[[:space:]]*:[[:space:]]*"[^"]*"' "$j" | sed -E 's/.*"([^"]*)"$/\1/')
        saves=$(grep -oE '"saves_path"[[:space:]]*:[[:space:]]*"[^"]*"' "$j" | sed -E 's/.*"([^"]*)"$/\1/')
      fi
    elif [[ -f $c ]]; then
      bios=$(shell_val "$c" bios_folder); roms=$(shell_val "$c" roms_folder)
      storage=$(shell_val "$c" storage_folder); saves=$(shell_val "$c" saves_folder)
    fi
    if [[ -z ${bios:-} && -d $HOME/retrodeck/bios ]]; then
      bios=$HOME/retrodeck/bios roms=$HOME/retrodeck/roms storage=$HOME/retrodeck/storage saves=$HOME/retrodeck/saves
    fi
    [[ -n ${bios:-} ]] && CONTEXTS+=("RetroDECK|$bios|$roms|$storage|$saves|$x")
  fi
}

# ----------------------------------------------------------------------------
# Hash index of the BIOS tree
# ----------------------------------------------------------------------------
declare -A H_PATH F_MD5        # md5 -> first path ; path -> md5
ALLFILES=()
build_index() {   # $1 = root
  H_PATH=(); F_MD5=(); ALLFILES=()
  [[ -d $1 ]] || return
  local line m p
  # prune big emulator-internal trees (Switch NAND, dev_flash, HDDs, ...) - they are checked separately
  local prune=( \( -type d \( -iname firmware -o -name registered -o -name dev_flash -o -name dev_hdd0 -o -name dev_hdd1
                 -o -iname vita3k -o -name sys_modules -o -name mlc01 -o -name nand -o -name sdmc -o -name ux0 -o -name vs0
                 -o -name os0 -o -name sa0 -o -name pd0 -o -name dolphin-emu -o -name Machines -o -name Databases \) -prune \) )
  while IFS= read -r -d '' p; do ALLFILES+=("$p"); done < <(find -L "$1" -maxdepth 6 "${prune[@]}" -o -type f -print0 2>/dev/null)
  ((${#ALLFILES[@]})) || return
  while IFS= read -r line; do
    [[ $line == \\* ]] && continue            # md5sum escapes odd filenames; skip them
    m=${line:0:32}; p=${line:34}
    F_MD5[$p]=$m; [[ -z ${H_PATH[$m]:-} ]] && H_PATH[$m]=$p
  done < <(find -L "$1" -maxdepth 6 "${prune[@]}" -o -type f -size -"$((OPT_MAXMB*1024+1))"k -print0 2>/dev/null | xargs -0 -r md5sum 2>/dev/null)
}
md5_of() {
  local p=$1 m
  if [[ -n ${F_MD5[$p]:-} ]]; then printf '%s' "${F_MD5[$p]}"; return; fi
  m=$(md5sum -- "$p" 2>/dev/null) || return 1
  m=${m:0:32}; F_MD5[$p]=$m; printf '%s' "$m"
}
ident() {         # md5 -> "what this file really is"
  local d=${K_DESC[$1]:-}
  [[ -n $d ]] && printf '%s' "$d" || printf 'unrecognised dump'
}

# ----------------------------------------------------------------------------
# File probe
#   probe <expected-abs-path> <comma-md5s or empty>
#   sets P_STATE  OK | NOHASH | BADHASH | CASE | ELSEWHERE | EMPTY | BROKEN | MISSING
#        P_PATH (file actually used/found)  P_MD5
# ----------------------------------------------------------------------------
probe() {
  local want=$1 hs=$2 dir base m h ci
  P_STATE=MISSING P_PATH="" P_MD5=""
  dir=$(dirname -- "$want"); base=$(basename -- "$want")
  if [[ -L $want && ! -e $want ]]; then P_STATE=BROKEN; P_PATH=$want; return; fi
  if [[ -f $want ]]; then
    P_PATH=$want
    if [[ ! -s $want ]]; then P_STATE=EMPTY; return; fi
    if [[ -z $hs ]]; then P_STATE=NOHASH; return; fi
    m=$(md5_of "$want"); P_MD5=$m
    [[ ",$hs," == *",$m,"* ]] && P_STATE=OK || P_STATE=BADHASH
    return
  fi
  if [[ -d $dir ]]; then
    ci=$(find -L "$dir" -maxdepth 1 -type f -iname "$(glob_esc "$base")" -print -quit 2>/dev/null)
    if [[ -n $ci ]]; then
      P_STATE=CASE P_PATH=$ci
      [[ -n $hs ]] && P_MD5=$(md5_of "$ci")
      return
    fi
  fi
  if [[ -n $hs ]]; then
    local IFS=,
    for h in $hs; do
      if [[ -n ${H_PATH[$h]:-} ]]; then P_STATE=ELSEWHERE P_PATH=${H_PATH[$h]} P_MD5=$h; return; fi
    done
  fi
}

# report <label> <expected-abs> <md5s> <importance REQ|REC|OPT|ANY> <roms-present 0/1/-> <system> [note]
#   prints one line (+fix), records NEED/WARN, returns 0 if the file is usable
report() {
  local label=$1 want=$2 hs=$3 imp=$4 rp=$5 sys=$6 note=${7:-}
  local disp; disp=$(short "$want")
  probe "$want" "$hs"
  case $P_STATE in
    OK)      l_ok "$label ${C_D}$(ident "$P_MD5")${C_0}"; ((CNT_OK++)); return 0 ;;
    NOHASH)  l_ok "$label ${C_D}present ($(human "$(fsize "$want")"), no reference hash to verify)${C_0}"; ((CNT_OK++)); return 0 ;;
    BADHASH)
      local what; what=$(ident "$P_MD5")
      if [[ $want == *.zip ]]; then
        l_ok "$label ${C_D}present (zip hash differs from reference - normal between MAME/FBNeo versions)${C_0}"; ((CNT_OK++)); return 0
      fi
      local exp_tag="" got_tag=${K_TAG[$P_MD5]:-} hh
      for hh in ${hs//,/ }; do exp_tag=${K_TAG[$hh]:-}; [[ -n $exp_tag ]] && break; done
      if [[ -n $got_tag && $got_tag != "$exp_tag" ]]; then
        l_bad "$label is the WRONG file - it is actually: ${C_BOLD}$what${C_0}"
        if [[ $imp == REQ && $rp == 1 ]]; then add_need "$sys: $disp is really '$what' - replace it with the correct dump"
        elif [[ $imp != OPT && $imp != ANY ]]; then add_warn "$sys: $disp is really '$what'"; fi
        return 1
      fi
      l_warn "$label ${C_Y}hash mismatch${C_0} - this file is: ${C_BOLD}$what${C_0} ${C_D}(md5 $P_MD5)${C_0}"
      add_warn "$sys: $disp has an unexpected hash ($what) - may be a bad/alternate dump"
      return 0 ;;
    CASE)
      l_warn "$label ${C_Y}wrong filename case${C_0}: found $(short "$P_PATH") - Linux is case-sensitive"
      l_fix "mv -n $(q "$P_PATH") $(q "$want")"; add_fix "mv -n $(q "$P_PATH") $(q "$want")"
      add_warn "$sys: rename $(short "$P_PATH") -> $(basename "$want") (case)"
      [[ $imp == OPT ]] && return 1
      return 2 ;;
    ELSEWHERE)
      l_warn "$label ${C_Y}not at $disp${C_0}, but the right file is here: $(short "$P_PATH")"
      local cmd="cp -n $(q "$P_PATH") $(q "$want")"
      [[ -d $(dirname "$want") ]] || cmd="mkdir -p $(q "$(dirname "$want")") && $cmd"
      l_fix "$cmd"; add_fix "$cmd"
      add_warn "$sys: copy $(short "$P_PATH") -> $disp"
      return 2 ;;
    EMPTY)   l_bad "$label is a 0-byte file ($disp)"; add_warn "$sys: $disp is empty"; return 1 ;;
    BROKEN)  l_bad "$label is a broken symlink ($disp -> $(readlink "$want"))"; add_warn "$sys: broken symlink $disp"; return 1 ;;
    MISSING)
      case $imp in
        OPT) ((OPT_VERBOSE)) && l_opt "$label - optional, not present${note:+ ($note)}"; return 1 ;;
        ANY) ((OPT_VERBOSE)) && l_opt "$label - not present"; return 1 ;;
        REC) if [[ $rp == 0 ]]; then l_opt "$label - recommended once you add games ($disp)${note:+ - $note}"
             else l_warn "$label - ${C_Y}recommended, missing${C_0} ($disp)${note:+ - $note}"
                  add_warn "$sys: recommended $(basename "$want") missing${note:+ ($note)}"; fi
             return 1 ;;
        REQ) if [[ $rp == 1 ]]; then
               l_bad "$label - MISSING, needed ($disp)${note:+ - $note}"; add_need "$sys: $(basename "$want") -> $disp${note:+ ($note)}"
             else
               l_opt "$label - missing ($disp) - needed once you add games${note:+ - $note}"
             fi
             return 1 ;;
      esac ;;
  esac
  return 1
}

# ----------------------------------------------------------------------------
# ROM folder detection (decides NEED vs "later")
# ----------------------------------------------------------------------------
declare -A ROMC
rom_count() {   # comma list of folders -> total files
  local f n tot=0 IFS=,
  [[ -z ${ROMS:-} || ! -d $ROMS ]] && { echo -1; return; }
  for f in $1; do
    [[ -z $f ]] && continue
    if [[ -z ${ROMC[$f]:-} ]]; then
      if [[ -d $ROMS/$f ]]; then
        n=$(find -L "$ROMS/$f" -maxdepth 3 -type f ! -name '.*' ! -iname '*.txt' ! -iname 'metadata*' ! -iname 'neogeo.zip' ! -iname 'naomi*.zip' ! -iname 'awbios.zip' ! -iname 'keys.txt' ! -iname '*.keys' \
             ! -path '*/media/*' ! -path '*/images/*' ! -path '*/videos/*' ! -path '*/manuals/*' 2>/dev/null | head -n 500 | wc -l)
      else n=0; fi
      ROMC[$f]=$n
    fi
    ((tot+=ROMC[$f]))
  done
  echo "$tot"
}
warm_romc() {   # pre-count every rom folder once (rom_count runs in subshells, so cache up front)
  ROMC=()
  [[ -n ${ROMS:-} && -d $ROMS ]] || return
  local d f
  for d in "$ROMS"/*/; do f=$(basename "$d"); rom_count "$f" >/dev/null; ROMC[$f]=$(rom_count "$f"); done
}
rp_flag() { local n; n=$(rom_count "$1"); if [[ -z $1 ]]; then echo -; elif ((n>0)); then echo 1; elif ((n<0)); then echo -; else echo 0; fi; }
rom_note() {
  local n; [[ -z $1 ]] && return; n=$(rom_count "$1")
  if ((n<0)); then printf '[roms folder unknown]'
  elif ((n>0)); then printf '[%s%s game files in roms/%s]' "$n" "$( ((n>=500)) && echo +)" "${1//,/ | }"
  else printf '[no games in roms/%s]' "${1//,/ | }"; fi
}

# ----------------------------------------------------------------------------
# Generic helpers for systems where any file with a known hash works
# (DuckStation, PCSX2: they identify BIOS by content, not by filename)
# ----------------------------------------------------------------------------
# hashdir <dir> <TAG> -> prints found BIOSes, sets HD_COUNT HD_REGIONS
hashdir() {
  local dir=$1 tag=$2 f m t r found=0 regs=""
  HD_COUNT=0 HD_REGIONS=""
  if [[ ! -d $dir ]]; then l_warn "folder does not exist: $(short "$dir")"; return; fi
  for f in "$dir"/*; do
    [[ -f $f ]] || continue
    m=$(md5_of "$f") || continue
    t=${K_TAG[$m]:-}
    if [[ $t == "$tag" ]]; then
      r=${K_REG[$m]}; ((found++))
      l_ok "$(basename "$f") ${C_D}${K_DESC[$m]} [$r]${C_0}"; ((CNT_OK++))
      regs+=" $r"
    elif [[ $tag == PS2 && $(fsize "$f") -eq 4194304 ]]; then
      local rv; rv=$(LC_ALL=C grep -a -m1 -oE '[0-9]{4}[JAEHCRKT][CDTX][0-9]{8}' "$f" 2>/dev/null | head -n1)
      if [[ -n $rv ]]; then
        r=$(ps2_region "${rv:4:1}"); ((found++)); regs+=" $r"
        l_warn "$(basename "$f") ${C_D}valid-looking PS2 BIOS (ROMVER $rv, $r) but hash not in any known list - possibly a bad dump${C_0}"
        add_warn "PS2: $(basename "$f") has ROMVER $rv but an unknown hash"
      fi
    elif [[ $tag == PS1 && $(fsize "$f") -eq 524288 ]]; then
      local sv; sv=$(LC_ALL=C grep -a -m1 -oE 'System ROM Version [0-9.]+ [0-9/]+ [AEJ]' "$f" 2>/dev/null | head -n1)
      if [[ -n $sv ]]; then
        r=$(case ${sv: -1} in A) echo US;; E) echo EU;; J) echo JP;; esac); ((found++)); regs+=" $r"
        l_warn "$(basename "$f") ${C_D}looks like a PS1 BIOS ($sv) but the hash is unknown - possibly a bad dump${C_0}"
        add_warn "PS1: $(basename "$f") ($sv) has an unknown hash"
      fi
    fi
  done
  HD_COUNT=$found; HD_REGIONS=$regs
}
ps2_region() { case $1 in J) echo JP;; A) echo US;; E) echo EU;; H) echo ASIA;; C) echo CN;; R) echo RU;; K) echo KR;; T) echo JP;; *) echo "?";; esac; }
region_line() {   # $1 regions string, $2.. wanted regions
  local have=$1 r out="" all=1; shift
  for r; do
    if [[ $have == *" $r"* || $have == *" ALL"* || $have == *"$r/"* || $have == *"/$r"* ]]; then out+="${C_G}$r ${S_OK}${C_0}  "
    else out+="${C_Y}$r -${C_0}  "; all=0; fi
  done
  l_info "regions covered: $out"
  return $((1-all))
}
# Find BIOSes of a TAG that sit anywhere else in the BIOS tree (to suggest moving them)
elsewhere_tag() {  # TAG dir-to-exclude
  local p m out=()
  for p in "${!F_MD5[@]}"; do
    m=${F_MD5[$p]}
    [[ ${K_TAG[$m]:-} == "$1" && $(dirname "$p") != "$2" ]] && out+=("$p")
  done
  printf '%s\n' "${out[@]}"
}

# ============================================================================
# CHECKS
# ============================================================================

check_hygiene() {
  hdr "BIOS folder hygiene"
  local issues=0 f b
  if [[ ! -d $BIOS ]]; then l_bad "BIOS folder does not exist: $BIOS"; add_need "BIOS folder $BIOS is missing"; return; fi
  [[ -r $BIOS ]] || { l_bad "BIOS folder not readable"; return; }
  l_info "${#ALLFILES[@]} files indexed under $(short "$BIOS") (hashed: ${#F_MD5[@]})"
  for f in "${ALLFILES[@]}"; do
    b=$(basename "$f")
    case ${b,,} in
      *:zone.identifier|*zone.identifier)
        l_warn "Windows download junk: $(short "$f")"; add_fix "rm -f $(q "$f")"; ((issues++)); continue ;;
      desktop.ini|thumbs.db|.ds_store|._*) l_info "junk file: $(short "$f")"; continue ;;
    esac
    if [[ ! -s $f ]]; then l_warn "0-byte file: $(short "$f")"; add_warn "0-byte file $(short "$f")"; ((issues++)); fi
    case ${b,,} in
      scph*.zip|scph*.7z|*bios*.7z|*bios*.rar|*.bin.zip|*.rom.zip|dc_boot*.zip|bios_cd*.zip|*.bin.7z|kick*.zip|ps2-*.zip|ps2*bios*.zip)
        l_warn "compressed BIOS - most emulators need it extracted: $(short "$f")"
        add_warn "extract $(short "$f")"; ((issues++)) ;;
      *.bin.txt|*.rom.txt|prod.keys.txt|keys.txt.txt|*.bin.bak)
        l_warn "suspicious double extension: $(short "$f")"; add_warn "double extension: $(short "$f")"; ((issues++)) ;;
      prod*.keys|title*.keys)
        [[ $f != */keys/* && $f != */switch/* && $f != */system/* ]] && { l_warn "Switch key file loose in BIOS folder (not used from here): $(short "$f")"; ((issues++)); } ;;
      *.pup) l_info "firmware package found: $(short "$f") (see PS3/Vita sections)" ;;
    esac
  done
  # broken symlinks (EmuDeck links bios/<emu>/keys|firmware into emulator folders)
  while IFS= read -r -d '' f; do
    l_bad "broken symlink: $(short "$f") -> $(readlink "$f")"
    add_warn "broken symlink $(short "$f") (re-run EmuDeck 'Reset configuration' for that emulator or recreate it)"
    ((issues++))
  done < <(find "$BIOS" -maxdepth 3 -xtype l -print0 2>/dev/null)
  # same name in different case
  local dup; dup=$(find "$BIOS" -maxdepth 2 -type f -printf '%h/%f\n' 2>/dev/null | awk '{l=tolower($0); c[l]++; n[l]=n[l]"  "$0} END{for(k in c) if(c[k]>1) print n[k]}')
  [[ -n $dup ]] && { l_warn "same filename in different case (confusing, pick one):"; l_sub "$dup"; ((issues++)); }
  ((issues==0)) && l_ok "no hygiene problems found"
}

# --------------------------------------------------------------------------
check_psx() {
  local folders="psx" note have_ds=0 dir
  local ds_cfg; ds_cfg=$(first_existing "$HOME/.local/share/duckstation/settings.ini" \
     "$HOME/.var/app/org.duckstation.DuckStation/config/duckstation/settings.ini" \
     "$HOME/.var/app/org.duckstation.DuckStation/data/duckstation/settings.ini" \
     "$XDGC/duckstation/settings.ini" "$HOME/.var/app/net.retrodeck.retrodeck/data/duckstation/settings.ini")
  if [[ $CTX == RetroDECK ]] || appimage 'DuckStation*.AppImage' >/dev/null || fp_installed org.duckstation.DuckStation || [[ -n $ds_cfg ]]; then have_ds=1; fi; ((have_ds)) || { ((OPT_ALL)) && { have_ds=1; NOTINST=1; }; }
  ((have_ds)) || return
  hdr "Sony PlayStation - DuckStation  $(rom_note $folders)"; CUR_KEY=psx
  dir=$(ini_get "$ds_cfg" SearchDirectory 2>/dev/null); dir=$(expand_path "${dir:-}")
  [[ -z $dir || $dir != /* ]] && dir=$BIOS
  l_info "DuckStation reads BIOS by hash from: $(short "$dir")  ${C_D}(filename does not matter)${C_0}"
  [[ -n $ds_cfg ]] && l_sub "config: $(short "$ds_cfg")"
  hashdir "$dir" PS1
  local rp; rp=$(rp_flag $folders)
  if ((HD_COUNT==0)); then
    local e; e=$(elsewhere_tag PS1 "$dir")
    if [[ -n $e ]]; then
      l_warn "no PS1 BIOS in that folder, but found elsewhere:"; while IFS= read -r f; do l_fix "cp -n $(q "$f") $(q "$dir/")"; add_fix "cp -n $(q "$f") $(q "$dir/")"; done <<<"$e"
    fi
    if [[ $rp == 1 ]]; then l_bad "NO PlayStation BIOS - DuckStation will not boot your games"; add_need "PS1 (DuckStation): any PS1 BIOS (e.g. scph5501.bin US / scph5502.bin EU / scph5500.bin JP) in $(short "$dir")"
    else l_warn "no PlayStation BIOS (needed once you add PS1 games)"; fi
  else
    mark_ok psx
    region_line "$HD_REGIONS" US EU JP || l_sub "DuckStation picks the BIOS matching each game's region; add the missing ones for those regions' games (or a region-free psxonpsp660.bin / ps1_rom.bin)"
  fi
}

# --------------------------------------------------------------------------
check_ps2() {
  local folders="ps2" have=0 dir cfg
  cfg=$(first_existing "$HOME/.config/PCSX2/inis/PCSX2.ini" "$HOME/.var/app/net.pcsx2.PCSX2/config/PCSX2/inis/PCSX2.ini" "$XDGC/PCSX2/inis/PCSX2.ini")
  if [[ $CTX == RetroDECK ]] || appimage 'pcsx2*.AppImage' >/dev/null || fp_installed net.pcsx2.PCSX2 || [[ -n $cfg ]] ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  if ((have)); then
    hdr "Sony PlayStation 2 - PCSX2  $(rom_note $folders)"; CUR_KEY=ps2
    dir=$(ini_get "$cfg" Bios 2>/dev/null); dir=$(expand_path "${dir:-}")
    [[ -z $dir || $dir != /* ]] && dir=$BIOS
    l_info "PCSX2 BIOS folder: $(short "$dir")  ${C_D}(filename does not matter, needs the full 4 MiB dump)${C_0}"
    [[ -n $cfg ]] && l_sub "config: $(short "$cfg")"
    hashdir "$dir" PS2
    local rp; rp=$(rp_flag $folders)
    if ((HD_COUNT==0)); then
      local e; e=$(elsewhere_tag PS2 "$dir")
      [[ -n $e ]] && { l_warn "PS2 BIOS found elsewhere:"; while IFS= read -r f; do l_fix "cp -n $(q "$f") $(q "$dir/")"; add_fix "cp -n $(q "$f") $(q "$dir/")"; done <<<"$e"; }
      if [[ $rp == 1 ]]; then l_bad "NO PS2 BIOS - PCSX2 cannot run games"; add_need "PS2 (PCSX2): one PS2 BIOS dump (e.g. SCPH-70012 US / SCPH-70004 EU / SCPH-70000 JP) in $(short "$dir")"
      else l_warn "no PS2 BIOS (needed once you add PS2 games)"; fi
    else
      mark_ok ps2
      region_line "$HD_REGIONS" US EU JP || l_sub "any region boots any game in PCSX2; matching region only matters for language/PAL-NTSC defaults"
      local ext; ext=$(find -L "$dir" -maxdepth 1 -type f \( -iname '*.erom' -o -iname '*.rom1' -o -iname '*.rom2' -o -iname '*.nvm' -o -iname '*.mec' \) 2>/dev/null | wc -l)
      ((ext)) && l_info "$ext companion file(s) (.EROM/.ROM1/.ROM2/.NVM/.MEC) present - only needed for the DVD player"
    fi
  fi
  # RetroArch LRPS2 / pcsx2 core
  if [[ " ${RA_CORES[*]:-} " == *" pcsx2_libretro "* ]]; then
    subnow "RetroArch LRPS2 core" "$(short "$RA_SYS/pcsx2/bios")"
    hashdir "$RA_SYS/pcsx2/bios" PS2
    if ((HD_COUNT==0)); then
      if [[ $(rp_flag $folders) == 1 ]]; then l_warn "LRPS2 core has no BIOS in system/pcsx2/bios"; add_warn "PS2 (RetroArch LRPS2): put a PS2 BIOS in $(short "$RA_SYS/pcsx2/bios")"; else l_opt "LRPS2: no BIOS in system/pcsx2/bios"; fi
    fi
  fi
}

# --------------------------------------------------------------------------
check_ps3() {
  local cfgdir="" have=0
  for cfgdir in "$HOME/.config/rpcs3" "$HOME/.var/app/net.rpcs3.RPCS3/config/rpcs3" "$XDGC/rpcs3"; do
    [[ -d $cfgdir ]] && break; cfgdir=""
  done
  if [[ $CTX == RetroDECK ]] || appimage 'rpcs3*.AppImage' >/dev/null || fp_installed net.rpcs3.RPCS3 || [[ -n $cfgdir ]] ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  ((have)) || return
  hdr "Sony PlayStation 3 - RPCS3  $(rom_note ps3)"; CUR_KEY=ps3
  local flash="" vfs="$cfgdir/vfs.yml" emudir
  if [[ -f $vfs ]]; then
    emudir=$(yml_get "$vfs" '\$\(EmulatorDir\)'); [[ -z $emudir ]] && emudir="$cfgdir/"
    flash=$(yml_get "$vfs" '/dev_flash/'); flash=${flash//\$(EmulatorDir)/$emudir}
    l_sub "config: $(short "$vfs")"
  fi
  [[ -z $flash ]] && flash=$(first_existing "$cfgdir/dev_flash" "$BIOS/rpcs3/dev_flash" "$HOME/.config/rpcs3/dev_flash")
  [[ -z $flash ]] && flash="${cfgdir:-$HOME/.config/rpcs3}/dev_flash"
  flash=${flash%/}
  local vt="$flash/vsh/etc/version.txt" rp; rp=$(rp_flag ps3)
  if [[ -f $vt ]]; then
    local rel; rel=$(grep -m1 -oE 'release:[0-9.]+' "$vt" | cut -d: -f2)
    local nmods; nmods=$(find "$flash/sys/external" -maxdepth 1 -name '*.sprx' 2>/dev/null | wc -l)
    if ((nmods > 50)); then
      l_ok "PS3 firmware installed: ${C_BOLD}${rel:-unknown}${C_0} ${C_D}($nmods system modules in $(short "$flash"))${C_0}"; ((CNT_OK++))
    else
      l_warn "firmware version file present (${rel:-?}) but only $nmods modules in dev_flash/sys/external - install looks incomplete"
      add_warn "PS3: firmware install in $(short "$flash") looks incomplete - reinstall PS3UPDAT.PUP via File > Install Firmware"
    fi
  else
    if [[ $rp == 1 ]]; then l_bad "PS3 firmware NOT installed (no $(short "$vt"))"; add_need "PS3 (RPCS3): install PS3UPDAT.PUP via RPCS3 > File > Install Firmware"
    else l_warn "PS3 firmware not installed (needed once you add PS3 games)"; fi
  fi
  # loose PUPs
  local p
  while IFS= read -r p; do
    [[ -z $p ]] && continue
    local magic; magic=$(head -c 5 "$p" 2>/dev/null)
    if [[ $magic == SCEUF ]]; then l_info "firmware package $(short "$p") ($(human "$(fsize "$p")")) is valid - install it from RPCS3 if the firmware above is missing"
    else l_warn "$(short "$p") does not look like a PS3 PUP (bad header) - re-download from Sony"; add_warn "PS3: $(short "$p") has a bad header"; fi
  done < <(printf '%s\n' "${ALLFILES[@]}" | grep -iE '/ps3updat[^/]*\.pup$')
}

# --------------------------------------------------------------------------
check_vita() {
  local cfg="" have=0 pref=""
  cfg=$(first_existing "$HOME/.config/Vita3K/config.yml" "$XDGC/Vita3K/config.yml" "$HOME/.var/app/net.retrodeck.retrodeck/config/Vita3K/config.yml")
  if [[ $CTX == RetroDECK ]] || [[ -d $HOME/Applications/Vita3K ]] || [[ -n $cfg ]] ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  ((have)) || return
  hdr "Sony PlayStation Vita - Vita3K  $(rom_note psvita)"; CUR_KEY=psvita
  [[ -n $cfg ]] && { pref=$(yml_get "$cfg" pref-path); l_sub "config: $(short "$cfg")"; }
  pref=$(expand_path "${pref:-}")
  [[ -z $pref ]] && pref=$(first_existing "$STORAGE/Vita3K" "$STORAGE/psvita/Vita3K" "$HOME/.local/share/Vita3K/Vita3K")
  pref=${pref%/}
  l_info "Vita3K data folder: $(short "${pref:-?}")"
  local rp; rp=$(rp_flag psvita)
  if [[ -n $pref && -d $pref/vs0 && -n "$(ls -A "$pref/vs0" 2>/dev/null)" ]]; then
    local v=""; [[ -f $pref/vs0/vsh/etc/version.txt ]] && v=$(grep -m1 -oE 'release:[0-9.]+' "$pref/vs0/vsh/etc/version.txt" | cut -d: -f2)
    l_ok "Vita firmware installed${v:+ ($v)} ${C_D}($(short "$pref/vs0"))${C_0}"; ((CNT_OK++))
  else
    if [[ $rp == 1 ]]; then l_bad "Vita firmware NOT installed"; add_need "Vita (Vita3K): install PSVUPDAT.PUP via Vita3K > File > Install Firmware"
    else l_warn "Vita firmware not installed (needed once you add Vita games)"; fi
  fi
  if [[ -n $pref ]] && compgen -G "$pref/sa0/data/font/pvf/*.pvf" >/dev/null; then
    l_ok "firmware font package installed ${C_D}(sa0/data/font/pvf)${C_0}"; ((CNT_OK++))
  else
    l_warn "font package not installed - some games show blank text/crash (Install Firmware > PSP2UPDAT.PUP font package)"
    add_warn "Vita: install the firmware FONT package (PSP2UPDAT.PUP) in Vita3K"
  fi
}

# --------------------------------------------------------------------------
check_xbox() {
  local toml="" have=0
  toml=$(first_existing "$HOME/.var/app/app.xemu.xemu/data/xemu/xemu/xemu.toml" "$HOME/.local/share/xemu/xemu/xemu.toml" "$XDGC/xemu/xemu.toml")
  if [[ $CTX == RetroDECK ]] || fp_installed app.xemu.xemu || appimage 'xemu*.AppImage' >/dev/null || [[ -n $toml ]] ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  ((have)) || return
  hdr "Microsoft Xbox - xemu  $(rom_note xbox)"; CUR_KEY=xbox
  local boot="" flash="" hdd="" eep=""
  if [[ -n $toml ]]; then
    l_sub "config: $(short "$toml")"
    boot=$(ini_get "$toml" bootrom_path); flash=$(ini_get "$toml" flashrom_path)
    hdd=$(ini_get "$toml" hdd_path); eep=$(ini_get "$toml" eeprom_path)
  fi
  boot=$(expand_path "${boot:-$BIOS/mcpx_1.0.bin}")
  if [[ -z $flash ]]; then flash=$(first_existing "$BIOS/Complex_4627v1.03.bin" "$BIOS/Complex_4627.bin" "$BIOS/Complex.bin"); flash=${flash:-$BIOS/Complex_4627v1.03.bin}; fi
  flash=$(expand_path "$flash")
  hdd=$(expand_path "${hdd:-$(first_existing "$STORAGE/xemu/xbox_hdd.qcow2" "$BIOS/xbox_hdd.qcow2")}")
  local rp; rp=$(rp_flag xbox)
  report "MCPX boot ROM" "$boot" "d49c52a4102f6df7bcf8d0617ac475ed" REQ "$rp" "Xbox" "must be MCPX 1.0 (512 bytes)"
  report "Flash ROM (BIOS)" "$flash" "" REQ "$rp" "Xbox" "Complex 4627 recommended"
  if [[ $P_STATE =~ ^(NOHASH)$ ]]; then
    local s; s=$(fsize "$flash")
    [[ $s == 1048576 || $s == 262144 ]] || { l_warn "flash ROM size is $s bytes - expected 262144 or 1048576"; add_warn "Xbox: flash ROM $(short "$flash") has an odd size ($s)"; }
  fi
  if [[ -n $hdd && -f $hdd ]]; then
    if [[ $(head -c 4 "$hdd" | od -An -tx1 | tr -d ' \n') == 514649fb ]]; then l_ok "HDD image ${C_D}$(short "$hdd") (qcow2, $(human "$(fsize "$hdd")"))${C_0}"; ((CNT_OK++))
    else l_warn "HDD image $(short "$hdd") is not a qcow2 file"; add_warn "Xbox: HDD image is not qcow2"; fi
  else
    if [[ $rp == 1 ]]; then l_bad "HDD image missing (${hdd:-not configured})"; add_need "Xbox (xemu): xbox_hdd.qcow2 (the prebuilt image from xemu.app) -> $(short "${hdd:-$STORAGE/xemu/xbox_hdd.qcow2}")"
    else l_warn "HDD image missing (needed once you add Xbox games)"; fi
  fi
  [[ -n $eep && -f $(expand_path "$eep") ]] && l_ok "EEPROM ${C_D}$(short "$(expand_path "$eep")")${C_0}" || l_info "EEPROM not present - xemu generates one automatically"
}

# --------------------------------------------------------------------------
switch_keys() {   # $1 label $2 keys file -> prints, returns 0 if usable; sets SW_GEN
  local f=$1 maxg=-1 hdr=0 bad=0 line k n
  SW_GEN=-1
  [[ -f $f ]] || return 1
  while IFS= read -r line; do
    line=${line%$'\r'}; [[ -z $line || $line == \;* || $line == \#* ]] && continue
    if [[ $line =~ ^[[:space:]]*([a-z0-9_]+)[[:space:]]*=[[:space:]]*([0-9a-fA-F]+)[[:space:]]*$ ]]; then
      k=${BASH_REMATCH[1]}
      [[ $k == header_key && ${#BASH_REMATCH[2]} == 64 ]] && hdr=1
      if [[ $k =~ ^(master_key|key_area_key_application|titlekek)_([0-9a-f]{2})$ ]]; then
        n=$((16#${BASH_REMATCH[2]})); ((n>maxg)) && maxg=$n
      fi
    else ((bad++)); fi
  done <"$f"
  SW_GEN=$maxg
  ((bad)) && l_warn "$bad malformed line(s) in $(short "$f")"
  ((hdr)) || { l_bad "prod.keys has no valid header_key - not a real prod.keys"; return 1; }
  ((maxg<0)) && { l_bad "prod.keys has no master/application keys"; return 1; }
  return 0
}
sw_fw_for_gen() {
  local -a m=(1.0.0 3.0.0 3.0.1 4.0.0 5.0.0 6.0.0 6.2.0 7.0.0 8.1.0 9.0.0 9.1.0 12.1.0 13.0.0 14.0.0 15.0.0 16.0.0 17.0.0 18.0.0 19.0.0 20.0.0)
  if (($1 < ${#m[@]})); then printf '%s' "${m[$1]}"; else printf 'newer than 20.x'; fi
}
check_switch_emu() {   # name keysdir fwdir layout(yuzu|ryujinx) biosLink
  local name=$1 kdir=$2 fwdir=$3 layout=$4 link=${5:-} rp
  rp=$(rp_flag switch)
  subnow "$name$( ((NOTINST)) && echo ' (not installed)')" "keys: $(short "$kdir")  firmware: $(short "$fwdir")"
  # EmuDeck links bios/<emu>/keys -> emulator folder. A real folder there is a classic mistake.
  if [[ -n $link ]]; then
    local lk; for lk in "$link/keys" "$link/firmware"; do
      if [[ -e $lk && ! -L $lk ]] && [[ -n "$(ls -A "$lk" 2>/dev/null)" ]]; then
        l_warn "$(short "$lk") is a plain folder, not EmuDeck's link - $name does not read it"
        l_fix "copy its contents to $(short "$( [[ $lk == */keys ]] && echo "$kdir" || echo "$fwdir")")"
        add_warn "$name: files in $(short "$lk") are not seen by the emulator (folder should be a symlink)"
      fi
    done
  fi
  local keys="$kdir/prod.keys" ok_keys=0 ok_fw=0
  if [[ -f $keys ]]; then
    if switch_keys "$keys"; then
      ok_keys=1; ((CNT_OK++))
      l_ok "prod.keys ${C_D}(key generation $SW_GEN -> supports firmware up to $(sw_fw_for_gen "$SW_GEN"))${C_0}"
    fi
  else
    local alt; alt=$(find -L "$kdir" -maxdepth 1 -type f \( -iname 'prod*.keys*' -o -iname 'keys.txt' -o -iname 'prod.key' \) -print -quit 2>/dev/null)
    if [[ -n $alt ]]; then l_warn "prod.keys not found, but $(short "$alt") is there - must be named exactly prod.keys"; l_fix "mv -n $(q "$alt") $(q "$keys")"; add_fix "mv -n $(q "$alt") $(q "$keys")"; fi
    if [[ $rp == 1 ]]; then l_bad "prod.keys MISSING"; add_need "Switch ($name): prod.keys -> $(short "$kdir")/"; else l_warn "prod.keys missing (needed once you add Switch games)"; fi
  fi
  [[ -f $kdir/title.keys ]] && l_ok "title.keys ${C_D}(optional)${C_0}" || { ((OPT_VERBOSE)) && l_opt "title.keys (optional)"; }
  # firmware
  local n=0 loose=0 nested=0 zips=0
  if [[ -d $fwdir ]]; then
    if [[ $layout == ryujinx ]]; then
      n=$(find -L "$fwdir" -mindepth 1 -maxdepth 1 -type d -name '*.nca' 2>/dev/null | wc -l)
      loose=$(find -L "$fwdir" -mindepth 1 -maxdepth 1 -type f -name '*.nca' 2>/dev/null | wc -l)
    else
      n=$(find -L "$fwdir" -mindepth 1 -maxdepth 1 -type f -name '*.nca' 2>/dev/null | wc -l)
      nested=$(find -L "$fwdir" -mindepth 2 -maxdepth 3 -type f -name '*.nca' 2>/dev/null | wc -l)
    fi
    zips=$(find -L "$fwdir" -maxdepth 2 -type f \( -iname '*.zip' -o -iname '*.7z' \) 2>/dev/null | wc -l)
  fi
  if ((n >= 100)); then
    l_ok "firmware installed ${C_D}($n NCAs)${C_0}"; ok_fw=1; ((CNT_OK++))
  elif ((n > 0)); then
    l_warn "only $n firmware NCAs - a full firmware has well over 100; looks incomplete"; add_warn "Switch ($name): firmware looks incomplete ($n NCAs)"; ok_fw=1
  else
    ((nested)) && { l_warn "$nested .nca files are inside a SUB-folder of $(short "$fwdir") - they must sit directly in it"; add_warn "Switch ($name): firmware NCAs are one folder too deep"; }
    ((loose)) && { l_warn "$loose loose .nca files in Ryujinx's folder - Ryujinx needs firmware installed via Tools > Install Firmware"; add_warn "Switch ($name): install firmware through Ryujinx's menu, don't copy NCAs"; }
    ((zips)) && { l_warn "firmware archive found in $(short "$fwdir") - extract it (yuzu forks) or use Install Firmware (Ryujinx)"; }
    if [[ $rp == 1 ]]; then l_bad "firmware NOT installed"; add_need "Switch ($name): firmware -> $( [[ $layout == ryujinx ]] && echo 'Ryujinx > Tools > Install Firmware' || echo "extract the NCA files into $(short "$fwdir")")"
    else l_warn "firmware not installed (needed once you add Switch games)"; fi
  fi
  ((ok_keys && ok_fw)) && mark_ok switch
  ((ok_keys && ok_fw)) && l_info "keys and firmware should come from the same firmware version (or keys newer than firmware)"
}
check_switch() {
  [[ $CTX == RetroDECK ]] && return   # RetroDECK ships no Switch emulator
  local any=0 e ap cfg nand
  for e in yuzu citron eden suyu sudachi; do
    ap=$(appimage "$e*.AppImage") || ap=""
    NOTINST=0
    [[ -n $ap || -d $HOME/.local/share/$e ]] || { ((OPT_ALL)) || continue; NOTINST=1; }
    ((any++)) || { local ni=$NOTINST; NOTINST=0; hdr "Nintendo Switch  $(rom_note switch)"; NOTINST=$ni; CUR_KEY=switch; }
    cfg="$HOME/.config/$e/qt-config.ini"
    nand=$(ini_get "$cfg" nand_directory 2>/dev/null); nand=$(expand_path "${nand:-}")
    [[ -z $nand || ! -d $nand ]] && nand="$HOME/.local/share/$e/nand"
    nand=${nand%/}
    local fw="$nand/system/Contents/registered"
    [[ -d $fw ]] || fw="$HOME/.local/share/$e/nand/system/Contents/registered"
    check_switch_emu "${e^}" "$HOME/.local/share/$e/keys" "$fw" yuzu "$BIOS/$e"
  done
  local rdir; rdir=$(first_existing "$HOME/.config/Ryujinx" "$HOME/.var/app/org.ryujinx.Ryujinx/config/Ryujinx")
  NOTINST=0
  [[ -n $rdir || -d $HOME/Applications/publish ]] || appimage 'ryujinx*.AppImage' >/dev/null || NOTINST=1
  if ((NOTINST==0 || OPT_ALL)); then
    ((any++)) || { local ni=$NOTINST; NOTINST=0; hdr "Nintendo Switch  $(rom_note switch)"; NOTINST=$ni; CUR_KEY=switch; }
    rdir=${rdir:-$HOME/.config/Ryujinx}
    check_switch_emu "Ryujinx" "$rdir/system" "$rdir/bis/system/Contents/registered" ryujinx "$BIOS/ryujinx"
  fi
}

# --------------------------------------------------------------------------
check_wiiu() {
  local have=0 f
  if [[ $CTX == RetroDECK ]] || appimage 'cemu*.AppImage' >/dev/null || fp_installed info.cemu.Cemu || [[ -d $HOME/.config/Cemu || -d $HOME/.local/share/Cemu ]] ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  ((have)) || return
  hdr "Nintendo Wii U - Cemu  $(rom_note wiiu)"; CUR_KEY=wiiu
  local enc; enc=$(find -L "$ROMS/wiiu" -maxdepth 2 -type f \( -iname '*.wud' -o -iname '*.wux' \) 2>/dev/null | head -n 50 | wc -l)
  local keys=""
  if [[ $CTX == RetroDECK ]]; then keys=$(first_existing "$BIOS/cemu/keys.txt" "$XDGC/Cemu/keys.txt")
  else keys=$(first_existing "$HOME/.config/Cemu/keys.txt" "$HOME/.local/share/Cemu/keys.txt" "$HOME/.var/app/info.cemu.Cemu/data/Cemu/keys.txt" "$ROMS/wiiu/keys.txt"); fi
  if [[ -n $keys ]]; then
    local good bad; good=$(grep -cE '^[[:space:]]*[0-9a-fA-F]{32}([[:space:]].*)?$' "$keys"); bad=$(grep -vE '^[[:space:]]*($|#|[0-9a-fA-F]{32}([[:space:]].*)?$)' "$keys" | wc -l)
    if ((good)); then l_ok "keys.txt ${C_D}$(short "$keys") ($good key lines)${C_0}"; ((CNT_OK++)); else l_warn "keys.txt at $(short "$keys") contains no valid 32-hex-digit keys"; add_warn "Wii U: keys.txt has no valid keys"; fi
    ((bad)) && l_warn "$bad malformed line(s) in keys.txt"
  else
    if ((enc)); then l_bad "keys.txt MISSING and you have $enc encrypted .wud/.wux dumps"; add_need "Wii U (Cemu): keys.txt with your disc keys -> $(short "$( [[ $CTX == RetroDECK ]] && echo "$BIOS/cemu" || echo "$HOME/.config/Cemu")")/keys.txt"
    else l_info "no keys.txt - only needed for encrypted .wud/.wux dumps (.wua / decrypted .rpx don't need it)"; fi
  fi
}

# --------------------------------------------------------------------------
check_3ds() {
  local have=0
  if [[ $CTX == RetroDECK ]] || appimage 'azahar*.AppImage' 'citra*.AppImage' >/dev/null || fp_installed io.github.azahar.Azahar || fp_installed org.azahar_emu.Azahar || [[ -d $HOME/.local/share/azahar-emu ]] ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  ((have)) || return
  hdr "Nintendo 3DS - Azahar  $(rom_note n3ds)"
  local k; k=$(first_existing "$HOME/.local/share/azahar-emu/sysdata/aes_keys.txt" "$BIOS/azahar/keys/aes_keys.txt" "$HOME/.var/app/io.github.azahar.Azahar/data/azahar-emu/sysdata/aes_keys.txt" "$SAVES/n3ds/azahar/sysdata/aes_keys.txt")
  if [[ -n $k ]]; then l_ok "aes_keys.txt ${C_D}$(short "$k")${C_0}"; ((CNT_OK++))
  else l_info "no aes_keys.txt - not needed for decrypted dumps (.3ds/.cci/.cxi decrypted, .cia installs). No BIOS required."; fi
}

# --------------------------------------------------------------------------
check_gc() {
  local have=0 base
  if [[ $CTX == RetroDECK ]] || fp_installed org.DolphinEmu.dolphin-emu ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  ((have)) || return
  hdr "Nintendo GameCube - Dolphin  $(rom_note gc)"
  l_info "No BIOS needed - Dolphin boots games with HLE. IPL.bin only adds the boot animation/menu."
  local -A rr
  if [[ $CTX == RetroDECK ]]; then base="$SAVES/gc/dolphin"; rr=([US]=US [EU]=EU [JP]=JP)
  else base="$HOME/.var/app/org.DolphinEmu.dolphin-emu/data/dolphin-emu/GC"; rr=([US]=USA [EU]=EUR [JP]=JAP); fi
  local r f m any=0
  for r in US EU JP; do
    f="$base/${rr[$r]}/IPL.bin"
    if [[ -f $f ]]; then
      m=$(md5_of "$f"); any=1
      if [[ ${K_TAG[$m]:-} == GC ]]; then
        if [[ ${K_REG[$m]} == "$r" || ($r == JP && ${K_REG[$m]} == US) ]]; then l_ok "$r IPL.bin ${C_D}${K_DESC[$m]}${C_0}"
        else l_warn "$r/IPL.bin is actually ${K_DESC[$m]} (${K_REG[$m]}) - wrong region folder"; add_warn "GameCube: $(short "$f") is a ${K_REG[$m]} IPL in the $r folder"; fi
      else l_warn "$r/IPL.bin hash not recognised ($m)"; fi
    else ((OPT_VERBOSE)) && l_opt "$r IPL.bin (optional) -> $(short "$f")"; fi
  done
  ((any)) || ((OPT_VERBOSE)) || l_opt "no IPL.bin files (optional)"
}

# --------------------------------------------------------------------------
check_nds_standalone() {
  local have=0 cfg
  cfg=$(first_existing "$HOME/.var/app/net.kuribo64.melonDS/config/melonDS/melonDS.toml" "$HOME/.var/app/net.kuribo64.melonDS/config/melonDS/melonDS.ini" \
        "$HOME/.config/melonDS/melonDS.toml" "$HOME/.config/melonDS/melonDS.ini" "$XDGC/melonDS/melonDS.toml" "$XDGC/melonDS/melonDS.ini")
  if [[ $CTX == RetroDECK ]] || fp_installed net.kuribo64.melonDS || [[ -n $cfg ]] ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  ((have)) || return
  hdr "Nintendo DS - melonDS  $(rom_note nds)"; CUR_KEY=nds
  local ext b7 b9 fw rp; rp=$(rp_flag nds)
  [[ -n $cfg ]] && l_sub "config: $(short "$cfg")"
  ext=$(ini_get "$cfg" ExternalBIOSEnable 2>/dev/null)
  b7=$(expand_path "$(ini_get "$cfg" BIOS7Path 2>/dev/null)"); b9=$(expand_path "$(ini_get "$cfg" BIOS9Path 2>/dev/null)"); fw=$(expand_path "$(ini_get "$cfg" FirmwarePath 2>/dev/null)")
  [[ -z $b7 ]] && b7="$BIOS/bios7.bin"; [[ -z $b9 ]] && b9="$BIOS/bios9.bin"; [[ -z $fw ]] && fw="$BIOS/firmware.bin"
  if [[ ${ext,,} == false || ${ext,,} == 0 ]]; then l_info "melonDS is set to its built-in FreeBIOS (ExternalBIOSEnable=false) - real BIOS not needed for DS mode"; fi
  report "bios7.bin" "$b7" "df692a80a5b1bc90728bc3dfc76cd948" REC "$rp" "NDS" "FreeBIOS works for most games; real BIOS = best compatibility"
  report "bios9.bin" "$b9" "a392174eb3e572fed6447e956bde4b25" REC "$rp" "NDS"
  report "firmware.bin" "$fw" "" REC "$rp" "NDS" "dump from your own DS; hash is unique per console"
  if [[ $P_STATE == NOHASH ]]; then local s; s=$(fsize "$fw"); [[ $s == 131072 || $s == 262144 || $s == 524288 ]] || { l_warn "firmware.bin size $s is unusual (expected 128/256/512 KiB)"; }; fi
  if ((OPT_VERBOSE)); then
    report "DSi ARM7 BIOS" "$BIOS/dsi_bios7.bin" "559dae4ea78eb9d67702c56c1d791e81" OPT - NDS
    report "DSi ARM9 BIOS" "$BIOS/dsi_bios9.bin" "87b665fce118f76251271c3732532777" OPT - NDS
    report "DSi firmware" "$BIOS/dsi_firmware.bin" "" OPT - NDS
    report "DSi NAND" "$BIOS/dsi_nand.bin" "" OPT - NDS
  fi
}

# --------------------------------------------------------------------------
check_flycast_standalone() {
  local have=0 d
  if fp_installed org.flycast.Flycast ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  ((have)) || return
  [[ $CTX == RetroDECK ]] && return
  d="$HOME/.var/app/org.flycast.Flycast/data/flycast"
  hdr "Sega Dreamcast / NAOMI / Atomiswave - Flycast (standalone)  $(rom_note dreamcast,naomi,naomi2,atomiswave)"
  l_info "Flycast data folder: $(short "$d")  ${C_D}(EmuDeck links it as bios/flycast/bios)${C_0}"
  CUR_KEY=dreamcast
  report "dc_boot.bin" "$d/dc_boot.bin" "e10c53c2f8b90bab96ead2d368858623,d407fcf70b56acb84b8c77c93b0e5327,93a9766f14159b403178ac77417c6b68" REC "$(rp_flag dreamcast)" "Dreamcast" "HLE BIOS works for most games"
  report "dc_flash.bin" "$d/dc_flash.bin" "0a93f7940c455905bea6e392dfde92a4" OPT - "Dreamcast"
  CUR_KEY=naomi;      report "naomi.zip" "$d/naomi.zip" "526eda1e2a7920c92c88178789d71d84" REQ "$(rp_flag naomi)" "NAOMI" && mark_ok naomi
  CUR_KEY=naomi2;     report "naomi2.zip" "$d/naomi2.zip" "c50072cbab75673e1b1a6b94355e6fa8" REQ "$(rp_flag naomi2)" "NAOMI 2" && mark_ok naomi2
  CUR_KEY=atomiswave; report "awbios.zip" "$d/awbios.zip" "85254fbe320ca82a768ec2c26bb08def" REQ "$(rp_flag atomiswave)" "Atomiswave" && mark_ok atomiswave
}

# --------------------------------------------------------------------------
check_n64dd() {
  local have=0 cfg
  cfg=$(first_existing "$HOME/.var/app/com.github.Rosalie241.RMG/config/RMG/mupen64plus.cfg")
  if fp_installed com.github.Rosalie241.RMG || [[ -n $cfg ]] ; then have=1; fi; ((have)) || { ((OPT_ALL)) && { have=1; NOTINST=1; }; }
  ((have)) || return
  local rp; rp=$(rp_flag n64dd)
  hdr "Nintendo 64DD - Rosalie's Mupen GUI  $(rom_note n64dd)"; CUR_KEY=n64dd
  local us jp dev
  us=$(expand_path "$(ini_get "$cfg" 64DD_AmericanIPL 2>/dev/null || true)"); jp=$(expand_path "$(ini_get "$cfg" 64DD_JapaneseIPL 2>/dev/null || true)")
  dev=$(expand_path "$(ini_get "$cfg" 64DD_DevelopmentIPL 2>/dev/null || true)")
  [[ -z $us ]] && us="$BIOS/64DD_IPL_US.n64"; [[ -z $jp ]] && jp="$BIOS/64DD_IPL_JP.n64"; [[ -z $dev ]] && dev="$BIOS/64DD_IPL_DEV.n64"
  [[ -n $cfg ]] && l_sub "config: $(short "$cfg")"
  report "64DD IPL (JP)" "$jp" "8d3d9f294b6e174bc7b1d2fd1c727530" REQ "$rp" "64DD" "almost every 64DD disk is Japanese"
  report "64DD IPL (US)" "$us" "" OPT - "64DD"
  report "64DD IPL (DEV)" "$dev" "" OPT - "64DD"
}

# --------------------------------------------------------------------------
zip_members() { # zip -> member names, one per line
  if command -v unzip >/dev/null 2>&1; then unzip -Z1 -- "$1" 2>/dev/null
  elif command -v bsdtar >/dev/null 2>&1; then bsdtar -tf "$1" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then python3 -I -c 'import sys,zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$1" 2>/dev/null
  else return 2; fi
}
zip_ok() {
  if command -v unzip >/dev/null 2>&1; then unzip -tqq -- "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then python3 -I -c 'import sys,zipfile; sys.exit(1 if zipfile.ZipFile(sys.argv[1]).testzip() else 0)' "$1" 2>/dev/null
  else return 0; fi
}
check_neogeo() {
  local rp; rp=$(rp_flag neogeo)
  local rpa; rpa=$(rp_flag arcade,fbneo,mame)
  [[ $rp == 1 || $rpa == 1 || $OPT_ALL == 1 || " ${RA_CORES[*]:-} " == *" fbneo_libretro "* ]] || return
  hdr "Arcade - Neo Geo BIOS (neogeo.zip)  $(rom_note neogeo,arcade,fbneo)"; CUR_KEY=neogeo
  local c found=() f
  for c in "$ROMS/neogeo" "$ROMS/arcade" "$ROMS/fbneo" "$ROMS/mame" "$BIOS" "$BIOS/mame" "$BIOS/mame/bios" "$BIOS/fbneo" "$RA_SYS/fbneo"; do
    [[ -f $c/neogeo.zip ]] && found+=("$c/neogeo.zip")
  done
  if ((${#found[@]}==0)); then
    if [[ $rp == 1 ]]; then l_bad "neogeo.zip not found anywhere"; add_need "Neo Geo: neogeo.zip -> $(short "$ROMS/neogeo")/ (next to the games; ES-DE launches from there)"
    else l_warn "neogeo.zip not found - every Neo Geo game (incl. ones in roms/arcade) needs it"; fi
    return
  fi
  for f in "${found[@]}"; do
    if ! zip_ok "$f"; then l_bad "$(short "$f") is corrupt (zip test failed)"; add_need "Neo Geo: $(short "$f") is corrupt"; continue; fi
    local mem; mem=$(zip_members "$f" | tr 'A-Z' 'a-z')
    local miss=() x
    for x in 000-lo.lo sfix.sfix sm1.sm1; do grep -qx "$x" <<<"$mem" || miss+=("$x"); done
    grep -qE '^(sp-s2\.sp1|sp-s\.sp1|sp-u2\.sp1|vs-bios\.rom|asia-s3\.rom|sp-e\.sp1|sp-j2\.sp1|sp1-u2|uni-bios.*\.rom|neo-epo\.bin|neo-po\.bin)$' <<<"$mem" || miss+=("a system BIOS (sp-s2.sp1 etc.)")
    if ((${#miss[@]})); then l_warn "$(short "$f") is missing: ${miss[*]} - outdated or partial set"; add_warn "Neo Geo: $(short "$f") incomplete (${miss[*]})"
    else l_ok "$(short "$f") ${C_D}(zip OK, $(grep -c . <<<"$mem") files)${C_0}"; ((CNT_OK++)); mark_ok neogeo; fi
  done
  if [[ $rp == 1 && ! -f $ROMS/neogeo/neogeo.zip ]]; then
    l_warn "you have games in roms/neogeo but no neogeo.zip next to them"
    l_fix "cp -n $(q "${found[0]}") $(q "$ROMS/neogeo/")"; add_fix "cp -n $(q "${found[0]}") $(q "$ROMS/neogeo/")"
  fi
}

# --------------------------------------------------------------------------
check_shadps4() {
  local ap; ap=$(appimage 'shadps4*.AppImage') || ap=""
  [[ -n $ap || -d $HOME/.local/share/shadPS4 ]] || { ((OPT_ALL)) || return; NOTINST=1; }
  [[ $CTX == RetroDECK ]] && return
  hdr "Sony PlayStation 4 - shadPS4  $(rom_note ps4)"
  local d="$HOME/.local/share/shadPS4/sys_modules" n
  n=$(find -L "$d" -maxdepth 1 -type f -iname '*.sprx' 2>/dev/null | wc -l)
  if ((n)); then l_ok "$n system modules in $(short "$d") ${C_D}(optional LLE modules)${C_0}"
  else l_info "no sys_modules - optional; a few games need LLE modules (libSceCesCs, libSceFont, libSceJson, libSceNgs2, libSceUlt...)"; fi
}

# --------------------------------------------------------------------------
# RetroArch
# --------------------------------------------------------------------------
RA_CORES=() RA_SYS="" RA_CFG=""
find_retroarch() {
  RA_CORES=(); RA_SYS=""; RA_CFG=""
  local cands=() d c
  if [[ $CTX == RetroDECK ]]; then
    cands=("$XDGC/retroarch")
  else
    cands=("$HOME/.var/app/org.libretro.RetroArch/config/retroarch" "$HOME/.config/retroarch" "$HOME/.local/share/Steam/steamapps/common/RetroArch")
  fi
  for d in "${cands[@]}"; do [[ -f $d/retroarch.cfg ]] && { RA_CFG="$d/retroarch.cfg"; break; }; done
  [[ -n $RA_CFG ]] || return 1
  local base; base=$(dirname "$RA_CFG")
  RA_SYS=$(ini_get "$RA_CFG" system_directory)
  case $RA_SYS in ""|default) RA_SYS="$base/system" ;; :/*) RA_SYS="$base/${RA_SYS#:/}" ;; esac
  RA_SYS=$(expand_path "$RA_SYS"); RA_SYS=${RA_SYS%/}
  local cdir; cdir=$(expand_path "$(ini_get "$RA_CFG" libretro_directory)")
  [[ $cdir == :/* ]] && cdir="$base/${cdir#:/}"
  local dirs=("$base/cores" "${cdir:-}" "$HOME/.local/share/flatpak/app/net.retrodeck.retrodeck/current/active/files/share/libretro/cores" \
              "/var/lib/flatpak/app/net.retrodeck.retrodeck/current/active/files/share/libretro/cores" \
              "/var/lib/flatpak/app/org.libretro.RetroArch/current/active/files/lib/retroarch/cores" "$base/../../data/retroarch/cores")
  local -A seen
  for d in "${dirs[@]}"; do
    [[ -n $d && -d $d ]] || continue
    for c in "$d"/*_libretro.so; do c=$(basename "$c" .so); [[ -z ${seen[$c]:-} ]] && { seen[$c]=1; RA_CORES+=("$c"); }; done
  done
  return 0
}

ra_rule() {   # core path rflag -> sets RR_RULE RR_ROMS RR_NOTE
  local core=$1 path=$2 rf=$3 line cre pre rule roms note
  RR_RULE="" RR_ROMS="" RR_NOTE=""
  while IFS='@' read -r cre pre rule roms note; do
    [[ -z $cre ]] && continue
    if [[ $core =~ $cre && $path =~ $pre ]]; then RR_RULE=$rule RR_ROMS=$roms RR_NOTE=$note; return; fi
  done <<<"$RA_RULES"
  [[ $rf == R ]] && RR_RULE=REQ || RR_RULE=OPT
}

check_retroarch() {
  find_retroarch || { ((OPT_ALL)) && { hdr "RetroArch"; l_info "RetroArch not found"; }; return; }
  hdr "RetroArch"
  l_info "config: $(short "$RA_CFG")"
  l_info "system/BIOS directory: $(short "$RA_SYS")"
  if [[ $(realpath -m "$RA_SYS") != "$(realpath -m "$BIOS")" ]]; then
    l_warn "RetroArch's system directory is NOT your $CTX BIOS folder - cores look in $(short "$RA_SYS")"
    add_warn "RetroArch system_directory ($(short "$RA_SYS")) differs from $(short "$BIOS")"
  fi
  local ncores=${#RA_CORES[@]}
  if ((ncores==0)) && ((OPT_ALL==0)); then l_warn "no cores found - nothing to check"; return; fi
  l_info "$ncores cores installed"
  local saveBIOS=$BIOS
  # rebuild index for RA_SYS if different
  if [[ $(realpath -m "$RA_SYS") != "$(realpath -m "$BIOS")" ]]; then build_index "$RA_SYS"; BIOS=$RA_SYS; fi

  local -A wanted; CORE_INST=0
  local c; for c in "${RA_CORES[@]}"; do wanted[$c]=1; done
  local core sysn path rf md5s desc lastcore="" any_out
  local -A grp_ok grp_seen grp_roms grp_note grp_sys grp_fix grp_names
  local cores_done=()
  while IFS='|' read -r core sysn path rf md5s desc; do
    [[ -z $core ]] && continue
    ((OPT_ALL)) || [[ -n ${wanted[$core]:-} ]] || continue
    ra_rule "$core" "$path" "$rf"
    if [[ $RR_RULE == SKIP ]]; then in_list "$core" "${cores_done[@]}" || cores_done+=("$core"); continue; fi
    if [[ $core != "$lastcore" ]]; then
      ra_flush_groups; ra_core_done
      lastcore=$core; cores_done+=("$core")
      CORE_INST=0; [[ -n ${wanted[$core]:-} ]] && CORE_INST=1
      sub "${core%_libretro}" "$sysn  $(rom_note "$RR_ROMS")"
    fi
    local rp; rp=$(rp_flag "$RR_ROMS"); ((CORE_INST)) || rp=0
    local label=$path rc
    CUR_KEY=${RR_ROMS%%,*}
    case $RR_RULE in
      ANY:*)
        local g="$core:${RR_RULE#ANY:}"
        grp_seen[$g]=1; grp_roms[$g]=$( ((CORE_INST)) && echo "$RR_ROMS"); grp_note[$g]=$RR_NOTE; grp_sys[$g]=$sysn; grp_names[$g]+="${grp_names[$g]:+, }$path"
        report "$label" "$RA_SYS/$path" "$md5s" ANY "$rp" "$sysn"; local rc=$?
        ((rc==0)) && grp_ok[$g]=1; ((rc==2)) && grp_fix[$g]=1 ;;
      REQ) report "$label" "$RA_SYS/$path" "$md5s" REQ "$rp" "$sysn (${core%_libretro})" "$RR_NOTE"; rc=$?
           if ((CORE_INST)) && [[ -n $RR_ROMS ]]; then CORE_HAS[$RR_ROMS]=1; ((rc)) && CORE_FAIL[$RR_ROMS]=1; fi ;;
      REC) report "$label" "$RA_SYS/$path" "$md5s" REC "$rp" "$sysn (${core%_libretro})" "$RR_NOTE" ;;
      *)   report "$label" "$RA_SYS/$path" "$md5s" OPT "$rp" "$sysn" "$RR_NOTE" ;;
    esac
  done <<<"$RA_TABLE"
  ra_flush_groups; ra_core_done
  # cores with no firmware at all
  local nofw=0; for c in "${RA_CORES[@]}"; do in_list "$c" "${cores_done[@]}" || ((nofw++)); done
  ((nofw)) && l_info "$nofw other installed cores need no BIOS"
  BIOS=$saveBIOS
}
ra_core_done() {   # a core is "ready" for a system when all its REQ files + groups for it are usable
  local k
  for k in "${!CORE_HAS[@]}"; do [[ -z ${CORE_FAIL[$k]:-} ]] && mark_ok "$k"; done
  CORE_HAS=(); CORE_FAIL=()
}
grp_label() { case ${1##*:} in psx) echo "PlayStation";; sat) echo "Saturn";; scd) echo "Sega CD";; 3do) echo "3DO";; loader|zoom) echo "Neo Geo CD";; font) echo "PC-98";; *) echo "${grp_sys[$1]}";; esac; }
ra_flush_groups() {
  local g rp
  for g in "${!grp_seen[@]}"; do
    rp=$(rp_flag "${grp_roms[$g]}")
    CUR_KEY=${grp_roms[$g]%%,*}
    if [[ -n ${grp_ok[$g]:-} ]]; then
      l_info "satisfied: ${grp_note[$g]:-one of the above}"
      [[ -n ${grp_roms[$g]} ]] && { CORE_HAS[${grp_roms[$g]}]=1; }
    elif [[ -n ${grp_fix[$g]:-} ]]; then
      l_warn "not usable until you apply the fix above - ${grp_note[$g]:-}"
      [[ -n ${grp_roms[$g]} ]] && { CORE_HAS[${grp_roms[$g]}]=1; CORE_FAIL[${grp_roms[$g]}]=1; }
      [[ $rp == 1 ]] && add_need "$(grp_label "$g") (${g%%:*}): apply the rename/copy fix for its BIOS (see fix commands)"
    elif [[ $rp == 1 ]]; then
      CORE_HAS[${grp_roms[$g]}]=1; CORE_FAIL[${grp_roms[$g]}]=1
      l_bad "MISSING - ${grp_note[$g]:-at least one is required} $(rom_note "${grp_roms[$g]}")"
      l_sub "any of: ${grp_names[$g]}"
      add_need "$(grp_label "$g") (${g%%:*}): ${grp_note[$g]:-one of: ${grp_names[$g]}} -> $(short "$RA_SYS")/"
    else
      l_opt "none present - ${grp_note[$g]:-one is required} - needed once you add games"
      ((OPT_VERBOSE)) || l_sub "any of: ${grp_names[$g]}"
    fi
  done
  grp_ok=(); grp_seen=(); grp_roms=(); grp_note=(); grp_sys=(); grp_fix=(); grp_names=()
}

# --------------------------------------------------------------------------
check_unknown() {
  ((OPT_UNKNOWN)) || return
  hdr "Files in the BIOS folder that match nothing known"
  local p m n=0
  for p in "${!F_MD5[@]}"; do
    m=${F_MD5[$p]}
    [[ -n ${K_DESC[$m]:-} ]] && continue
    grep -qF "$m" <<<"$RA_TABLE" && continue
    case ${p,,} in *.txt|*.md|*.json|*.xml|*.ini|*.cfg|*.dat|*.yml|*.zip|*.keys) continue ;; esac
    l_info "$(short "$p") ${C_D}($(human "$(fsize "$p")"), md5 $m)${C_0}"; ((n++))
  done
  ((n)) || l_ok "nothing unrecognised (zips, keys and text files are skipped)"
}

# ============================================================================
# MAIN
# ============================================================================
load_known
detect_contexts

printf '%s%sSteam Deck BIOS checker v%s%s\n' "$C_BOLD" "$C_M" "$VERSION" "$C_0"
if ((${#CONTEXTS[@]}==0)); then
  printf '%sNo EmuDeck or RetroDECK install found.%s Point me at a folder:  %s --bios ~/path/to/bios [--roms ~/path/to/roms]\n' "$C_R" "$C_0" "$0"
  exit 2
fi

for ctx in "${CONTEXTS[@]}"; do
  IFS='|' read -r CTX BIOS ROMS STORAGE SAVES XDGC <<<"$ctx"
  BIOS=${BIOS%/}; ROMS=${ROMS%/}; STORAGE=${STORAGE%/}; SAVES=${SAVES%/}
  printf '\n%s%s################  %s  ################%s\n' "$C_BOLD" "$C_M" "$CTX" "$C_0"
  printf '  BIOS:    %s\n  ROMs:    %s\n  storage: %s\n' "$BIOS" "${ROMS:-?}" "${STORAGE:-?}"
  [[ $CTX == EmuDeck ]] && printf '  %ssettings: %s%s\n' "$C_D" "${EMUDECK_SETTINGS:-}" "$C_0"
  [[ $CTX == EmuDeck && -n ${EMUDECK_NOTE:-} ]] && printf '  %s%s%s\n' "$C_Y" "$EMUDECK_NOTE" "$C_0"
  [[ -d $BIOS ]] || { printf '  %sBIOS folder missing!%s\n' "$C_R" "$C_0"; add_need "$CTX: BIOS folder $BIOS does not exist"; continue; }
  printf '  %sindexing and hashing BIOS files...%s' "$C_D" "$C_0"
  build_index "$BIOS"
  warm_romc
  printf '\r\033[K'
  find_retroarch >/dev/null 2>&1 || true
  NOTINST=0; check_hygiene
  NOTINST=0; check_psx
  NOTINST=0; check_ps2
  NOTINST=0; check_ps3
  NOTINST=0; check_vita
  NOTINST=0; check_xbox
  NOTINST=0; check_switch
  NOTINST=0; check_wiiu
  NOTINST=0; check_3ds
  NOTINST=0; check_gc
  NOTINST=0; check_nds_standalone
  NOTINST=0; check_flycast_standalone
  NOTINST=0; check_n64dd
  NOTINST=0; check_shadps4
  NOTINST=0; check_neogeo
  NOTINST=0; check_retroarch; NOTINST=0
  [[ $(realpath -m "${RA_SYS:-/nonexistent}") != "$(realpath -m "$BIOS")" ]] && build_index "$BIOS"
  check_unknown
  CUR_KEY=""
done
resolve_needs

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
hdr "SUMMARY"
printf '  %s%d OK%s   %s%d need%s   %s%d warnings%s   %d fix commands\n' "$C_G" "$CNT_OK" "$C_0" "$C_R" "$CNT_NEED" "$C_0" "$C_Y" "$CNT_WARN" "$C_0" "${#FIXES[@]}"
if ((${#NEEDS[@]})); then
  printf '\n  %s%sYOU NEED (blocking - you have games for these):%s\n' "$C_BOLD" "$C_R" "$C_0"
  printf '%s\n' "${NEEDS[@]}" | awk '!s[$0]++' | while IFS= read -r n; do printf '    %s%s%s %s\n' "$C_R" "$S_BAD" "$C_0" "$n"; done
fi
if ((${#WARNS[@]})); then
  printf '\n  %s%sSHOULD LOOK AT:%s\n' "$C_BOLD" "$C_Y" "$C_0"
  printf '%s\n' "${WARNS[@]}" | awk '!s[$0]++' | sed "s/^/    $S_WARN /"
fi
if ((${#FIXES[@]})); then
  printf '\n  %s%sSUGGESTED FIX COMMANDS%s %s(review before running)%s\n' "$C_BOLD" "$C_C" "$C_0" "$C_D" "$C_0"
  printf '    %s\n' "${FIXES[@]}"
  if [[ -n $OPT_FIXSCRIPT ]]; then
    {
      printf '#!/usr/bin/env bash\n# generated by deck-bios-check.sh v%s on %s\n# REVIEW EVERY LINE before running.  cp/mv use -n (never overwrite).\nset -e\n' "$VERSION" "$(date)"
      printf '%s\n' "${FIXES[@]}"
    } >"$OPT_FIXSCRIPT" && chmod +x "$OPT_FIXSCRIPT" && printf '\n  fix script written to %s\n' "$OPT_FIXSCRIPT"
  else
    printf '  %s(use --fix-script fixes.sh to save these to a file)%s\n' "$C_D" "$C_0"
  fi
fi
((${#NEEDS[@]}==0)) && printf '\n  %s%s Nothing blocking: every system you have games for has what it needs.%s\n' "$C_G" "$S_OK" "$C_0"
printf '\n'
((${#NEEDS[@]})) && exit 1
exit 0
