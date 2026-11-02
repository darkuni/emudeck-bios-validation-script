set -e
H=$1; S=$2
E=$H/Emulation; B=$E/bios; R=$E/roms
mkdir -p $H/.config/EmuDeck $B $R $E/storage $H/Applications
cat > $H/.config/EmuDeck/settings.sh <<X
emulationPath=~/Emulation
romsPath=~/Emulation/roms
biosPath=~/Emulation/bios
storagePath=~/Emulation/storage
savesPath=~/Emulation/saves
X
for d in psx ps2 segacd saturn neogeo switch dreamcast xbox wiiu fds; do mkdir -p $R/$d; echo "x" > $R/$d/systeminfo.txt; done
for d in psx ps2 segacd saturn neogeo switch dreamcast xbox; do echo game > "$R/$d/Some Game.chd"; done
mkdir -p $R/ps3/GAME.PS3; echo x > $R/ps3/GAME.PS3/PARAM.SFO
echo wux > $R/wiiu/zelda.wux
mkfake(){ printf '%s' "FAKE-$2" > "$1"; }
mkfake "$B/scph5501.bin" us5501
mkfake "$B/SCPH5502.BIN" eu5502
mkfake "$B/ps1 jp.bin" jp5500
# PS2 4MB unknown with ROMVER
head -c 4194304 /dev/zero > $B/SCPH-70012.bin; printf '0200AC20040614' | dd of=$B/SCPH-70012.bin bs=1 seek=1000 conv=notrunc 2>/dev/null
mkfake "$B/ps2good.bin" ps2good
mkfake "$B/bios_CD_U.bin" sat101    # wrong: actually Saturn JP
mkdir -p $B/saturn; mkfake "$B/saturn/mpr-17933.bin" mpr17933
mkfake "$B/disksys.rom" fds
touch "$B/firmware.bin"
printf 'junk' > "$B/scph1001.zip"
printf '[ZoneTransfer]' > "$B/scph5501.bin:Zone.Identifier"
mkdir -p $B/dc
# neogeo.zip with members
mkdir -p /tmp/ng && cd /tmp/ng && for f in 000-lo.lo sfix.sfix sm1.sm1 sp-s2.sp1; do echo $f > $f; done && rm -f $R/arcade/neogeo.zip && mkdir -p $R/arcade && zip -q $R/arcade/neogeo.zip 000-lo.lo sfix.sfix sm1.sm1 sp-s2.sp1 && cd - >/dev/null
# neocd: loader present, zoom missing
mkdir -p $B/neocd; mkfake $B/neocd/neocd_z.rom neocdz
# RetroArch flatpak
RA=$H/.var/app/org.libretro.RetroArch/config/retroarch; mkdir -p $RA/cores
echo "system_directory = \"~/Emulation/bios\"" > $RA/retroarch.cfg
for c in swanstation mednafen_saturn genesis_plus_gx flycast mesen neocd puae opera pcsx2 snes9x; do touch $RA/cores/${c}_libretro.so; done
# DuckStation AppImage + config pointing to bios
touch $H/Applications/DuckStation.AppImage; mkdir -p $H/.local/share/duckstation
printf '[BIOS]\nSearchDirectory = %s\n' "$B" > $H/.local/share/duckstation/settings.ini
touch $H/Applications/pcsx2-Qt.AppImage; mkdir -p $H/.config/PCSX2/inis; printf '[Folders]\nBios = %s\n' "$B" > $H/.config/PCSX2/inis/PCSX2.ini
# RPCS3 without firmware, PUP present
touch $H/Applications/rpcs3.AppImage; mkdir -p $H/.config/rpcs3
printf 'SCEUF\0\0\0junk' > $B/PS3UPDAT.PUP
# Vita3K no firmware
mkdir -p $H/Applications/Vita3K $H/.config/Vita3K; echo "pref-path: $E/storage/Vita3K/" > $H/.config/Vita3K/config.yml
# xemu
X=$H/.var/app/app.xemu.xemu/data/xemu/xemu; mkdir -p $X $E/storage/xemu
printf "[sys.files]\nbootrom_path = '%s/mcpx_1.0.bin'\nflashrom_path = '%s/Complex_4627v1.03.bin'\nhdd_path = '%s/storage/xemu/xbox_hdd.qcow2'\n" $B $B $E > $X/xemu.toml
mkfake $B/mcpx_1.0.bin mcpx11
head -c 1048576 /dev/zero > $B/Complex_4627v1.03.bin
printf 'QFI\xfb' > $E/storage/xemu/xbox_hdd.qcow2
# Cemu (no keys)
touch $H/Applications/Cemu.AppImage
# Switch: citron with keys + nested firmware; ryujinx keys only; broken symlink
touch $H/Applications/citron.AppImage
mkdir -p $H/.local/share/citron/keys $H/.local/share/citron/nand/system/Contents/registered/Firmware19
printf 'header_key = %s\nmaster_key_00 = %s\nmaster_key_12 = %s\nbogus line\n' $(printf 'a%.0s' {1..64}) $(printf 'b%.0s' {1..32}) $(printf 'c%.0s' {1..32}) > $H/.local/share/citron/keys/prod.keys
for i in $(seq 1 30); do touch $H/.local/share/citron/nand/system/Contents/registered/Firmware19/$(printf '%032x' $i).nca; done
mkdir -p $B/citron; ln -sfn $H/.local/share/citron/keys $B/citron/keys; ln -sfn $H/.local/share/citron/nand/system/Contents/registered $B/citron/firmware
mkdir -p $H/.config/Ryujinx/system; echo 'garbage' > $H/.config/Ryujinx/system/Prod.keys.txt
mkdir -p $B/eden; ln -sfn /nonexistent/eden/keys $B/eden/keys
