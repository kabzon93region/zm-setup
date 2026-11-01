#!/bin/sh
# Sync magitrickle (enabled groups with interface Mihomo) -> TWO mihomo rule-provider files:
#   /etc/mihomo/ruleset/mtrickle.yaml  (non-AI groups)  -> group VPN (sub #1 vlessi)
#   /etc/mihomo/ruleset/ai.yaml        (Google/AI)      -> group AI (sub #2 de5, Germany)
# AI detection: whole groups by name + domain patterns (AI domains live inside Geoblock too).
# Reloads mihomo only on change.
exec python3 - <<'PYEOF'
import os, re, json, sys, time, urllib.request

def controller_headers(path):
    with open(path, encoding='utf-8') as config:
        for line in config:
            match = re.match(r'^secret:\s*(.*)$', line.rstrip('\r\n'))
            if not match:
                continue
            value = match.group(1).strip()
            if value.startswith('"'):
                value, end = json.JSONDecoder().raw_decode(value)
                tail = match.group(1).strip()[end:].strip()
                if tail and not tail.startswith('#'):
                    raise ValueError('Invalid controller secret')
            elif value.startswith("'"):
                quoted = re.fullmatch(r"'((?:[^']|'')*)'\s*(?:#.*)?", value)
                if not quoted:
                    raise ValueError('Invalid controller secret')
                value = quoted.group(1).replace("''", "'")
            else:
                value = re.split(r'\s+#', value, maxsplit=1)[0].strip()
                if value.startswith('#'):
                    value = ''
                if value.startswith(('|', '>', '[', '{', '&', '*', '!')):
                    raise ValueError('Unsupported controller secret')
            if not isinstance(value, str) or any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise ValueError('Invalid controller secret')
            return {'Authorization': 'Bearer ' + value} if value else {}
    return {}

SRC = '/etc/magitrickle/state/config.yaml'
MT  = '/etc/mihomo/ruleset/mtrickle.yaml'
# v1.17.0: IP-based rules are emitted separately. The restricted VPN subscription must never see
# P2P, and a torrent peer is always a raw IP - so every IP-CIDR rule is routed to the RESERVE
# group (a subscription that allows torrents) instead. Invariant enforced by geomask --check:
# mtrickle.yaml must contain zero IP-CIDR entries.
MTBULK = '/etc/mihomo/ruleset/mtrickle_bulk.yaml'
AI  = '/etc/mihomo/ruleset/ai.yaml'
# v1.13.3: googlevideo edges -> VPN. Generated from the dedicated MagiTrickle group so the
# user edits ONE place (:8080); no hand-maintained ruleset file. Rule precedes ytdirect->DIRECT.
YTVPN = '/etc/mihomo/ruleset/ytvpn.yaml'
GOOGLEVIDEO_GROUP = 'GoogleVideo VPN'

# Whole groups routed to the German AI subscription.
AI_GROUPS = {'Google+AI to DE'}
# interfaces that carry traffic INTO mihomo (tunnelled); anything else (pppoe-wan, blackhole,
# wireguard) leaves by another path and must not appear in these rulesets
TUNNELED_IFACES = {'Mihomo', 'AI', 'VPN-noP2P'}
# AI system/check domains that live inside non-AI groups (e.g. Geoblock).
AI_DOMAIN_RE = re.compile(
    r'^(?:[\w-]+\.)*(openai\.com|chatgpt\.com|claude\.ai|claude\.com|anthropic\.com'
    r'|oaistatic\.com|oaiusercontent\.com|sora\.com|suno\.ai|suno\.com|cursor\.com'
    r'|cursor\.sh|cursorapi\.com|statsig\.com|statsigapi\.net)$', re.IGNORECASE)
# Extra safety net (kept from previous version).
# ECH (Encrypted Client Hello) hides the real SNI; the outer ClientHello carries a
# public name instead (Cloudflare uses cloudflare-ech.com). Routing that public name
# via AI keeps every ECH handshake on the German node instead of leaking to DIRECT.
AI_EXTRA = ['DOMAIN-SUFFIX,statsig.com', 'DOMAIN-SUFFIX,statsigapi.net',
            'DOMAIN-SUFFIX,cloudflare-ech.com']

