#!/bin/sh
# geomask-node-scan.sh - nightly subscription node audit (geomask v1.11.0+).
# Downloads the VPN subscription, resolves every node SERVER through a geo db
# (country + ASN), blocks nodes matching bad_countries/bad_asns by adding their
# exact names to the VPN group exclude-filter, unblocks clean ones, validates
# (mihomo -t) and hot-reloads ONLY when the filter changed. Never selects nodes,
# never touches traffic. Config: /etc/geomask-nodes.conf.
# OpenWrt has python3; a Windows sandbox may only expose "python" (a Store alias is not always
# executable from sh), so fall back rather than dying at exec with "python3: not found".
if python3 -c 'pass' >/dev/null 2>&1; then _py=python3; else _py=python; fi
exec "$_py" - "$@" <<'PYEOF'
import re, sys, json, time, urllib.request, urllib.parse, subprocess, os

# every path is env-overridable so the script can be exercised by the sandbox tests
_E=os.environ
CONF=_E.get('GM_NODES_CONF','/etc/geomask-nodes.conf')
CFG=_E.get('GM_MIHOMO_CFG','/etc/mihomo/config.yaml')
BLOCKF=_E.get('GM_NODES_BLOCK','/etc/geomask-node-block.txt')
STATE=_E.get('GM_NODES_STATE','/tmp/geomask-nodescan.state')
LOG=_E.get('GM_NODES_LOG','/root/geo-sync.log')

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
# v1.20.4: sub_provider=all -> scan every subscription, one child run each. Re-running the
# wrapper per provider keeps the existing single-provider logic (and its rollback) untouched.
_argv=sys.argv[1:]
# testability: --list-providers runs the enumeration only (used by the sandbox tests, so a
# broken regex cannot silently scan nothing again)
if '--list-providers' in _argv:
    _t=open(os.environ.get('GM_MIHOMO_CFG', CFG), encoding='utf-8', errors='replace').read()
    try:
        _i=_t.index('\nproxy-providers:\n')
    except ValueError:
        print(''); sys.exit(1)
    _h=_t[_i:]
    _n=re.search(r'\n(?=[a-z])', _h[1:])
    if _n: _h=_h[:_n.start()+1]
    print(','.join(p for p in re.findall(r'^  ([A-Za-z0-9_-]+):\s*$', _h, re.M)
                   if re.search(r'^  %s:\n(?:.*\n)*?\s+url:' % re.escape(p), _h, re.M)))
    sys.exit(0)
if '--provider' in _argv:
    provider=_argv[_argv.index('--provider')+1]
elif provider.strip()=='all':
    _t=open(CFG, encoding='utf-8', errors='replace').read()
    try:
        _i=_t.index('\nproxy-providers:\n')
    except ValueError:
        log('sub_provider=all but no proxy-providers section'); sys.exit(1)
    _head=_t[_i:]
    # stop at the next top-level key so rule-providers entries cannot be mistaken for proxies
    _nxt=re.search(r'\n(?=[a-z])', _head[1:])
    if _nxt: _head=_head[:_nxt.start()+1]
    # NOTE: both searches need re.M - without it "^" only matches the very start of the string
    # and the list silently came back empty ("scanning all 0 providers").
    _provs=[p for p in re.findall(r'^  ([A-Za-z0-9_-]+):\s*$', _head, re.M)
            if re.search(r'^  %s:\n(?:.*\n)*?\s+url:' % re.escape(p), _head, re.M)]
    if not _provs:
        log('sub_provider=all but no proxy-provider with a url was found - refusing to no-op')
        sys.exit(1)
    log('scanning all %d providers: %s' % (len(_provs), ','.join(_provs)))
    # One provider failing must not erase the others: a blocked subscription legitimately
    # returns a stub, and the guard refuses to rewrite the filter from that. Only fail if
    # every single pass failed - otherwise the nightly job would glow red forever.
    _ok=[]; _bad=[]; _skip=[]
    for _p in _provs:
        r=subprocess.run(['/bin/sh', '/usr/bin/geomask-node-scan.sh', '--provider', _p])
        if r.returncode==0: _ok.append(_p)
        elif r.returncode==3: _skip.append(_p)
        else: _bad.append(_p)
    log('all-provider pass done: ok=[%s] skipped-by-design=[%s] failed=[%s]'
        % (','.join(_ok), ','.join(_skip), ','.join(_bad)))
    if not _ok and not _skip:
        log('every provider failed - nothing was updated'); sys.exit(1)
    sys.exit(0)
# v1.13.7: the panel (Remnawave) serves a 1-node stub ("Приложение не поддерживается") to
# unknown clients, so the scan must identify itself. clash-meta -> YAML, v2rayNG -> links.
sub_ua=cfgd.get('sub_user_agent','clash-meta')

