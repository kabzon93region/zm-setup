#!/bin/sh
# geomask-ytwatch.sh - YouTube edge auto-pin watchdog (geomask v1.14.0+).
#
# Why: googlevideo.com edges are IP-blocked per hostname and Google rotates those names,
# so any static list lags. Default path is DIRECT (DPI/zapret). This watcher reads mihomo's
# OWN dial errors and pins only the hosts that actually fail into the MagiTrickle group
# "GoogleVideo VPN" (which sync turns into ytvpn.yaml, matched BEFORE ytdirect). A nightly
# --reset drops the automatic pins so healthy edges return to zapret.
#
#   geomask-ytwatch.sh            scan + pin (cron */5)
#   geomask-ytwatch.sh --reset    remove automatic pins (cron, nightly)
#   geomask-ytwatch.sh --status   JSON for the panel
#   geomask-ytwatch.sh --mode auto|blanket   switch mode (also called by the panel)
#
# Config: /etc/geomask-ytwatch.conf. Nothing here selects proxies or touches traffic directly.
exec python3 - "$@" <<'PYEOF'
import calendar, json, os, re, socket, subprocess, sys, time, urllib.request, http.client

CONF='/etc/geomask-ytwatch.conf'
STATE='/etc/geomask/ytwatch.state'
JOURNAL='/root/geo-sync.log'
SOCKPATH='/var/run/magitrickle.sock'
BLANKET='googlevideo.com'

def log(msg):
    try:
        with open(JOURNAL,'a',encoding='utf-8') as f:
            f.write('%s YTWATCH %s\n' % (time.strftime('%F %T'), msg))
    except Exception:
        pass

cfgd={}
try:
    for ln in open(CONF, encoding='utf-8'):
        ln=ln.strip()
        if ln and not ln.startswith('#') and '=' in ln:
            k,_,v=ln.partition('='); cfgd[k.strip()]=v.strip()
except Exception as e:
    log('conf read failed: %s' % e)

mode=cfgd.get('mode','auto')
threshold=max(1,int(cfgd.get('fail_threshold','2')))
window=max(5,int(cfgd.get('window_min','30')))
cap=max(1,int(cfgd.get('max_pins','40')))
group_name=cfgd.get('group_name','GoogleVideo VPN')
# v1.15.2: stalled-connection detection. An edge that DPI kills AFTER the TCP handshake
# produces no mihomo error at all, so the log scan above cannot see it. Such a connection
# still shows up in the controller API: alive for a long time with almost no bytes back.
stall_age=max(5,int(cfgd.get('stall_min_age','25')))
stall_bytes=max(1024,int(cfgd.get('stall_max_bytes','10000')))
stall_threshold=max(1,int(cfgd.get('stall_threshold','1')))
# how many quiet connections the same host must show in one sample to count as a stalled edge
stall_min_conns=max(1,int(cfgd.get('stall_min_conns','3')))
# how many distinct quiet edges in ONE sample means "the class is being killed" -> blanket rule
blanket_when=max(2,int(cfgd.get('blanket_when','4')))
# clean samples required before the blanket rule is taken back down
blanket_off=max(1,int(cfgd.get('blanket_off_after','20')))

# ---------- MagiTrickle API over unix socket (handles chunked responses) ----------
class U(http.client.HTTPConnection):
    def connect(self):
        s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(8); s.connect(SOCKPATH); self.sock=s

def api(method, path, body=None):
    try:
        c=U('localhost')
        c.request(method, path, body=(json.dumps(body) if body is not None else None),
                  headers=({'Content-Type':'application/json'} if body is not None else {}))
        r=c.getresponse(); raw=r.read().decode('utf-8','replace'); c.close()
        try: return r.status, json.loads(raw)
        except Exception: return r.status, {'raw': raw[:200]}
    except Exception as e:
        return 0, {'error': str(e)}

def group_id(name):
    st,gs=api('GET','/api/v1/groups')
    if st!=200: return None
    for g in (gs.get('groups',[]) if isinstance(gs,dict) else []):
        if g.get('name')==name: return g.get('id')
    return None

