# Extract DuckStation's PS1/PS2 BIOS table (md5|PS1/PS2|region|description) from src/core/bios.cpp
import re, sys
t = open(sys.argv[1]).read()
for m in re.finditer(r'\{"([^"]+)",\s*"[^"]*",\s*(?:"([^"]*)"|nullptr),\s*ConsoleRegion::(\w+),.*?MakeHashFromString\("([0-9a-f]{32})"\)\}', t):
    d, fn, reg, h = m.groups()
    tag = 'PS2' if d.startswith('PS2') else 'PS1'
    r = {'NTSC_J': 'JP', 'NTSC_U': 'US', 'PAL': 'EU', 'Auto': 'JP'}[reg]
    print(f"{h}|{tag}|{r}|{d}")
