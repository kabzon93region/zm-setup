#!/bin/sh
# geomask morning check - run BEFORE enabling the torrent client, right after the
# P2P-restricted subscription comes back. Read-only: it never changes routing.
#
#   /root/geomask-morning-check.sh            full check
#   /root/geomask-morning-check.sh --quick    invariants only (no probes)
#
# Exit code 0 = safe to start torrenting. Anything else = read the printed reason.
Q=${1:-}
FAIL=0
ok()   { printf '  OK    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  WARN  %s\n' "$1"; }
CFG=/etc/mihomo/config.yaml
RS=/etc/mihomo/ruleset
SEC=$(grep -m1 -oE '^secret:[[:space:]]*["'\'']?[^"'\''[:space:]]+' $CFG | sed -E 's/^secret:[[:space:]]*["'\'']?//')
api() { curl -s -m 8 -H "Authorization: Bearer $SEC" "http://127.0.0.1:9090$1"; }

echo "=== geomask morning check  $(date '+%F %T') ==="

echo
echo "--- 1. invariants: can P2P reach the restricted slot? ---"
N=$(awk '/^rules:/{f=1;next} f&&/^[^ ]/{exit} f' $CFG | grep -c 'VPN-noP2P')
[ "$N" = "0" ] && ok "no rule at all points at VPN-noP2P" || warn "$N rule(s) point at VPN-noP2P - check which"
P=$(awk '/^rules:/{f=1;next} f&&/^[^ ]/{exit} f' $CFG | grep 'VPN-noP2P$' | grep -cE 'SRC-PORT|DST-PORT|IP-CIDR|NETWORK')
[ "$P" = "0" ] && ok "none of them is a port/IP/protocol match" || bad "$P port/IP rules on the restricted slot"
I=$(grep -cE '^\s*-\s*IP-CIDR' $RS/mtrickle.yaml)
[ "$I" = "0" ] && ok "mtrickle.yaml contains no IP rules" || bad "$I IP rules inside the domain ruleset"
B=$(grep -cE '^\s*-\s*IP-CIDR' $RS/mtrickle_bulk.yaml)
[ "$B" -gt 0 ] && ok "mtrickle_bulk.yaml holds the $B IP rules (tolerant lane)" || bad "IP ruleset is empty"
grep -q 'RULE-SET,mtrickle_bulk,VPN' $CFG && ok "IP ruleset -> VPN (P2P-tolerant)" || bad "IP ruleset is not routed to the tolerant lane"
A=$(awk '/^rules:/{f=1;next} f&&/^[^ ]/{exit} f' $CFG | grep -n 'RULE-SET,ai,AI' | cut -d: -f1)
M=$(awk '/^rules:/{f=1;next} f&&/^[^ ]/{exit} f' $CFG | grep -n 'RULE-SET,mtrickle,' | cut -d: -f1)
[ -n "$A" ] && [ -n "$M" ] && [ "$A" -lt "$M" ] && ok "AI rule is evaluated before the VPN lists ($A < $M)" \
  || bad "AI rule is not ahead of the VPN lists"

echo
echo "--- 2. what is loaded where ---"
for g in VPN VPN-noP2P AI; do
  J=$(api "/proxies/$g")
  L=$(printf '%s' "$J" | tr ',' '\n' | grep -m1 '"now":' | sed -E 's/.*"now":"//; s/",?$//')
  C=$(printf '%s' "$J" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("all") or []))
except Exception: print("?")')
  printf '  %-11s now=%-34s members=%s\n' "$g" "$L" "$C"
done
api '/providers/rules' | tr '{' '\n' | grep -oE '"(ai|mtrickle|mtrickle_bulk|torrentdirect|ytvpn)":\{"[^}]*ruleCount":[0-9]+' \
  | sed -E 's/\{".*ruleCount"/ = /; s/"//g; s/^/    /'

echo
echo "--- 3. tracker: attempts against the restricted slot ---"
/usr/bin/geomask-vpnwatch.sh --report | sed 's/^/  /'
LINES=$(wc -l < /root/geomask-vpn-audit.log 2>/dev/null || echo 0)
BARE=$(/usr/bin/geomask-vpnwatch.sh --report | grep -oE 'bare IPs \(P2P-shaped\): [0-9]+' | grep -oE '[0-9]+$')
[ "${BARE:-0}" = "0" ] && ok "no bare-IP destination ever tried the restricted slot" \
  || bad "$BARE bare-IP destinations tried it - do NOT start torrenting"
echo "    (log lines: $LINES; last entry: $(tail -1 /root/geomask-vpn-audit.log 2>/dev/null | cut -c1-19))"

if [ "$Q" = "--quick" ]; then
  echo; echo "=== quick mode finished: FAIL=$FAIL ==="; exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
fi

DEC() { logread | grep -m1 "$1" | sed -E 's/.*using ([A-Za-z0-9_-]+).*/\1/; s/.*match ([A-Za-z0-9_]+) .*/\1/'; }
echo
echo "--- 4. live probes through the rule chain (listener 7894) ---"
for h in openrouter.ai api.openai.com; do
  C=$(curl -s -o /dev/null -m 12 -x http://192.168.0.1:7894 -w '%{http_code}' "https://$h/" 2>/dev/null)
  D=$(DEC "$h")
  [ "$D" = "AI" ] && ok "$h -> AI (http $C)" || bad "$h -> ${D:-unknown}, expected AI"
done
C=$(curl -s -o /dev/null -m 12 -x http://192.168.0.1:7894 -w '%{http_code}' http://1337.abcvg.info:80/announce 2>/dev/null)
D=$(DEC abcvg)
[ "$D" = "DIRECT" ] && ok "tracker -> DIRECT (http $C)" || warn "tracker -> ${D:-unknown} (expected DIRECT)"
C=$(curl -s -o /dev/null -m 10 -x http://192.168.0.1:7894 -w '%{http_code}' http://188.165.77.110:56627/ 2>/dev/null)
D=$(DEC '188.165.77.110')
[ "$D" = "VPN" ] && ok "peer on an OVH address -> VPN (tolerant lane)" \
  || { [ "$D" = "VPN-noP2P" ] && bad "peer reached the RESTRICTED slot" || warn "peer -> ${D:-unknown}"; }
sleep 1

echo
echo "--- 5. geomask's own verdict ---"
sh /tmp/geomask.sh --check 2>&1 | tail -2 | sed 's/^/  /'

echo
echo "--- 6. DNS safety (stale bypass pins, redirect loops) ---"
if [ -x /usr/bin/geomask-dnscheck.sh ]; then
  /usr/bin/geomask-dnscheck.sh --quick 2>&1 | grep -E 'FAIL|WARN|RESULT' | sed 's/^/  /'
  [ "${PIPESTATUS[0]:-0}" = "0" ] || true
else
  echo "  (geomask-dnscheck.sh not installed)"
fi

echo
if [ $FAIL -eq 0 ]; then
  echo "=== RESULT: safe to enable the torrent client ==="
else
  echo "=== RESULT: $FAIL problem(s) - read the FAIL lines above before torrenting ==="
fi
exit $FAIL