def group_rules(gid):
    st,r=api('GET','/api/v1/groups/%s/rules'%gid)
    return (r.get('rules',[]) if isinstance(r,dict) else [])

def rule_state(gid):
    rs=group_rules(gid)
    blanket=[x for x in rs if str(x.get('rule','')).lower()==BLANKET]
    edges={str(x.get('rule','')).lower(): x.get('id') for x in rs
           if str(x.get('rule','')).endswith('googlevideo.com') and x not in blanket}
    return blanket, edges

def auto_rule_ids(gid):
    """Rules the watcher itself created are tagged name='ytwatch' inside MagiTrickle.
    That tag is the durable source of truth for what may be released - the state file lives
    in /tmp and is lost on reboot or reinstall."""
    return [x.get('id') for x in group_rules(gid) if str(x.get('name','')).strip()=='ytwatch']

# ---------- failure scan from mihomo's own log ----------
FAIL_RE=re.compile(r'msg="\[(?:TCP|UDP)\] dial \S+ \(match [^)]*\) \S+ --> ([a-z0-9.\-]+\.googlevideo\.com):\d+ error: ')
TIME_RE=re.compile(r'time="(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})')

def recent_failures():
    counts={}
    try:
        out=subprocess.run(['logread'], capture_output=True, timeout=20).stdout.decode('utf-8','replace')
    except Exception as e:
        log('logread failed: %s' % e); return counts
    cutoff=time.time()-window*60
    for ln in out.splitlines():
        m=FAIL_RE.search(ln)
        if not m: continue
        tm=TIME_RE.search(ln)
        if tm:
            try:
                ts=time.mktime(time.strptime(tm.group(1).split('.')[0].replace('T',' '), '%Y-%m-%d %H:%M:%S'))
                if ts < cutoff: continue
            except Exception:
                pass
        host=m.group(1).lower()
        counts[host]=counts.get(host,0)+1
    return counts

# ---------- stalled connections via the mihomo controller ----------
MIHOMO_CONF='/etc/mihomo/config.yaml'

def controller_secret():
    try:
        for ln in open(MIHOMO_CONF, encoding='utf-8'):
            m=re.match(r'^secret:\s*["\']?([^"\'\s]+)', ln)
            if m: return m.group(1)
    except Exception:
        pass
    return ''

def utc_age(iso, now):
    """seconds since an RFC3339 UTC timestamp; -1 when unparsable"""
    try:
        return now - calendar.timegm(time.strptime(iso[:19], '%Y-%m-%dT%H:%M:%S'))
    except Exception:
        return -1

def is_stalled(c, now):
    """pure classifier: is this controller connection a stalled, DIRECT-routed video edge?"""
    md=c.get('metadata') or {}
    host=str(md.get('host') or '').lower()
    if not host.endswith('googlevideo.com'): return False
    chains=[str(x).upper() for x in (c.get('chains') or [])]
    if chains and chains[0] != 'DIRECT': return False      # already off DIRECT - nothing to pin
    if utc_age(str(c.get('start') or ''), now) < stall_age: return False
    try:
        if int(c.get('download') or 0) > stall_bytes: return False
    except Exception:
        pass
    return True

def stalled_edges(now=None):
    """{host: count} for *.googlevideo.com connections that leave DIRECT, are older than
    stall_age and downloaded less than stall_bytes - i.e. connected but starved."""
    now = now if now is not None else time.time()
    out={}
    try:
        req=urllib.request.Request('http://127.0.0.1:9090/connections')
        s=controller_secret()
        if s: req.add_header('Authorization','Bearer '+s)
        data=json.load(urllib.request.urlopen(req, timeout=10))
    except Exception as e:
        log('controller /connections failed: %s' % e); return out
    for c in (data.get('connections') or []):
        if is_stalled(c, now):
            host=str((c.get('metadata') or {}).get('host') or '').lower()
            out[host]=out.get(host,0)+1
    return out

# ---------- state (which pins are automatic) ----------
def load_state():
    try:
        with open(STATE,encoding='utf-8') as f: return json.load(f)
    except Exception: return {'pins': [], 'last': None, 'failures': {}, 'stalled': {}, 'stall_seen': {}}

