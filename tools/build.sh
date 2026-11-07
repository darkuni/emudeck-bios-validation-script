#!/usr/bin/env bash
# Rebuild deck-bios-check.sh and deck-bios-check.ps1 from the templates + shared data.
# Run tools/update-data.sh first if you want fresh data from upstream.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
python3 -I - "$here" <<'PY'
import sys, os
here = sys.argv[1]; root = os.path.dirname(here)
rd = lambda p: open(os.path.join(here, p), encoding='utf-8').read()
version = rd('VERSION').strip()
known = rd('data/known.txt').strip(); ra = rd('data/ra.txt').strip(); rules = rd('data/rules.txt').strip()
html = rd('report.html').strip()
assert '@@DATA@@' in html and '@@REPORT_END@@' not in html
for blob in (known, ra, rules, html):            # PowerShell here-string safety
    assert "\n'@" not in blob and not blob.startswith("'@")

# bash
s = rd('template.sh')
s = s.replace('@@VERSION@@', version, 1)
s = s.replace("<<'@@KNOWN_END@@'\n@@KNOWN@@\n@@KNOWN_END@@", "<<'@@KNOWN_END@@'\n" + known + "\n@@KNOWN_END@@", 1)
s = s.replace("@@RACORES@@\n@@RA_END@@", ra + "\n@@RA_END@@", 1)
s = s.replace("@@RULES@@\n@@RULES_END@@", rules + "\n@@RULES_END@@", 1)
s = s.replace("@@REPORT_HTML@@\n@@REPORT_END@@", html + "\n@@REPORT_END@@", 1)
for ph in ('@@VERSION@@', '@@KNOWN@@', '@@RACORES@@', '@@RULES@@', '@@REPORT_HTML@@'):
    assert ph not in s, ph
open(os.path.join(root, 'deck-bios-check.sh'), 'w', encoding='utf-8', newline='\n').write(s)

# PowerShell (UTF-8 with BOM + CRLF so Windows PowerShell 5.1 reads it correctly)
p = rd('template.ps1')
p = p.replace('@@VERSION@@', version, 1)
p = p.replace("@'\n@@KNOWN@@\n'@", "@'\n" + known + "\n'@", 1)
p = p.replace("@'\n@@RACORES@@\n'@", "@'\n" + ra + "\n'@", 1)
p = p.replace("@'\n@@RULES@@\n'@", "@'\n" + rules + "\n'@", 1)
p = p.replace("@'\n@@REPORT_HTML@@\n'@", "@'\n" + html + "\n'@", 1)
for ph in ('@@VERSION@@', '@@KNOWN@@', '@@RACORES@@', '@@RULES@@', '@@REPORT_HTML@@'):
    assert ph not in p, ph
p = p.replace('\r\n', '\n').replace('\n', '\r\n')
open(os.path.join(root, 'deck-bios-check.ps1'), 'w', encoding='utf-8-sig', newline='').write(p)
print('built deck-bios-check.sh + deck-bios-check.ps1 v' + version)
PY
chmod +x "$here/../deck-bios-check.sh"
bash -n "$here/../deck-bios-check.sh"