lines = open(SRC, encoding='utf-8').read().splitlines()
section = ''
grp = None
rule = None
GRPS = []

def flush_rule():
    global rule
    if rule is not None and grp is not None:
        grp['rules'].append(rule)
    rule = None

def flush_group():
    global grp
    flush_rule()
    if grp is not None:
        GRPS.append(grp)
    grp = None

for ln in lines:
    if not ln.strip():
        continue
    s = ln.lstrip()
    ind = len(ln) - len(s)
    if ind == 0 and not s.startswith('-') and ':' in s:
        flush_group()
        section = s.split(':', 1)[0]
        continue
    if section not in ('groups', 'subscriptions'):
        continue
    if ind == 0 and s.startswith('- id:'):
        flush_group()
        grp = {'interface': '', 'enable': 'true', 'name': '', 'rules': []}
        continue
    if grp is None:
        continue
    if ind == 2 and s.startswith('- '):
        flush_rule()
        rule = {'enable': 'true', 'type': '', 'rule': ''}
        k, _, v = s[2:].partition(':')
        k = k.strip()
        if k in ('type', 'rule', 'enable'):
            rule[k] = v.strip().strip('"').strip("'")
        continue
    if rule is not None and ind >= 4 and s.split(':', 1)[0] in ('type', 'rule', 'enable'):
        k, _, v = s.partition(':')
        rule[k.strip()] = v.strip().strip('"').strip("'")
        continue
    if ind == 2:
        flush_rule()
        k, _, v = s.partition(':')
        k = k.strip()
        if k in ('interface', 'enable', 'name'):
            grp[k] = v.strip().strip('"').strip("'")
flush_group()

def cidr(v, v6=False):
    v = v.strip()
    if '/' in v:
        return v
    return v + ('/128' if v6 else '/32')

def emit(r):
    t = r.get('type', '')
    v = r.get('rule', '').strip()
    if not v:
        return None
    if t == 'namespace':
        return 'DOMAIN-SUFFIX,' + v.lower()
    if t == 'domain':
        return 'DOMAIN,' + v.lower()
    if t == 'regex':
        return 'DOMAIN-REGEX,' + v
    if t == 'wildcard':
        pat = ''.join('.*' if c == '*' else '.' if c == '?' else re.escape(c) for c in v)
        return 'DOMAIN-REGEX,' + pat
    if t == 'subnet':
        return 'IP-CIDR,' + cidr(v) + ',no-resolve'
    if t == 'subnet6':
        return 'IP-CIDR6,' + cidr(v) + ',no-resolve'
    return None

def is_ai_domain(e):
    # DOMAIN-SUFFIX,x / DOMAIN,x -> test x against AI pattern
    m = re.match(r'^DOMAIN(?:-SUFFIX)?,(.+)$', e)
    return bool(m and AI_DOMAIN_RE.match(m.group(1)))

# The restricted subscription forbids P2P. Groups pointed at its tunnel are routed by the
# interface itself, so mihomo rules never see them - which also means --check cannot see them.
# Report IP-shaped entries there explicitly: a bare address is exactly how a torrent peer
# arrives, so an IP range on that interface is the one thing that can break the owner's rule.
def audit_restricted():
    ipre = re.compile(r'^\d+\.\d+\.\d+\.\d+(/\d+)?$')
    for g in GRPS:
        if g.get('interface') != 'VPN-noP2P' or str(g.get('enable')).lower() != 'true':
            continue
        ips = [str(r.get('rule')) for r in g['rules']
               if str(r.get('enable')).lower() == 'true' and ipre.match(str(r.get('rule')).strip())]
        if ips:
            print('WARN: group %r is on the restricted tunnel and holds %d IP range(s) - '
                  'traffic to those addresses goes to the P2P-forbidding subscription'
                  % (g.get('name'), len(ips)))
audit_restricted()

