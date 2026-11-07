# Builds a fake EmuDeck-for-Windows install (APPDATA, Emulation folder, emulators) full of
# deliberate mistakes, swaps a few real reference hashes for the hashes of dummy files
# (no real BIOS needed), runs deck-bios-check.ps1 and asserts every mistake is caught.
# Runs on Windows PowerShell 5.1 and PowerShell 7 (Windows or Linux).
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) 'deck-bios-check.ps1'
$exe = (Get-Process -Id $PID).Path
$isWin = ($env:OS -eq 'Windows_NT')
$work = Join-Path ([IO.Path]::GetTempPath()) ('dbc-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function J { $r = $args[0]; for ($i = 1; $i -lt $args.Count; $i++) { $r = Join-Path $r $args[$i] }; $r }
function MkDir($p) { New-Item -ItemType Directory -Force -Path $p | Out-Null; $p }
function Put($p, $text) { MkDir (Split-Path -Parent $p) | Out-Null; [IO.File]::WriteAllText($p, $text) }
function Fake($p, $tag) { Put $p ('FAKE-' + $tag) }
$md5 = [Security.Cryptography.MD5]::Create()
function M($tag) { ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::ASCII.GetBytes('FAKE-' + $tag)))).Replace('-', '').ToLowerInvariant() }

# ---- fake user profile ---------------------------------------------------------
$UPd = MkDir (J $work 'Users' 'deck')
$ADd = MkDir (J $UPd 'AppData' 'Roaming')
$LADd = MkDir (J $UPd 'AppData' 'Local')
$EMU = MkDir (J $work 'Emu Drive' 'Emulation')
$B = MkDir (J $EMU 'bios'); $R = MkDir (J $EMU 'roms'); MkDir (J $EMU 'storage') | Out-Null
$EMUS = MkDir (J $ADd 'EmuDeck' 'Emulators')

# EmuDeck settings.ps1 written the way EmuDeck writes it (quotes, variable reuse, comments)
Put (J $ADd 'EmuDeck' 'settings.ps1') ("`$emulationPath=`"$EMU`"`r`n`$biosPath=`"`$emulationPath" + [IO.Path]::DirectorySeparatorChar + "bios`"  # comment`r`n`$doInstallRA=`"true`"`r`n")

# games
foreach ($d in 'psx', 'ps2', 'segacd', 'saturn', 'neogeo', 'switch', 'dreamcast', 'xbox') { Put (J $R $d 'Some Game.chd') 'game'; Put (J $R $d 'systeminfo.txt') 'x' }
Put (J $R 'ps3' 'GAME.PS3' 'PARAM.SFO') 'x'
Put (J $R 'wiiu' 'zelda.wux') 'wux'
MkDir (J $R 'fds') | Out-Null

# BIOS files with mistakes
Fake (J $B 'scph5501.bin') 'us5501'
Fake (J $B 'scph5502.bin.bin') 'eu5502'          # hidden double extension
Fake (J $B 'ps1 jp.bin') 'jp5500'                # right file, wrong name
$ps2 = New-Object byte[] 4194304; $rv = [Text.Encoding]::ASCII.GetBytes('0200AC20040614'); [Array]::Copy($rv, 0, $ps2, 1000, $rv.Length)
[IO.File]::WriteAllBytes((J $B 'SCPH-70012.bin'), $ps2)   # valid-looking PS2 dump, unknown hash
Fake (J $B 'bios_CD_U.bin') 'sat101'             # actually a Saturn BIOS
Fake (J $B 'saturn' 'mpr-17933.bin') 'mpr17933'   # right file, wrong folder
Fake (J $B 'disksys.rom') 'fds'
[IO.File]::WriteAllBytes((J $B 'firmware.bin'), (New-Object byte[] 0))
Put (J $B 'scph1001.zip') 'junk'
Fake (J $B 'mcpx_1.0.bin') 'mcpx11'              # MCPX 1.1 - wrong for xemu
[IO.File]::WriteAllBytes((J $B 'Complex_4627v1.03.bin'), (New-Object byte[] 1048576))
Fake (J $B 'neocd' 'neocd_z.rom') 'neocdz'
MkDir (J $EMU 'storage' 'xemu') | Out-Null
[IO.File]::WriteAllBytes((J $EMU 'storage' 'xemu' 'xbox_hdd.qcow2'), [byte[]](0x51, 0x46, 0x49, 0xFB))
Put (J $B 'PS3UPDAT.PUP') "SCEUF`0`0`0junk"

