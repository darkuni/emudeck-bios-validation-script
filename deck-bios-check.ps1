<#
=============================================================================
 deck-bios-check.ps1  -  BIOS / firmware / keys checker for Windows
=============================================================================
 The Windows twin of deck-bios-check.sh. Works with EmuDeck for Windows,
 a plain RetroArch install, or any folder you point it at (-Bios).
 Runs on the PowerShell built into Windows (5.1) and on PowerShell 7.

 Read-only. It never changes your files; fixes are printed as commands.

 Usage (from PowerShell):
   powershell -ExecutionPolicy Bypass -File .\deck-bios-check.ps1 [options]

   -Report              friendly HTML report, opened in your browser
   -ReportFile FILE     write the HTML report to FILE (implies -Report)
   -NoOpen              with -Report: write the file but don't open it
   -InstallShortcut     add a "BIOS Checker" icon (desktop + Start menu)
   -UninstallShortcut   remove it again
   -Bios DIR            check this BIOS folder (skips EmuDeck detection)
   -Roms DIR            ROM root used to decide what you NEED (with -Bios)
   -All                 also show emulators/cores you don't have installed
   -ShowOptional        also list optional files
   -Unknown             list files in the BIOS folder that match nothing known
   -FixScript FILE      write the suggested fix commands to FILE (never run)
   -Json FILE           machine-readable results
   -MaxHashMB N         skip hashing files bigger than N MiB (default 64)
   -NoColor             plain output
   -Help

 Exit code: 0 = nothing blocking, 1 = something you NEED is missing, 2 = error
=============================================================================
#>
param(
  [string]$Bios = '',
  [string]$Roms = '',
  [switch]$All,
  [switch]$ShowOptional,
  [switch]$Unknown,
  [string]$FixScript = '',
  [string]$Json = '',
  [int]$MaxHashMB = 64,
  [switch]$NoColor,
  [switch]$Report,
  [string]$ReportFile = '',
  [switch]$NoOpen,
  [switch]$InstallShortcut,
  [switch]$UninstallShortcut,
  [switch]$Help
)

$VERSION = '1.2.0'
$script:SELF_SB = $MyInvocation.MyCommand.ScriptBlock
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

if ($Help) {
  Write-Host 'deck-bios-check.ps1 - emulator BIOS / firmware / keys checker'
  Write-Host ''
  Write-Host '  -Report              friendly HTML report, opened in your browser'
  Write-Host '  -ReportFile FILE     write the HTML report to FILE (implies -Report)'
  Write-Host '  -NoOpen              with -Report: write the file but do not open it'
  Write-Host '  -InstallShortcut     add a "BIOS Checker" icon (desktop + Start menu)'
  Write-Host '  -UninstallShortcut   remove it again'
  Write-Host '  -Bios DIR            check this BIOS folder (skips EmuDeck detection)'
  Write-Host '  -Roms DIR            ROM root used to decide what you NEED (with -Bios)'
  Write-Host '  -All                 also show emulators/cores you do not have installed'
  Write-Host '  -ShowOptional        also list optional files'
  Write-Host '  -Unknown             list files in the BIOS folder that match nothing known'
  Write-Host '  -FixScript FILE      write the suggested fix commands to FILE (never run)'
  Write-Host '  -Json FILE           machine-readable results'
  Write-Host '  -MaxHashMB N         skip hashing files bigger than N MiB (default 64)'
  Write-Host '  -NoColor             plain output'
  Write-Host ''
  Write-Host 'Exit code: 0 = nothing blocking, 1 = something you NEED is missing, 2 = error'
  return
}
if ($ReportFile) { $Report = [switch]$true }

# ----------------------------------------------------------------------------
# Environment
# ----------------------------------------------------------------------------
$IsWin = ($env:OS -eq 'Windows_NT')
$SEP = [IO.Path]::DirectorySeparatorChar
$UP  = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$AD  = if ($env:APPDATA) { $env:APPDATA } else { [IO.Path]::Combine($UP, 'AppData', 'Roaming') }
$LAD = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::Combine($UP, 'AppData', 'Local') }
$DOCS = @([IO.Path]::Combine($UP, 'Documents'))
try { $md = [Environment]::GetFolderPath('MyDocuments'); if ($md -and $DOCS -notcontains $md -and $env:DECKBIOS_TEST -ne '1') { $DOCS += $md } } catch {}

function JP {   # join path parts, normalising / and \ to this OS's separator
  $r = ''
  foreach ($a in $args) {
    if ($null -eq $a -or "$a" -eq '') { continue }
    $raw = "$a"; $unc = ($r -eq '' -and $raw -match '^[\\/]{2}[^\\/]')
    $s = ($raw -replace '[\\/]+', [string]$SEP)
    if ($unc) { $s = [string]$SEP + $s }
    if ($r -eq '') { $r = $s } else { $r = [IO.Path]::Combine($r, $s.TrimStart($SEP)) }
  }
  return $r
}
function FirstExisting { foreach ($p in $args) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }; return $null }
function IsDir($p)  { return ($p -and [IO.Directory]::Exists($p)) }
function IsFile($p) { return ($p -and [IO.File]::Exists($p)) }
function FSize($p)  { try { return (New-Object IO.FileInfo $p).Length } catch { return 0 } }
function Human($b)  { if ($b -ge 1MB) { return ('{0} MiB' -f [math]::Floor($b / 1MB)) } elseif ($b -ge 1KB) { return ('{0} KiB' -f [math]::Floor($b / 1KB)) } else { return "$b B" } }
function Q($s)      { return "'" + ([string]$s).Replace("'", "''") + "'" }   # PowerShell single-quote
function IsCloud($fi) { $a = [int]$fi.Attributes; return (($a -band 0x400000) -ne 0) -or (($a -band 0x40000) -ne 0) -or (($a -band 0x1000) -ne 0) }