mt_payload, ai_payload = [], []
ytvpn_payload = []
yt_group_found = False
seen_mt, seen_ai, seen_yt = set(), set(), set()
moved = 0
for g in GRPS:
    # v1.21.6: work off the INTERFACE, not off one hard-coded name. Only groups that actually
    # tunnel belong in these rulesets; pppoe-wan and blackhole do not.
    # This used to be `!= 'Mihomo'`, so the moment the owner pointed "Google+AI to DE" at the AI
    # tunnel the sync stopped seeing it and ai.yaml collapsed from 170 rules to 3 - the rule
    # chain then sent Google/AI to DIRECT for any traffic that did not arrive through the
    # MagiTrickle group match. A group on the restricted tunnel keeps its domains in the normal
    # set: traffic there is already routed by the interface, and this way the chain still sends
    # it to the P2P-tolerant lane rather than losing the domain entirely.
    if g.get('interface') not in TUNNELED_IFACES or str(g.get('enable')).lower() != 'true':
        continue
    is_ai = g.get('interface') == 'AI' or g.get('name') in AI_GROUPS
    is_ytvpn = g.get('name') == GOOGLEVIDEO_GROUP
    if is_ytvpn:
        yt_group_found = True
    for r in g['rules']:
        if str(r.get('enable')).lower() != 'true':
            continue
        e = emit(r)
        if not e:
            continue
        if is_ytvpn:
            if e not in seen_yt:
                seen_yt.add(e)
                ytvpn_payload.append(e)
            continue
        if is_ai:
            if e not in seen_ai:
                seen_ai.add(e)
                ai_payload.append(e)
        else:
            if is_ai_domain(e):
                if e not in seen_ai:
                    seen_ai.add(e)
                    ai_payload.append(e)
                    moved += 1
                continue
            if e not in seen_mt:
                seen_mt.add(e)
                mt_payload.append(e)

for e in AI_EXTRA:
    if e not in seen_ai:
        seen_ai.add(e)
        ai_payload.append(e)

if not mt_payload or not ai_payload:
    print('ERROR: empty payload (mt=%d ai=%d), refusing to overwrite' % (len(mt_payload), len(ai_payload)))
    sys.exit(1)

hdr = '# AUTO-GENERATED by /root/sync_mtrickle_mihomo.sh from magitrickle config - DO NOT EDIT\n'

def write_if_changed(path, payload):
    body = hdr + ('payload: []\n' if not payload
                  else 'payload:\n' + ''.join('  - %s\n' % p for p in payload))
    old = open(path).read() if os.path.exists(path) else None
    if old == body:
        return False, len(payload)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    open(tmp, 'w').write(body)
    os.replace(tmp, path)
    return True, len(payload)

# v1.17.0: split by rule TYPE. Domain rules may stay on the restricted VPN subscription;
# IP rules cannot, because a torrent peer is always a bare address.
mt_dom = [p for p in mt_payload if not p.startswith('IP-CIDR')]
mt_ip  = [p for p in mt_payload if p.startswith('IP-CIDR')]

c1, n1 = write_if_changed(MT, mt_dom)
c4, n4 = write_if_changed(MTBULK, mt_ip)
c2, n2 = write_if_changed(AI, ai_payload)
# v1.14.0: write ytvpn.yaml whenever the GoogleVideo group EXISTS (even with zero rules - that is
# the legitimate "auto mode, nothing broken right now" state). Only an absent group leaves the file
# untouched, so a transient config-read failure can never blank the pins.
c3 = False; n3 = len(ytvpn_payload)
if yt_group_found or ytvpn_payload:
    c3, n3 = write_if_changed(YTVPN, ytvpn_payload)
print('mtrickle.yaml: %d domain rules (%s)' % (n1, 'updated' if c1 else 'up-to-date'))
print('mtrickle_bulk.yaml: %d IP rules -> RESERVE (%s)' % (n4, 'updated' if c4 else 'up-to-date'))
print('ai.yaml:       %d rules (%s, + %d moved from non-AI groups by domain pattern)' % (n2, 'updated' if c2 else 'up-to-date', moved))
print('ytvpn.yaml:    %d rules (%s)' % (n3, 'updated' if c3 else 'up-to-date'))

