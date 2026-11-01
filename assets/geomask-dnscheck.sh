#!/bin/sh
# geomask-dnscheck.sh - read-only DNS safety audit (geomask v1.22.1+).
#
#   geomask-dnscheck.sh            full audit (probes the network, ~20 s)
#   geomask-dnscheck.sh --quick    configuration only, no outbound probes
#
# It exists because of two incidents seen on routers of this kind:
#   1) a DoH proxy and an ad blocker both force-redirect port 53, the proxy bootstraps its
#      own server name through that redirected port, and LAN DNS stops answering entirely
#      (symptom: "site address not found", fixed by turning any VPN on);
#   2) a "bypass" address pinned into /etc/hosts goes stale, so every client keeps dialling
#      a dead IP and the site breaks even though the tunnel itself is fine.
# Nothing here changes anything: it only reports.
QUICK=${1:-}
FAIL=0; WARN=0
ok()   { printf '  OK    %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== DNS safety check  $(date '+%F %T') ==="

echo
echo "--- 1) is the resolver actually alive ---"
ANS=$(nslookup yandex.ru 127.0.0.1 2>/dev/null | awk '/^Address: /{print $2; exit}')
[ -n "$ANS" ] && ok "dnsmasq answers on 127.0.0.1:53 ($ANS)" \
  || bad "dnsmasq does NOT answer on 127.0.0.1:53 - LAN clients cannot resolve anything"
ANS2=$(nslookup yandex.ru 192.168.0.1 2>/dev/null | awk '/^Address: /{print $2; exit}')
[ -n "$ANS2" ] && ok "answers on the LAN address too" || bad "does not answer on 192.168.0.1:53"
pgrep -f dnsmasq >/dev/null 2>&1 || bad "no dnsmasq process at all"

echo
echo "--- 2) who owns port 53, and is anything redirected into a loop ---"
LIST=$(netstat -lntu 2>/dev/null | grep -cE ':53[[:space:]]')
[ "$LIST" -gt 0 ] && ok "port 53 has a listener ($LIST socket(s))" || bad "nothing listens on :53"
DOH_PORT=$(uci get https-dns-proxy.@https-dns-proxy[0].listen_port 2>/dev/null)
[ -n "$DOH_PORT" ] && echo "  https-dns-proxy listens on :$DOH_PORT"
# the loop shape: a redirect of :53 that lands on the DoH proxy, while the proxy resolves its
# own server names through :53
NFORCE=0
for pkg in https-dns-proxy adblock-fast; do
  v=$(uci get $pkg.config.force_dns 2>/dev/null)
  [ "$v" = "1" ] && { NFORCE=$((NFORCE+1)); echo "  $pkg claims force_dns"; }
done
# NOTE: use if/elif here. The old `cond && warn ... || ok ...` chain printed BOTH lines,
# because warn() succeeds, so the following || branch still ran.
if [ "$NFORCE" -gt 1 ]; then
  warn "$NFORCE packages both force-redirect DNS - one of them must win, and the usual outcome is a loop"
elif [ "$NFORCE" = "1" ]; then
  ok "exactly one package forces DNS redirection"
else
  ok "no package forces DNS redirection"
fi
if [ -n "$DOH_PORT" ]; then
  REDIR=$(nft list ruleset 2>/dev/null | grep -E 'dport 53' | grep -c "redirect to :$DOH_PORT")
  [ "$REDIR" -gt 0 ] && warn "port 53 is redirected to the DoH proxy :$DOH_PORT - if its bootstrap also uses :53, DNS dies" \
    || ok "no :53 -> :$DOH_PORT redirect (proxy is not in the resolution path)"
fi

echo
echo "--- 3) can the DoH proxy bootstrap at all (this is what breaks silently) ---"
BOOT=$(uci get https-dns-proxy.@https-dns-proxy[0].bootstrap_dns 2>/dev/null)
if [ -n "$BOOT" ]; then
  echo "  bootstrap_dns = $BOOT"
  if [ "$QUICK" = "--quick" ]; then
    echo "  skipped reachability probe (--quick)"
  else
    FIRST=$(echo "$BOOT" | cut -d, -f1 | tr -d ' ')
    case "$FIRST" in
      *[a-zA-Z]*) warn "bootstrap is a hostname ($FIRST) - it needs working DNS to get working DNS" ;;
      *) R=$(python3 - "$FIRST" <<'PY'
import socket, sys
ip=sys.argv[1]
try:
    s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
    # a DNS query for the root NS over UDP; no reply means the ISP drops port 53
    q=bytes.fromhex('abcd01000001000000000000') + b'\x07iso-3166\x02eu\x00\x00\x0c\x00\x01'
    s.sendto(q,(ip,53)); s.recv(512); print('ok')
except Exception:
    print('dead')
PY
)
         [ "$R" = "ok" ] && ok "bootstrap $FIRST answers over UDP:53" \
           || warn "bootstrap $FIRST does NOT answer over UDP:53 - if the proxy ever takes over DNS, clients will hang"
         ;;
    esac
  fi
else
  ok "no https-dns-proxy bootstrap configured"
fi
FAM=$(uci get https-dns-proxy.config.force_ip_family 2>/dev/null)
if [ "$FAM" = "auto" ]; then
  warn "force_ip_family=auto - pin it to 4 (or 6) so the proxy cannot pick a path it redirects itself"
elif [ -n "$FAM" ]; then
  ok "force_ip_family=$FAM"
fi

echo
echo "--- 4) stale bypass pins in /etc/hosts (the Telegram case) ---"
if [ "$QUICK" = "--quick" ]; then
  grep -cE '^[0-9]' /etc/hosts | sed 's/^/  /' | sed 's/  /  pinned address lines: /'
  echo "  skipped liveness probe (--quick)"
else
python3 - <<'PY'
import socket
dead=[]; alive=0; seen=set()
for ln in open('/etc/hosts', encoding='utf-8', errors='replace'):
    ln=ln.strip()
    if not ln or ln.startswith('#'): continue
    p=ln.split()
    if len(p) < 2: continue
    ip=p[0]
    if not ip[0].isdigit() or ip in ('127.0.0.1','0.0.0.0') or ip in seen: continue
    seen.add(ip)
    ok=False
    for port in (443, 80):
        try:
            s=socket.create_connection((ip,port), timeout=3); s.close(); ok=True; break
        except Exception: pass
    if ok: alive+=1
    else: dead.append((ip, p[1], len(p)-1))
print('  live pinned addresses: %d, unreachable: %d' % (alive, len(dead)))
for ip, host, n in dead[:10]:
    print('  WARN  %s (serves %d name%s) does not answer on 443/80 - clients dial a dead address'
          % (ip, n, 's' if n>1 else ''))
PY
fi

echo
echo "--- 5) the tunnels must not be asked to resolve themselves ---"
grep -qE '^dns:' /etc/mihomo/config.yaml 2>/dev/null \
  && warn "mihomo has its own dns: section - verify it does not point at the redirected port" \
  || ok "mihomo uses the system resolver (no own dns section to loop through)"
for t in Mihomo AI VPN-noP2P; do
  [ -e "/sys/class/net/$t" ] && echo "  tunnel $t: present" || warn "tunnel $t missing"
done

echo
if [ $FAIL -eq 0 ] && [ $WARN -eq 0 ]; then echo "=== RESULT: DNS looks healthy ==="
elif [ $FAIL -eq 0 ]; then echo "=== RESULT: working, but $WARN warning(s) above are worth a look ==="
else echo "=== RESULT: $FAIL problem(s) - DNS is likely broken for clients ==="; fi
exit $FAIL