function IniGet($file, $key) {   # first "key=value" (any section), quotes stripped
  if (-not (IsFile $file)) { return '' }
  foreach ($l in [IO.File]::ReadAllLines($file)) {
    if ($l -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(.*?)\s*$')) {
      $v = $Matches[1]; $v = $v.Trim('"').Trim("'")
      return $v
    }
  }
  return ''
}
function YmlGet($file, $key) {
  if (-not (IsFile $file)) { return '' }
  foreach ($l in [IO.File]::ReadAllLines($file)) {
    if ($l -match ('^\s*' + [regex]::Escape($key) + ':\s*(.*?)\s*$')) { return $Matches[1].Trim('"').Trim("'") }
  }
  return ''
}
function PsVar($file, $name, $emuPath) {   # read "$name = value" from EmuDeck's settings.ps1 without running it
  if (-not (IsFile $file)) { return '' }
  foreach ($l in [IO.File]::ReadAllLines($file)) {
    if ($l -match ('^\s*\$' + [regex]::Escape($name) + '\s*=\s*(.+?)\s*$')) {
      $v = $Matches[1] -replace '\s+#.*$', ''
      $v = $v.Replace('"', '').Replace("'", '')
      if ($emuPath) { $v = $v.Replace('${emulationPath}', $emuPath).Replace('$emulationPath', $emuPath) }
      $v = $v.Replace('$env:USERPROFILE', $UP).Replace('$env:APPDATA', $AD).Replace('$HOME', $UP)
      return $v.Trim()
    }
  }
  return ''
}
function Resolve-Rel($value, $base) {   # emulator config paths may be relative to the emulator folder
  if (-not $value) { return '' }
  $v = $value.Replace('\\', '\')
  if ([IO.Path]::IsPathRooted($v)) { return (JP $v) }
  return (JP $base $v)
}

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
$S_OK = '[ OK ]'; $S_BAD = '[NEED]'; $S_WARN = '[WARN]'; $S_INFO = '[info]'; $S_OPT = '[ -- ]'; $S_FIX = '  fix:'
$script:NEEDS = New-Object System.Collections.ArrayList
$script:WARNS = New-Object System.Collections.ArrayList
$script:FIXES = New-Object System.Collections.ArrayList
$script:PNEED = @{}; $script:SAT = @{}; $script:CORE_HAS = @{}; $script:CORE_FAIL = @{}
$script:CNT_OK = 0; $script:CUR_KEY = ''; $script:NOTINST = $false
$script:REC = $false; $script:SEC_ID = 0; $script:CUR_SUB = ''; $script:CUR_SUBD = ''; $script:PENDING = $null
$script:EV = New-Object System.Collections.ArrayList
$script:SECS = New-Object System.Collections.ArrayList
$script:CTXS = New-Object System.Collections.ArrayList
$script:R = @{}

function Out-Line($text, $color) {
  if ($NoColor -or -not $color) { Write-Host $text } else { Write-Host $text -ForegroundColor $color }
}
function Ev($lvl, $text) {
  if (-not $script:REC) { $script:R = @{}; return }
  $r = $script:R
  [void]$script:EV.Add([ordered]@{ sec = $script:SEC_ID; sub = $script:CUR_SUB; subd = $script:CUR_SUBD; lvl = $lvl; kind = [string]$r.kind
    text = [string]$text; file = [string]$r.file; found = [string]$r.found; want = [string]$r.want; what = [string]$r.what; note = [string]$r.note })
  $script:R = @{}
}
function Hdr($title, $games) {
  $script:SEC_ID++; $script:CUR_SUB = ''; $script:CUR_SUBD = ''; $script:PENDING = $null
  if ($script:REC) { [void]$script:SECS.Add([ordered]@{ id = $script:SEC_ID; ctx = $script:CTX; title = $title; games = [string]$games; notinst = [bool]$script:NOTINST }) }
  $t = "== $title =="; if ($games) { $t += "  $games" }; if ($script:NOTINST) { $t += '  (not installed - shown because of -All)' }
  Write-Host ''; Out-Line $t 'Cyan'
}
function Sub($title, $desc, [switch]$Now) { $script:CUR_SUB = $title; $script:CUR_SUBD = [string]$desc; $script:PENDING = "  $title  $desc"; if ($Now) { PFlush } }
function PFlush { if ($script:PENDING) { Write-Host ''; Out-Line $script:PENDING 'White'; $script:PENDING = $null } }
function L-Ok($t)   { PFlush; Ev 'ok' $t;   Out-Line "    $S_OK $t" 'Green' }
function L-Bad($t)  { PFlush; Ev 'bad' $t;  Out-Line "    $S_BAD $t" 'Red' }
function L-Warn($t) { PFlush; Ev 'warn' $t; Out-Line "    $S_WARN $t" 'Yellow' }
function L-Info($t) { PFlush; Ev 'info' $t; Out-Line "    $S_INFO $t" 'DarkGray' }
function L-Opt($t)  { PFlush; Ev 'opt' $t;  Out-Line "    $S_OPT $t" 'DarkGray' }
function L-Fix($t)  { PFlush; Ev 'fix' $t;  Out-Line "      $S_FIX $t" 'DarkCyan' }
function L-Sub($t)  { PFlush; Ev 'sub' $t;  Out-Line "           $t" 'DarkGray' }

function Add-Warn($t, $sec = $null, $sub = $null) {
  if ($null -eq $sec) { $sec = $script:SEC_ID }; if ($null -eq $sub) { $sub = $script:CUR_SUB }
  [void]$script:WARNS.Add([ordered]@{ text = $t; sec = $sec; sub = $sub })
}
function Add-Need($t, $key) {
  if ($script:NOTINST) { Add-Warn "$t  (emulator not installed)"; return }
  if (-not $key) { $key = $script:CUR_KEY }; if (-not $key) { $key = '_' }
  if (-not $script:PNEED.ContainsKey($key)) { $script:PNEED[$key] = New-Object System.Collections.ArrayList }
  [void]$script:PNEED[$key].Add([ordered]@{ text = $t; sec = $script:SEC_ID; sub = $script:CUR_SUB })
}
function Add-Fix($cmd) { if (-not $script:FIXES.Contains($cmd)) { [void]$script:FIXES.Add($cmd) } }
function Mark-Ok($keys) { foreach ($k in ([string]$keys -split ',')) { if ($k) { $script:SAT[$k] = $true } } }
function Resolve-Needs {
  foreach ($k in @($script:PNEED.Keys)) {
    foreach ($n in $script:PNEED[$k]) {
      $first = ($k -split ',')[0]
      if ($k -ne '_' -and $script:SAT.ContainsKey($first)) { Add-Warn ($n.text + '  (not blocking: another emulator for this system is ready)') $n.sec $n.sub }
      else { [void]$script:NEEDS.Add($n) }
    }
  }
  $script:PNEED = @{}
}
function Short($p) {
  $p = [string]$p
  if ($script:BIOS -and $p.StartsWith($script:BIOS + $SEP, [StringComparison]::OrdinalIgnoreCase)) { return 'bios' + $SEP + $p.Substring($script:BIOS.Length + 1) }
  if ($UP -and $p.StartsWith($UP + $SEP, [StringComparison]::OrdinalIgnoreCase)) { return '~' + $SEP + $p.Substring($UP.Length + 1) }
  return $p
}
function Fix-Copy($src, $dst) {
  $dir = [IO.Path]::GetDirectoryName($dst)
  $c = "if (-not (Test-Path -LiteralPath $(Q $dst))) { "
  if (-not (IsDir $dir)) { $c += "New-Item -ItemType Directory -Force -Path $(Q $dir) | Out-Null; " }
  return $c + "Copy-Item -LiteralPath $(Q $src) -Destination $(Q $dst) }"
}
function Fix-Rename($src, $newName) { return "Rename-Item -LiteralPath $(Q $src) -NewName $(Q $newName)" }

# ----------------------------------------------------------------------------
# Embedded data
# ----------------------------------------------------------------------------
$KNOWN_DATA = @'
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
'@
$RA_DATA = @'
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
'@
$RULES_DATA = @'
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
'@
$script:K = @{}
foreach ($l in ($KNOWN_DATA -split "`r?`n")) {
  if (-not $l -or $l.StartsWith('#')) { continue }
  $p = $l.Split('|', 4)
  if ($p.Count -eq 4) { $script:K[$p[0]] = @{ tag = $p[1]; reg = $p[2]; desc = $p[3] } }
}
$script:RA_ROWS = New-Object System.Collections.ArrayList
foreach ($l in ($RA_DATA -split "`r?`n")) {
  if (-not $l) { continue }
  $p = $l.Split('|', 6)
  if ($p.Count -eq 6) { [void]$script:RA_ROWS.Add(@{ core = $p[0]; sys = $p[1]; path = $p[2]; rf = $p[3]; md5 = $p[4]; desc = $p[5] }) }
}
$script:RULES = New-Object System.Collections.ArrayList
foreach ($l in ($RULES_DATA -split "`r?`n")) {
  if (-not $l) { continue }
  $p = $l.Split('@', 5)
  if ($p.Count -ge 4) { [void]$script:RULES.Add(@{ cre = $p[0]; pre = $p[1]; rule = $p[2]; roms = $p[3]; note = $(if ($p.Count -ge 5) { $p[4] } else { '' }) }) }
}
function Ident($m) { if ($m -and $script:K.ContainsKey($m)) { return $script:K[$m].desc } else { return 'unrecognised dump' } }
function KTag($m)  { if ($m -and $script:K.ContainsKey($m)) { return $script:K[$m].tag } else { return '' } }

# ----------------------------------------------------------------------------
# Hash index
# ----------------------------------------------------------------------------
$PRUNE = @('firmware', 'registered', 'dev_flash', 'dev_hdd0', 'dev_hdd1', 'vita3k', 'sys_modules', 'mlc01', 'nand', 'sdmc',
           'ux0', 'vs0', 'os0', 'sa0', 'pd0', 'dolphin-emu', 'Machines', 'Databases')
$script:MD5ALG = [Security.Cryptography.MD5]::Create()
$script:F_MD5 = @{}; $script:H_PATH = @{}
$script:ALLFILES = New-Object System.Collections.ArrayList
$script:CLOUD = New-Object System.Collections.ArrayList

function Md5($p) {
  if ($script:F_MD5.ContainsKey($p)) { return $script:F_MD5[$p] }
  try {
    $fs = [IO.File]::OpenRead($p)
    try { $h = ([BitConverter]::ToString($script:MD5ALG.ComputeHash($fs))).Replace('-', '').ToLowerInvariant() } finally { $fs.Dispose() }
    $script:F_MD5[$p] = $h; return $h
  } catch { return '' }
}
function Build-Index($root) {
  $script:F_MD5 = @{}; $script:H_PATH = @{}; $script:ALLFILES.Clear(); $script:CLOUD.Clear()
  if (-not (IsDir $root)) { return }
  $stack = New-Object System.Collections.Stack
  $stack.Push(@($root, 0))
  while ($stack.Count -gt 0) {
    $it = $stack.Pop(); $d = $it[0]; $depth = $it[1]
    try { $entries = [IO.Directory]::GetFileSystemEntries($d) } catch { continue }
    foreach ($e in $entries) {
      if ([IO.Directory]::Exists($e)) {
        if ($depth -lt 6 -and ($PRUNE -notcontains [IO.Path]::GetFileName($e))) { $stack.Push(@($e, ($depth + 1))) }
      } else { [void]$script:ALLFILES.Add($e) }
    }
  }
  $limit = [long]$MaxHashMB * 1MB
  foreach ($f in $script:ALLFILES) {
    try { $fi = New-Object IO.FileInfo $f } catch { continue }
    if (IsCloud $fi) { [void]$script:CLOUD.Add($f); continue }
    if ($fi.Length -le $limit) {
      $m = Md5 $f
      if ($m -and -not $script:H_PATH.ContainsKey($m)) { $script:H_PATH[$m] = $f }
    }
  }
}

# ----------------------------------------------------------------------------
# Probe + report
#   P.state: OK NOHASH BADHASH CASE DOUBLEEXT ELSEWHERE EMPTY CLOUD MISSING
# ----------------------------------------------------------------------------
function Probe($want, $hs) {
  $script:P = @{ state = 'MISSING'; path = ''; md5 = '' }
  $dir = [IO.Path]::GetDirectoryName($want); $base = [IO.Path]::GetFileName($want)
  $hl = ",$hs,"
  if (IsFile $want) {
    $script:P.path = $want
    $fi = New-Object IO.FileInfo $want
    if (IsCloud $fi) { $script:P.state = 'CLOUD'; return }
    if ($fi.Length -eq 0) { $script:P.state = 'EMPTY'; return }
    if (-not $hs) { $script:P.state = 'NOHASH'; return }
    $m = Md5 $want; $script:P.md5 = $m
    if ($hl.Contains(",$m,")) { $script:P.state = 'OK' } else { $script:P.state = 'BADHASH' }
    return
  }
  if (IsDir $dir) {
    foreach ($f in [IO.Directory]::GetFiles($dir)) {
      $n = [IO.Path]::GetFileName($f)
      if (-not $IsWin -and $n -ieq $base) { $script:P.state = 'CASE'; $script:P.path = $f; if ($hs) { $script:P.md5 = Md5 $f }; return }
      if ($n.Length -gt $base.Length -and $n.StartsWith("$base.", [StringComparison]::OrdinalIgnoreCase)) {
        $m = ''; if ($hs) { $m = Md5 $f }
        if (-not $hs -or $hl.Contains(",$m,")) { $script:P.state = 'DOUBLEEXT'; $script:P.path = $f; $script:P.md5 = $m; return }
      }
    }
  }
  if ($hs) {
    foreach ($h in $hs.Split(',')) {
      if ($h -and $script:H_PATH.ContainsKey($h)) { $script:P.state = 'ELSEWHERE'; $script:P.path = $script:H_PATH[$h]; $script:P.md5 = $h; return }
    }
  }
}

# Report <label> <expected> <md5s> <REQ|REC|OPT|ANY> <rp 1/0/-> <system> [note]
# returns 0 usable, 1 not usable, 2 fixable
function Report-File($label, $want, $hs, $imp, $rp, $sys, $note = '') {
  $disp = Short $want
  Probe $want $hs
  $P = $script:P
  $script:R = @{ file = [IO.Path]::GetFileName($want); want = $disp; note = $note; found = $(if ($P.path) { Short $P.path } else { '' }) }
  switch ($P.state) {
    'OK'      { $script:R.kind = 'ok'; $script:R.what = (Ident $P.md5); L-Ok "$label  $(Ident $P.md5)"; $script:CNT_OK++; return 0 }
    'NOHASH'  { $script:R.kind = 'present'; L-Ok "$label  present ($(Human (FSize $want)), no reference hash to verify)"; $script:CNT_OK++; return 0 }
    'BADHASH' {
      $what = Ident $P.md5
      if ($want -like '*.zip') { $script:R.kind = 'zipok'; L-Ok "$label  present (zip hash differs from reference - normal between MAME/FBNeo versions)"; $script:CNT_OK++; return 0 }
      $exp = ''; foreach ($h in $hs.Split(',')) { $exp = KTag $h; if ($exp) { break } }
      $got = KTag $P.md5
      if ($got -and $got -ne $exp) {
        $script:R.kind = 'wrongfile'; $script:R.what = $what
        L-Bad "$label is the WRONG file - it is actually: $what"
        if ($imp -eq 'REQ' -and $rp -eq '1') { Add-Need "${sys}: $disp is really '$what' - replace it with the correct dump" }
        elseif ($imp -ne 'OPT' -and $imp -ne 'ANY') { Add-Warn "${sys}: $disp is really '$what'" }
        return 1
      }
      $script:R.kind = 'badhash'; $script:R.what = $what
      L-Warn "$label  hash mismatch - this file is: $what (md5 $($P.md5))"
      Add-Warn "${sys}: $disp has an unexpected hash ($what) - may be a bad/alternate dump"
      return 0
    }
    'CASE' {
      $script:R.kind = 'case'
      L-Warn "$label  wrong filename case: found $(Short $P.path)"
      $c = "Move-Item -LiteralPath $(Q $P.path) -Destination $(Q $want)"; L-Fix $c; Add-Fix $c
      Add-Warn "${sys}: rename $(Short $P.path) -> $([IO.Path]::GetFileName($want)) (case)"
      if ($imp -eq 'OPT') { return 1 }; return 2
    }
    'DOUBLEEXT' {
      $script:R.kind = 'doubleext'
      L-Warn "$label  is there but named $([IO.Path]::GetFileName($P.path)) - Windows hides the extra extension"
      $c = Fix-Rename $P.path ([IO.Path]::GetFileName($want)); L-Fix $c; Add-Fix $c
      Add-Warn "${sys}: rename $(Short $P.path) -> $([IO.Path]::GetFileName($want)) (double extension)"
      return 2
    }
    'ELSEWHERE' {
      $script:R.kind = 'elsewhere'
      L-Warn "$label  not at $disp, but the right file is here: $(Short $P.path)"
      $c = Fix-Copy $P.path $want; L-Fix $c; Add-Fix $c
      Add-Warn "${sys}: copy $(Short $P.path) -> $disp"
      return 2
    }
    'EMPTY' { $script:R.kind = 'empty'; L-Bad "$label is a 0-byte file ($disp)"; Add-Warn "${sys}: $disp is empty"; return 1 }
    'CLOUD' { $script:R.kind = 'cloudonly'; L-Bad "$label is only in OneDrive, not on this PC ($disp)"; Add-Warn "${sys}: $disp is a cloud-only OneDrive file - right-click it > Always keep on this device"; return 1 }
    default {
      switch ($imp) {
        'OPT' { if ($ShowOptional -or $script:REC) { $script:R.kind = 'missing_opt'; $t = "$label - optional, not present$(if ($note) { " ($note)" })"
                  if ($ShowOptional) { L-Opt $t } else { Ev 'opt' $t } }
                $script:R = @{}; return 1 }
        'ANY' { if ($ShowOptional) { L-Opt "$label - not present" }; $script:R = @{}; return 1 }
        'REC' { if ($rp -eq '0') { $script:R.kind = 'missing_later'; L-Opt "$label - recommended once you add games ($disp)$(if ($note) { " - $note" })" }
                else { $script:R.kind = 'missing_rec'; L-Warn "$label - recommended, missing ($disp)$(if ($note) { " - $note" })"
                       Add-Warn "${sys}: recommended $([IO.Path]::GetFileName($want)) missing$(if ($note) { " ($note)" })" }
                return 1 }
        'REQ' { if ($rp -eq '1') { $script:R.kind = 'missing_req'; L-Bad "$label - MISSING, needed ($disp)$(if ($note) { " - $note" })"
                                   Add-Need "${sys}: $([IO.Path]::GetFileName($want)) -> $disp$(if ($note) { " ($note)" })" }
                else { $script:R.kind = 'missing_later'; L-Opt "$label - missing ($disp) - needed once you add games$(if ($note) { " - $note" })" }
                return 1 }
      }
    }
  }
  return 1
}

# ----------------------------------------------------------------------------
# ROM folders decide NEED vs "later"
# ----------------------------------------------------------------------------
$script:ROMC = @{}
$SKIPROM = @('neogeo.zip', 'awbios.zip', 'keys.txt')
function Rom-Count($folders) {
  if (-not $script:ROMS -or -not (IsDir $script:ROMS)) { return -1 }
  $tot = 0
  foreach ($f in ([string]$folders -split ',')) {
    if (-not $f) { continue }
    if (-not $script:ROMC.ContainsKey($f)) {
      $d = JP $script:ROMS $f; $n = 0
      if (IsDir $d) {
        $n = @(Get-ChildItem -LiteralPath $d -Recurse -Depth 2 -File -Force -ErrorAction SilentlyContinue | Where-Object {
              -not $_.Name.StartsWith('.') -and $_.Extension -ne '.txt' -and $_.Name -notlike 'metadata*' -and $SKIPROM -notcontains $_.Name -and
              $_.Name -notlike 'naomi*.zip' -and $_.Name -notlike '*.keys' -and $_.FullName -notmatch '[\\/](media|images|videos|manuals)[\\/]' } |
              Select-Object -First 500).Count
      }
      $script:ROMC[$f] = $n
    }
    $tot += $script:ROMC[$f]
  }
  return $tot
}
function Rp($folders) { if (-not $folders) { return '-' }; $n = Rom-Count $folders; if ($n -gt 0) { return '1' } elseif ($n -lt 0) { return '-' } else { return '0' } }
function Rom-Note($folders) {
  if (-not $folders) { return '' }
  $n = Rom-Count $folders; $f = ([string]$folders).Replace(',', ' | ')
  if ($n -lt 0) { return '[roms folder unknown]' }
  if ($n -gt 0) { return "[$n$(if ($n -ge 500) { '+' }) game files in roms/$f]" }
  return "[no games in roms/$f]"
}

# ----------------------------------------------------------------------------
# Hash-identified BIOS folders (DuckStation, PCSX2)
# ----------------------------------------------------------------------------
function Ps2Region($c) { switch -CaseSensitive ($c) { 'J' { 'JP' } 'A' { 'US' } 'E' { 'EU' } 'H' { 'ASIA' } 'C' { 'CN' } 'R' { 'RU' } 'K' { 'KR' } 'T' { 'JP' } default { '?' } } }
function Hash-Dir($dir, $tag) {
  $script:HD_COUNT = 0; $script:HD_REGIONS = ''
  if (-not (IsDir $dir)) { L-Warn "folder does not exist: $(Short $dir)"; return }
  foreach ($f in [IO.Directory]::GetFiles($dir)) {
    $fi = New-Object IO.FileInfo $f
    if (IsCloud $fi) { $script:R = @{ kind = 'cloudonly'; file = $fi.Name; want = (Short $f) }; L-Bad "$($fi.Name) is only in OneDrive, not on this PC"; continue }
    $m = Md5 $f; if (-not $m) { continue }
    $t = KTag $m
    if ($t -eq $tag) {
      $r = $script:K[$m].reg; $script:HD_COUNT++; $script:HD_REGIONS += " $r"
      $script:R = @{ kind = 'bios_found'; file = $fi.Name; what = $script:K[$m].desc; note = $r }
      L-Ok "$($fi.Name)  $($script:K[$m].desc) [$r]"; $script:CNT_OK++
    } elseif ($tag -eq 'PS2' -and $fi.Length -eq 4194304) {
      $txt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f))
      $mm = [regex]::Match($txt, '[0-9]{4}[JAEHCRKT][CDTX][0-9]{8}')
      if ($mm.Success) {
        $r = Ps2Region $mm.Value.Substring(4, 1); $script:HD_COUNT++; $script:HD_REGIONS += " $r"
        L-Warn "$($fi.Name)  valid-looking PS2 BIOS (ROMVER $($mm.Value), $r) but hash not in any known list - possibly a bad dump"
        Add-Warn "PS2: $($fi.Name) has ROMVER $($mm.Value) but an unknown hash"
      }
    } elseif ($tag -eq 'PS1' -and $fi.Length -eq 524288) {
      $txt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f))
      $mm = [regex]::Match($txt, 'System ROM Version [0-9.]+ [0-9/]+ [AEJ]')
      if ($mm.Success) {
        $r = @{ A = 'US'; E = 'EU'; J = 'JP' }[$mm.Value.Substring($mm.Value.Length - 1)]; $script:HD_COUNT++; $script:HD_REGIONS += " $r"
        L-Warn "$($fi.Name)  looks like a PS1 BIOS ($($mm.Value)) but the hash is unknown - possibly a bad dump"
        Add-Warn "PS1: $($fi.Name) ($($mm.Value)) has an unknown hash"
      }
    }
  }
}
function Region-Line($have, [string[]]$want) {
  $out = @(); $all = $true
  foreach ($r in $want) {
    if ($have -match "(^| )$r( |/|$)" -or $have -match '(^| )ALL( |$)' -or $have -match "/$r( |$)") { $out += "$r OK" } else { $out += "$r -"; $all = $false }
  }
  L-Info ('regions covered: ' + ($out -join '   '))
  return $all
}
function Elsewhere-Tag($tag, $exclude) {
  $out = @()
  foreach ($p in @($script:F_MD5.Keys)) {
    if ((KTag $script:F_MD5[$p]) -eq $tag -and [IO.Path]::GetDirectoryName($p) -ne $exclude) { $out += $p }
  }
  return $out
}

# ============================================================================
# CHECKS
# ============================================================================
function RomDir($rel) { if ($script:ROMS) { return (JP $script:ROMS $rel) } else { return $null } }
function Emu($rel) { if ($script:EMUS) { return (JP $script:EMUS $rel) } else { return $null } }
function Std-Installed { foreach ($p in $args) { if ($p -and (Test-Path -LiteralPath $p)) { return $true } }; return $false }
function Set-Have([bool]$installed) {
  if ($installed) { return $true }
  if ($All) { $script:NOTINST = $true; return $true }
  return $false
}