# ---------------------------------------------------------------------------
# v1.19.0: zapret sync, direction A - everything that rides a TUNNEL must be
# excluded from DPI processing.
#
# Why: zapret's hostlist mode also rewrites DNS answers and injects fake packets for
# the domains it knows. For a domain that leaves through a proxy tunnel that is pure
# noise - the DPI on WAN sees only the encrypted hop to the proxy anyway. Excluding
# tunnel-bound domains keeps zapret focused on what actually goes out in the clear.
#
# Direction B (zapret's force-list -> a MagiTrickle group that bypasses mihomo) is
# deliberately NOT automated: adding those domains to a direct group would create
# cross-lane conflicts with the curated lists, and resolving those is a human call.
# Nothing is ever copied the other way either (zapret exclude -> MagiTrickle): the
# exclude list contains plain RU sites.
ZEXCL = '/opt/zapret/ipset/zapret-hosts-user-exclude.txt'
ZBEG  = '# >>> geomask sync: tunneled domains (generated) >>>'
ZEND  = '# <<< geomask sync: tunneled domains <<<'

def _zapret_sync():
    if not os.path.exists(ZEXCL):
        print('zapret: %s absent - skip' % ZEXCL); return False
    # domains that mihomo sends DIRECT must KEEP being processed by zapret
    pinned_direct = set()
    try:
        cfg = open('/etc/mihomo/config.yaml', encoding='utf-8', errors='replace').read()
        pinned_direct = {m.lower() for m in re.findall(
            r'-\s*DOMAIN-SUFFIX,([a-z0-9.\-]+),DIRECT', cfg, re.I)}
    except Exception:
        pass
    # zapret's hostlist format is a BARE domain; our payload items carry the mihomo rule type
    # ("DOMAIN-SUFFIX,example.com"), which zapret would treat as a literal hostname and never
    # match. Strip the type from every source before writing.
    def bare(p):
        return p.split(',', 1)[1].lower() if p.startswith(('DOMAIN,', 'DOMAIN-SUFFIX,')) else None

    tunnel = {d for d in (bare(p) for p in mt_dom) if d}
    tunnel |= {d for d in (bare(p) for p in ai_payload) if d}
    tunnel |= {d for d in (bare(p) for p in ytvpn_payload) if d}
    tunnel = tunnel - pinned_direct
    tunnel = {d for d in tunnel if re.fullmatch(r'[a-z0-9.\-\u0080-\uffff]+', d)}
    global TUNNEL_SET
    TUNNEL_SET = set(tunnel)          # direction B below works on exactly this set
    if not tunnel:
        print('zapret: nothing to exclude - skip'); return False
    try:
        old = open(ZEXCL, encoding='utf-8', errors='replace').read().splitlines()
    except Exception as e:
        print('zapret: cannot read exclude file (%s)' % e); return False
    # drop our previous block by marker positions, keep everything else (line 1 is the
    # "# nochange" guard and must survive)
    try:
        bi = next(i for i, l in enumerate(old) if l.strip() == ZBEG)
        ei = next(i for i, l in enumerate(old) if l.strip() == ZEND)
    except StopIteration:
        bi = ei = None
    if bi is not None and ei is not None and ei > bi:
        pre, post = old[:bi], old[ei+1:]
    else:
        pre, post = old, []
    body = [ZBEG] + sorted(tunnel) + [ZEND]
    new = pre + body + post
    if new == old:
        print('zapret exclude: up-to-date (%d tunneled domains)' % len(tunnel)); return False
    try:
        with open(ZEXCL + '.tmp', 'w', encoding='utf-8', newline='\n') as f:
            f.write('\n'.join(new) + '\n')
        os.replace(ZEXCL + '.tmp', ZEXCL)
        print('zapret exclude: wrote %d tunneled domains (reload needed)' % len(tunnel))
        return True
    except Exception as e:
        print('zapret exclude: write failed (%s)' % e); return False