def save_state(st):
    st['last']=time.strftime('%F %T')
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE+'.tmp','w',encoding='utf-8') as f: json.dump(st,f)
        os.replace(STATE+'.tmp', STATE)
    except Exception as e:
        log('state write failed: %s' % e)

# ---------- actions ----------
def sync_now():
    try:
        subprocess.run(['sh','/root/sync_mtrickle_mihomo.sh'], capture_output=True, timeout=60)
    except Exception as e:
        log('sync failed: %s' % e)

def do_status():
    gid=group_id(group_name)
    out={'mode': mode, 'group': group_name, 'group_found': bool(gid),
         'threshold': threshold, 'window_min': window, 'max_pins': cap,
         'stall_min_age': stall_age, 'stall_max_bytes': stall_bytes,
         'stall_threshold': stall_threshold}
    st=load_state()
    out['auto_pins']=sorted(st.get('pins',[]))
    out['stalled']=st.get('stalled') or {}
    out['recent_errors']=st.get('failures') or {}
    if gid:
        blanket, edges = rule_state(gid)
        out['blanket_present']=bool(blanket)
        out['pinned_hosts']=sorted(edges.keys())
        out['pinned_count']=len(edges)
    # pinned_count is every rule in the group; the auto-pins the watchdog itself owns are a
    # different number and they diverged (status said 38 while --reset released 71). Show both,
    # or the operator reads one figure and trusts the wrong one.
    out['auto_pin_count']=len(st.get('pins') or [])
    out['stall_seen']=st.get('stall_seen') or {}
    out['stall_min_conns']=stall_min_conns
    return out

def set_mode(new_mode):
    global mode
    if new_mode not in ('auto','blanket'):
        log('bad mode %r' % new_mode); return False
    gid=group_id(group_name)
    if not gid:
        log('group %s not found' % group_name); return False
    blanket, edges = rule_state(gid)
    if new_mode=='blanket':
        if not blanket:
            api('POST','/api/v1/groups/%s/rules?save=true'%gid,
                {'type':'namespace','rule':BLANKET,'name':'','enable':True})
            log('mode=blanket: added blanket rule')
    else:
        for x in blanket:
            api('DELETE','/api/v1/groups/%s/rules/%s?save=true'%(gid,x['id']))
            log('mode=auto: removed blanket rule')
    # persist the choice
    try:
        t=open(CONF,encoding='utf-8').read()
        t=re.sub(r'(?m)^mode=.*$','mode=%s'%new_mode, t)
        open(CONF,'w',encoding='utf-8',newline='\n').write(t)
    except Exception as e:
        log('mode persist failed: %s' % e)
    mode=new_mode
    sync_now()
    return True

def do_reset():
    gid=group_id(group_name)
    if not gid:
        log('reset: group %s not found' % group_name); return 0
    st=load_state()
    blanket, edges = rule_state(gid)
    removed=0
    # release by the MagiTrickle tag (authoritative) and, for safety, by the recorded list too
    for rid in auto_rule_ids(gid):
        api('DELETE','/api/v1/groups/%s/rules/%s?save=true'%(gid,rid)); removed+=1
    for host in st.get('pins',[]):
        rid=edges.get(host.lower())
        if rid:
            api('DELETE','/api/v1/groups/%s/rules/%s?save=true'%(gid,rid)); removed+=1
    st['pins']=[]
    st['stall_seen']={}
    save_state(st)
    if removed:
        log('reset: released %d auto-pins back to zapret' % removed)
        sync_now()
    return removed