function Check-Hygiene {
  Hdr 'BIOS folder hygiene' ''
  $issues = 0
  if (-not (IsDir $script:BIOS)) { L-Bad "BIOS folder does not exist: $($script:BIOS)"; Add-Need "BIOS folder $($script:BIOS) is missing" '_'; return }
  L-Info "$($script:ALLFILES.Count) files indexed under $(Short $script:BIOS) (hashed: $($script:F_MD5.Count))"
  if ($script:BIOS -match 'OneDrive') {
    L-Warn 'your BIOS folder is inside OneDrive - files set to "online-only" are invisible to emulators'
    Add-Warn 'BIOS folder is inside OneDrive: right-click it > Always keep on this device'; $issues++
  }
  foreach ($f in $script:CLOUD) {
    L-Bad "only in OneDrive, not on this PC: $(Short $f)"
    Add-Warn "cloud-only file $(Short $f) - right-click > Always keep on this device"; $issues++
  }
  foreach ($f in $script:ALLFILES) {
    $b = [IO.Path]::GetFileName($f); $lb = $b.ToLowerInvariant()
    if ($lb -like '*zone.identifier') { L-Warn "download junk file: $(Short $f)"; Add-Fix "Remove-Item -LiteralPath $(Q $f)"; $issues++; continue }
    if (@('desktop.ini', 'thumbs.db', '.ds_store') -contains $lb -or $lb.StartsWith('._')) { L-Info "junk file: $(Short $f)"; continue }
    if ($script:CLOUD -contains $f) { continue }
    if ((FSize $f) -eq 0) { L-Warn "0-byte file: $(Short $f)"; Add-Warn "0-byte file $(Short $f)"; $issues++ }
    if ($lb -match '^(scph.*\.(zip|7z|rar)|.*bios.*\.(7z|rar)|.*\.(bin|rom)\.(zip|7z)|dc_boot.*\.zip|bios_cd.*\.zip|kick.*\.zip|ps2-.*\.zip|ps2.*bios.*\.zip)$') {
      L-Warn "compressed BIOS - most emulators need it extracted: $(Short $f)"; Add-Warn "extract $(Short $f)"; $issues++
    } elseif ($lb -match '\.(bin|rom|img|keys|pce|sfc|n64|txt|zip)\.(bin|rom|txt|zip|bak|img)$') {
      L-Warn "double extension (Windows hides the last one): $(Short $f)"
      Add-Warn "double extension: $(Short $f)"; $issues++
    } elseif ($lb -like 'prod*.keys' -or $lb -like 'title*.keys') {
      if ($f -notmatch '[\\/](keys|switch|system)[\\/]') { L-Warn "Switch key file loose in BIOS folder (not used from here): $(Short $f)"; $issues++ }
    } elseif ($lb -like '*.pup') { L-Info "firmware package found: $(Short $f) (see PS3/Vita sections)" }
  }
  # broken links / junctions
  try {
    foreach ($d in (Get-ChildItem -LiteralPath $script:BIOS -Directory -Force -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
      if ([int]$d.Attributes -band [int][IO.FileAttributes]::ReparsePoint) {
        $ok = $true; try { [void][IO.Directory]::GetFileSystemEntries($d.FullName) } catch { $ok = $false }
        if (-not $ok) { L-Bad "broken link/junction: $(Short $d.FullName)"; Add-Warn "broken link $(Short $d.FullName) - re-run EmuDeck's setup for that emulator"; $issues++ }
      }
    }
  } catch {}
  if ($issues -eq 0) { L-Ok 'no hygiene problems found' }
}

# --------------------------------------------------------------------------
function Check-Psx {
  $cfg = FirstExisting (Emu 'duckstation/settings.ini') (JP $DOCS[0] 'DuckStation/settings.ini') $(if ($DOCS.Count -gt 1) { JP $DOCS[1] 'DuckStation/settings.ini' }) (JP $LAD 'DuckStation/settings.ini')
  if (-not (Set-Have ([bool]$cfg -or (Std-Installed (Emu 'duckstation'))))) { return }
  Hdr 'Sony PlayStation - DuckStation' (Rom-Note 'psx'); $script:CUR_KEY = 'psx'
  $dir = ''
  if ($cfg) { $dir = Resolve-Rel (IniGet $cfg 'SearchDirectory') ([IO.Path]::GetDirectoryName($cfg)) }
  if (-not $dir) { $dir = $script:BIOS }
  L-Info "DuckStation reads BIOS by hash from: $(Short $dir)  (filename does not matter)"
  if ($cfg) { L-Sub "config: $(Short $cfg)" }
  Hash-Dir $dir 'PS1'
  $rp = Rp 'psx'
  if ($script:HD_COUNT -eq 0) {
    $e = @(Elsewhere-Tag 'PS1' $dir)
    if ($e.Count) { L-Warn 'no PS1 BIOS in that folder, but found elsewhere:'; foreach ($f in $e) { $c = Fix-Copy $f (JP $dir ([IO.Path]::GetFileName($f))); L-Fix $c; Add-Fix $c } }
    if ($rp -eq '1') { L-Bad 'NO PlayStation BIOS - DuckStation will not boot your games'; Add-Need "PS1 (DuckStation): any PS1 BIOS (e.g. scph5501.bin US / scph5502.bin EU / scph5500.bin JP) in $(Short $dir)" }
    else { L-Warn 'no PlayStation BIOS (needed once you add PS1 games)' }
  } else {
    Mark-Ok 'psx'
    if (-not (Region-Line $script:HD_REGIONS @('US', 'EU', 'JP'))) { L-Sub "DuckStation picks the BIOS matching each game's region; add the missing ones (or a region-free psxonpsp660.bin / ps1_rom.bin)" }
  }
}

# --------------------------------------------------------------------------
function Check-Ps2 {
  $cfg = FirstExisting (Emu 'PCSX2-Qt/inis/PCSX2.ini') (JP $DOCS[0] 'PCSX2/inis/PCSX2.ini') $(if ($DOCS.Count -gt 1) { JP $DOCS[1] 'PCSX2/inis/PCSX2.ini' })
  $hadHdr = $false
  if (Set-Have ([bool]$cfg -or (Std-Installed (Emu 'PCSX2-Qt')))) {
    $hadHdr = $true
    Hdr 'Sony PlayStation 2 - PCSX2' (Rom-Note 'ps2'); $script:CUR_KEY = 'ps2'
    $dir = ''
    if ($cfg) { $dir = Resolve-Rel (IniGet $cfg 'Bios') ([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($cfg))) }
    if (-not $dir) { $dir = $script:BIOS }
    L-Info "PCSX2 BIOS folder: $(Short $dir)  (filename does not matter, needs the full 4 MiB dump)"
    if ($cfg) { L-Sub "config: $(Short $cfg)" }
    Hash-Dir $dir 'PS2'
    if ($script:HD_COUNT -eq 0) {
      $e = @(Elsewhere-Tag 'PS2' $dir)
      if ($e.Count) { L-Warn 'PS2 BIOS found elsewhere:'; foreach ($f in $e) { $c = Fix-Copy $f (JP $dir ([IO.Path]::GetFileName($f))); L-Fix $c; Add-Fix $c } }
      if ((Rp 'ps2') -eq '1') { L-Bad 'NO PS2 BIOS - PCSX2 cannot run games'; Add-Need "PS2 (PCSX2): one PS2 BIOS dump (e.g. SCPH-70012 US / SCPH-70004 EU / SCPH-70000 JP) in $(Short $dir)" }
      else { L-Warn 'no PS2 BIOS (needed once you add PS2 games)' }
    } else {
      Mark-Ok 'ps2'
      if (-not (Region-Line $script:HD_REGIONS @('US', 'EU', 'JP'))) { L-Sub 'any region boots any game in PCSX2; matching region only matters for language/PAL-NTSC defaults' }
    }
  }
  if ($script:RA_CORES -contains 'pcsx2_libretro') {
    $script:NOTINST = $false
    if (-not $hadHdr) { Hdr 'Sony PlayStation 2 - RetroArch' (Rom-Note 'ps2'); $script:CUR_KEY = 'ps2' }
    $d = JP $script:RA_SYS 'pcsx2/bios'
    Sub 'RetroArch LRPS2 core' (Short $d) -Now
    Hash-Dir $d 'PS2'
    if ($script:HD_COUNT -eq 0) {
      if ((Rp 'ps2') -eq '1') { L-Warn 'LRPS2 core has no BIOS in system/pcsx2/bios'; Add-Warn "PS2 (RetroArch LRPS2): put a PS2 BIOS in $(Short $d)" }
      else { L-Opt 'LRPS2: no BIOS in system/pcsx2/bios' }
    }
  }
}

# --------------------------------------------------------------------------
function Check-Ps3 {
  $dirE = Emu 'RPCS3'
  if (-not (Set-Have (Std-Installed $dirE))) { return }
  if (-not $dirE) { $dirE = JP $AD 'RPCS3' }
  Hdr 'Sony PlayStation 3 - RPCS3' (Rom-Note 'ps3'); $script:CUR_KEY = 'ps3'
  $vfs = FirstExisting (JP $dirE 'config/vfs.yml') (JP $dirE 'vfs.yml')
  $flash = ''
  if ($vfs) {
    L-Sub "config: $(Short $vfs)"
    $emudir = YmlGet $vfs '$(EmulatorDir)'; if (-not $emudir) { $emudir = $dirE }
    $flash = YmlGet $vfs '/dev_flash/'
    if ($flash) { $flash = Resolve-Rel ($flash.Replace('$(EmulatorDir)', $emudir + $SEP)) $dirE }
  }
  if (-not $flash) { $flash = JP $dirE 'dev_flash' }
  $flash = $flash.TrimEnd('\', '/')
  $vt = JP $flash 'vsh/etc/version.txt'
  if (IsFile $vt) {
    $rel = ''; $m = [regex]::Match([IO.File]::ReadAllText($vt), 'release:([0-9.]+)'); if ($m.Success) { $rel = $m.Groups[1].Value }
    $nm = 0; $ext = JP $flash 'sys/external'; if (IsDir $ext) { $nm = @([IO.Directory]::GetFiles($ext, '*.sprx')).Count }
    if ($nm -gt 50) { L-Ok "PS3 firmware installed: $(if ($rel) { $rel } else { 'unknown' }) ($nm system modules in $(Short $flash))"; $script:CNT_OK++ }
    else { L-Warn "firmware version file present ($rel) but only $nm modules in dev_flash/sys/external - install looks incomplete"
           Add-Warn "PS3: firmware install in $(Short $flash) looks incomplete - reinstall PS3UPDAT.PUP via File > Install Firmware" }
  } elseif ((Rp 'ps3') -eq '1') { L-Bad "PS3 firmware NOT installed (no $(Short $vt))"; Add-Need 'PS3 (RPCS3): install PS3UPDAT.PUP via RPCS3 > File > Install Firmware' }
  else { L-Warn 'PS3 firmware not installed (needed once you add PS3 games)' }
  foreach ($p in $script:ALLFILES) {
    if ([IO.Path]::GetFileName($p) -like 'ps3updat*.pup') {
      $hdr = ''; try { $fs = [IO.File]::OpenRead($p); $b = New-Object byte[] 5; [void]$fs.Read($b, 0, 5); $fs.Dispose(); $hdr = [Text.Encoding]::ASCII.GetString($b) } catch {}
      if ($hdr -eq 'SCEUF') { L-Info "firmware package $(Short $p) ($(Human (FSize $p))) is valid - install it from RPCS3 if the firmware above is missing" }
      else { L-Warn "$(Short $p) does not look like a PS3 PUP (bad header) - re-download it from Sony"; Add-Warn "PS3: $(Short $p) has a bad header" }
    }
  }
}

# --------------------------------------------------------------------------
function Check-Vita {
  $cfg = FirstExisting (Emu 'Vita3K/config.yml') (JP $AD 'Vita3K/config.yml')
  if (-not (Set-Have ([bool]$cfg -or (Std-Installed (Emu 'Vita3K') (JP $AD 'Vita3K'))))) { return }
  Hdr 'Sony PlayStation Vita - Vita3K' (Rom-Note 'psvita'); $script:CUR_KEY = 'psvita'
  $pref = ''
  if ($cfg) { $pref = YmlGet $cfg 'pref-path'; L-Sub "config: $(Short $cfg)" }
  if ($pref) { $pref = Resolve-Rel $pref ([IO.Path]::GetDirectoryName($cfg)) }
  if (-not $pref) { $pref = FirstExisting (JP $script:STORAGE 'Vita3K') (JP $AD 'Vita3K/Vita3K') (Emu 'Vita3K') }
  if ($pref) { $pref = $pref.TrimEnd('\', '/') }
  L-Info "Vita3K data folder: $(if ($pref) { Short $pref } else { '?' })"
  $vs0 = JP $pref 'vs0'
  if ($pref -and (IsDir $vs0) -and @([IO.Directory]::GetFileSystemEntries($vs0)).Count -gt 0) {
    $v = ''; $vf = JP $vs0 'vsh/etc/version.txt'; if (IsFile $vf) { $m = [regex]::Match([IO.File]::ReadAllText($vf), 'release:([0-9.]+)'); if ($m.Success) { $v = " ($($m.Groups[1].Value))" } }
    L-Ok "Vita firmware installed$v ($(Short $vs0))"; $script:CNT_OK++
  } elseif ((Rp 'psvita') -eq '1') { L-Bad 'Vita firmware NOT installed'; Add-Need 'Vita (Vita3K): install PSVUPDAT.PUP via Vita3K > File > Install Firmware' }
  else { L-Warn 'Vita firmware not installed (needed once you add Vita games)' }
  $pvf = JP $pref 'sa0/data/font/pvf'
  if ($pref -and (IsDir $pvf) -and @([IO.Directory]::GetFiles($pvf, '*.pvf')).Count -gt 0) { L-Ok 'firmware font package installed (sa0/data/font/pvf)'; $script:CNT_OK++ }
  else { L-Warn 'font package not installed - some games show blank text/crash (Install Firmware > PSP2UPDAT.PUP font package)'; Add-Warn 'Vita: install the firmware FONT package (PSP2UPDAT.PUP) in Vita3K' }
}

# --------------------------------------------------------------------------
function Check-Xbox {
  $toml = FirstExisting (Emu 'xemu/xemu.toml') (JP $AD 'xemu/xemu/xemu.toml')
  if (-not (Set-Have ([bool]$toml -or (Std-Installed (Emu 'xemu'))))) { return }
  Hdr 'Microsoft Xbox - xemu' (Rom-Note 'xbox'); $script:CUR_KEY = 'xbox'
  $boot = ''; $flash = ''; $hdd = ''; $eep = ''
  if ($toml) {
    L-Sub "config: $(Short $toml)"
    $base = [IO.Path]::GetDirectoryName($toml)
    $boot = Resolve-Rel (IniGet $toml 'bootrom_path') $base; $flash = Resolve-Rel (IniGet $toml 'flashrom_path') $base
    $hdd = Resolve-Rel (IniGet $toml 'hdd_path') $base; $eep = Resolve-Rel (IniGet $toml 'eeprom_path') $base
  }
  if (-not $boot) { $boot = JP $script:BIOS 'mcpx_1.0.bin' }
  if (-not $flash) { $flash = FirstExisting (JP $script:BIOS 'Complex_4627v1.03.bin') (JP $script:BIOS 'Complex_4627.bin') (JP $script:BIOS 'Complex.bin'); if (-not $flash) { $flash = JP $script:BIOS 'Complex_4627v1.03.bin' } }
  if (-not $hdd) { $hdd = FirstExisting (JP $script:STORAGE 'xemu/xbox_hdd.qcow2') (JP $script:BIOS 'xbox_hdd.qcow2') }
  $rp = Rp 'xbox'
  [void](Report-File 'MCPX boot ROM' $boot 'd49c52a4102f6df7bcf8d0617ac475ed' 'REQ' $rp 'Xbox' 'must be MCPX 1.0 (512 bytes)')
  [void](Report-File 'Flash ROM (BIOS)' $flash '' 'REQ' $rp 'Xbox' 'Complex 4627 recommended')
  if ($script:P.state -eq 'NOHASH') { $s = FSize $flash; if ($s -ne 1048576 -and $s -ne 262144) { L-Warn "flash ROM size is $s bytes - expected 262144 or 1048576"; Add-Warn "Xbox: flash ROM $(Short $flash) has an odd size ($s)" } }
  if ($hdd -and (IsFile $hdd)) {
    $b = New-Object byte[] 4; try { $fs = [IO.File]::OpenRead($hdd); [void]$fs.Read($b, 0, 4); $fs.Dispose() } catch {}
    if ($b[0] -eq 0x51 -and $b[1] -eq 0x46 -and $b[2] -eq 0x49 -and $b[3] -eq 0xFB) { L-Ok "HDD image $(Short $hdd) (qcow2, $(Human (FSize $hdd)))"; $script:CNT_OK++ }
    else { L-Warn "HDD image $(Short $hdd) is not a qcow2 file"; Add-Warn 'Xbox: HDD image is not qcow2' }
  } elseif ($rp -eq '1') { L-Bad "HDD image missing ($(if ($hdd) { $hdd } else { 'not configured' }))"; Add-Need "Xbox (xemu): xbox_hdd.qcow2 (the prebuilt image from xemu.app) -> $(Short $(if ($hdd) { $hdd } else { JP $script:STORAGE 'xemu/xbox_hdd.qcow2' }))" }
  else { L-Warn 'HDD image missing (needed once you add Xbox games)' }
  if ($eep -and (IsFile $eep)) { L-Ok "EEPROM $(Short $eep)" } else { L-Info 'EEPROM not present - xemu generates one automatically' }
}

# --------------------------------------------------------------------------
function Test-SwitchKeys($f) {
  $script:SW_GEN = -1; $maxg = -1; $hdr = $false; $bad = 0
  foreach ($l in [IO.File]::ReadAllLines($f)) {
    $l = $l.Trim(); if (-not $l -or $l.StartsWith(';') -or $l.StartsWith('#')) { continue }
    if ($l -match '^([a-z0-9_]+)\s*=\s*([0-9a-fA-F]+)$') {
      $k = $Matches[1]; $v = $Matches[2]
      if ($k -eq 'header_key' -and $v.Length -eq 64) { $hdr = $true }
      if ($k -match '^(master_key|key_area_key_application|titlekek)_([0-9a-f]{2})$') { $n = [Convert]::ToInt32($Matches[2], 16); if ($n -gt $maxg) { $maxg = $n } }
    } else { $bad++ }
  }
  $script:SW_GEN = $maxg
  if ($bad) { L-Warn "$bad malformed line(s) in $(Short $f)" }
  if (-not $hdr) { L-Bad 'prod.keys has no valid header_key - not a real prod.keys'; return $false }
  if ($maxg -lt 0) { L-Bad 'prod.keys has no master/application keys'; return $false }
  return $true
}
function Sw-Fw($g) {
  $m = @('1.0.0', '3.0.0', '3.0.1', '4.0.0', '5.0.0', '6.0.0', '6.2.0', '7.0.0', '8.1.0', '9.0.0', '9.1.0', '12.1.0', '13.0.0', '14.0.0', '15.0.0', '16.0.0', '17.0.0', '18.0.0', '19.0.0', '20.0.0')
  if ($g -lt $m.Count) { return $m[$g] } else { return 'newer than 20.x' }
}
function Check-SwitchEmu($name, $kdir, $fwdir, $layout, $link) {
  $rp = Rp 'switch'
  Sub "$name$(if ($script:NOTINST) { ' (not installed)' })" "keys: $(Short $kdir)  firmware: $(Short $fwdir)" -Now
  if ($link) {
    foreach ($pair in @(@((JP $link 'keys'), $kdir), @((JP $link 'firmware'), $fwdir))) {
      $lk = $pair[0]; $real = $pair[1]
      if ((IsDir $lk) -and @([IO.Directory]::GetFileSystemEntries($lk)).Count -gt 0 -and (Test-Path -LiteralPath $real) -and
          @([IO.Directory]::GetFileSystemEntries($real)).Count -eq 0) {
        L-Warn "$(Short $lk) has files, but $name's own folder $(Short $real) is empty - EmuDeck's link between them is missing"
        L-Sub "re-run EmuDeck's setup for $name, or copy the files into $(Short $real)"
        Add-Warn "${name}: files in $(Short $lk) are not seen by the emulator (link missing)"
      }
    }
  }
  $keys = JP $kdir 'prod.keys'; $okK = $false; $okF = $false
  if (IsFile $keys) {
    if (Test-SwitchKeys $keys) { $okK = $true; $script:CNT_OK++; L-Ok "prod.keys (key generation $($script:SW_GEN) -> supports firmware up to $(Sw-Fw $script:SW_GEN))" }
  } else {
    $alt = $null
    if (IsDir $kdir) { foreach ($f in [IO.Directory]::GetFiles($kdir)) { $n = [IO.Path]::GetFileName($f); if ($n -like 'prod*.keys*' -or $n -eq 'keys.txt' -or $n -eq 'prod.key') { $alt = $f; break } } }
    if ($alt) { L-Warn "prod.keys not found, but $(Short $alt) is there - must be named exactly prod.keys"; $c = Fix-Rename $alt 'prod.keys'; L-Fix $c; Add-Fix $c }
    if ($rp -eq '1') { L-Bad 'prod.keys MISSING'; Add-Need "Switch ($name): prod.keys -> $(Short $kdir)$SEP" } else { L-Warn 'prod.keys missing (needed once you add Switch games)' }
  }
  if (IsFile (JP $kdir 'title.keys')) { L-Ok 'title.keys (optional)' } elseif ($ShowOptional) { L-Opt 'title.keys (optional)' }
  $n = 0; $loose = 0; $nested = 0; $zips = 0
  if (IsDir $fwdir) {
    if ($layout -eq 'ryujinx') {
      $n = @([IO.Directory]::GetDirectories($fwdir, '*.nca')).Count; $loose = @([IO.Directory]::GetFiles($fwdir, '*.nca')).Count
    } else {
      $n = @([IO.Directory]::GetFiles($fwdir, '*.nca')).Count
      foreach ($sd in [IO.Directory]::GetDirectories($fwdir)) { $nested += @(Get-ChildItem -LiteralPath $sd -Recurse -Depth 1 -Filter '*.nca' -File -ErrorAction SilentlyContinue).Count }
    }
    $zips = @(Get-ChildItem -LiteralPath $fwdir -Depth 1 -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.zip', '.7z' }).Count
  }
  if ($n -ge 100) { L-Ok "firmware installed ($n NCAs)"; $okF = $true; $script:CNT_OK++ }
  elseif ($n -gt 0) { L-Warn "only $n firmware NCAs - a full firmware has well over 100; looks incomplete"; Add-Warn "Switch ($name): firmware looks incomplete ($n NCAs)"; $okF = $true }
  else {
    if ($nested) { L-Warn "$nested .nca files are inside a SUB-folder of $(Short $fwdir) - they must sit directly in it"; Add-Warn "Switch ($name): firmware NCAs are one folder too deep" }
    if ($loose) { L-Warn "$loose loose .nca files in Ryujinx's folder - Ryujinx needs firmware installed via Tools > Install Firmware"; Add-Warn "Switch ($name): install firmware through Ryujinx's menu, don't copy NCAs" }
    if ($zips) { L-Warn "firmware archive found in $(Short $fwdir) - extract it (yuzu forks) or use Install Firmware (Ryujinx)" }
    if ($rp -eq '1') { L-Bad 'firmware NOT installed'; Add-Need "Switch ($name): firmware -> $(if ($layout -eq 'ryujinx') { 'Ryujinx > Tools > Install Firmware' } else { "extract the NCA files into $(Short $fwdir)" })" }
    else { L-Warn 'firmware not installed (needed once you add Switch games)' }
  }
  if ($okK -and $okF) { Mark-Ok 'switch'; L-Info 'keys and firmware should come from the same firmware version (or keys newer than firmware)' }
}
function Check-Switch {
  $any = $false
  $forks = @(
    @{ n = 'Citron'; e = 'citron'; u = 'citron/user' },
    @{ n = 'Eden'; e = 'eden'; u = 'eden-windows-msvc/user' },
    @{ n = 'Yuzu'; e = 'yuzu'; u = 'yuzu/yuzu-windows-msvc/user' },
    @{ n = 'Suyu'; e = 'suyu'; u = 'suyu/user' },
    @{ n = 'Sudachi'; e = 'sudachi'; u = 'sudachi/user' })
  foreach ($fk in $forks) {
    $script:NOTINST = $false
    $user = $null
    $eu = Emu $fk.u; if ($eu -and (IsDir $eu)) { $user = $eu }
    if (-not $user) { $su = JP $AD $fk.e; if (IsDir $su) { $user = $su } }
    if (-not $user) { if (-not $All) { continue }; $script:NOTINST = $true; $user = $(if ($script:EMUS) { Emu $fk.u } else { JP $AD $fk.e }) }
    if (-not $any) { $ni = $script:NOTINST; $script:NOTINST = $false; Hdr 'Nintendo Switch' (Rom-Note 'switch'); $script:NOTINST = $ni; $script:CUR_KEY = 'switch'; $any = $true }
    Check-SwitchEmu $fk.n (JP $user 'keys') (JP $user 'nand/system/Contents/registered') 'yuzu' $(if ($script:EMUS) { JP $script:BIOS $fk.e })
  }
  $script:NOTINST = $false
  $r = $null
  $er = Emu 'Ryujinx/portable'; if ($er -and (IsDir $er)) { $r = $er }
  if (-not $r) { $sr = JP $AD 'Ryujinx'; if (IsDir $sr) { $r = $sr } }
  if ($r -or $All) {
    if (-not $r) { $script:NOTINST = $true; $r = $(if ($script:EMUS) { Emu 'Ryujinx/portable' } else { JP $AD 'Ryujinx' }) }
    if (-not $any) { $ni = $script:NOTINST; $script:NOTINST = $false; Hdr 'Nintendo Switch' (Rom-Note 'switch'); $script:NOTINST = $ni; $script:CUR_KEY = 'switch' }
    Check-SwitchEmu 'Ryujinx' (JP $r 'system') (JP $r 'bis/system/Contents/registered') 'ryujinx' $(if ($script:EMUS) { JP $script:BIOS 'ryujinx' })
  }
}

# --------------------------------------------------------------------------
function Check-WiiU {
  if (-not (Set-Have (Std-Installed (Emu 'cemu') (JP $AD 'Cemu')))) { return }
  Hdr 'Nintendo Wii U - Cemu' (Rom-Note 'wiiu'); $script:CUR_KEY = 'wiiu'
  $enc = 0; $wd = RomDir 'wiiu'
  if ($wd -and (IsDir $wd)) { $enc = @(Get-ChildItem -LiteralPath $wd -Recurse -Depth 1 -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.wud', '.wux' } | Select-Object -First 50).Count }
  $keys = FirstExisting (Emu 'cemu/keys.txt') (JP $AD 'Cemu/keys.txt') $(if ($wd) { JP $wd 'keys.txt' })
  if ($keys) {
    $good = 0; $bad = 0
    foreach ($l in [IO.File]::ReadAllLines($keys)) { if ($l -match '^\s*[0-9a-fA-F]{32}(\s.*)?$') { $good++ } elseif ($l -notmatch '^\s*($|#)') { $bad++ } }
    if ($good) { L-Ok "keys.txt $(Short $keys) ($good key lines)"; $script:CNT_OK++ } else { L-Warn "keys.txt at $(Short $keys) contains no valid 32-hex-digit keys"; Add-Warn 'Wii U: keys.txt has no valid keys' }
    if ($bad) { L-Warn "$bad malformed line(s) in keys.txt" }
  } elseif ($enc) { L-Bad "keys.txt MISSING and you have $enc encrypted .wud/.wux dumps"; Add-Need "Wii U (Cemu): keys.txt with your disc keys -> $(Short $(if ($script:EMUS) { Emu 'cemu/keys.txt' } else { JP $AD 'Cemu/keys.txt' }))" }
  else { L-Info "no keys.txt - only needed for encrypted .wud/.wux dumps (.wua / decrypted .rpx don't need it)" }
}

# --------------------------------------------------------------------------
function Check-3ds {
  if (-not (Set-Have (Std-Installed (Emu 'azahar') (JP $AD 'Azahar')))) { return }
  Hdr 'Nintendo 3DS - Azahar' (Rom-Note 'n3ds')
  $k = FirstExisting (Emu 'azahar/user/sysdata/aes_keys.txt') (JP $script:BIOS 'azahar/keys/aes_keys.txt') (JP $AD 'Azahar/sysdata/aes_keys.txt')
  if ($k) { L-Ok "aes_keys.txt $(Short $k)"; $script:CNT_OK++ }
  else { L-Info 'no aes_keys.txt - not needed for decrypted dumps (.3ds/.cci/.cxi decrypted, .cia installs). No BIOS required.' }
}

# --------------------------------------------------------------------------
function Check-Gc {
  $base = FirstExisting (Emu 'Dolphin-x64/User/GC') (JP $AD 'Dolphin Emulator/GC') (JP $DOCS[0] 'Dolphin Emulator/GC')
  if (-not (Set-Have ([bool]$base -or (Std-Installed (Emu 'Dolphin-x64'))))) { return }
  Hdr 'Nintendo GameCube - Dolphin' (Rom-Note 'gc')
  L-Info 'No BIOS needed - Dolphin boots games with HLE. IPL.bin only adds the boot animation/menu.'
  if (-not $base) { $base = $(if ($script:EMUS) { Emu 'Dolphin-x64/User/GC' } else { JP $AD 'Dolphin Emulator/GC' }) }
  $any = $false
  foreach ($pair in @(@('US', 'USA'), @('EU', 'EUR'), @('JP', 'JAP'))) {
    $f = JP $base $pair[1] 'IPL.bin'
    if (IsFile $f) {
      $any = $true; $m = Md5 $f
      if ((KTag $m) -eq 'GC') {
        $reg = $script:K[$m].reg
        if ($reg -eq $pair[0] -or ($pair[0] -eq 'JP' -and $reg -eq 'US')) { L-Ok "$($pair[0]) IPL.bin  $($script:K[$m].desc)" }
        else { L-Warn "$($pair[0])/IPL.bin is actually $($script:K[$m].desc) ($reg) - wrong region folder"; Add-Warn "GameCube: $(Short $f) is a $reg IPL in the $($pair[0]) folder" }
      } else { L-Warn "$($pair[0])/IPL.bin hash not recognised ($m)" }
    } elseif ($ShowOptional) { L-Opt "$($pair[0]) IPL.bin (optional) -> $(Short $f)" }
  }
  if (-not $any -and -not $ShowOptional) { L-Opt 'no IPL.bin files (optional)' }
}

# --------------------------------------------------------------------------
function Check-Nds {
  $cfg = FirstExisting (Emu 'melonDS/melonDS.toml') (Emu 'melonDS/melonDS.ini')
  if (-not (Set-Have ([bool]$cfg -or (Std-Installed (Emu 'melonDS'))))) { return }
  Hdr 'Nintendo DS - melonDS' (Rom-Note 'nds'); $script:CUR_KEY = 'nds'
  $rp = Rp 'nds'
  $b7 = ''; $b9 = ''; $fw = ''; $ext = ''
  if ($cfg) {
    L-Sub "config: $(Short $cfg)"; $base = [IO.Path]::GetDirectoryName($cfg)
    $ext = IniGet $cfg 'ExternalBIOSEnable'
    $b7 = Resolve-Rel (IniGet $cfg 'BIOS7Path') $base; $b9 = Resolve-Rel (IniGet $cfg 'BIOS9Path') $base; $fw = Resolve-Rel (IniGet $cfg 'FirmwarePath') $base
  }
  if (-not $b7) { $b7 = JP $script:BIOS 'bios7.bin' }; if (-not $b9) { $b9 = JP $script:BIOS 'bios9.bin' }; if (-not $fw) { $fw = JP $script:BIOS 'firmware.bin' }
  if ($ext -eq 'false' -or $ext -eq '0') { L-Info "melonDS is set to its built-in FreeBIOS (ExternalBIOSEnable=false) - real BIOS not needed for DS mode" }
  [void](Report-File 'bios7.bin' $b7 'df692a80a5b1bc90728bc3dfc76cd948' 'REC' $rp 'NDS' 'FreeBIOS works for most games; real BIOS = best compatibility')
  [void](Report-File 'bios9.bin' $b9 'a392174eb3e572fed6447e956bde4b25' 'REC' $rp 'NDS')
  [void](Report-File 'firmware.bin' $fw '' 'REC' $rp 'NDS' 'dump from your own DS; hash is unique per console')
  if ($ShowOptional) {
    [void](Report-File 'DSi ARM7 BIOS' (JP $script:BIOS 'dsi_bios7.bin') '559dae4ea78eb9d67702c56c1d791e81' 'OPT' '-' 'NDS')
    [void](Report-File 'DSi ARM9 BIOS' (JP $script:BIOS 'dsi_bios9.bin') '87b665fce118f76251271c3732532777' 'OPT' '-' 'NDS')
    [void](Report-File 'DSi firmware' (JP $script:BIOS 'dsi_firmware.bin') '' 'OPT' '-' 'NDS')
    [void](Report-File 'DSi NAND' (JP $script:BIOS 'dsi_nand.bin') '' 'OPT' '-' 'NDS')
  }
}

# --------------------------------------------------------------------------
function Check-Flycast {
  $d = Emu 'flycast/data'
  if (-not (Set-Have (Std-Installed (Emu 'flycast')))) { return }
  if (-not $d) { $d = JP $AD 'flycast/data' }
  Hdr 'Sega Dreamcast / NAOMI / Atomiswave - Flycast (standalone)' (Rom-Note 'dreamcast,naomi,naomi2,atomiswave')
  L-Info "Flycast data folder: $(Short $d)"
  $script:CUR_KEY = 'dreamcast'
  [void](Report-File 'dc_boot.bin' (JP $d 'dc_boot.bin') 'e10c53c2f8b90bab96ead2d368858623,d407fcf70b56acb84b8c77c93b0e5327,93a9766f14159b403178ac77417c6b68' 'REC' (Rp 'dreamcast') 'Dreamcast' 'HLE BIOS works for most games')
  [void](Report-File 'dc_flash.bin' (JP $d 'dc_flash.bin') '0a93f7940c455905bea6e392dfde92a4' 'OPT' '-' 'Dreamcast')
  $script:CUR_KEY = 'naomi';      if ((Report-File 'naomi.zip' (JP $d 'naomi.zip') '526eda1e2a7920c92c88178789d71d84' 'REQ' (Rp 'naomi') 'NAOMI') -eq 0) { Mark-Ok 'naomi' }
  $script:CUR_KEY = 'naomi2';     if ((Report-File 'naomi2.zip' (JP $d 'naomi2.zip') 'c50072cbab75673e1b1a6b94355e6fa8' 'REQ' (Rp 'naomi2') 'NAOMI 2') -eq 0) { Mark-Ok 'naomi2' }
  $script:CUR_KEY = 'atomiswave'; if ((Report-File 'awbios.zip' (JP $d 'awbios.zip') '85254fbe320ca82a768ec2c26bb08def' 'REQ' (Rp 'atomiswave') 'Atomiswave') -eq 0) { Mark-Ok 'atomiswave' }
}

# --------------------------------------------------------------------------
function Check-ShadPs4 {
  $d = FirstExisting (Emu 'ShadPS4-qt/user/sys_modules') (JP $script:BIOS 'shadps4/sys_modules')
  if (-not (Set-Have ([bool]$d -or (Std-Installed (Emu 'ShadPS4-qt'))))) { return }
  Hdr 'Sony PlayStation 4 - shadPS4' (Rom-Note 'ps4')
  $n = 0; if ($d -and (IsDir $d)) { $n = @([IO.Directory]::GetFiles($d, '*.sprx')).Count }
  if ($n) { L-Ok "$n system modules in $(Short $d) (optional LLE modules)" }
  else { L-Info 'no sys_modules - optional; a few games need LLE modules (libSceCesCs, libSceFont, libSceJson, libSceNgs2, libSceUlt...)' }
}

# --------------------------------------------------------------------------
function Zip-Members($p) {
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $z = [IO.Compression.ZipFile]::OpenRead($p)
    try { return @($z.Entries | ForEach-Object { $_.FullName.ToLowerInvariant() }) } finally { $z.Dispose() }
  } catch { return $null }
}
function Check-NeoGeo {
  $rp = Rp 'neogeo'; $rpa = Rp 'arcade,fbneo,mame'
  if (-not ($rp -eq '1' -or $rpa -eq '1' -or $All -or ($script:RA_CORES -contains 'fbneo_libretro'))) { return }
  Hdr 'Arcade - Neo Geo BIOS (neogeo.zip)' (Rom-Note 'neogeo,arcade,fbneo'); $script:CUR_KEY = 'neogeo'
  $found = @()
  foreach ($c in @((RomDir 'neogeo'), (RomDir 'arcade'), (RomDir 'fbneo'), (RomDir 'mame'), $script:BIOS, (JP $script:BIOS 'mame'), (JP $script:BIOS 'mame/bios'), (JP $script:BIOS 'fbneo'), $(if ($script:RA_SYS) { JP $script:RA_SYS 'fbneo' }))) {
    if ($c) { $z = JP $c 'neogeo.zip'; if ((IsFile $z) -and $found -notcontains $z) { $found += $z } }
  }
  if ($found.Count -eq 0) {
    if ($rp -eq '1') { L-Bad 'neogeo.zip not found anywhere'; Add-Need "Neo Geo: neogeo.zip -> $(Short (RomDir 'neogeo'))$SEP (next to the games; ES-DE launches from there)" }
    else { L-Warn 'neogeo.zip not found - every Neo Geo game (incl. ones in roms/arcade) needs it' }
    return
  }
  foreach ($f in $found) {
    $mem = Zip-Members $f
    if ($null -eq $mem) { L-Bad "$(Short $f) is corrupt (cannot open zip)"; Add-Need "Neo Geo: $(Short $f) is corrupt"; continue }
    $miss = @(); foreach ($x in @('000-lo.lo', 'sfix.sfix', 'sm1.sm1')) { if ($mem -notcontains $x) { $miss += $x } }
    $sys = @($mem | Where-Object { $_ -match '^(sp-s2\.sp1|sp-s\.sp1|sp-u2\.sp1|vs-bios\.rom|asia-s3\.rom|sp-e\.sp1|sp-j2\.sp1|sp1-u2|uni-bios.*\.rom|neo-epo\.bin|neo-po\.bin)$' })
    if ($sys.Count -eq 0) { $miss += 'a system BIOS (sp-s2.sp1 etc.)' }
    if ($miss.Count) { L-Warn "$(Short $f) is missing: $($miss -join ', ') - outdated or partial set"; Add-Warn "Neo Geo: $(Short $f) incomplete ($($miss -join ', '))" }
    else { L-Ok "$(Short $f) (zip OK, $($mem.Count) files)"; $script:CNT_OK++; Mark-Ok 'neogeo' }
  }
  $ng = RomDir 'neogeo'
  if ($rp -eq '1' -and $ng -and -not (IsFile (JP $ng 'neogeo.zip'))) {
    L-Warn 'you have games in roms/neogeo but no neogeo.zip next to them'
    $c = Fix-Copy $found[0] (JP $ng 'neogeo.zip'); L-Fix $c; Add-Fix $c
  }
}

# --------------------------------------------------------------------------
# RetroArch
# --------------------------------------------------------------------------
$script:RA_CORES = @(); $script:RA_SYS = ''; $script:RA_CFG = ''
function Find-RetroArch {
  $script:RA_CORES = @(); $script:RA_SYS = ''; $script:RA_CFG = ''
  $cands = @((Emu 'RetroArch'), 'C:\RetroArch-Win64', (JP $AD 'RetroArch'))
  foreach ($d in $cands) { if ($d) { $c = JP $d 'retroarch.cfg'; if (IsFile $c) { $script:RA_CFG = $c; break } } }
  if (-not $script:RA_CFG) { return $false }
  $base = [IO.Path]::GetDirectoryName($script:RA_CFG)
  $sys = IniGet $script:RA_CFG 'system_directory'
  if (-not $sys -or $sys -eq 'default') { $sys = JP $base 'system' }
  elseif ($sys.StartsWith(':')) { $sys = JP $base $sys.Substring(1) }
  $script:RA_SYS = (Resolve-Rel $sys $base).TrimEnd('\', '/')
  $cdir = IniGet $script:RA_CFG 'libretro_directory'
  if ($cdir -and $cdir.StartsWith(':')) { $cdir = JP $base $cdir.Substring(1) }
  $seen = @{}
  foreach ($d in @((JP $base 'cores'), $cdir)) {
    if ($d -and (IsDir $d)) {
      foreach ($f in [IO.Directory]::GetFiles($d)) {
        $n = [IO.Path]::GetFileNameWithoutExtension($f)
        if ($n -like '*_libretro' -and -not $seen.ContainsKey($n)) { $seen[$n] = $true; $script:RA_CORES += $n }
      }
    }
  }
  return $true
}
function Ra-Rule($core, $path, $rf) {
  foreach ($r in $script:RULES) {
    if ($core -match $r.cre -and $path -match $r.pre) { return $r }
  }
  return @{ rule = $(if ($rf -eq 'R') { 'REQ' } else { 'OPT' }); roms = ''; note = '' }
}
function Grp-Label($g) {
  switch (($g -split ':')[-1]) { 'psx' { 'PlayStation' } 'sat' { 'Saturn' } 'scd' { 'Sega CD' } '3do' { '3DO' } 'loader' { 'Neo Geo CD' } 'zoom' { 'Neo Geo CD' } 'font' { 'PC-98' } default { $script:GRP[$g].sys } }
}
function Ra-CoreDone {
  foreach ($k in @($script:CORE_HAS.Keys)) { if (-not $script:CORE_FAIL.ContainsKey($k)) { Mark-Ok $k } }
  $script:CORE_HAS = @{}; $script:CORE_FAIL = @{}
}
function Ra-FlushGroups {
  foreach ($g in @($script:GRP.Keys)) {
    $grp = $script:GRP[$g]; $rp = Rp $grp.roms
    $script:CUR_KEY = ($grp.roms -split ',')[0]
    $label = Grp-Label $g; $core = ($g -split ':')[0]
    $script:R = @{ note = $grp.note; file = ($grp.names -join ', ') }
    if ($grp.ok) {
      $script:R.kind = 'group_ok'; L-Info "satisfied: $(if ($grp.note) { $grp.note } else { 'one of the above' })"
      if ($grp.roms) { $script:CORE_HAS[$grp.roms] = $true }
    } elseif ($grp.fix) {
      $script:R.kind = 'group_fix'; L-Warn "not usable until you apply the fix above - $($grp.note)"
      if ($grp.roms) { $script:CORE_HAS[$grp.roms] = $true; $script:CORE_FAIL[$grp.roms] = $true }
      if ($rp -eq '1') { Add-Need "$label ($core): apply the rename/copy fix for its BIOS (see fix commands)" }
    } elseif ($rp -eq '1') {
      $script:CORE_HAS[$grp.roms] = $true; $script:CORE_FAIL[$grp.roms] = $true
      $script:R.kind = 'group_missing'; L-Bad "MISSING - $(if ($grp.note) { $grp.note } else { 'at least one is required' }) $(Rom-Note $grp.roms)"
      L-Sub "any of: $($grp.names -join ', ')"
      Add-Need "$label ($core): $(if ($grp.note) { $grp.note } else { 'one of: ' + ($grp.names -join ', ') }) -> $(Short $script:RA_SYS)$SEP"
    } else {
      $script:R.kind = 'group_later'; L-Opt "none present - $(if ($grp.note) { $grp.note } else { 'one is required' }) - needed once you add games"
      if (-not $ShowOptional) { L-Sub "any of: $($grp.names -join ', ')" }
    }
  }
  $script:GRP = [ordered]@{}
}
function Check-RetroArch {
  if (-not (Find-RetroArch)) { if ($All) { Hdr 'RetroArch' ''; L-Info 'RetroArch not found' }; return }
  Hdr 'RetroArch' ''
  L-Info "config: $(Short $script:RA_CFG)"
  L-Info "system/BIOS directory: $(Short $script:RA_SYS)"
  $sameDir = ($script:RA_SYS.TrimEnd('\', '/') -eq $script:BIOS.TrimEnd('\', '/'))
  if (-not $sameDir) {
    L-Warn "RetroArch's system directory is NOT your $($script:CTX) BIOS folder - cores look in $(Short $script:RA_SYS)"
    Add-Warn "RetroArch system_directory ($(Short $script:RA_SYS)) differs from $(Short $script:BIOS)"
  }
  if ($script:RA_CORES.Count -eq 0 -and -not $All) { L-Warn 'no cores found - nothing to check'; return }
  L-Info "$($script:RA_CORES.Count) cores installed"
  $saveBios = $script:BIOS
  if (-not $sameDir) { Build-Index $script:RA_SYS; $script:BIOS = $script:RA_SYS }
  $wanted = @{}; foreach ($c in $script:RA_CORES) { $wanted[$c] = $true }
  $script:GRP = [ordered]@{}; $last = ''; $done = @{}; $inst = $false
  foreach ($row in $script:RA_ROWS) {
    $core = $row.core
    if (-not $All -and -not $wanted.ContainsKey($core)) { continue }
    $rr = Ra-Rule $core $row.path $row.rf
    if ($rr.rule -eq 'SKIP') { $done[$core] = $true; continue }
    if ($core -ne $last) {
      Ra-FlushGroups; Ra-CoreDone
      $last = $core; $done[$core] = $true; $inst = $wanted.ContainsKey($core)
      Sub ($core -replace '_libretro$', '') "$($row.sys)  $(Rom-Note $rr.roms)"
    }
    $rp = Rp $rr.roms; if (-not $inst) { $rp = '0' }
    $script:CUR_KEY = ($rr.roms -split ',')[0]
    $want = JP $script:RA_SYS $row.path
    $short = $core -replace '_libretro$', ''
    if ($rr.rule -like 'ANY:*') {
      $g = "${core}:" + $rr.rule.Substring(4)
      if (-not $script:GRP.Contains($g)) { $script:GRP[$g] = @{ ok = $false; fix = $false; roms = $(if ($inst) { $rr.roms } else { '' }); note = $rr.note; sys = $row.sys; names = New-Object System.Collections.ArrayList } }
      [void]$script:GRP[$g].names.Add($row.path)
      $rc = Report-File $row.path $want $row.md5 'ANY' $rp $row.sys
      if ($rc -eq 0) { $script:GRP[$g].ok = $true } elseif ($rc -eq 2) { $script:GRP[$g].fix = $true }
    } elseif ($rr.rule -eq 'REQ') {
      $rc = Report-File $row.path $want $row.md5 'REQ' $rp "$($row.sys) ($short)" $rr.note
      if ($inst -and $rr.roms) { $script:CORE_HAS[$rr.roms] = $true; if ($rc -ne 0) { $script:CORE_FAIL[$rr.roms] = $true } }
    } elseif ($rr.rule -eq 'REC') {
      [void](Report-File $row.path $want $row.md5 'REC' $rp "$($row.sys) ($short)" $rr.note)
    } else {
      [void](Report-File $row.path $want $row.md5 'OPT' $rp $row.sys $rr.note)
    }
  }
  Ra-FlushGroups; Ra-CoreDone
  $nofw = 0; foreach ($c in $script:RA_CORES) { if (-not $done.ContainsKey($c)) { $nofw++ } }
  if ($nofw) { L-Info "$nofw other installed cores need no BIOS" }
  $script:BIOS = $saveBios
  if (-not $sameDir) { Build-Index $script:BIOS }
}

# --------------------------------------------------------------------------
function Check-Unknown {
  if (-not $Unknown) { return }
  Hdr 'Files in the BIOS folder that match nothing known' ''
  $n = 0
  foreach ($p in @($script:F_MD5.Keys)) {
    $m = $script:F_MD5[$p]
    if ($script:K.ContainsKey($m) -or $RA_DATA.Contains($m)) { continue }
    if ($p -match '\.(txt|md|json|xml|ini|cfg|dat|yml|zip|keys)$') { continue }
    L-Info "$(Short $p)  ($(Human (FSize $p)), md5 $m)"; $n++
  }
  if ($n -eq 0) { L-Ok 'nothing unrecognised (zips, keys and text files are skipped)' }
}

# ============================================================================
# Report / JSON / shortcut
# ============================================================================
$REPORT_TPL = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BIOS Checker</title>
<style>
  :root{
    --bg:#11161d; --panel:#1b232e; --panel2:#222c39; --line:#2e3a4a; --text:#e6edf5; --dim:#93a3b8;
    --blue:#1a9fff; --red:#ff5d5d; --yellow:#ffc53d; --green:#5cc84a; --grey:#7c8a9c;
  }
  *{box-sizing:border-box}
  html,body{margin:0;background:var(--bg);color:var(--text);font:17px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans",sans-serif}
  a{color:var(--blue)}
  code{font-family:ui-monospace,"DejaVu Sans Mono",monospace;font-size:.86em;background:#0d1218;border:1px solid var(--line);border-radius:5px;padding:1px 5px;word-break:break-all}
  abbr{text-decoration:underline dotted var(--dim);cursor:help}
  .wrap{max-width:1100px;margin:0 auto;padding:24px 20px 60px}
  header{display:flex;align-items:center;gap:14px;flex-wrap:wrap}
  header h1{margin:0;font-size:28px;letter-spacing:.3px}
  header .ver{color:var(--dim);font-size:14px}
  .ctx{color:var(--dim);font-size:14px;margin:6px 0 0}
  .ctx b{color:var(--text);font-weight:600}
  .banner{margin:22px 0 16px;padding:22px 24px;border-radius:14px;background:var(--panel);border-left:8px solid var(--green)}
  .banner.red{border-color:var(--red)} .banner.yellow{border-color:var(--yellow)}
  .banner h2{margin:0 0 6px;font-size:24px}
  .banner p{margin:0;color:var(--dim)}
  .chips{display:flex;gap:10px;flex-wrap:wrap;margin-top:14px}
  .chip{padding:6px 14px;border-radius:999px;background:var(--panel2);font-size:15px;cursor:pointer;border:2px solid transparent;user-select:none}
  .chip.on{border-color:var(--blue)}
  .chip .dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:7px;vertical-align:1px}
  .todo{margin:0 0 20px;padding:16px 20px;border-radius:12px;background:#2a1b1f;border:1px solid #5a2a31}
  .todo h3{margin:0 0 8px;font-size:18px;color:var(--red)}
  .todo ol{margin:0;padding-left:22px} .todo li{margin:4px 0}
  .todo a{color:var(--text);text-decoration:none;border-bottom:1px dashed var(--dim)}
  .toolbar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin:0 0 18px}
  button{font:inherit;font-size:15px;color:var(--text);background:var(--panel2);border:1px solid var(--line);border-radius:9px;padding:9px 16px;cursor:pointer;min-height:42px}
  button:hover{border-color:var(--blue)} button.primary{background:var(--blue);border-color:var(--blue);color:#fff;font-weight:600}
  label.tog{display:flex;align-items:center;gap:8px;color:var(--dim);font-size:15px;cursor:pointer;user-select:none}
  label.tog input{width:20px;height:20px}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(480px,1fr));gap:16px}
  @media (max-width:560px){.grid{grid-template-columns:1fr}}
  .card{background:var(--panel);border-radius:14px;padding:18px 20px;border-top:5px solid var(--green);scroll-margin-top:16px}
  .card.red{border-color:var(--red)} .card.yellow{border-color:var(--yellow)} .card.idle{border-color:var(--grey)}
  .card.flash{outline:3px solid var(--blue)}
  .card h3{margin:0;font-size:20px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
  .pill{font-size:13px;font-weight:700;padding:3px 10px;border-radius:999px;color:#111;white-space:nowrap}
  .pill.red{background:var(--red)} .pill.yellow{background:var(--yellow)} .pill.green{background:var(--green)} .pill.idle{background:var(--grey)}
  .emu{color:var(--dim);font-size:14px;margin-top:2px}
  .headline{margin:10px 0 8px;font-size:16px}
  .items{list-style:none;margin:0;padding:0}
  .items li{padding:8px 0 8px 32px;position:relative;border-top:1px solid var(--line);font-size:15.5px}
  .items li:first-child{border-top:none}
  .items li .ic{position:absolute;left:4px;top:8px;width:20px;text-align:center;font-weight:700}
  .ic.ok{color:var(--green)} .ic.bad{color:var(--red)} .ic.warn{color:var(--yellow)} .ic.info,.ic.opt{color:var(--grey)}
  .items li.subhead{padding-left:0;font-weight:700;color:var(--blue);border-top:none;margin-top:6px}
  .items li.note{color:var(--dim);font-size:14px}
  .small{color:var(--dim);font-size:13.5px;display:block;margin-top:2px}
  .fix{display:flex;gap:8px;align-items:flex-start;margin:6px 0 2px;background:#0d1218;border:1px solid var(--line);border-radius:8px;padding:8px 10px}
  .fix code{flex:1;background:none;border:none;padding:0;font-size:13px}
  .fix button{padding:4px 12px;min-height:32px;font-size:13px}
  details{margin-top:10px} summary{cursor:pointer;color:var(--dim);font-size:14px;user-select:none}
  details .help{margin:8px 0 0;font-size:15px;line-height:1.55}
  details pre{white-space:pre-wrap;font-size:12.5px;color:var(--dim);background:#0d1218;border-radius:8px;padding:10px;margin:8px 0 0;font-family:ui-monospace,"DejaVu Sans Mono",monospace}
  .group-title{margin:30px 0 12px;font-size:15px;letter-spacing:1px;text-transform:uppercase;color:var(--dim)}
  .howto{margin-top:30px;background:var(--panel);border-radius:14px;padding:18px 22px;font-size:15.5px}
  .howto h3{margin:0 0 8px}
  footer{margin-top:28px;color:var(--dim);font-size:13px;text-align:center}
  .toast{position:fixed;bottom:22px;left:50%;transform:translateX(-50%);background:var(--blue);color:#fff;padding:10px 20px;border-radius:999px;font-weight:600;opacity:0;transition:opacity .2s;pointer-events:none}
  .toast.show{opacity:1}
  .hidden{display:none!important}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>BIOS Checker</h1><span class="ver" id="ver"></span>
  </header>
  <div class="ctx" id="ctx"></div>

  <div class="banner" id="banner"><h2 id="bannerTitle"></h2><p id="bannerText"></p>
    <div class="chips" id="chips"></div>
  </div>

  <div class="todo hidden" id="todo"><h3>To do</h3><ol id="todoList"></ol></div>

  <div class="toolbar">
    <button class="primary hidden" id="btnCopyAll">Copy all fixes</button>
    <button class="hidden" id="btnSave">Save fixes as a script</button>
    <label class="tog"><input type="checkbox" id="optOptional"> Show optional extras</label>
    <label class="tog"><input type="checkbox" id="optTech"> Show technical details</label>
  </div>

  <div id="cards"></div>

  <div class="howto" id="howto"></div>
  <footer id="foot"></footer>
</div>
<div class="toast" id="toast">Copied</div>

<script type="application/json" id="data">@@DATA@@</script>
<script>
"use strict";
const D = JSON.parse(document.getElementById('data').textContent);
const WIN = D.platform === 'windows';
const SHELL = WIN ? 'PowerShell' : 'Konsole';
const PASTE = WIN ? 'right-click (or Ctrl+V)' : 'Ctrl+Shift+V';
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const base = p => String(p||'').split('/').pop();

// ---------- plain-language glossary (hover / tap) ----------
const GLOSS = [
  ['prod.keys','The Switch decryption keys, dumped from your own Switch. Emulators need them to read Switch games.'],
  ['title.keys','Optional Switch keys for individual games/DLC.'],
  ['keys.txt','A text file of Wii U disc keys. Only needed for encrypted .wud/.wux disc images.'],
  ['aes_keys.txt','3DS decryption keys. Only needed for encrypted 3DS game dumps.'],
  ['firmware','The console\'s own system software. Some emulators need it installed before games run.'],
  ['BIOS','The console\'s startup chip. Many emulators need a copy of it (a "BIOS file") to start games.'],
  ['NCAs?','The individual files a Switch firmware is made of.'],
  ['MCPX','The original Xbox\'s tiny secret boot chip. xemu needs a dump of version 1.0.'],
  ['flash ROM','The original Xbox\'s main BIOS chip.'],
  ['qcow2','The disk-image format xemu uses for the Xbox hard drive.'],
  ['HDD image','A file that acts as the console\'s hard drive.'],
  ['EEPROM','A small settings chip. xemu creates one automatically.'],
  ['IPL','The GameCube boot menu/animation. Optional.'],
  ['HLE','"High-level emulation" - the emulator fakes the BIOS itself. Works for most games, a real BIOS works for all.'],
  ['FreeBIOS','melonDS\'s built-in replacement for the DS BIOS.'],
  ['hash','A fingerprint of a file\'s contents. Matching fingerprints prove you have the exact right file.'],
  ['md5','A type of file fingerprint (hash).'],
  ['ROMVER','A version tag stored inside every PS2 BIOS.'],
  ['PUP','Sony\'s official system-update file. You install it from inside the emulator.'],
  ['dev_flash','Where RPCS3 keeps the installed PS3 system software.'],
  ['symlink','A shortcut that points to another folder. EmuDeck uses these to link emulator folders into your bios folder.'],
  ['Kickstarts?','The Amiga\'s built-in ROM (its BIOS).'],
  ['AROS','A free stand-in for the Amiga Kickstart. Works for some games, not all.'],
  ['Y-ZOOM','A small ROM the Neo Geo CD needs for scaling graphics.'],
  ['LLE','"Low-level emulation" - using real system files instead of fakes.'],
  ['region','Where a console was sold (US, Europe, Japan). Some emulators want the BIOS that matches each game\'s region.'],
  ['case-sensitive','On Linux and the Steam Deck, "BIOS.BIN" and "bios.bin" are two different names.'],
  ['OneDrive','Microsoft\'s cloud sync. "Online-only" files are not really on your PC, so emulators can\'t read them.'],
  ['junction','A Windows folder shortcut. EmuDeck uses these to link emulator folders to your bios folder.'],
  ['core','A RetroArch "core" is one emulator running inside RetroArch.'],
];
const GLOSS_RE = new RegExp('\\b(' + GLOSS.map(g => g[0]).join('|') + ')\\b', 'g');
function gloss(text){
  return esc(text).replace(GLOSS_RE, m => {
    const g = GLOSS.find(([k]) => new RegExp('^' + k + '$').test(m));
    return g ? `<abbr title="${esc(g[1])}">${m}</abbr>` : m;
  });
}

// ---------- what each system needs, in plain words ----------
const HELP = [
  [/hygiene/i, 'General problems in your BIOS folder that confuse emulators: leftover Windows files, zipped BIOS that need unzipping, empty files, broken shortcuts and duplicate names that only differ in capital letters.'],
  [/PlayStation 2|PCSX2|LRPS2/i, 'PS2 emulation needs a dump of the PS2 BIOS. The filename does not matter for PCSX2 - it reads the file itself. Any region boots any game. It must be the full 4 MiB dump.'],
  [/PlayStation 3|RPCS3/i, 'RPCS3 needs the PS3 system software (PS3UPDAT.PUP), which Sony offers as a free official download. Install it once inside RPCS3: File - Install Firmware.'],
  [/PlayStation Vita|Vita3K/i, 'Vita3K needs the Vita system software (PSVUPDAT.PUP) and the separate font package (PSP2UPDAT.PUP), both official Sony downloads. Install both inside Vita3K: File - Install Firmware.'],
  [/PlayStation 4|shadPS4/i, 'shadPS4 needs no BIOS. A few games run better with extra system modules copied from your own PS4.'],
  [/PlayStation|DuckStation|swanstation|psx|pcsx_rearmed/i, 'PS1 emulation needs a PS1 BIOS. DuckStation recognises any PS1 BIOS by its contents, so the name does not matter. RetroArch cores need exact names: scph5501.bin (US), scph5502.bin (Europe), scph5500.bin (Japan). Having one per region you play is ideal.'],
  [/Switch|Citron|Ryujinx|Yuzu|Eden|Suyu|Sudachi/i, 'Switch emulators need two things from your own Switch: prod.keys (decryption keys) and the firmware (system files). Keys must be from the same firmware version or newer. Ryujinx installs firmware through its menu: Tools - Install Firmware.'],
  [/Xbox|xemu/i, 'xemu needs three files: the MCPX 1.0 boot ROM, the flash BIOS (Complex 4627 is the usual one) and an Xbox hard-drive image. xemu\'s website offers a ready-made hard-drive image.'],
  [/Wii U|Cemu/i, 'Cemu needs no BIOS. keys.txt is only needed for encrypted disc images (.wud/.wux). Decrypted games and .wua files work without it.'],
  [/3DS|Azahar|citra/i, 'Azahar needs no BIOS. aes_keys.txt only matters for encrypted dumps.'],
  [/GameCube|Dolphin/i, 'Dolphin needs no BIOS. The IPL.bin file only adds the original GameCube boot animation and menu.'],
  [/Nintendo DS|melonDS|desmume/i, 'melonDS has its own built-in BIOS that works for most games. The real files (bios7.bin, bios9.bin, firmware.bin) give the best compatibility. DSi mode needs all the DSi files.'],
  [/Dreamcast|NAOMI|Atomiswave|flycast/i, 'Flycast can run most Dreamcast games without a BIOS. The real dc_boot.bin helps the few that need it. NAOMI and Atomiswave arcade games always need their BIOS zip (naomi.zip, naomi2.zip, awbios.zip).'],
  [/Sega CD|genesis|picodrive|Sega 8/i, 'Genesis games need no BIOS. Sega CD games need the Sega CD BIOS matching the game\'s region: bios_CD_U.bin (US), bios_CD_E.bin (Europe), bios_CD_J.bin (Japan).'],
  [/Saturn|kronos|yaba|mednafen_saturn/i, 'Beetle Saturn needs mpr-17933.bin for US/European games and sega_101.bin for Japanese games. Kronos uses kronos/saturn_bios.bin.'],
  [/Neo Geo CD|neocd/i, 'The Neo Geo CD core needs two files in bios/neocd: one CD system BIOS (front loader, top loader or CDZ) and the Y-ZOOM ROM (ng-lo.rom or 000-lo.lo).'],
  [/Neo Geo|neogeo/i, 'Every Neo Geo game needs neogeo.zip. Keep a copy in the same folder as your Neo Geo games.'],
  [/64DD|RMG|mupen/i, 'The 64DD (a Japanese N64 add-on) needs its IPL BIOS. Regular N64 games need nothing.'],
  [/3DO|opera/i, 'The 3DO needs one 3DO BIOS. panafz10.bin is the usual choice.'],
  [/Amiga|puae/i, 'Amiga games run best with real Kickstart ROMs (kick34005.A500 for most A500 games, kick40068.A1200 for A1200/WHDLoad). Without them RetroArch uses AROS, which breaks many games.'],
  [/Disk System|mesen|nestopia|fceumm/i, 'Regular NES games need nothing. Famicom Disk System games need disksys.rom.'],
  [/PC Engine|TurboGrafx|pce/i, 'Regular PC Engine/TurboGrafx games need nothing. CD games need syscard3.pce.'],
  [/RetroArch/i, 'RetroArch looks for all BIOS files in its "system" folder. On EmuDeck and RetroDECK that is your bios folder.'],
  [/hygiene|BIOS folder/i, 'General problems in your BIOS folder that confuse emulators.'],
];
const help = t => (HELP.find(([re]) => re.test(t)) || [null, ''])[1];

const CORE_NAMES = {
  swanstation:'PlayStation', mednafen_psx_hw:'PlayStation', mednafen_psx:'PlayStation', pcsx_rearmed:'PlayStation',
  mednafen_saturn:'Sega Saturn', kronos:'Sega Saturn', yabasanshiro:'Sega Saturn', yabause:'Sega Saturn',
  genesis_plus_gx:'Sega Genesis / Sega CD', genesis_plus_gx_wide:'Sega Genesis / Sega CD (widescreen)', picodrive:'Sega Genesis / 32X / Sega CD',
  flycast:'Dreamcast / NAOMI / Atomiswave', neocd:'Neo Geo CD', opera:'3DO', puae:'Amiga', puae2021:'Amiga',
  mesen:'NES / Famicom Disk System', nestopia:'NES / Famicom Disk System', fceumm:'NES / Famicom Disk System',
  snes9x:'Super Nintendo (Satellaview / Sufami Turbo)', bsnes:'Super Nintendo', 'mesen-s':'Super Nintendo / Game Boy',
  mednafen_pce:'PC Engine / TurboGrafx-CD', mednafen_pce_fast:'PC Engine / TurboGrafx-CD', mednafen_supergrafx:'PC Engine SuperGrafx',
  melonds:'Nintendo DS', melondsds:'Nintendo DS', desmume:'Nintendo DS', mupen64plus_next:'Nintendo 64 / 64DD',
  mgba:'Game Boy Advance', gambatte:'Game Boy / Color', sameboy:'Game Boy / Color', gearboy:'Game Boy / Color',
  same_cdi:'Philips CD-i', handy:'Atari Lynx', mednafen_lynx:'Atari Lynx', mednafen_pcfx:'PC-FX', a5200:'Atari 5200',
  atari800:'Atari 800 / 5200', prosystem:'Atari 7800', hatari:'Atari ST', freeintv:'Intellivision', gearcoleco:'ColecoVision',
  bluemsx:'MSX', fmsx:'MSX', px68k:'Sharp X68000', np2kai:'NEC PC-98', quasi88:'NEC PC-88', minivmac:'Macintosh',
  o2em:'Odyssey 2 / Videopac', freechaf:'Channel F', pokemini:'Pokemon Mini', ppsspp:'PSP', dolphin:'GameCube / Wii',
  fbneo:'Arcade (FinalBurn Neo)', prboom:'Doom', citra:'Nintendo 3DS', vice_x64sc:'Commodore 64',
};
const REGION = {US:'US', EU:'European', JP:'Japanese', ALL:'region-free', ASIA:'Asian', CN:'Chinese', RU:'Russian', KR:'Korean', 'US/EU':'US/European'};

function parseGames(s){
  if (!s) return {n:null, dir:''};
  const m = s.match(/\[(\d+)\+? game files in (roms\/[^\]]*)\]/); if (m) return {n:+m[1], dir:m[2].replace(/ \| /g,', ')};
  const z = s.match(/\[no games in (roms\/[^\]]*)\]/); if (z) return {n:0, dir:z[1].replace(/ \| /g,', ')};
  return {n:null, dir:''};
}

// ---------- turn a raw event into a friendly line ----------
const B = s => `<b>${esc(s)}</b>`;
const C = s => `<code>${esc(s)}</code>`;
const noteTxt = e => e.note ? `<span class="small">${gloss(e.note)}</span>` : '';
function friendly(e){
  const f = e.file, k = e.kind;
  switch(k){
    case 'ok': return ['ok', `${B(f)} is the right file.<span class="small">${esc(e.what)}</span>`];
    case 'present': return ['ok', `${B(f)} is there.<span class="small">There's no reference fingerprint for this one (it's often unique to each console), so only its presence is checked.</span>`];
    case 'zipok': return ['ok', `${B(f)} is there and not damaged.`];
    case 'bios_found': return ['ok', `Found a ${esc(REGION[e.note]||e.note)} BIOS: ${B(f)}<span class="small">${esc(e.what)}</span>`];
    case 'wrongfile': return ['bad', `${B(f)} is the <b>wrong file</b>. It is really: ${B(e.what)}. Replace it with the correct one.`];
    case 'badhash': return ['warn', `${B(f)} is a different version than expected (${esc(e.what)}). It will probably work - if games act strange, replace it with a known-good dump.`];
    case 'case': return ['warn', `${B(f)} is there, but spelled with different capital letters (${C(base(e.found))}). Linux is <abbr title="On the Deck, &quot;BIOS.BIN&quot; and &quot;bios.bin&quot; are two different names.">case-sensitive</abbr>, so the emulator can't see it. The fix below renames it.`];
    case 'elsewhere': return ['warn', `You have ${B(f)}, but it's in the wrong place: ${C(e.found)}. The emulator looks in ${C(e.want)}. The fix below copies it there.`];
    case 'doubleext': return ['warn', `${B(f)} is there, but its real name is ${C(base(e.found))}. Windows hides file extensions by default, so the extra one is easy to miss. The fix below renames it.`];
    case 'cloudonly': return ['bad', `${B(f)} is only in <abbr title="Microsoft's cloud sync. Online-only files are not really on your PC.">OneDrive</abbr>, not actually on this PC. Right-click it in File Explorer and choose <b>Always keep on this device</b>.`];
    case 'empty': return ['bad', `${B(f)} is an empty file (0 bytes) - the copy probably failed. Copy it again.`];
    case 'broken': return ['bad', `${B(f)} is a broken shortcut that points nowhere.`];
    case 'missing_req': return ['bad', `Missing ${B(f)}. You have games for this, so you need it. It goes here: ${C(e.want)}${noteTxt(e)}`];
    case 'missing_rec': return ['warn', `Recommended: ${B(f)} - goes in ${C(e.want)}${noteTxt(e)}`];
    case 'missing_later': return ['opt', `${B(f)} - you'll need this when you add games. It goes in ${C(e.want)}${noteTxt(e)}`];
    case 'missing_opt': return ['opt', `Optional: ${B(f)}${noteTxt(e)}`, 'optional'];
    case 'group_ok': return ['ok', `Requirement met${e.note ? ': ' + gloss(e.note) : ''}`];
    case 'group_missing': return ['bad', `You need <b>at least one</b> of these: ${e.file.split(', ').map(C).join(' ')}${noteTxt(e)}`];
    case 'group_fix': return ['warn', `The file you need is there, but not usable until you run the fix above.`];
    case 'group_later': return ['opt', `When you add games you'll need one of: ${e.file.split(', ').map(C).join(' ')}${noteTxt(e)}`];
  }
  return [e.lvl, gloss(e.text)];
}

// ---------- build cards ----------
const needs = D.needs || [], warns = D.warns || [];
const cards = [];
for (const s of D.sections){
  if (/^SUMMARY$/.test(s.title)) continue;
  const evs = D.events.filter(e => e.sec === s.id);
  const isRA = /^RetroArch$/.test(s.title);
  const groups = new Map();
  for (const e of evs){
    const key = isRA ? e.sub : '';
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(e);
  }
  if (!groups.size) groups.set('', []);
  for (const [sub, list] of groups){
    let title, emu, gamesStr;
    if (isRA && sub){
      const sysd = (list[0].subd || '').split('  [')[0].trim();
      title = CORE_NAMES[sub] || sysd || sub;
      emu = 'RetroArch - ' + sub + ' core';
      gamesStr = (list[0].subd || '').includes('[') ? '[' + list[0].subd.split('  [')[1] : '';
    } else if (isRA){
      title = 'RetroArch setup'; emu = 'RetroArch'; gamesStr = '';
    } else if (/hygiene/i.test(s.title)){
      title = 'Your BIOS folder'; emu = 'General checks'; gamesStr = '';
    } else if (/^Arcade - Neo Geo/.test(s.title)){
      title = 'Neo Geo'; emu = 'Arcade BIOS (neogeo.zip)'; gamesStr = s.games;
    } else {
      const parts = s.title.split(' - ');
      title = parts[0].replace(/^(Sony|Microsoft) /, ''); emu = parts.slice(1).join(' - '); gamesStr = s.games;
    }
    let g = parseGames(gamesStr);
    if (g.n === null) for (const e of list){ const x = parseGames(e.text); if (x.n !== null){ g = x; break; } }
    const match = x => x.sec === s.id && (!isRA || (x.sub || '') === sub);
    const cn = needs.filter(match), cw = warns.filter(match);
    const hasBadLine = list.some(e => e.lvl === 'bad' && e.kind !== 'missing_opt');
    const hasWarnLine = list.some(e => e.lvl === 'warn');
    let level = cn.length ? 'red' : (cw.length || hasWarnLine || (hasBadLine && g.n !== 0)) ? 'yellow' : 'green';
    if (level !== 'red' && g.n === 0) level = 'idle';
    if (level === 'green' && g.n === null && list.length && list.every(e => ['opt','sub','fix'].includes(e.lvl) || ['missing_later','group_later','missing_opt'].includes(e.kind))) level = 'idle';
    if (s.notinst) level = 'idle';
    cards.push({id:'c' + cards.length, title, emu, ctx:s.ctx, g, level, list, needs:cn, notinst:s.notinst, sectionTitle:s.title + ' ' + sub});
  }
}

const ORDER = {red:0, yellow:1, green:2, idle:3};
cards.sort((a,b) => ORDER[a.level] - ORDER[b.level] || a.title.localeCompare(b.title));
const PILL = {red:'Needs attention', yellow:'Check this', green:'Ready', idle:'No games yet'};
const HEAD = {
  red: c => c.g.n ? `You have ${c.g.n} game file${c.g.n>1?'s':''} for this, and they won't start until this is fixed.` : 'Something required is missing.',
  yellow: c => 'Should work - but there is something worth a look.',
  green: c => c.g.n ? 'Ready to play.' : 'All good.',
  idle: c => c.notinst ? 'This emulator is not installed (shown because of --all).' : `No games in ${esc(c.g.dir || 'its roms folder')} yet. Here's what you'll need when you add some.`,
};

function renderCard(c){
  const el = document.createElement('div');
  el.className = 'card ' + c.level; el.id = c.id; el.dataset.level = c.level;
  let html = `<h3>${esc(c.title)} <span class="pill ${c.level}">${PILL[c.level]}</span></h3>`;
  const meta = [c.emu, D.contexts.length > 1 ? c.ctx : '', c.g.n ? c.g.n + ' game file' + (c.g.n>1?'s':'') : ''].filter(Boolean);
  html += `<div class="emu">${esc(meta.join(' - '))}</div>`;
  html += `<div class="headline">${HEAD[c.level](c)}</div><ul class="items">`;
  const raw = []; let lastSub = null, lastKind = '';
  for (const e of c.list){
    if (!/^RetroArch/.test(c.emu) && e.sub && e.sub !== lastSub){ lastSub = e.sub; html += `<li class="subhead">${esc(e.sub)}</li>`; }
    if (e.lvl === 'sub' && /^any of:/.test(e.text) && /^group_/.test(lastKind)){ raw.push(e.text); continue; }
    lastKind = e.kind;
    raw.push((e.lvl === 'fix' ? '    -> ' : '') + e.text);
    if (e.lvl === 'fix'){
      html += `<li class="nobullet" style="padding-left:32px"><div class="fix"><code>${esc(e.text)}</code><button data-copy="${esc(e.text)}">Copy</button></div></li>`;
      continue;
    }
    if (e.lvl === 'sub' && !e.kind){ html += `<li class="note" style="padding-left:32px">${gloss(e.text)}</li>`; continue; }
    const [lvl, txt, tag] = friendly(e);
    const icon = {ok:'✔', bad:'✘', warn:'!', info:'•', opt:'○', sub:'•'}[lvl] || '•';
    const cls = tag === 'optional' || (e.lvl === 'opt' && e.kind === 'missing_opt') ? ' class="optional"' : (lvl === 'info' ? ' class="note"' : '');
    html += `<li${cls}><span class="ic ${lvl}">${icon}</span>${txt}</li>`;
  }
  if (!c.list.length) html += `<li class="note">Nothing to report.</li>`;
  html += `</ul>`;
  const h = help(c.title + ' ' + c.emu + ' ' + c.sectionTitle);
  if (h) html += `<details><summary>What does this system need?</summary><div class="help">${gloss(h)}</div></details>`;
  html += `<details class="tech hidden"><summary>Technical details</summary><pre>${esc(raw.join('\n'))}</pre></details>`;
  el.innerHTML = html;
  return el;
}

// ---------- page ----------
$('#ver').textContent = 'v' + D.version + ' - checked ' + D.generated;
$('#ctx').innerHTML = D.contexts.map(c =>
  `Checked your <b>${esc(c.name)}</b> setup - BIOS folder ${C(c.bios)}${c.roms ? ', games in ' + C(c.roms) : ''}${c.note ? '<br><span style="color:var(--yellow)">' + esc(c.note) + '</span>' : ''}`).join('<br>');

const n = {red:0, yellow:0, green:0, idle:0}; cards.forEach(c => n[c.level]++);
const banner = $('#banner');
if (!D.contexts.length){
  banner.className = 'banner red'; $('#bannerTitle').textContent = 'No EmuDeck or RetroDECK setup found';
  $('#bannerText').textContent = WIN ? 'Run the script from PowerShell with -Bios to point it at your BIOS folder.' : 'Run the script from Konsole with --bios to point it at your BIOS folder.';
} else if (n.red){
  banner.className = 'banner red';
  $('#bannerTitle').textContent = `${n.red} system${n.red>1?'s need':' needs'} something before ${n.red>1?'their':'its'} games will run`;
  $('#bannerText').textContent = 'Start with the red cards. Each one says exactly which file is missing and where it goes.';
} else if (n.yellow){
  banner.className = 'banner yellow';
  $('#bannerTitle').textContent = 'Everything you have games for should run';
  $('#bannerText').textContent = 'A few things are worth a look - see the yellow cards.';
} else {
  banner.className = 'banner';
  $('#bannerTitle').textContent = 'You\'re all set';
  $('#bannerText').textContent = 'Every system you have games for has what it needs.';
}

let filter = 'all';
const chipDefs = [['all','All', '#93a3b8', cards.length], ['red','Needs attention','var(--red)', n.red], ['yellow','Check this','var(--yellow)', n.yellow], ['green','Ready','var(--green)', n.green], ['idle','No games yet','var(--grey)', n.idle]];
$('#chips').innerHTML = chipDefs.filter(d => d[3] || d[0] === 'all').map(([k,l,col,cnt]) =>
  `<span class="chip${k==='all'?' on':''}" data-f="${k}"><span class="dot" style="background:${col}"></span>${l}: ${cnt}</span>`).join('');
$('#chips').addEventListener('click', ev => {
  const ch = ev.target.closest('.chip'); if (!ch) return;
  filter = ch.dataset.f; document.querySelectorAll('.chip').forEach(x => x.classList.toggle('on', x === ch)); applyFilters();
});

// to-do list from blocking needs
const todo = [];
for (const c of cards) for (const nd of c.needs) todo.push([c, nd.text]);
const orphan = needs.filter(nd => !cards.some(c => c.needs.includes(nd)));
if (todo.length || orphan.length){
  $('#todo').classList.remove('hidden');
  $('#todoList').innerHTML = todo.map(([c,t]) => `<li><a href="#${c.id}" data-jump="${c.id}"><b>${esc(c.title)}</b></a> - ${gloss(t.replace(/^[^:]*:\s*/, ''))}</li>`).join('')
    + orphan.map(nd => `<li>${gloss(nd.text)}</li>`).join('');
}
document.addEventListener('click', ev => {
  const j = ev.target.closest('[data-jump]');
  if (j){ ev.preventDefault(); const el = document.getElementById(j.dataset.jump); filter='all'; applyFilters(); el.scrollIntoView({behavior:'smooth'}); el.classList.add('flash'); setTimeout(() => el.classList.remove('flash'), 1500); }
  const b = ev.target.closest('[data-copy]'); if (b) copy(b.dataset.copy);
});

// cards, grouped
const wrap = $('#cards');
const GROUPS = [['red','Needs attention'], ['yellow','Worth a look'], ['green','Ready'], ['idle','No games yet']];
for (const [lvl, label] of GROUPS){
  const list = cards.filter(c => c.level === lvl); if (!list.length) continue;
  const sec = document.createElement('section'); sec.dataset.level = lvl;
  sec.innerHTML = `<div class="group-title">${label}</div>`;
  const grid = document.createElement('div'); grid.className = 'grid';
  list.forEach(c => grid.appendChild(renderCard(c)));
  sec.appendChild(grid); wrap.appendChild(sec);
}

function applyFilters(){
  document.querySelectorAll('#cards section').forEach(s => s.classList.toggle('hidden', filter !== 'all' && s.dataset.level !== filter));
  document.querySelectorAll('.chip').forEach(x => x.classList.toggle('on', x.dataset.f === filter));
  const opt = $('#optOptional').checked, tech = $('#optTech').checked;
  document.querySelectorAll('li.optional').forEach(li => li.classList.toggle('hidden', !opt));
  document.querySelectorAll('details.tech').forEach(d => d.classList.toggle('hidden', !tech));
}
$('#optOptional').addEventListener('change', applyFilters);
$('#optTech').addEventListener('change', applyFilters);
applyFilters();

// fixes
const fixes = D.fixes || [];
if (fixes.length){
  $('#btnCopyAll').classList.remove('hidden'); $('#btnSave').classList.remove('hidden');
  $('#btnCopyAll').textContent = `Copy all fixes (${fixes.length})`;
}
const script = () => WIN
  ? '# BIOS Checker fixes - ' + D.generated + '\r\n# Copies never overwrite existing files.\r\n' + fixes.join('\r\n') + '\r\n'
  : '#!/usr/bin/env bash\n# BIOS Checker fixes - ' + D.generated + '\n# cp -n / mv -n never overwrite existing files.\n' + fixes.join('\n') + '\n';
$('#howto').innerHTML = WIN
  ? `<h3>How to use a fix</h3>Each fix is one PowerShell command that copies or renames a file. Copies never overwrite an existing file; the only deletions are download junk files (<code>Zone.Identifier</code>).
     <ol><li>Press <b>Copy</b> next to the fix (or <b>Copy all fixes</b> at the top).</li>
     <li>Open <b>PowerShell</b> (Start menu - type <i>PowerShell</i>).</li>
     <li>Right-click (or Ctrl+V) to paste, then press <b>Enter</b>.</li>
     <li>Run BIOS Checker again to confirm.</li></ol>
     BIOS, firmware and keys must be dumped from hardware you own. This tool never downloads or shares them.`
  : `<h3>How to use a fix</h3>Each fix is a single command that copies or renames a file. Fixes never overwrite anything (<code>cp -n</code> / <code>mv -n</code>); the only deletions are Windows junk files (<code>Zone.Identifier</code>).
     <ol><li>Press <b>Copy</b> next to the fix (or <b>Copy all fixes</b> at the top).</li>
     <li>Open <b>Konsole</b> (Desktop Mode - application menu - System - Konsole).</li>
     <li>Paste with <b>Ctrl+Shift+V</b> and press <b>Enter</b>.</li>
     <li>Run BIOS Checker again to confirm.</li></ol>
     BIOS, firmware and keys must be dumped from hardware you own. This tool never downloads or shares them.`;
$('#btnCopyAll').addEventListener('click', () => copy(fixes.join('\n')));
$('#btnSave').addEventListener('click', () => {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([script()], {type:'text/plain'}));
  a.download = WIN ? 'bios-fixes.ps1' : 'bios-fixes.sh'; document.body.appendChild(a); a.click(); a.remove();
  toast(WIN ? 'Saved bios-fixes.ps1 to Downloads - right-click it > Run with PowerShell' : 'Saved bios-fixes.sh to Downloads - run it with: bash ~/Downloads/bios-fixes.sh');
});
async function copy(t){
  try { await navigator.clipboard.writeText(t); }
  catch(e){ const a = document.createElement('textarea'); a.value = t; document.body.appendChild(a); a.select(); document.execCommand('copy'); a.remove(); }
  toast(`Copied - paste into ${SHELL} with ${PASTE}`);
}
function toast(msg){ const t = $('#toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('show'), 2600); }
$('#foot').innerHTML = `deck-bios-check v${esc(D.version)} - <a href="https://github.com/darkuni/emudeck-bios-validation-script">github.com/darkuni/emudeck-bios-validation-script</a>`;
</script>
</body>
</html>
'@
function Build-Json {
  $o = [ordered]@{
    tool = 'deck-bios-check'; platform = $(if ($IsWin) { 'windows' } else { 'linux' }); version = $VERSION
    generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    counts = [ordered]@{ ok = $script:CNT_OK; need = $script:NEEDS.Count; warn = $script:WARNS.Count; fix = $script:FIXES.Count }
    all = [bool]$All; contexts = $script:CTXS; sections = $script:SECS; events = $script:EV
    needs = $script:NEEDS; warns = $script:WARNS; fixes = $script:FIXES
  }
  return (ConvertTo-Json -InputObject $o -Depth 6 -Compress)
}
function Write-Utf8($path, $text) {
  $d = [IO.Path]::GetDirectoryName($path); if ($d -and -not (IsDir $d)) { [void](New-Item -ItemType Directory -Force -Path $d) }
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}
function Do-Shortcut([bool]$install) {
  $dir = JP $LAD 'deck-bios-check'; $target = JP $dir 'deck-bios-check.ps1'
  $desk = [Environment]::GetFolderPath('Desktop'); $start = JP $AD 'Microsoft/Windows/Start Menu/Programs'
  $lnks = @((JP $desk 'BIOS Checker.lnk'), (JP $start 'BIOS Checker.lnk'))
  if (-not $install) {
    foreach ($l in $lnks) { if (IsFile $l) { Remove-Item -LiteralPath $l -Force } }
    if (IsDir $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Write-Host 'BIOS Checker shortcut removed.'; return 0
  }
  [void](New-Item -ItemType Directory -Force -Path $dir)
  if ($PSCommandPath) { if ($PSCommandPath -ne $target) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force } }
  else { [IO.File]::WriteAllText($target, $script:SELF_SB.ToString(), (New-Object Text.UTF8Encoding $true)) }
  try { Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue } catch {}
  if (-not $IsWin) { Write-Host "Shortcuts are Windows-only. Script saved to $target"; return 0 }
  $ps = JP $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
  $sh = New-Object -ComObject WScript.Shell
  foreach ($l in $lnks) {
    $ld = [IO.Path]::GetDirectoryName($l); if (-not (IsDir $ld)) { continue }
    $s = $sh.CreateShortcut($l)
    $s.TargetPath = $ps
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -Report"
    $s.WorkingDirectory = $dir
    $s.IconLocation = (JP $env:SystemRoot 'System32/shell32.dll') + ',22'
    $s.Description = 'Checks your emulator BIOS, firmware and keys and explains what is missing'
    $s.Save()
  }
  Write-Host 'Installed:'
  Write-Host "  desktop:     $($lnks[0])"
  Write-Host "  Start menu:  $($lnks[1])"
  Write-Host "  script:      $target"
  Write-Host "Double-click 'BIOS Checker' to get the friendly report. Remove with -UninstallShortcut."
  return 0
}

# ============================================================================
# MAIN
# ============================================================================
function Finish($code) { if ($PSCommandPath) { exit $code } else { $global:LASTEXITCODE = $code } }

if ($InstallShortcut -or $UninstallShortcut) { [void](Do-Shortcut ([bool]$InstallShortcut)); Finish 0; return }
if ($Json -or $Report) { $script:REC = $true }

# contexts: name, bios, roms, storage, saves, emus, settings, note
$contexts = @()
if ($Bios) {
  $b = [IO.Path]::GetFullPath($Bios).TrimEnd('\', '/'); $parent = [IO.Path]::GetDirectoryName($b)
  $romsArg = $(if ($Roms) { [IO.Path]::GetFullPath($Roms) } elseif (IsDir (JP $parent 'roms')) { JP $parent 'roms' } else { '' })
  $contexts += @{ name = 'custom'; bios = $b; roms = $romsArg; storage = (JP $parent 'storage'); saves = (JP $parent 'saves'); emus = $(if (IsDir (JP $AD 'EmuDeck/Emulators')) { JP $AD 'EmuDeck/Emulators' } else { '' }); settings = ''; note = '' }
} else {
  $s = FirstExisting (JP $AD 'EmuDeck/settings.ps1') (JP $UP 'EmuDeck/settings.ps1')
  $emu = ''; $note = ''
  if ($s) { $emu = PsVar $s 'emulationPath' '' }
  if (-not $emu -and (IsDir 'C:\Emulation')) { $emu = 'C:\Emulation' }
  if ($s -or (IsDir (JP $AD 'EmuDeck/Emulators'))) {
    if (-not $emu) { $emu = 'C:\Emulation' }
    $emu = JP $emu
    $bp = $(if ($s) { PsVar $s 'biosPath' $emu } else { '' }); if (-not $bp) { $bp = JP $emu 'bios' }
    $rp_ = $(if ($s) { PsVar $s 'romsPath' $emu } else { '' }); if (-not $rp_) { $rp_ = JP $emu 'roms' }
    $sp = $(if ($s) { PsVar $s 'storagePath' $emu } else { '' }); if (-not $sp) { $sp = JP $emu 'storage' }
    $vp = $(if ($s) { PsVar $s 'savesPath' $emu } else { '' }); if (-not $vp) { $vp = JP $emu 'saves' }
    $contexts += @{ name = 'EmuDeck'; bios = (JP $bp); roms = (JP $rp_); storage = (JP $sp); saves = (JP $vp); emus = (JP $AD 'EmuDeck/Emulators'); settings = $(if ($s) { $s } else { '(settings.ps1 not found - assumed C:\Emulation)' }); note = $note }
  }
}
if ($contexts.Count -eq 0) {
  $script:EMUS = ''
  if (Find-RetroArch) {
    $contexts += @{ name = 'RetroArch'; bios = $script:RA_SYS; roms = ''; storage = ''; saves = ''; emus = ''; settings = $script:RA_CFG; note = 'No EmuDeck found - checking your RetroArch install. Use -Roms to tell me where your games are.' }
  }
}

Write-Host "BIOS Checker v$VERSION (PowerShell edition)" -ForegroundColor Magenta
if ($contexts.Count -eq 0) {
  Out-Line 'No EmuDeck or RetroArch install found.' 'Red'
  Write-Host 'Point me at a folder:  .\deck-bios-check.ps1 -Bios D:\path\to\bios [-Roms D:\path\to\roms]'
  Finish 2; return
}

foreach ($cx in $contexts) {
  $script:CTX = $cx.name; $script:BIOS = ([string]$cx.bios).TrimEnd('\', '/'); $script:ROMS = ([string]$cx.roms).TrimEnd('\', '/')
  $script:STORAGE = ([string]$cx.storage).TrimEnd('\', '/'); $script:SAVES = $cx.saves; $script:EMUS = $cx.emus
  $script:ROMC = @{}
  Write-Host ''
  Out-Line "################  $($script:CTX)  ################" 'Magenta'
  Write-Host "  BIOS:    $($script:BIOS)"
  Write-Host "  ROMs:    $(if ($script:ROMS) { $script:ROMS } else { '?' })"
  Write-Host "  storage: $(if ($script:STORAGE) { $script:STORAGE } else { '?' })"
  if ($cx.settings) { Out-Line "  settings: $($cx.settings)" 'DarkGray' }
  if ($cx.note) { Out-Line "  $($cx.note)" 'Yellow' }
  if ($script:REC) { [void]$script:CTXS.Add([ordered]@{ name = $script:CTX; bios = $script:BIOS; roms = $script:ROMS; settings = [string]$cx.settings; note = [string]$cx.note }) }
  if (-not (IsDir $script:BIOS)) { Out-Line '  BIOS folder missing!' 'Red'; $script:SEC_ID = 0; Add-Need "$($script:CTX): BIOS folder $($script:BIOS) does not exist" '_'; continue }
  Write-Host '  indexing and hashing BIOS files...' -ForegroundColor DarkGray
  Build-Index $script:BIOS
  [void](Find-RetroArch)
  foreach ($chk in @('Check-Hygiene', 'Check-Psx', 'Check-Ps2', 'Check-Ps3', 'Check-Vita', 'Check-Xbox', 'Check-Switch', 'Check-WiiU', 'Check-3ds',
                     'Check-Gc', 'Check-Nds', 'Check-Flycast', 'Check-ShadPs4', 'Check-NeoGeo', 'Check-RetroArch', 'Check-Unknown')) {
    $script:NOTINST = $false; $script:CUR_KEY = ''
    & $chk
  }
  $script:NOTINST = $false
}
Resolve-Needs

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
$script:SEC_ID = 0
Write-Host ''; Out-Line '== SUMMARY ==' 'Cyan'
Write-Host ("  {0} OK   {1} need   {2} warnings   {3} fix commands" -f $script:CNT_OK, $script:NEEDS.Count, $script:WARNS.Count, $script:FIXES.Count)
if ($script:NEEDS.Count) {
  Write-Host ''; Out-Line '  YOU NEED (blocking - you have games for these):' 'Red'
  $seen = @{}; foreach ($n in $script:NEEDS) { if (-not $seen.ContainsKey($n.text)) { $seen[$n.text] = 1; Out-Line "    $S_BAD $($n.text)" 'Red' } }
}
if ($script:WARNS.Count) {
  Write-Host ''; Out-Line '  SHOULD LOOK AT:' 'Yellow'
  $seen = @{}; foreach ($w in $script:WARNS) { if (-not $seen.ContainsKey($w.text)) { $seen[$w.text] = 1; Write-Host "    $S_WARN $($w.text)" } }
}
if ($script:FIXES.Count) {
  Write-Host ''; Out-Line '  SUGGESTED FIX COMMANDS (review before running - paste into PowerShell)' 'Cyan'
  foreach ($f in $script:FIXES) { Write-Host "    $f" }
  if ($FixScript) {
    $txt = "# generated by deck-bios-check.ps1 v$VERSION on $(Get-Date)`r`n# REVIEW EVERY LINE before running. Copies never overwrite existing files.`r`n" + ($script:FIXES -join "`r`n") + "`r`n"
    Write-Utf8 $FixScript $txt; Write-Host ''; Write-Host "  fix script written to $FixScript"
  } else { Out-Line '  (use -FixScript fixes.ps1 to save these to a file)' 'DarkGray' }
}
if ($script:NEEDS.Count -eq 0) { Write-Host ''; Out-Line '  Nothing blocking: every system you have games for has what it needs.' 'Green' }
Write-Host ''

if ($script:REC) {
  $js = Build-Json
  if ($Json) { Write-Utf8 $Json $js; Write-Host "  JSON written to $Json" }
  if ($Report) {
    $rf = $(if ($ReportFile) { [IO.Path]::GetFullPath($ReportFile) } else { JP $LAD 'deck-bios-check/report.html' })
    $data = $js.Replace('</', '<\/')
    $i = $REPORT_TPL.IndexOf('@@DATA@@')
    $html = $REPORT_TPL.Substring(0, $i) + $data + $REPORT_TPL.Substring($i + 8)
    Write-Utf8 $rf $html
    Write-Host "  Report: $rf"
    if (-not $NoOpen) { try { if ($IsWin) { Start-Process -FilePath $rf } else { Start-Process -FilePath 'xdg-open' -ArgumentList $rf } } catch { Write-Host '  (could not open a browser - open the file above yourself)' } }
  }
}
if ($script:NEEDS.Count) { Finish 1 } else { Finish 0 }
