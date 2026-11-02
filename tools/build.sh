#!/usr/bin/env bash
# Rebuild ../deck-bios-check.sh from tools/template.sh + generated data in tools/data/.
# Run tools/update-data.sh first if you want fresh data from upstream.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
python3 -I - "$here/template.sh" "$here/data/known.txt" "$here/data/ra.txt" "$here/../deck-bios-check.sh" <<'PY'
import sys
tpl, known, ra, out = sys.argv[1:5]
s = open(tpl).read()
k = open(known).read().strip(); r = open(ra).read().strip()
s = s.replace("<<'@@KNOWN_END@@'\n@@KNOWN@@\n@@KNOWN_END@@", "<<'@@KNOWN_END@@'\n" + k + "\n@@KNOWN_END@@", 1)
s = s.replace("@@RACORES@@\n@@RA_END@@", r + "\n@@RA_END@@", 1)
html = open(tpl.rsplit('/',1)[0] + '/report.html').read().strip()
assert '@@REPORT_END@@' not in html and '@@DATA@@' in html
s = s.replace("@@REPORT_HTML@@\n@@REPORT_END@@", html + "\n@@REPORT_END@@", 1)
assert '@@KNOWN@@' not in s and '@@RACORES@@' not in s and '@@REPORT_HTML@@' not in s, "placeholders not replaced"
open(out, 'w').write(s)
PY
chmod +x "$here/../deck-bios-check.sh"
bash -n "$here/../deck-bios-check.sh"
echo "built deck-bios-check.sh"
