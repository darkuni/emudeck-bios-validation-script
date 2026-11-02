import re,glob,os,sys
core_dir, sysdat = sys.argv[1], sys.argv[2]
md5={}   # path -> set
bymd5base={}
for m in re.finditer(r'rom \( name "?([^"\s]+)"? size (\d+) crc \w+ md5 (\w+)', open(sysdat,encoding='utf-8',errors='replace').read()):
    md5.setdefault(m.group(1),set()).add(m.group(3).lower())
rows=[]
for f in sorted(glob.glob(core_dir+'/*.info')):
    kv={}
    for line in open(f,encoding='utf-8',errors='replace'):
        m=re.match(r'\s*(\w+)\s*=\s*"?(.*?)"?\s*$',line)
        if m: kv[m.group(1)]=m.group(2)
    n=int(kv.get('firmware_count','0') or 0)
    if not n: continue
    core=os.path.basename(f)[:-5]
    sysn=kv.get('systemname',kv.get('display_name',''))
    for i in range(n):
        p=kv.get(f'firmware{i}_path','').strip()
        if not p: continue
        d=kv.get(f'firmware{i}_desc','').replace('|','/')
        o='O' if kv.get(f'firmware{i}_opt','false').lower()=='true' else 'R'
        h=md5.get(p) or set()
        rows.append(f"{core}|{sysn}|{p}|{o}|{','.join(sorted(h))}|{d}")
print('\n'.join(rows))
