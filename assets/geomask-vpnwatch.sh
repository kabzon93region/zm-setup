#!/bin/sh
# geomask-vpnwatch.sh - record everything that tries to use the P2P-restricted subscription.
#
# The subscription is currently disabled by its provider, so nothing actually flows - but the
# proxy core still logs every routing decision. Capturing those decisions answers the only
# question that matters before switching it back on: what WOULD go through it, and does any of
# it look like P2P (bare-IP destinations, non-443 ports).
#
#   geomask-vpnwatch.sh --tick     cron every minute: append new events, rotate the log
#   geomask-vpnwatch.sh --report   summary: hosts, counts, sources, P2P-looking share
#   geomask-vpnwatch.sh --clear    empty the log
#
# Config: /etc/geomask/vpnwatch.conf. Nothing here changes routing.
exec python3 - "$@" <<'PYEOF'
import hashlib, json, os, re, subprocess, sys, time, urllib.request

CONF='/etc/geomask/vpnwatch.conf'
CURSOR='/etc/geomask/vpnwatch.cursor'
CFG='/etc/mihomo/config.yaml'

def read(p, default=''):
    try:
        return open(p, encoding='utf-8').read()
    except Exception:
        return default

cfgd={}
for ln in read(CONF).splitlines():
    ln=ln.strip()
    if ln and not ln.startswith('#') and '=' in ln:
        k,_,v=ln.partition('='); cfgd[k.strip()]=v.strip()

GROUP=cfgd.get('group','VPN-noP2P')
LOGF=cfgd.get('logfile','/root/geomask-vpn-audit.log')
MAXL=max(500,int(cfgd.get('max_lines','20000')))

def secret():
    for ln in read(CFG).splitlines():
        m=re.match(r'^secret:\s*["\']?([^"\'\s]+)', ln)
        if m: return m.group(1)
    return ''

def api(path):
    req=urllib.request.Request('http://127.0.0.1:9090'+path)
    s=secret()
    if s: req.add_header('Authorization','Bearer '+s)
    try:
        return json.load(urllib.request.urlopen(req, timeout=8))
    except Exception:
        return {}

# ---- parsing ----
MSG_RE=re.compile(r'time="([^"]*)".*?msg="(.*)"')
DIAL_RE=re.compile(r'\[(TCP|UDP)\] dial (\S+)(?: \(match ([^)]*)\))? (\S+)? --> (\S+)(?: error: (.*))?')
USE_RE=re.compile(r'\[(TCP|UDP)\] (\S+) --> (\S+)(?: match (\S+))? using (\S+)')

def log_events():
    """lines from the system log that mention the watched group"""
    try:
        out=subprocess.run(['logread'], capture_output=True, timeout=25).stdout.decode('utf-8','replace')
    except Exception as e:
        sys.stderr.write('logread failed: %s\n' % e); return []
    ev=[]
    for ln in out.splitlines():
        if GROUP not in ln: continue
        m=MSG_RE.search(ln)
        ts, msg = (m.group(1), m.group(2)) if m else ('', ln)
        d=DIAL_RE.search(msg)
        if d:
            ev.append({'ts': ts, 'proto': d.group(1), 'target': d.group(5),
                       'rule': d.group(3) or '', 'error': d.group(6) or '',
                       'kind': 'dial', 'src': d.group(4) or ''})
            continue
        u=USE_RE.search(msg)
        if u:
            ev.append({'ts': ts, 'proto': u.group(1), 'target': u.group(3),
                       'rule': u.group(4) or '', 'error': '',
                       'kind': 'route', 'src': u.group(2)})
    return ev

def conn_events():
    """currently open connections routed to the watched group (catches long-lived flows)"""
    d=api('/connections')
    out=[]
    for c in (d.get('connections') or []):
        chains=[str(x) for x in (c.get('chains') or [])]
        if not chains or chains[0] != GROUP: continue
        md=c.get('metadata') or {}
        host=str(md.get('host') or md.get('destinationIP') or '')
        out.append({'id': str(c.get('id')), 'host': host,
                    'port': md.get('destinationPort'), 'proto': md.get('network'),
                    'src': md.get('sourceIP'), 'down': c.get('download'), 'up': c.get('upload'),
                    'rule': c.get('rulePayload') or c.get('rule') or ''})
    return out

def load_cursor():
    try:
        d=json.loads(read(CURSOR) or '{}')
        return set(d.get('seen', [])), d.get('conns', [])
    except Exception:
        return set(), []

def save_cursor(seen, conns):
    # keep the dedupe set bounded
    seen=list(seen)[-4000:]
    try:
        os.makedirs(os.path.dirname(CURSOR), exist_ok=True)
        json.dump({'seen': seen, 'conns': conns, 'at': time.strftime('%F %T')},
                  open(CURSOR+'.tmp','w'))
        os.replace(CURSOR+'.tmp', CURSOR)
    except Exception:
        pass