# neogeo.zip in roms/arcade
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zsrc = MkDir (J $work 'ngsrc'); foreach ($f in '000-lo.lo', 'sfix.sfix', 'sm1.sm1', 'sp-s2.sp1') { Put (J $zsrc $f) $f }
MkDir (J $R 'arcade') | Out-Null
[IO.Compression.ZipFile]::CreateFromDirectory($zsrc, (J $R 'arcade' 'neogeo.zip'))

# emulators (EmuDeck for Windows layout)
Put (J $EMUS 'duckstation' 'settings.ini') "[BIOS]`r`nSearchDirectory = $B`r`n"
Put (J $EMUS 'PCSX2-Qt' 'inis' 'PCSX2.ini') "[Folders]`r`nBios = $B`r`n"
MkDir (J $EMUS 'RPCS3') | Out-Null
Put (J $EMUS 'Vita3K' 'config.yml') ("pref-path: " + (J $EMU 'storage' 'Vita3K') + "`n")
Put (J $EMUS 'xemu' 'xemu.toml') ("[sys.files]`nbootrom_path = '" + (J $B 'mcpx_1.0.bin') + "'`nflashrom_path = '" + (J $B 'Complex_4627v1.03.bin') + "'`nhdd_path = '" + (J $EMU 'storage' 'xemu' 'xbox_hdd.qcow2') + "'`n")
MkDir (J $EMUS 'cemu') | Out-Null
$keys = 'header_key = ' + ('a' * 64) + "`nmaster_key_00 = " + ('b' * 32) + "`nmaster_key_12 = " + ('c' * 32) + "`nbogus line`n"
Put (J $EMUS 'citron' 'user' 'keys' 'prod.keys') $keys
$fw = MkDir (J $EMUS 'citron' 'user' 'nand' 'system' 'Contents' 'registered' 'Firmware19')
1..30 | ForEach-Object { Put (J $fw ('{0:x32}.nca' -f $_)) '' }
Put (J $EMUS 'Ryujinx' 'portable' 'system' 'Prod.keys.txt') 'garbage'
$ra = MkDir (J $EMUS 'RetroArch' 'cores')
Put (J $EMUS 'RetroArch' 'retroarch.cfg') "system_directory = `"$B`"`n"
foreach ($c in 'swanstation', 'mednafen_saturn', 'genesis_plus_gx', 'flycast', 'mesen', 'neocd', 'puae', 'opera', 'pcsx2', 'snes9x') { Put (J $ra "${c}_libretro.dll") '' }

# ---- test copy of the script with dummy hashes ----------------------------------
$src = [IO.File]::ReadAllText($script)
$swap = @{ '490f666e1afb15b7362b406ed1cea246' = 'us5501'; '32736f17079d0b2b7024407c39bd3050' = 'eu5502'; '8dd7d5296a650fac7319bce665a6a53c' = 'jp5500'
           '85ec9ca47d8f6807718151cbcca8b964' = 'sat101'; '3240872c70984b6cbfda1586cab68dbe' = 'mpr17933'; 'ca30b50f880eb660a320674ed365ef7a' = 'fds'
           '11526d58d4c524daef7d5d677dc6b004' = 'neocdz'; '196a5f59a13382c185636e691d6c323d' = 'mcpx11' }
foreach ($k in $swap.Keys) { $src = $src.Replace($k, (M $swap[$k])) }
$t = J $work 't.ps1'
[IO.File]::WriteAllText($t, $src, (New-Object Text.UTF8Encoding $true))

