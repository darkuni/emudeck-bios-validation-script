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

$VERSION = '@@VERSION@@'
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
@@KNOWN@@
'@
$RA_DATA = @'
@@RACORES@@
'@
$RULES_DATA = @'
@@RULES@@
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
@@REPORT_HTML@@
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