def do_scan():
    gid=group_id(group_name)
    if not gid:
        log('group %s not found - nothing to do' % group_name); return
    st=load_state()
    if mode!='auto':
        # in blanket mode everything is already on VPN; just keep the record fresh
        st['failures']=recent_failures(); save_state(st); return
    blanket, edges = rule_state(gid)
    if blanket:
        log('mode=auto but blanket rule present - removing it')
        for x in blanket:
            api('DELETE','/api/v1/groups/%s/rules/%s?save=true'%(gid,x['id']))
        sync_now()
        blanket, edges = rule_state(gid)
    counts=recent_failures()
    st['failures']=counts
    stalled_all=stalled_edges()
    # A quiet connection is NOT by itself a blocked edge: the YouTube player keeps prefetch and
    # keep-alive connections that legitimately transfer almost nothing, and abandons connections
    # when it switches edge. Requiring a SWARM of quiet connections for the same host is what
    # separates a DPI-killed edge (dozens of fresh connections, ~0 bytes back) from normal idle
    # noise. Without this, the 5s threshold pinned healthy edges every minute and each wrong pin
    # slowed the TV down, which made the player open more quiet connections - a feedback loop.
    stalled={h:n for h,n in stalled_all.items() if h not in edges and int(n) >= stall_min_conns}
    st['stalled']=stalled
    # --- aggregate trigger (owner, 01.11): the TV/phone player waits only 10-15s for a stream,
    # then restarts the connection ON A DIFFERENT EDGE. Per-host pins therefore cannot win that
    # race: by the time an edge is proven bad, the player has left it, and we just grow a list of
    # names we will never use again. What the player cannot rotate away from is the class - so
    # when MANY edges look quiet at once, that is not "one bad edge", it is "edges are being
    # killed", and the whole googlevideo namespace goes to VPN as a single rule.
    if len(stalled) >= blanket_when:
        if not blanket:
            log('blanket: %d distinct quiet edges in one sample (>= %d) - routing the whole class'
                % (len(stalled), blanket_when))
            set_mode('blanket')
            st['stall_seen']={}; st['clean_samples']=0
            save_state(st); return
        st['clean_samples']=0
    else:
        if blanket:
            n=int(st.get('clean_samples',0))+1
            st['clean_samples']=n
            if n >= blanket_off:
                log('blanket: %d clean samples - back to per-edge auto' % n)
                set_mode('auto'); st['clean_samples']=0
                save_state(st); return
        else:
            st['clean_samples']=0
    # a stalled connection is a per-sample observation: count consecutive sightings so one
    # transient sample cannot pin an edge on its own
    seen={h:int(n) for h,n in (st.get('stall_seen') or {}).items() if h not in edges}
    fresh={}
    # count SAMPLES, not connections. Adding the connection count made stall_threshold mean
    # "N quiet connections in total", which a single swarm satisfies at once - so the threshold
    # never actually waited for sustained evidence. The per-sample swarm gate is stall_min_conns;
    # this counter is how many consecutive minutes the host kept qualifying.
    for h in stalled:
        fresh[h]=int(seen.get(h,0))+1
    st['stall_seen']=fresh
    why={}
    cand={}
    for h,n in counts.items():
        if n >= threshold: cand[h]=n; why[h]='errors'
    for h,n in fresh.items():
        if n >= stall_threshold:
            cand[h]=max(cand.get(h,0), n)
            why[h]=why.get(h) or 'stalled'
    added=[]; reasons={}
    for host in sorted(cand):
        if host in edges: continue
        if len(edges)+len(added) >= cap:
            log('max_pins=%d reached, %d candidate(s) not pinned' % (cap, len(cand)))
            break
        r=api('POST','/api/v1/groups/%s/rules?save=true'%gid,
              {'type':'domain','rule':host,'name':'ytwatch','enable':True})
        if r[0]==200:
            added.append(host); edges[host]=True; reasons[host]=why.get(host,'?')
    if added:
        st['pins']=sorted(set(st.get('pins',[])) | set(added))
        save_state(st)
        detail=', '.join('%s[%s]' % (h, reasons.get(h,'?')) for h in added[:6])
        log('pinned %d edge(s): %s%s' % (len(added), detail, (' …' if len(added)>6 else '')))
        sync_now()
    else:
        save_state(st)

args=[a for a in sys.argv[1:]]
if '--status' in args:
    print(json.dumps(do_status(), ensure_ascii=False)); sys.exit(0)
if '--reset' in args:
    do_reset(); sys.exit(0)
if '--mode' in args:
    i=args.index('--mode')
    ok=set_mode(args[i+1] if i+1 < len(args) else '')
    print(json.dumps({'ok': ok, 'mode': mode})); sys.exit(0 if ok else 1)
do_scan()
PYEOF
