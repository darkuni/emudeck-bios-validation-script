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
#    --report            friendly HTML report, opened in your browser
#    --report-file FILE  write the HTML report to FILE (implies --report)
#    --no-open           with --report: write the file but don't open it
#    --install-shortcut  add a "BIOS Checker" icon (desktop + app menu)
#    --uninstall-shortcut  remove it again
#    --json FILE         machine-readable results
#    --no-color          plain output      --ascii   no unicode symbols
#    -h, --help
#
#  Exit code: 0 = nothing blocking, 1 = something you NEED is missing, 2 = error
# =============================================================================

VERSION="1.1.0"
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
OPT_JSON="" OPT_REPORT=0 OPT_REPORTFILE="" OPT_NOOPEN=0 OPT_INSTALL=""

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
    --json) OPT_JSON="${2:-}"; shift ;;
    --report) OPT_REPORT=1 ;;
    --report-file) OPT_REPORT=1; OPT_REPORTFILE="${2:-}"; shift ;;
    --no-open) OPT_NOOPEN=1 ;;
    --install-shortcut) OPT_INSTALL=install ;;
    --uninstall-shortcut) OPT_INSTALL=uninstall ;;
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

# ---------------------------------------------------------------------------
# Structured recording (for --json / --report). Every printed line becomes an
# event tied to its section (hdr) and sub-section (sub). report() fills R_* so
# the UI can phrase findings in plain language.
# ---------------------------------------------------------------------------
REC=0 SEC_ID=0 CUR_SUB="" CUR_SUBD="" JV=""
EVJ=() SECJ=() NEEDS_LOC=() WARNS_LOC=()
R_KIND="" R_FILE="" R_FOUND="" R_WANT="" R_WHAT="" R_NOTE=""
jv() {   # JSON-escape $1 into JV (no subshell)
  local s=$1
  s=${s//$'\e'\[+([0-9;])m/}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/\\t}
  s=${s//[$'\001'-$'\037']/}
  JV=$s
}
ev() {
  ((REC)) || return 0
  local o="{\"sec\":$SEC_ID"
  jv "$CUR_SUB";  o+=",\"sub\":\"$JV\""
  jv "$CUR_SUBD"; o+=",\"subd\":\"$JV\""
  o+=",\"lvl\":\"$1\",\"kind\":\"$R_KIND\""
  jv "$2";        o+=",\"text\":\"$JV\""
  jv "$R_FILE";   o+=",\"file\":\"$JV\""
  jv "$R_FOUND";  o+=",\"found\":\"$JV\""
  jv "$R_WANT";   o+=",\"want\":\"$JV\""
  jv "$R_WHAT";   o+=",\"what\":\"$JV\""
  jv "$R_NOTE";   o+=",\"note\":\"$JV\"}"
  EVJ+=("$o")
  R_KIND="" R_FILE="" R_FOUND="" R_WANT="" R_WHAT="" R_NOTE=""
}
hdr()   { CUR_SUB="" CUR_SUBD=""; ((SEC_ID++))
          if ((REC)); then local t=${1%%  \[*} n=""; [[ $1 == *"  ["* ]] && n="[${1#*  \[}"
            local o; jv "${CTX:-}"; o="{\"id\":$SEC_ID,\"ctx\":\"$JV\""; jv "$t"; o+=",\"title\":\"$JV\""; jv "$n"; o+=",\"games\":\"$JV\",\"notinst\":$NOTINST}"; SECJ+=("$o"); fi
          PENDING=""; printf '\n%s%s== %s ==%s%s\n' "$C_BOLD" "$C_B" "$1" "$C_0" "$( ((NOTINST)) && printf ' %s(not installed - shown because of --all)%s' "$C_D" "$C_0")"; }
PENDING=""
sub()   { CUR_SUB=$1 CUR_SUBD=${2:-}; PENDING=$(printf '\n  %s%s%s%s' "$C_BOLD" "$1" "$C_0" "${2:+ $C_D$2$C_0}"); }
subnow(){ sub "$@"; pflush; }
pflush(){ [[ -n $PENDING ]] && { printf '%s\n' "$PENDING"; PENDING=""; }; return 0; }
l_ok()  { pflush; ev ok "$1"; printf '    %s%s%s %s\n' "$C_G" "$S_OK" "$C_0" "$1"; }
l_bad() { pflush; ev bad "$1"; printf '    %s%s %s%s\n' "$C_R" "$S_BAD" "$1" "$C_0"; }
l_warn(){ pflush; ev warn "$1"; printf '    %s%s%s %s\n' "$C_Y" "$S_WARN" "$C_0" "$1"; }
l_info(){ pflush; ev info "$1"; printf '    %s%s %s%s\n' "$C_D" "$S_INFO" "$1" "$C_0"; }
l_opt() { pflush; ev opt "$1"; printf '    %s%s %s%s\n' "$C_D" "$S_OPT" "$1" "$C_0"; }
l_fix() { pflush; ev fix "$1"; printf '      %s%s %s%s\n' "$C_C" "$S_FIX" "$1" "$C_0"; }
l_sub() { pflush; ev sub "$1"; printf '      %s%s%s\n' "$C_D" "$1" "$C_0"; }

# Needs are recorded per system key (rom folder). If ANY emulator/core for that
# system turns out to be ready, the other emulators' gaps become warnings.
declare -A SAT PNEED CORE_HAS CORE_FAIL
CUR_KEY=""
NOTINST=0
add_need() {
  if ((NOTINST)); then add_warn "$1  (emulator not installed)"; return; fi
  local k=${2:-$CUR_KEY}; k=${k:-_}; PNEED[$k]+="$SEC_ID"$'\x1f'"$CUR_SUB"$'\x1f'"$1"$'\n'
}
mark_ok()  { local k; for k in ${1//,/ }; do SAT[$k]=1; done; }
resolve_needs() {
  local k line
  for k in "${!PNEED[@]}"; do
    local ls lu
    while IFS=$'\x1f' read -r ls lu line; do
      [[ -z $line ]] && continue
      if [[ $k != _ && -n ${SAT[${k%%,*}]:-} ]]; then add_warn "$line  (not blocking: another emulator for this system is ready)" "$ls" "$lu"
      else NEEDS+=("$line"); NEEDS_LOC+=("$ls"$'\x1f'"$lu"); ((CNT_NEED++)); fi
    done <<<"${PNEED[$k]}"
  done
  PNEED=()
}
add_warn() { WARNS+=("$1"); WARNS_LOC+=("${2:-$SEC_ID}"$'\x1f'"${3-$CUR_SUB}"); ((CNT_WARN++)); }
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
@@KNOWN@@
@@KNOWN_END@@
}

# ----------------------------------------------------------------------------
# Embedded data: libretro core firmware (core|system|path|R/O|md5s|description)
# generated from libretro-core-info + System.dat
# ----------------------------------------------------------------------------
RA_TABLE=$(cat <<'@@RA_END@@'
@@RACORES@@
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
  R_FILE=${want##*/} R_WANT=$disp R_NOTE=$note R_FOUND=""
  [[ -n $P_PATH ]] && R_FOUND=$(short "$P_PATH")
  case $P_STATE in
    OK)      R_KIND=ok R_WHAT=$(ident "$P_MD5"); l_ok "$label ${C_D}$(ident "$P_MD5")${C_0}"; ((CNT_OK++)); return 0 ;;
    NOHASH)  R_KIND=present; l_ok "$label ${C_D}present ($(human "$(fsize "$want")"), no reference hash to verify)${C_0}"; ((CNT_OK++)); return 0 ;;
    BADHASH)
      local what; what=$(ident "$P_MD5")
      if [[ $want == *.zip ]]; then
        R_KIND=zipok; l_ok "$label ${C_D}present (zip hash differs from reference - normal between MAME/FBNeo versions)${C_0}"; ((CNT_OK++)); return 0
      fi
      local exp_tag="" got_tag=${K_TAG[$P_MD5]:-} hh
      for hh in ${hs//,/ }; do exp_tag=${K_TAG[$hh]:-}; [[ -n $exp_tag ]] && break; done
      if [[ -n $got_tag && $got_tag != "$exp_tag" ]]; then
        R_KIND=wrongfile R_WHAT=$what; l_bad "$label is the WRONG file - it is actually: ${C_BOLD}$what${C_0}"
        if [[ $imp == REQ && $rp == 1 ]]; then add_need "$sys: $disp is really '$what' - replace it with the correct dump"
        elif [[ $imp != OPT && $imp != ANY ]]; then add_warn "$sys: $disp is really '$what'"; fi
        return 1
      fi
      R_KIND=badhash R_WHAT=$what; l_warn "$label ${C_Y}hash mismatch${C_0} - this file is: ${C_BOLD}$what${C_0} ${C_D}(md5 $P_MD5)${C_0}"
      add_warn "$sys: $disp has an unexpected hash ($what) - may be a bad/alternate dump"
      return 0 ;;
    CASE)
      R_KIND=case; l_warn "$label ${C_Y}wrong filename case${C_0}: found $(short "$P_PATH") - Linux is case-sensitive"
      l_fix "mv -n $(q "$P_PATH") $(q "$want")"; add_fix "mv -n $(q "$P_PATH") $(q "$want")"
      add_warn "$sys: rename $(short "$P_PATH") -> $(basename "$want") (case)"
      [[ $imp == OPT ]] && return 1
      return 2 ;;
    ELSEWHERE)
      R_KIND=elsewhere; l_warn "$label ${C_Y}not at $disp${C_0}, but the right file is here: $(short "$P_PATH")"
      local cmd="cp -n $(q "$P_PATH") $(q "$want")"
      [[ -d $(dirname "$want") ]] || cmd="mkdir -p $(q "$(dirname "$want")") && $cmd"
      l_fix "$cmd"; add_fix "$cmd"
      add_warn "$sys: copy $(short "$P_PATH") -> $disp"
      return 2 ;;
    EMPTY)   R_KIND=empty; l_bad "$label is a 0-byte file ($disp)"; add_warn "$sys: $disp is empty"; return 1 ;;
    BROKEN)  R_KIND=broken; l_bad "$label is a broken symlink ($disp -> $(readlink "$want"))"; add_warn "$sys: broken symlink $disp"; return 1 ;;
    MISSING)
      case $imp in
        OPT) if ((OPT_VERBOSE || REC)); then R_KIND=missing_opt; ev opt "$label - optional, not present${note:+ ($note)}"; ((OPT_VERBOSE)) && { pflush; printf '    %s%s %s%s\n' "$C_D" "$S_OPT" "$label - optional, not present${note:+ ($note)}" "$C_0"; }; fi; R_KIND=""; return 1 ;;
        ANY) ((OPT_VERBOSE)) && l_opt "$label - not present"; R_KIND=""; return 1 ;;
        REC) if [[ $rp == 0 ]]; then R_KIND=missing_later; l_opt "$label - recommended once you add games ($disp)${note:+ - $note}"
             else R_KIND=missing_rec; l_warn "$label - ${C_Y}recommended, missing${C_0} ($disp)${note:+ - $note}"
                  add_warn "$sys: recommended $(basename "$want") missing${note:+ ($note)}"; fi
             return 1 ;;
        REQ) if [[ $rp == 1 ]]; then
               R_KIND=missing_req; l_bad "$label - MISSING, needed ($disp)${note:+ - $note}"; add_need "$sys: $(basename "$want") -> $disp${note:+ ($note)}"
             else
               R_KIND=missing_later; l_opt "$label - missing ($disp) - needed once you add games${note:+ - $note}"
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
      R_KIND=bios_found R_FILE=${f##*/} R_WHAT=${K_DESC[$m]} R_NOTE=$r; l_ok "$(basename "$f") ${C_D}${K_DESC[$m]} [$r]${C_0}"; ((CNT_OK++))
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
      R_KIND=group_ok R_NOTE=${grp_note[$g]:-} R_FILE=${grp_names[$g]}; l_info "satisfied: ${grp_note[$g]:-one of the above}"
      [[ -n ${grp_roms[$g]} ]] && { CORE_HAS[${grp_roms[$g]}]=1; }
    elif [[ -n ${grp_fix[$g]:-} ]]; then
      R_KIND=group_fix R_NOTE=${grp_note[$g]:-} R_FILE=${grp_names[$g]}; l_warn "not usable until you apply the fix above - ${grp_note[$g]:-}"
      [[ -n ${grp_roms[$g]} ]] && { CORE_HAS[${grp_roms[$g]}]=1; CORE_FAIL[${grp_roms[$g]}]=1; }
      [[ $rp == 1 ]] && add_need "$(grp_label "$g") (${g%%:*}): apply the rename/copy fix for its BIOS (see fix commands)"
    elif [[ $rp == 1 ]]; then
      CORE_HAS[${grp_roms[$g]}]=1; CORE_FAIL[${grp_roms[$g]}]=1
      R_KIND=group_missing R_NOTE=${grp_note[$g]:-} R_FILE=${grp_names[$g]}; l_bad "MISSING - ${grp_note[$g]:-at least one is required} $(rom_note "${grp_roms[$g]}")"
      l_sub "any of: ${grp_names[$g]}"
      add_need "$(grp_label "$g") (${g%%:*}): ${grp_note[$g]:-one of: ${grp_names[$g]}} -> $(short "$RA_SYS")/"
    else
      R_KIND=group_later R_NOTE=${grp_note[$g]:-} R_FILE=${grp_names[$g]}; l_opt "none present - ${grp_note[$g]:-one is required} - needed once you add games"
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
# JSON / HTML report / desktop shortcut
# ============================================================================
CTXJ=()
jarr() { local IFS=,; printf '%s' "$*"; }
jstrs() { local out=() x; for x; do jv "$x"; out+=("\"$JV\""); done; jarr "${out[@]}"; }
jlocs() {   # name-of-text-array name-of-loc-array
  local -n _t=$1 _l=$2; local out=() i sec sb
  for i in "${!_t[@]}"; do
    IFS=$'\x1f' read -r sec sb <<<"${_l[$i]:-0}"
    jv "${_t[$i]}"; local tx=$JV; jv "$sb"
    out+=("{\"text\":\"$tx\",\"sec\":${sec:-0},\"sub\":\"$JV\"}")
  done
  jarr "${out[@]}"
}
build_json() {
  local o
  jv "$VERSION"; o="{\"tool\":\"deck-bios-check\",\"version\":\"$JV\""
  jv "$(date '+%Y-%m-%d %H:%M')"; o+=",\"generated\":\"$JV\""
  o+=",\"counts\":{\"ok\":$CNT_OK,\"need\":$CNT_NEED,\"warn\":$CNT_WARN,\"fix\":${#FIXES[@]}}"
  o+=",\"all\":$OPT_ALL,\"contexts\":[$(jarr "${CTXJ[@]}")]"
  o+=",\"sections\":[$(jarr "${SECJ[@]}")]"
  o+=",\"events\":[$(jarr "${EVJ[@]}")]"
  o+=",\"needs\":[$(jlocs NEEDS NEEDS_LOC)]"
  o+=",\"warns\":[$(jlocs WARNS WARNS_LOC)]"
  o+=",\"fixes\":[$(jstrs "${FIXES[@]}")]}"
  JSON_OUT=$o
}
REPORT_TPL=$(cat <<'@@REPORT_END@@'
@@REPORT_HTML@@
@@REPORT_END@@
)
write_report() {   # $1 = output file
  local data=${JSON_OUT//<\//<\\/}
  local pre=${REPORT_TPL%%@@DATA@@*} post=${REPORT_TPL#*@@DATA@@}
  mkdir -p "$(dirname "$1")" && printf '%s%s%s\n' "$pre" "$data" "$post" >"$1"
}
open_file() {
  local opener
  for opener in xdg-open kde-open5 kde-open gio; do
    if command -v "$opener" >/dev/null 2>&1; then
      if [[ $opener == gio ]]; then nohup gio open "$1" >/dev/null 2>&1 &
      else nohup "$opener" "$1" >/dev/null 2>&1 & fi
      return 0
    fi
  done
  return 1
}
notify() {
  if command -v kdialog >/dev/null 2>&1; then kdialog --title "BIOS Checker" --passivepopup "$1" 4 >/dev/null 2>&1 &
  elif command -v notify-send >/dev/null 2>&1; then notify-send "BIOS Checker" "$1" >/dev/null 2>&1 &
  fi
}
shortcut() {   # install | uninstall
  local dir="$HOME/.local/share/deck-bios-check" app="$HOME/.local/share/applications/deck-bios-checker.desktop" desk f
  desk=$(xdg-user-dir DESKTOP 2>/dev/null); [[ -z $desk || $desk == "$HOME" ]] && desk="$HOME/Desktop"
  if [[ $1 == uninstall ]]; then
    rm -f "$app" "$desk/deck-bios-checker.desktop"; rm -rf "$dir"
    echo "BIOS Checker shortcut removed."; return 0
  fi
  mkdir -p "$dir" "$(dirname "$app")"
  local self; self=$(realpath -- "$0")
  [[ $self != "$dir/deck-bios-check.sh" ]] && cp -f -- "$self" "$dir/deck-bios-check.sh"
  chmod +x "$dir/deck-bios-check.sh"
  cat >"$app" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=BIOS Checker
GenericName=Emulator BIOS checker
Comment=Checks your emulator BIOS, firmware and keys and explains what is missing
Exec=bash "$dir/deck-bios-check.sh" --report
Icon=system-search
Terminal=false
Categories=Game;Utility;
DESKTOP
  chmod +x "$app"
  if [[ -d $desk ]]; then
    f="$desk/deck-bios-checker.desktop"; cp -f "$app" "$f"; chmod +x "$f"
    command -v gio >/dev/null 2>&1 && gio set "$f" metadata::trusted true >/dev/null 2>&1
  fi
  echo "Installed:"
  echo "  app menu:  BIOS Checker  ($app)"
  [[ -d $desk ]] && echo "  desktop:   $desk/deck-bios-checker.desktop"
  echo "  script:    $dir/deck-bios-check.sh"
  echo "Double-click 'BIOS Checker' to get the friendly report. Remove with --uninstall-shortcut."
}

# ============================================================================
# MAIN
# ============================================================================
if [[ -n $OPT_INSTALL ]]; then shortcut "$OPT_INSTALL"; exit $?; fi
[[ -n $OPT_JSON || $OPT_REPORT == 1 ]] && REC=1
((OPT_REPORT)) && notify "Checking your BIOS files..."
load_known
detect_contexts

printf '%s%sSteam Deck BIOS checker v%s%s\n' "$C_BOLD" "$C_M" "$VERSION" "$C_0"
if ((${#CONTEXTS[@]}==0)); then
  ((OPT_REPORT)) && notify "No EmuDeck or RetroDECK install found."
  printf '%sNo EmuDeck or RetroDECK install found.%s Point me at a folder:  %s --bios ~/path/to/bios [--roms ~/path/to/roms]\n' "$C_R" "$C_0" "$0"
  exit 2
fi

for ctx in "${CONTEXTS[@]}"; do
  IFS='|' read -r CTX BIOS ROMS STORAGE SAVES XDGC <<<"$ctx"
  BIOS=${BIOS%/}; ROMS=${ROMS%/}; STORAGE=${STORAGE%/}; SAVES=${SAVES%/}
  printf '\n%s%s################  %s  ################%s\n' "$C_BOLD" "$C_M" "$CTX" "$C_0"
  if ((REC)); then
    _c=""; jv "$CTX"; _c="{\"name\":\"$JV\""; jv "$BIOS"; _c+=",\"bios\":\"$JV\""; jv "$ROMS"; _c+=",\"roms\":\"$JV\""
    jv "$( [[ $CTX == EmuDeck ]] && echo "${EMUDECK_SETTINGS:-}")"; _c+=",\"settings\":\"$JV\""
    jv "$( [[ $CTX == EmuDeck ]] && echo "${EMUDECK_NOTE:-}")"; _c+=",\"note\":\"$JV\"}"; CTXJ+=("$_c")
  fi
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
if ((REC)); then
  build_json
  if [[ -n $OPT_JSON ]]; then printf '%s\n' "$JSON_OUT" >"$OPT_JSON" && printf '  JSON written to %s\n' "$OPT_JSON"; fi
  if ((OPT_REPORT)); then
    rf=${OPT_REPORTFILE:-${XDG_CACHE_HOME:-$HOME/.cache}/deck-bios-check/report.html}
    if write_report "$rf"; then
      printf '  %sReport: %s%s\n' "$C_BOLD" "$rf" "$C_0"
      if ((OPT_NOOPEN==0)); then open_file "$rf" || printf '  (could not open a browser - open the file above yourself)\n'; fi
    fi
  fi
fi
((${#NEEDS[@]})) && exit 1
exit 0