# ---------------------------------------------------------------------------
# v1.20.4: zapret direction B - a domain that leaves through the tunnel must NOT stay in
# zapret's FORCE list. Forcing DPI on it is pointless (the WAN only sees the encrypted hop to
# the proxy) and harmful: the fake packets land on the proxy connection, not on the site.
#
# Lines are commented out in place, never deleted, so the operator's list survives and any
# single line can be restored by hand. Domains listed in /etc/geomask/zapret-force-keep.txt
# are never touched - that is where the gaming exceptions live (wardogs / epic / pragmaengine
# must keep being processed even though neighbouring names are tunneled).
ZFORCE = '/opt/zapret/ipset/zapret-hosts-user.txt'
ZKEEP  = '/etc/geomask/zapret-force-keep.txt'
ZMK    = '# geomask: tunneled, DPI removed'
TUNNEL_SET = set()

def _zapret_force_sync():
    if not TUNNEL_SET or not os.path.exists(ZFORCE):
        return
    keep = set()
    if os.path.exists(ZKEEP):
        keep = {l.strip().lower() for l in open(ZKEEP, encoding='utf-8', errors='replace')
                if l.strip() and not l.strip().startswith('#')}
    try:
        lines = open(ZFORCE, encoding='utf-8', errors='replace').read().splitlines()
    except Exception as e:
        print('zapret force: cannot read (%s)' % e); return
    out = []; moved = 0; restored = 0
    for ln in lines:
        s = ln.strip()
        if s.startswith(ZMK):
            dom = s[len(ZMK):].strip().lower()
            if dom in keep or dom not in TUNNEL_SET:
                out.append(dom); restored += 1          # it came back into the clear
            else:
                out.append(ln)                          # still tunneled - keep commented
            continue
        if not s or s.startswith('#'):
            out.append(ln); continue
        dom = s.lower()
        if dom in keep or dom not in TUNNEL_SET:
            out.append(ln)
        else:
            out.append('%s %s' % (ZMK, dom)); moved += 1
    if not moved and not restored:
        print('zapret force: up-to-date'); return
    try:
        with open(ZFORCE + '.tmp', 'w', encoding='utf-8', newline='\n') as f:
            f.write('\n'.join(out) + '\n')
        os.replace(ZFORCE + '.tmp', ZFORCE)
        print('zapret force: %d out of DPI, %d restored (reload needed)' % (moved, restored))
    except Exception as e:
        print('zapret force: write failed (%s)' % e)

try:
    ZAPRET_CHANGED = _zapret_sync()
except Exception as _ze:
    # a zapret problem must never block the mihomo ruleset sync
    ZAPRET_CHANGED = False
    print('zapret exclude: skipped (%s)' % _ze)
try:
    _zapret_force_sync()
except Exception as _zf:
    print('zapret force: skipped (%s)' % _zf)

if c1 or c2 or c3 or c4:
    _r_ok = False
    try:
        req = urllib.request.Request(
            'http://127.0.0.1:9090/configs?force=true',
            data=json.dumps({'path': '/etc/mihomo/config.yaml'}).encode(),
            method='PUT', headers={'Content-Type': 'application/json',
                                   **controller_headers('/etc/mihomo/config.yaml')})
        urllib.request.urlopen(req, timeout=5).read()
        _r_ok = True
        print('mihomo reloaded')
    except Exception as e:
        print('reload FAILED (configuration or controller error; restart needed)')

# v1.10.0: machine-readable last-run state for the panel; journal line only on real change
try:
    _st = {'ts': time.strftime('%F %T'), 'mt': n1, 'ai': n2, 'moved': moved,
           'changed': bool(c1 or c2), 'reload': _r_ok if (c1 or c2) else None}
    with open('/tmp/geomask-sync.state.tmp', 'w') as f:
        json.dump(_st, f)
    os.replace('/tmp/geomask-sync.state.tmp', '/tmp/geomask-sync.state')
except Exception:
    pass
if c1 or c2:
    try:
        with open('/root/geo-sync.log', 'a') as f:
            f.write('%s SYNC changed: VPN=%d AI=%d moved-to-AI=%d reload=%s\n' %
                    (_st['ts'], n1, n2, moved, 'ok' if _r_ok else 'FAILED'))
    except Exception:
        pass
PYEOF
