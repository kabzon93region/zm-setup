#!/bin/sh
# geomask-node-scan.sh - nightly subscription node audit (geomask v1.11.0+).
# Downloads the VPN subscription, resolves every node SERVER through a geo db
# (country + ASN), blocks nodes matching bad_countries/bad_asns by adding their
# exact names to the VPN group exclude-filter, unblocks clean ones, validates
# (mihomo -t) and hot-reloads ONLY when the filter changed. Never selects nodes,
# never touches traffic. Config: /etc/geomask-nodes.conf.
exec python3 - <<'PYEOF'
import re, sys, json, time, urllib.request, urllib.parse, subprocess, os

CONF='/etc/geomask-nodes.conf'
CFG='/etc/mihomo/config.yaml'
BLOCKF='/etc/geomask-node-block.txt'
STATE='/tmp/geomask-nodescan.state'
LOG='/root/geo-sync.log'

def log(msg):
    line='%s NODESCAN %s\n' % (time.strftime('%F %T'), msg)
    try:
        with open(LOG,'a') as f: f.write(line)
    except Exception: pass

cfgd={}
try:
    for ln in open(CONF, encoding='utf-8'):
        ln=ln.strip()
        if ln and not ln.startswith('#') and '=' in ln:
            k,_,v=ln.partition('='); cfgd[k.strip()]=v.strip()
except Exception as e:
    log('conf read failed: %s' % e); sys.exit(1)

bad_countries={c.strip().upper() for c in cfgd.get('bad_countries','RU,BY').split(',') if c.strip()}
bad_asns={('AS'+a.replace('AS','').strip().upper()) for a in cfgd.get('bad_asns','').split(',') if a.strip()}
base_filter=cfgd.get('base_filter','Россия')
provider=cfgd.get('sub_provider','sub')
# v1.13.7: the panel (Remnawave) serves a 1-node stub ("Приложение не поддерживается") to
# unknown clients, so the scan must identify itself. clash-meta -> YAML, v2rayNG -> links.
sub_ua=cfgd.get('sub_user_agent','clash-meta')

text=open(CFG, encoding='utf-8').read()
# provider url (+ optional header x-hwid lines)
m=re.search(r'%s:\s*\n(?:[^\n]*\n)*?\s*url:\s*"?([^"\n]+)"?' % re.escape(provider), text)
if not m:
    log('provider %s url not found' % provider); sys.exit(1)
url=m.group(1).strip()
hdrs={}
hm=re.search(r'%s:\s*\n((?:[^\n]*\n)*?)\s*url:' % re.escape(provider), text)
if hm and 'x-hwid' in hm.group(1):
    hv=re.search(r'-\s*"?([^"\n]+)"?', hm.group(1)[hm.group(1).find('x-hwid'):])
    if hv: hdrs['x-hwid']=hv.group(1).strip()

raw=''
for _try in range(3):
    try:
        h=dict(hdrs); h['User-Agent']=sub_ua
        raw=urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=25).read().decode('utf-8','replace')
        # The panel answers a tiny stub ("Приложение не поддерживается", ~1.4 KB) when it does
        # not recognise the client or is rate-limiting; the real payload is 12-15 KB.
        if len(raw) > 2000:
            break
        log('subscription looks like a stub (%d bytes), retrying' % len(raw))
    except Exception as e:
        log('subscription download failed (try %d/3): %s' % (_try+1, e))
    time.sleep(5*(_try+1))
if not raw.strip():
    log('subscription download failed: empty response'); sys.exit(1)
sub_text=raw
# v1.13.8: only base64-decode when the body really is base64. b64decode(validate=False)
# silently discards ':' and spaces, so feeding it a YAML config produced mojibake and the
# parser then saw ~no nodes at all (that is how the filter lost its exact-name bans).
_s=re.sub(r'\s', '', raw)
if _s and re.fullmatch(r'[A-Za-z0-9+/=]+', _s) \
   and not re.search(r'(?m)^(vless|ss|trojan|vmess|anytls|hysteria2?)://', raw):
    try:
        import base64
        _dec=base64.b64decode(_s+'===').decode('utf-8','replace')
        if _dec.strip():
            sub_text=_dec
    except Exception:
        pass