# ---- run ------------------------------------------------------------------------
$saved = @{ USERPROFILE = $env:USERPROFILE; APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA; DECKBIOS_TEST = $env:DECKBIOS_TEST }
$env:USERPROFILE = $UPd; $env:APPDATA = $ADd; $env:LOCALAPPDATA = $LADd; $env:DECKBIOS_TEST = '1'
$rep = J $work 'report.html'; $js = J $work 'r.json'
$ErrorActionPreference = 'Continue'
$out = (& $exe -NoProfile -ExecutionPolicy Bypass -File $t -NoColor -ReportFile $rep -NoOpen -Json $js 2>&1 | Out-String)
$rc = $LASTEXITCODE

$fail = 0
function Expect($s) { if ($out.Contains($s)) { Write-Host "PASS  $s" } else { Write-Host "FAIL  $s"; $script:fail = 1 } }
$S = [IO.Path]::DirectorySeparatorChar
Expect "BIOS:    $B"
Expect 'regions covered: US OK   EU OK   JP OK'
Expect 'is there but named scph5502.bin.bin'
Expect ("but the right file is here: bios${S}ps1 jp.bin")
Expect 'bios_CD_U.bin is the WRONG file - it is actually: Saturn sega_101'
Expect ("but the right file is here: bios${S}saturn${S}mpr-17933.bin")
Expect 'ROMVER 0200AC20040614'
Expect 'MCPX boot ROM is the WRONG file'
Expect 'inside a SUB-folder'
Expect 'must be named exactly prod.keys'
Expect 'keys.txt MISSING and you have 1 encrypted'
Expect 'PS3 firmware NOT installed'
Expect 'Vita firmware not installed'
Expect 'compressed BIOS'
Expect '0-byte file'
Expect 'no neogeo.zip next to them'
Expect 'Sega CD (genesis_plus_gx_libretro)'
Expect 'Rename-Item -LiteralPath'
Expect 'Copy-Item -LiteralPath'
if ($rc -eq 1) { Write-Host 'PASS  exit code 1' } else { Write-Host "FAIL  exit code $rc"; $fail = 1 }

$html = [IO.File]::ReadAllText($rep)
if ($html.Contains('"tool":"deck-bios-check"') -and -not $html.Contains('@@DATA@@') -and $html.Contains('"platform":"' + $(if ($isWin) { 'windows' } else { 'linux' }) + '"')) { Write-Host 'PASS  HTML report generated' } else { Write-Host 'FAIL  HTML report'; $fail = 1 }
try { $d = Get-Content -Raw $js | ConvertFrom-Json; if ($d.needs.Count -gt 0 -and $d.events.Count -gt 50 -and $d.sections.Count -gt 5) { Write-Host 'PASS  JSON is valid' } else { throw 'counts' } } catch { Write-Host "FAIL  JSON invalid: $_"; $fail = 1 }

# settings.ps1 that points at a folder with a space, plus -Bios mode
$out2 = (& $exe -NoProfile -ExecutionPolicy Bypass -File $t -NoColor -Bios $B 2>&1 | Out-String)
if ($out2.Contains('custom') -and $out2.Contains("BIOS:    $B")) { Write-Host 'PASS  -Bios mode' } else { Write-Host 'FAIL  -Bios mode'; $fail = 1 }

# shortcut (Windows only)
if ($isWin) {
  $o3 = (& $exe -NoProfile -ExecutionPolicy Bypass -File $script -InstallShortcut 2>&1 | Out-String)
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'BIOS Checker.lnk'
  $copy = J $LADd 'deck-bios-check' 'deck-bios-check.ps1'
  if ((Test-Path $lnk) -and (Test-Path $copy)) { Write-Host 'PASS  shortcut installed' } else { Write-Host "FAIL  shortcut install`n$o3"; $fail = 1 }
  & $exe -NoProfile -ExecutionPolicy Bypass -File $script -UninstallShortcut | Out-Null
  if (-not (Test-Path $lnk)) { Write-Host 'PASS  shortcut removed' } else { Write-Host 'FAIL  shortcut removal'; $fail = 1 }
}

foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] -ErrorAction SilentlyContinue }
if ($fail) { Write-Host ''; Write-Host $out; Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue; exit 1 }
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host "all checks passed ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))"