def append(lines):
    if not lines: return
    try:
        with open(LOGF,'a',encoding='utf-8') as f:
            f.write('\n'.join(lines)+'\n')
        # rotate
        n=sum(1 for _ in open(LOGF, encoding='utf-8', errors='replace'))
        if n > MAXL:
            keep=open(LOGF, encoding='utf-8', errors='replace').read().splitlines()[-MAXL:]
            open(LOGF,'w',encoding='utf-8',newline='\n').write('\n'.join(keep)+'\n')
    except Exception as e:
        sys.stderr.write('log write failed: %s\n' % e)

def is_bare_ip(h):
    """a destination written as an address, not a name - the shape a torrent peer has"""
    return bool(re.fullmatch(r'\d{1,3}(\.\d{1,3}){3}', h or ''))

def is_group_traffic(h):
    """multicast / broadcast / link-local (mDNS 224.0.0.251, SSDP, Chromecast, DHCP). These
    arrive on their own and are NOT peer-to-peer. Counting them as P2P made the single signal
    the operator is told to watch cry wolf over 20 lines of 224.0.0.251:5353."""
    if not h: return False
    try:
        o=[int(x) for x in h.split('.')]
    except ValueError:
        return False
    if len(o)!=4 or any(x>255 for x in o): return False
    return o[0] in (224, 225, 239) or o[0]==0 or h=='255.255.255.255' \
        or (o[0]==169 and o[1]==254) or o[0]==127

def do_tick():
    seen, known = load_cursor()
    lines=[]
    for e in log_events():
        key=hashlib.md5(('%s|%s|%s|%s' % (e['ts'], e['kind'], e['target'], e['error'])).encode()).hexdigest()[:16]
        if key in seen: continue
        seen.add(key)
        lines.append('%s %s %s %s %s src=%s%s' % (e['ts'], e['kind'], e['proto'], e['target'],
                        e['rule'] or '-', e['src'] or '-',
                        (' err=' + e['error']) if e['error'] else ''))
    cur=conn_events()
    for c in cur:
        if c['id'] in known: continue
        lines.append('%s live %s %s:%s src=%s rule=%s up=%s down=%s' % (
            time.strftime('%FT%T'), c['proto'], c['host'], c['port'], c['src'],
            c['rule'] or '-', c['up'], c['down']))
    append(lines)
    save_cursor(seen, [c['id'] for c in cur])
    print(json.dumps({'ok': True, 'events': len(lines), 'group': GROUP,
                      'open_now': len(cur), 'logfile': LOGF}))

def do_report():
    try:
        raw=open(LOGF, encoding='utf-8', errors='replace').read().splitlines()
    except Exception:
        print(json.dumps({'ok': False, 'error': 'no log yet'})); return
    hosts={}; bare=0; grp=0; errs={}; srcs={}; first=last=''
    for ln in raw:
        p=ln.split()
        if len(p) < 4: continue
        if not first: first=p[0]
        last=p[0]
        m=re.search(r'-->\s+(\S+)', ln)
        tgt=(m.group(1) if m else (p[3] if len(p)>3 else ''))
        host=re.sub(r':\d+$','', tgt.split(' ')[0])
        if host:
            hosts[host]=hosts.get(host,0)+1
            if is_bare_ip(host):
                if is_group_traffic(host): grp+=1
                else: bare+=1
        m=re.search(r'err=(.*)', ln)
        if m:
            k=m.group(1)[:60]; errs[k]=errs.get(k,0)+1
        s=re.search(r'src=(192\.168\.\d+\.\d+)', ln)
        if s: srcs[s.group(1)]=srcs.get(s.group(1),0)+1
    top=sorted(hosts.items(), key=lambda x:-x[1])[:25]
    print('watched group : %s' % GROUP)
    print('log lines     : %d  (%s .. %s)' % (len(raw), first or '-', last or '-'))
    print('distinct dests: %d' % len(hosts))
    print('PEER-SHAPED (bare IP, not multicast): %d   <- this is the number to watch' % bare)
    if grp: print('   (ignored as local multicast/broadcast traffic: %d)' % grp)
    print('sources       : %s' % (dict(sorted(srcs.items(), key=lambda x:-x[1])[:8]) or '-'))
    print('errors        :')
    for k,v in sorted(errs.items(), key=lambda x:-x[1])[:6]: print('   %5d  %s' % (v,k))
    print('top destinations:')
    for h,v in top:
        tag='   <- peer-shaped IP' if (is_bare_ip(h) and not is_group_traffic(h)) else \
            ('   (multicast, ignored)' if is_group_traffic(h) else '')
        print('   %5d  %s%s' % (v, h, tag))

args=sys.argv[1:]
if '--report' in args: do_report(); sys.exit(0)
if '--clear' in args:
    try: os.remove(LOGF)
    except Exception: pass
    save_cursor(set(), [])
    print(json.dumps({'ok': True, 'cleared': LOGF})); sys.exit(0)
do_tick()
PYEOF