text=open(CFG, encoding='utf-8').read()
# Read the provider block properly: url plus EVERY header entry, in both shapes the config uses
#   header:
#     x-hwid: value          and          x-hwid:
#                                            - value
# The old single-regex attempt silently produced no header for some layouts, and without
# x-hwid the panel answers a 1.4 KB stub ("Приложение не поддерживается") instead of the real
# 16 KB subscription - so the scan kept refusing to update the filter on a working account.
def provider_block(name):
    m=re.search(r'(?m)^  %s:\n' % re.escape(name), text)
    if not m: return None
    rest=text[m.end():]
    nxt=re.search(r'(?m)^  \S', rest)
    return rest[:nxt.start()] if nxt else rest

blk=provider_block(provider)
if blk is None or 'url:' not in blk:
    log('provider %s url not found' % provider); sys.exit(1)
url=re.search(r'url:\s*"?([^"\n]+)"?', blk).group(1).strip()
hdrs={}
hsec=re.search(r'(?m)^    header:\n((?:      .*\n|\s*\n)+)', blk)
if hsec:
    hb=hsec.group(1)
    key=None
    for ln in hb.splitlines():
        km=re.match(r'^      ([A-Za-z0-9_-]+):\s*(.*)$', ln)
        im=re.match(r'^\s+-\s*"?([^"\n]+)"?\s*$', ln)
        if km:
            key=km.group(1)
            if km.group(2).strip(): hdrs[key]=km.group(2).strip().strip('"\'')
        elif im and key:
            hdrs[key]=im.group(1).strip()
log('provider %s: url ok, %d header(s): %s' % (provider, len(hdrs), ','.join(hdrs) or 'none'))

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
    # offsets must be ABSOLUTE: the caller slices cfgtext with them. Yielding slice-relative
    # positions made every group read from the wrong place, so provider_of_block never matched
    # and the scan logged "no group using provider X accepts a name filter" for a group that
    # plainly did use it.
    for ln in lines:
        if ln and not ln.startswith(' '):
            break
        g=re.match(r'^  - name:\s*(\S.*)$', ln)
        if g:
            if name is not None: yield (name, body_start+start, body_start+pos)
            name=g.group(1).strip().strip('"\''); start=pos
        pos+=len(ln)+1
    if name is not None: yield (name, body_start+start, body_start+pos)

def provider_of_block(blk):
    u=re.search(r'use:\n((?:[ ]{6}-\s+\S+\n?)+)', blk)
    return re.findall(r'-\s+(\S+)', u.group(1))[0] if u else None

def apply_filter_all(cfgtext, filt, prov, name_filter_groups):
    """write the filter into every GROUP that uses this provider. Never listeners, never a
    group that is not listed in name_filter_groups for the base part."""
    esc=filt.replace("'", "''")
    line="    exclude-filter: '%s'" % esc
    out=[]; cursor=0; touched=0; matched=0
    for name, s, e in group_blocks(cfgtext):
        blk=cfgtext[s:e]
        if provider_of_block(blk) != prov:
            continue
        if name not in name_filter_groups:
            continue
        matched += 1
        cleaned='\n'.join(l for l in blk.split('\n') if 'exclude-filter' not in l)
        # insert right after the "use:" list so the YAML stays readable
        ul=re.search(r'(use:\n(?:[ ]{6}-\s+\S+\n)+)', cleaned)
        ins = ul.end() if ul else len(cleaned)
        newblk=cleaned[:ins]+line+'\n'+cleaned[ins:]
        if newblk != blk:
            out.append(cfgtext[cursor:s]); out.append(newblk); cursor=e; touched+=1
    out.append(cfgtext[cursor:])
    joined=''.join(out)
    return joined, (joined != cfgtext), matched, touched

NFG=[g.strip() for g in cfgd.get('name_filter_groups','VPN,VPN-noP2P').split(',') if g.strip()]
out, changed, matched, touched = apply_filter_all(text, new_filter, provider, NFG)
# "nothing to change" is a SUCCESS, not an error. The old code reported it as "no group uses
# this provider" and exited 1, so a healthy nightly run failed every night once the filter had
# settled - and the all-provider pass then declared that every provider had failed.
if matched == 0:
    # Not an error: a provider whose groups are deliberately outside name filtering (the AI
    # subscription is USA-only) will always land here. Reporting it as "failed" made the nightly
    # log show a broken provider every single night, which is how a guard stops being believed.
    log('provider %s has no name-filtered group - skipped by design' % provider)
    print('nodes=%d blocked=%d errors=%d applied=False (no name-filtered group)'
          % (total, len(blocked), errs)); sys.exit(3)
if not changed:
    log('filter for provider %s already up to date across %d group(s)' % (provider, matched))
    print('nodes=%d blocked=%d errors=%d applied=False (already up to date)'
          % (total, len(blocked), errs)); sys.exit(0)
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