nodes=[]
for ln in sub_text.splitlines():
    ln=ln.strip()
    mm=re.match(r'^(vless|ss|trojan|vmess|anytls|hysteria2?)://\S+', ln, re.I)
    if not mm: continue
    frag=''
    if '#' in ln:
        frag=ln.split('#',1)[1]
        frag=urllib.parse.unquote(frag.split('|')[0]).strip()
    srv=None
    sm=re.search(r'@([A-Za-z0-9.\-]+):(\d+)', ln)
    if sm: srv=sm.group(1)
    if frag and srv and frag.lower()!='ip':
        nodes.append((frag, srv))

# yaml-style subscription: a proxy item may put server:/port: several lines AFTER its name:
# (v1.13.6 fix - the old regex required server on the very next line and silently matched
# almost nothing once the provider switched to a full YAML config with "type:" in between).
def parse_yaml_items(t):
    out=[]; name=None; srv=None
    def close():
        if name and srv: out.append((name, srv))
    for ln in t.splitlines():
        raw=ln.strip()
        # flow style:  - {name: X, server: y, port: 443}
        if raw.startswith('- {') or raw.startswith('{'):
            body=raw.lstrip('- ').strip('{}')
            kv=dict(re.findall(r'(\w+)\s*:\s*"?([^",}]+)"?', body))
            if kv.get('name') and kv.get('server'):
                out.append((kv['name'].strip().strip('"\''), kv['server'].strip().strip('"\'')))
            continue
        mn=re.match(r'^-\s*name:\s*(.+?)\s*$', raw)
        if mn:
            close()
            name=mn.group(1).strip().strip('"').strip("'"); srv=None
            continue
        ms=re.match(r'^server:\s*(.+?)\s*$', raw)
        if ms and name and not srv:
            srv=ms.group(1).strip().strip('"').strip("'")
    close()
    return out

if not nodes:
    nodes=parse_yaml_items(sub_text)

# safety net: a parse regression must not silently wipe the exact-name bans
MIN_NODES=3
if len(nodes) < MIN_NODES:
    log('suspiciously few nodes parsed (%d < %d) - subscription format changed? refusing to rewrite filter'
        % (len(nodes), MIN_NODES))
    sys.exit(1)

if not nodes:
    log('no nodes parsed from subscription'); sys.exit(1)

# geodb per unique server (cached)
cache={}
def lookup(host):
    if host in cache: return cache[host]
    r=('', '')
    try:
        j=json.load(urllib.request.urlopen('http://ip-api.com/json/%s?fields=status,countryCode,as' % host, timeout=10))
        if j.get('status')=='success':
            r=(j.get('countryCode',''), (j.get('as','').split(' ')[0]).upper())
    except Exception:
        r=None
    cache[host]=r
    return r

blocked=set(); total=0; errs=0
for name, srv in nodes:
    total+=1
    res=lookup(srv)
    if res is None:
        errs+=1
        continue  # lookup failed: keep node as-is (do not block on doubt)
    cc, asn = res
    bad = (cc in bad_countries) or (asn in bad_asns)
    if bad:
        blocked.add(name)

# compose exclude-filter: base + exact blocked names (regex-escaped), de-duplicated.
# The previous version appended every blocked name on each run without deduplicating, so the
# alternation grew junk like "Russia|Mobile|RF|Auto|Russia|Mobile|Auto|..." - and once it even
# collected "USA", which emptied the AI group. Order is kept stable so the file does not churn.
seen=set(); parts=[]
for raw in ([base_filter.strip()] if base_filter.strip() else []) + [re.escape(n) for n in sorted(blocked)]:
    for p in raw.split('|'):
        p=p.strip()
        if p and p not in seen:
            seen.add(p); parts.append(p)
new_filter='|'.join(parts)

def group_blocks(cfgtext):
    """yield (group_name, start, end) for every proxy-groups entry"""
    try: i=cfgtext.index('\nproxy-groups:\n')
    except ValueError: return
    body_start=i+15
    lines=cfgtext[body_start:].split('\n')
    pos=0; name=None; start=None
    for ln in lines:
        if ln and not ln.startswith(' '):
            break
        g=re.match(r'^  - name:\s*(\S.*)$', ln)
        if g:
            if name is not None: yield (name, start, pos)
            name=g.group(1).strip().strip('"\''); start=pos
        pos+=len(ln)+1
    if name is not None: yield (name, start, pos)

def provider_of_block(blk):
    u=re.search(r'use:\n((?:[ ]{6}-\s+\S+\n?)+)', blk)
    return re.findall(r'-\s+(\S+)', u.group(1))[0] if u else None

def apply_filter_all(cfgtext, filt, prov, name_filter_groups):
    """write the filter into every GROUP that uses this provider. Never listeners, never a
    group that is not listed in name_filter_groups for the base part."""
    esc=filt.replace("'", "''")
    line="    exclude-filter: '%s'" % esc
    out=[]; cursor=0; touched=0
    for name, s, e in group_blocks(cfgtext):
        blk=cfgtext[s:e]
        if provider_of_block(blk) != prov:
            continue
        if name not in name_filter_groups:
            continue
        cleaned='\n'.join(l for l in blk.split('\n') if 'exclude-filter' not in l)
        # insert right after the "use:" list so the YAML stays readable
        ul=re.search(r'(use:\n(?:[ ]{6}-\s+\S+\n)+)', cleaned)
        ins = ul.end() if ul else len(cleaned)
        newblk=cleaned[:ins]+line+'\n'+cleaned[ins:]
        if newblk != blk:
            out.append(cfgtext[cursor:s]); out.append(newblk); cursor=e; touched+=1
    out.append(cfgtext[cursor:])
    joined=''.join(out)
    return joined, (joined != cfgtext), touched

NFG=[g.strip() for g in cfgd.get('name_filter_groups','VPN,VPN-noP2P').split(',') if g.strip()]
out, changed, touched = apply_filter_all(text, new_filter, provider, NFG)
if touched == 0:
    log('no group using provider %s accepts a name filter (name_filter_groups=%s) - nothing done'
        % (provider, ','.join(NFG))); sys.exit(1)
applied=False
if changed:
    open(CFG+'.bak_nodescan','w',encoding='utf-8').write(text)
    open(CFG+'.tmp','w',encoding='utf-8').write(out)
    try:
        rc=subprocess.run(['mihomo','-d','/etc/mihomo','-f',CFG+'.tmp','-t'], capture_output=True, timeout=30).returncode
    except Exception:
        rc=1
    if rc==0:
        os.replace(CFG+'.tmp', CFG)
        try:
            # v1.13.7: controller is protected by a secret; without Bearer the reload 401s
            sm=re.search(r'^secret:\s*(\S+)', text, re.M)
            sec=sm.group(1).strip().strip('"\'') if sm else ''
            r=urllib.request.Request('http://127.0.0.1:9090/configs?force=true',
                data=json.dumps({'path':CFG}).encode(), method='PUT',
                headers={'Content-Type':'application/json'})
            if sec: r.add_header('Authorization', 'Bearer '+sec)
            urllib.request.urlopen(r, timeout=8).read()
        except Exception as e:
            log('reload failed: %s' % e)
        log('filter updated, blocked=%d total=%d lookup-errors=%d' % (len(blocked), total, errs))
        applied=True
    else:
        try: os.remove(CFG+'.tmp')
        except Exception: pass
        log('VALIDATION FAILED - config untouched (test rc=%d)' % rc)
else:
    log('no change (blocked=%d of %d, errors=%d)' % (len(blocked), total, errs))

# remember list + state for the panel
try:
    with open(BLOCKF,'w',encoding='utf-8') as f:
        f.write('\n'.join(sorted(blocked))+'\n')
except Exception: pass
st={'ts':time.strftime('%F %T'),'total':total,'blocked':len(blocked),'errors':errs,'changed':applied}
try:
    with open(STATE+'.tmp','w') as f: json.dump(st,f)
    os.replace(STATE+'.tmp', STATE)
except Exception: pass
print('nodes=%d blocked=%d errors=%d applied=%s' % (total, len(blocked), errs, applied))
PYEOF
