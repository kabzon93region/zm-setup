#!/bin/sh
# geomask.sh - geo-masking overlay + 2-subscription mihomo stack for OpenWrt
# Workflow: check -> geo overlay -> mihomo 2 subs -> AI-DNS (no DNS leak) -> magitrickle sync -> services -> verify
#
# Usage:
#   sh geomask.sh              interactive menu (status dashboard + actions loop)
#   sh geomask.sh --reinstall  delete -> install -> configure geomask (asks for 2 subscription URLs)
#   sh geomask.sh --backup     create a full settings backup (LuCI-restorable) and exit
#   sh geomask.sh --auto       all steps unattended: check, apply if needed, verify; stop on FAIL
#   sh geomask.sh --check      read-only report of every step (no changes, no downloads)
#   sh geomask.sh --step N     single step N interactively
#   sh geomask.sh --yes        never ask (with --auto/--step/--reinstall)
#   sh geomask.sh --restart    allow mihomo/magitrickle restarts where needed (drops VPN ~3s)
#   sh geomask.sh --vpn-url U --ai-url U    set subscription URLs (kept secret in config only)
#   sh geomask.sh --seed-lists  restore MagiTrickle domain lists from the bundled template (all groups)
#   sh geomask.sh --help
#
# Install (jsDelivr CDN - fast, shows download progress):
#   curl -fL -m 60 -o /tmp/geomask.sh 'https://cdn.jsdelivr.net/gh/kabzon93region/geomask@master/geomask.sh' && sh /tmp/geomask.sh
# wget fallback:
#   wget -T 30 -O /tmp/geomask.sh 'https://cdn.jsdelivr.net/gh/kabzon93region/geomask@master/geomask.sh' && sh /tmp/geomask.sh
# GitHub raw (can be VERY slow from some networks -> looks like a hang; prefer jsDelivr):
#   sh <(wget -qO - 'https://raw.githubusercontent.com/kabzon93region/geomask/master/geomask.sh')
#
# SAFETY: never reboots the router; never restarts working services (only starts missing ones);
#         never touches network/pppoe config; backups before every file write and before ANY
#         mihomo restart (full settings backup via sysupgrade -b -> /root/geomask-backups/,
#         built in /tmp then moved, freshest one kept, published read-only over SMB as
#         'geomask-backups' with links in the panel - v1.9.0),
#         mihomo restart = trial-run on shifted ports FIRST, restart only if the trial starts,
#         and automatic rollback to the previous config if the restarted service does not
#         answer. Hard pin: /root/.geomask-norestart disables --restart entirely.

set -u

GM_VERSION="1.21.7"
GM_PREFIX="${GM_PREFIX:-}"          # path prefix for tests (empty on real router)
GM_YES=0
GM_AUTO=0
GM_CHECK_ONLY=0
GM_RESTART=0
GM_BACKUP=0
GM_REINSTALL=0
GM_SEED_LISTS=0
GM_STEP=""
GM_VPN_URL=""
GM_AI_URL=""

# ---- embedded assets are injected by build.py into the heredocs below ----

PASS=0; FAILCNT=0; SKIP=0

log()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAILCNT=$((FAILCNT+1)); }
warn() { printf '  [WARN] %s\n' "$*"; }
hdr()  { printf '\n== [%s] %s ==\n' "$1" "$2"; }

ask() { # ask "question" -> 0=yes  (auto/yes modes never block)
  [ "$GM_YES" = 1 ] && return 0
  [ "$GM_AUTO" = 1 ] && return 0
  printf '%s [y/N]: ' "$1"
  read -r _a || return 1
  case "$_a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

P() { printf '%s%s' "$GM_PREFIX" "$1"; }

# Keep authentication out of curl argv and diagnostics; read the active config on each call.
controller_curl() {
  python3 - "$(P /etc/mihomo/config.yaml)" "$@" <<'GM_CONTROLLER_PY'
import json, re, subprocess, sys

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

try:
    headers = controller_headers(sys.argv[1])
    options = ''.join('header = ' + json.dumps(k + ': ' + v, ensure_ascii=False) + '\n'
                      for k, v in headers.items())
    result = subprocess.run(['curl', '--config', '-', *sys.argv[2:]],
                            input=options.encode('utf-8'))
    sys.exit(result.returncode)
except Exception:
    print('Controller request failed (configuration or transport error)', file=sys.stderr)
    sys.exit(1)
GM_CONTROLLER_PY
}

# extract provider url from mihomo config: _prov_url <file> <provider-name>
_prov_url() {
  awk -v p="^  $2:" '$0 ~ p {f=1;next} f && /^    url:/{gsub(/^[^"]*"/,"");gsub(/".*/,"");print;exit} f && /^  [A-Za-z0-9_-]+:/{f=0} f && /^[A-Za-z]/{f=0}' "$1" 2>/dev/null
}

save_stream() { # save_stream <target-path> <mode>  (content on stdin)
  _t="$(P "$1")"; _m="$2"
  mkdir -p "$(dirname "$_t")"
  _tmp="$_t.zmnew"
  cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
  if [ -f "$_t" ]; then
    if cmp -s "$_tmp" "$_t"; then rm -f "$_tmp"; info "unchanged: $1"; return 0; fi
    cp -p "$_t" "$_t.bak_geomask_$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
  fi
  chmod "$_m" "$_tmp" 2>/dev/null || true
  mv -f "$_tmp" "$_t" || return 1
  info "written: $1 (mode $_m)"
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

svc_alive() { pidof "$1" >/dev/null 2>&1; }

initd() { # initd <svc> <action>  - respects GM_PREFIX for tests
  "$(P /etc/init.d/$1)" "$2" 2>/dev/null
}

# ============================================================ STEP 1: env
step1_check() {
  _need=0
  [ -f "$(P /etc/openwrt_release)" ] && info "OpenWrt: $(grep '^DISTRIB_RELEASE=' "$(P /etc/openwrt_release)" 2>/dev/null | cut -d"'" -f2)" || { bad "not OpenWrt (/etc/openwrt_release missing)"; _need=1; }
  if have apk; then info "pkg manager: apk"; elif have opkg; then info "pkg manager: opkg"; else bad "no apk/opkg"; _need=1; fi
  for c in python3 curl; do
    if have "$c"; then info "$c: present"; else warn "$c: MISSING (needed for magitrickle->mihomo sync)"; _need=1; fi
  done
  _tmp=$(df -m "$(P /tmp)" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "${_tmp:-}" ] && [ "$_tmp" -ge 20 ] 2>/dev/null; then info "/tmp free: ${_tmp}MB"; else warn "/tmp free low or unknown"; _need=1; fi
  _root=$(df -m "$(P /)" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "${_root:-}" ] && [ "$_root" -ge 30 ] 2>/dev/null; then info "root free: ${_root}MB"; else warn "root free low or unknown"; _need=1; fi
  _code=$(curl -m 5 -s -o /dev/null -w '%{http_code}' http://www.gstatic.com/generate_204 2>/dev/null)
  if [ "$_code" = "204" ]; then info "internet: OK (204 via router path)"; else warn "internet check: HTTP ${_code:-none} (WAN may be down)"; _need=1; fi
  return $_need
}
step1_apply() { warn "env issues cannot be auto-fixed here - fix manually, then re-run"; }
step1_verify() { step1_check; }

# ============================================================ STEP 2: geo overlay (ours)

# ============================================================ STEP 2: geo overlay (ours)
step2_check() {
  _need=0
  for f in /usr/bin/geo-backend.sh /usr/libexec/rpcd/geo-sync \
           /usr/share/rpcd/acl.d/luci-app-geo-sync.json \
           /usr/share/luci/menu.d/luci-app-geo-sync.json \
           /www/luci-static/resources/view/geo-sync/main.js; do
    if [ -s "$(P "$f")" ]; then info "present: $f"; else bad "missing: $f"; _need=1; fi
  done
  if have ubus && ubus list 2>/dev/null | grep -qx 'geo-sync'; then info "ubus geo-sync: registered"; else bad "ubus geo-sync not registered"; _need=1; fi
  if [ -e /etc/ksmbd/ksmbd.conf ]; then
    if grep -qF "[geomask-backups]" /etc/ksmbd/ksmbd.conf; then info "SMB share geomask-backups: present"
    else bad "SMB share geomask-backups missing"; _need=1; fi
  fi
  return $_need
}
step2_apply() {
  save_stream /usr/bin/geo-backend.sh 755 <<'ASSET_EOF'
#!/bin/sh
# geo-backend.sh - backend for LuCI "Гео-маскировка и AI" panel (geo-sync ubus object).
# Commands:
#   status | leases | log | sync_lists | google | backups | stack | nodescan
#   nodes_get | nodes_set <0|1> <HH:MM> <countries> <asns> <base> <provider>
#   sync_set <N> | syncd_set <on|off> | pin_set <on|off>   (v1.12.0 automation controls)
#   lists_get | lists_seed   (v1.13.0 bundled MagiTrickle lists template: status + restore)
#   global <direct|vpn> | ipv6 <on|off>
#   dev_add <ip> <mode> [mac] [name] | dev_del <ip>
#     modes: bypass (real IP) | realtz (VPN, own tz) | ai (FULLY via AI subscription)
#   ai_sub_get | ai_sub_set <url>   (AI subscription / mihomo provider de5)
#   subs_list | sub_add <name> <url> | sub_del <id>
#   ai_sub_use <id> | vpn_sub_use <id>  (switch provider url from registry, no mihomo restart)
#   upd_check [force] | upd_status | upd_apply   (self-update from GitHub releases, v1.7.0+)
# Device modes (per-device geo policy):
#   bypass  - device routes DIRECT (real IP), beats fwmark+Mihomo; real tz (GeoSync off on PC)
#   realtz  - device routes via mihomo (masked IP), but PC keeps real tz (GeoSync off on PC)
# NOTE: router timezone is NOT used for geo-masking (Google reads the PC browser tz), so no
#       tz commands here. PC-side tz is handled by GeoSync.ps1 on each PC.
# Output: JSON on stdout. Exit 0.

DEVICES=/etc/geo-devices.list
EXCL_OLD=/etc/geo-exclude.list   # legacy (ip name) -> migrated to DEVICES as bypass
SUBS_FILE=/etc/geomask-subs.list # registry: id|name|url (one per line)
AI_TUN_DEV=AI
AI_TUN_IP=198.19.0.1
AI_SOCKS_PORT=7891
LOG=/root/geo-sync.log
MIHOMO_API=http://127.0.0.1:9090
MIHOMO_CONF=/etc/mihomo/config.yaml
TUN=http://127.0.0.1:7890
SYNCLISTS=/root/sync_mtrickle_mihomo.sh
AI_RULES=/etc/mihomo/ruleset/ai.yaml
MT_RULES=/etc/mihomo/ruleset/mtrickle.yaml
BACKEND_VERSION="1.21.7"
# self-update state (panel button): check cache, status file, detached runner
UPD_DIR=/tmp/geomask-upd
UPD_CHECK=$UPD_DIR/check.json
UPD_STATUS=$UPD_DIR/status.json
UPD_PIDF=$UPD_DIR/pid
UPD_TTL=3600
UPD_REPO=kabzon93region/geomask
DEPLOY_JS=/www/luci-static/resources/view/geo-sync/main.js
DEPLOY_GUARD=/usr/bin/geomask-guard.sh
DEPLOY_BACKEND=/usr/bin/geo-backend.sh

# Keep authentication out of curl argv and diagnostics; read the active config on each call.
controller_curl() {
  python3 - "$MIHOMO_CONF" "$@" <<'GM_CONTROLLER_PY'
import json, re, subprocess, sys

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

try:
    headers = controller_headers(sys.argv[1])
    options = ''.join('header = ' + json.dumps(k + ': ' + v, ensure_ascii=False) + '\n'
                      for k, v in headers.items())
    result = subprocess.run(['curl', '--config', '-', *sys.argv[2:]],
                            input=options.encode('utf-8'))
    sys.exit(result.returncode)
except Exception:
    print('Controller request failed (configuration or transport error)', file=sys.stderr)
    sys.exit(1)
GM_CONTROLLER_PY
}

# escape a string for JSON: backslash, quote, tab; CR stripped; newline -> \n
json_esc() {
  printf '%s' "$1" | awk '
    BEGIN { ORS="" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      gsub(/\r/, "")
      if (NR>1) printf "\\n"
      print
    }
  '
}

# current node of a mihomo group (VPN or AI)
_grp_node() {
  controller_curl -s -m3 "$MIHOMO_API/proxies/$1" | grep -oE '"now":"[^"]*"' | head -1 | sed 's/"now":"//; s/"$//'
}

# count rules in a rule-provider yaml (payload lines starting with "  - ")
_count_rules() {
  [ -f "$1" ] && grep -cE '^  - ' "$1" 2>/dev/null || echo 0
}

# migrate legacy /etc/geo-exclude.list (ip name) -> /etc/geo-devices.list (ip mode name)
_migrate() {
  if [ -f "$EXCL_OLD" ] && [ ! -f "$DEVICES" ]; then
    while read -r dip dname; do
      case "$dip" in ''|'#'*) continue ;; esac
      echo "$dip bypass ${dname:-$dip}" >> "$DEVICES"
    done < "$EXCL_OLD"
    echo "$(date +%FT%T) MIGRATE exclude->devices (all bypass)" >> "$LOG"
  fi
}

_prov_of_group() { # _prov_of_group <group> -> provider name used by that mihomo group ('' if none)
  python3 -c '
import re,sys
try: t=open("/etc/mihomo/config.yaml",encoding="utf-8").read()
except Exception: sys.exit(0)
m=re.search(r"(?m)^  - name: %s\s*\n(?:^(?:    .*|\s*)\n)*" % re.escape(sys.argv[1]), t)
if not m: sys.exit(0)
u=re.search(r"use:\n\s+-\s+(\S+)", m.group(0))
print(u.group(1) if u else "")
' "$1" 2>/dev/null
}

_url_of_provider() { # _url_of_provider <provider> -> its url line
  P="$1"
  awk -v p="  $P:" '$0==p{f=1;next} f&&/^    url:/{gsub(/^[^"]*"/,"");gsub(/".*/,"");print;exit} f&&/^  [A-Za-z0-9_-]+:/{exit}' "$MIHOMO_CONF" 2>/dev/null
}

cmd_status() {
  _migrate
  VPN_NODE=$(_grp_node VPN)          # slot VPN: P2P-tolerant tunnel (may be absent)
  VPNNP_NODE=$(_grp_node VPN-noP2P)  # slot VPN-noP2P: the subscription whose provider forbids P2P
  AI_NODE=$(_grp_node AI)
  GLOBAL=$(controller_curl -s -m3 "$MIHOMO_API/proxies/GLOBAL" | grep -oE '"now":"[^"]*"' | head -1 | sed 's/"now":"//; s/"$//')
  if crontab -l 2>/dev/null | grep -q 'sync_mtrickle_mihomo'; then LCRON=1; else LCRON=0; fi
  if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then V6=0;
    elif [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ]; then V6=0; else V6=1; fi
  DOH=$(uci -q get https-dns-proxy.@https-dns-proxy[0].resolver_url || echo '')
  AI_RC=$(_count_rules "$AI_RULES")
  MT_RC=$(_count_rules "$MT_RULES")
  GOOGLE_CC=$(cat /tmp/geo-google 2>/dev/null || echo '')
  SYNC_AT=$(cat /tmp/geo-sync-at 2>/dev/null || echo '')
  DEV_LIST='['
  FIRST=1
  if [ -f "$DEVICES" ]; then
    while read -r dip dmode dname; do
      case "$dip" in ''|'#'*) continue ;; esac
      [ "$FIRST" = 1 ] || DEV_LIST="$DEV_LIST,"
      DEV_LIST="$DEV_LIST{\"ip\":\"$dip\",\"mode\":\"$dmode\",\"name\":\"$(json_esc "${dname:-}")\"}"
      FIRST=0
    done < "$DEVICES"
  fi
  DEV_LIST="$DEV_LIST]"
  BYPASS=$(printf '%s' "$DEV_LIST" | grep -o '"mode":"bypass"' | wc -l | tr -d ' ')
  REALTZ=$(printf '%s' "$DEV_LIST" | grep -o '"mode":"realtz"' | wc -l | tr -d ' ')
  N_AI=$(printf '%s' "$DEV_LIST" | grep -o '"mode":"ai"' | wc -l | tr -d ' ')
  RULES=$(ip rule show | grep -c 'lookup main' || echo 0)
  _de5u=$(_url_of_provider "$(_prov_of_group AI)")
  [ -n "$_de5u" ] || _de5u=$(_url_of_provider de5)
  _sub2u=$(_url_of_provider "$(_prov_of_group VPN)")
  _subu=$(_url_of_provider "$(_prov_of_group VPN-noP2P)")
  AI_SUB_ID=$(_sub_id_by_url "$_de5u" 2>/dev/null || echo '')
  VPN_SUB_ID=$(_sub_id_by_url "$_sub2u" 2>/dev/null || echo '')
  VPNNP_SUB_ID=$(_sub_id_by_url "$_subu" 2>/dev/null || echo '')
  if ip link show "$AI_TUN_DEV" >/dev/null 2>&1; then AI_TUN=1; else AI_TUN=0; fi
  if netstat -lntp 2>/dev/null | grep -q ':7891'; then AI_LST=1; else AI_LST=0; fi
  # AI-DNS (no DNS leak for AI devices): 0=off/absent, 1=working, 2=partial
  # working = ip rule routes marked DNS to the AI tunnel AND the AI DNS chain listens
  if [ -f /etc/geomask-aidns.off ] || [ ! -f /etc/geomask-aidns.uid ]; then AIDNS=0
  elif ip route get 1.1.1.1 mark 0x64 2>/dev/null | grep -q 'dev AI' \
       && netstat -ltnpu 2>/dev/null | grep -q '192.168.0.53:5353 '; then AIDNS=1
  else AIDNS=2; fi
  printf '{"vpn_node":"%s","vpn_cc":"%s","vpn_nop2p_node":"%s","vpn_nop2p_cc":"%s","ai_node":"%s","ai_cc":"%s","global":"%s","lcron":%s,"ipv6":%s,"doh":"%s","ai_rules":%s,"mt_rules":%s,"google":"%s","sync_at":"%s","devices":%s,"n_bypass":%s,"n_realtz":%s,"rules_ok":%s,"n_ai":%s,"ai_tun":%s,"ai_listener":%s,"ai_sub":"%s","vpn_sub":"%s","vpn_nop2p_sub":"%s","ai_url":"%s","vpn_url":"%s","vpn_nop2p_url":"%s","aidns":%s}' \
    "$(json_esc "$VPN_NODE")" "$(_node_cc "$VPN_NODE")" \
    "$(json_esc "$VPNNP_NODE")" "$(_node_cc "$VPNNP_NODE")" \
    "$(json_esc "$AI_NODE")" "$(_node_cc "$AI_NODE")" \
    "$(json_esc "$GLOBAL")" "$LCRON" "$V6" "$(json_esc "$DOH")" \
    "$AI_RC" "$MT_RC" "$(json_esc "$GOOGLE_CC")" "$(json_esc "$SYNC_AT")" \
    "$DEV_LIST" "$BYPASS" "$REALTZ" "$RULES" \
    "$N_AI" "$AI_TUN" "$AI_LST" "$(json_esc "$AI_SUB_ID")" "$(json_esc "$VPN_SUB_ID")" "$(json_esc "$VPNNP_SUB_ID")" \
    "$(json_esc "$_de5u")" "$(json_esc "$_sub2u")" "$(json_esc "$_subu")" "$AIDNS"
}

# country fragment from a node name (flag emoji or RU word) - coarse, for display
_node_cc() {
  n="$1"
  case "$n" in
    *Германия*|*Germany*|*🇩🇪*) echo DE ;;
    *Нидерланды*|*Netherlands*|*🇳🇱*) echo NL ;;
    *Финляндия*|*Finland*|*🇫🇮*) echo FI ;;
    *Латвия*|*Latvia*|*🇱🇻*) echo LV ;;
    *Литва*|*Lithuania*|*🇱🇹*) echo LT ;;
    *Эстония*|*Estonia*|*🇪🇪*) echo EE ;;
    *Польша*|*Poland*|*🇵🇱*) echo PL ;;
    *Дания*|*Denmark*|*🇩🇰*) echo DK ;;
    *Швеция*|*Sweden*|*🇸🇪*) echo SE ;;
    *Норвегия*|*Norway*|*🇳🇴*) echo NO ;;
    *США*|*USA*|*🇺🇸*) echo US ;;
    *Турция*|*Turkey*|*🇹🇷*) echo TR ;;
    *Албания*|*Albania*|*🇦🇱*) echo AL ;;
    *Франция*|*France*|*🇫🇷*) echo FR ;;
    *Италия*|*Italy*|*🇮🇹*) echo IT ;;
    *Испания*|*Spain*|*🇪🇸*) echo ES ;;
    *Австрия*|*Austria*|*🇦🇹*) echo AT ;;
    *Швейцария*|*Switzerland*|*🇨🇭*) echo CH ;;
    *Великобритания*|*UK*|*🇬🇧*) echo GB ;;
    *) echo '' ;;
  esac
}

cmd_leases() {
  printf '{"leases":['
  [ -f /tmp/dhcp.leases ] || { printf ']}'; return; }
  FIRST=1
  while read -r ts mac ip name rest; do
    [ -n "$ip" ] || continue
    [ $FIRST -eq 1 ] || printf ','
    printf '{"ip":"%s","mac":"%s","name":"%s"}' "$ip" "$mac" "$(json_esc "${name:-}")"
    FIRST=0
  done < /tmp/dhcp.leases
  printf ']}'
}

cmd_log() {
  printf '{"log":"%s"}' "$(json_esc "$(tail -30 "$LOG" 2>/dev/null)")"
}

# manual list sync (magitrickle -> mihomo rulesets), runs the cron script immediately
cmd_sync_lists() {
  OUT=$(sh "$SYNCLISTS" 2>&1)
  date '+%F %T' > /tmp/geo-sync-at
  echo "$(date +%FT%T) SYNC_LISTS manual" >> "$LOG"
  AI_RC=$(_count_rules "$AI_RULES")
  MT_RC=$(_count_rules "$MT_RULES")
  printf '{"ai_rules":%s,"mt_rules":%s,"output":"%s"}' "$AI_RC" "$MT_RC" "$(json_esc "$OUT")"
}

# quick Google geo-check: country of the exit that Google traffic actually uses.
# Google/AI domains are routed to group AI (ai.yaml), so asking an IP-geo service
# through the AI listener (mihomo listeners: proxy=AI) reports exactly what Google sees.
cmd_google() {
  CC=$(curl -s -m15 -x "http://127.0.0.1:$AI_SOCKS_PORT" \
    'https://ipinfo.io/country' 2>/dev/null | tr -d '[:space:]')
  case "$CC" in [A-Z][A-Z]) ;; *) CC='' ;; esac
  [ -n "$CC" ] && printf '%s\n' "$CC" > /tmp/geo-google
  AI_NODE=$(_grp_node AI)
  printf '{"google":"%s","ai_node":"%s"}' "$(json_esc "$CC")" "$(json_esc "$AI_NODE")"
}

cmd_global() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    direct) NAME=DIRECT ;;
    vpn)    NAME=VPN ;;
    *) printf '{"error":"bad arg"}'; return 1 ;;
  esac
  controller_curl -s -m5 -X PUT "$MIHOMO_API/proxies/GLOBAL" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$NAME\"}" >/dev/null
  cmd_status
}

cmd_ipv6() {
  case "$1" in
    off)
      cp -n /etc/config/network "/etc/config/network.bak_v6off_$(date +%s)" 2>/dev/null || true
      echo 'net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1' > /etc/sysctl.d/99-disable-ipv6.conf
      sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1
      for d in /proc/sys/net/ipv6/conf/*; do echo 1 > "$d/disable_ipv6" 2>/dev/null || true; done
      uci set network.lan.ip6assign='0'; uci commit network
      reload_config 2>/dev/null || ubus call network reload >/dev/null 2>&1
      ;;
    on)
      rm -f /etc/sysctl.d/99-disable-ipv6.conf
      for d in /proc/sys/net/ipv6/conf/*; do echo 0 > "$d/disable_ipv6" 2>/dev/null || true; done
      uci set network.lan.ip6assign='60'; uci commit network
      reload_config 2>/dev/null || ubus call network reload >/dev/null 2>&1
      ;;
    *) printf '{"error":"bad arg"}'; return 1 ;;
  esac
  sleep 1
  cmd_status
}

# AI-DNS on demand: regenerate the nft DNAT list for ai-mode devices + reload firewall.
# Installs nothing (that is the installer's aidns step); only re-syncs the device list.
cmd_aidns_apply() {
  if [ -f /etc/geomask-aidns.off ]; then
    printf '{"ok":true,"warn":"AI-DNS disabled (/etc/geomask-aidns.off)"}'
    return 0
  fi
  if [ ! -f /etc/geomask-aidns.uid ]; then
    printf '{"ok":false,"warn":"AI-DNS not installed - run the aidns step of geomask"}'
    return 0
  fi
  _before=$(cat /tmp/geomask-aidns-last 2>/dev/null)
  _aidns_sync
  _after=$(cat /tmp/geomask-aidns-last 2>/dev/null)
  if [ "$_before" != "$_after" ]; then
    echo "$(date +%FT%T) AI-DNS apply (manual)" >> "$LOG"
    printf '{"ok":true,"warn":""}'
  else
    printf '{"ok":true,"warn":"no changes"}'
  fi
  return 0
}

# add/update a device geo-policy: dev_add <ip> <mode> [mac] [name]
cmd_dev_add() {
  IP="$1"; MODE="$2"; MAC="$3"; NAME="${4:-$IP}"
  case "$IP" in ''|*[!0-9.]*) printf '{"error":"bad ip"}'; return 1 ;; esac
  echo "$IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { printf '{"error":"bad ip"}'; return 1; }
  case "$MODE" in bypass|realtz|ai) ;; *) printf '{"error":"bad mode"}'; return 1 ;; esac
  NAME=$(printf '%s' "$NAME" | tr -d '"\\"\n\r\t' | head -c 64)
  mkdir -p "$(dirname "$DEVICES")"; touch "$DEVICES"
  # replace existing entry for this ip
  grep -v "^$IP " "$DEVICES" > "$DEVICES.tmp" 2>/dev/null || true
  mv -f "$DEVICES.tmp" "$DEVICES"
  echo "$IP $MODE $NAME" >> "$DEVICES"
  # stable lease if mac given (strict MAC format only)
  if [ -n "$MAC" ] && echo "$MAC" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'; then
    if ! uci show dhcp | grep -q "\.mac='$MAC'"; then
      SEC="dhcp.$(uci add dhcp host)"
      uci set "$SEC.mac=$MAC"; uci set "$SEC.ip=$IP"; uci set "$SEC.name=$NAME"
      uci commit dhcp
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    fi
  fi
  _apply_routing
  echo "$(date +%FT%T) DEV add $IP mode=$MODE ($NAME)" >> "$LOG"
  cmd_status
}

cmd_dev_del() {
  IP="$1"
  case "$IP" in ''|*[!0-9.]*) printf '{"error":"bad ip"}'; return 1 ;; esac
  echo "$IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { printf '{"error":"bad ip"}'; return 1; }
  [ -f "$DEVICES" ] && sed -i "\|^$IP |d" "$DEVICES"
  # remove rules for this ip explicitly per table (bypass -> main, ai -> 101).
  # NEVER delete by pref alone: all per-device rules share priority 19900, so
  # `ip rule del pref` would drop another device's rule (and _apply_routing re-adds it)
  ip rule del from "$IP" lookup main 2>/dev/null || true
  ip rule del from "$IP" lookup 101 2>/dev/null || true
  SEC=$(uci show dhcp | grep "\.ip='$IP'" | head -1 | sed "s/\.ip=.*//")
  if [ -n "$SEC" ]; then uci delete "$SEC"; uci commit dhcp; fi
  _apply_routing
  echo "$(date +%FT%T) DEV del $IP" >> "$LOG"
  cmd_status
}

# AI-DNS: keep the nft DNAT list in sync with the ai-mode devices of /etc/geo-devices.list.
# No-op when the step was not installed (/etc/geomask-aidns.uid absent) or disabled
# (/etc/geomask-aidns.off present). Firewall is reloaded only when the list changes.
# NOTE: the AI dnsmasq listens on 192.168.0.53:5353 (NOT :53) - the main dnsmasq
# rebinds every interface address including our alias, so :53 there is taken.
_aidns_sync() {
  [ -f /etc/geomask-aidns.uid ] || return 0
  [ -f /etc/geomask-aidns.off ] && return 0
  _uid=$(cat /etc/geomask-aidns.uid 2>/dev/null | tr -dc '0-9')
  [ -n "$_uid" ] || return 0
  _ips=$(awk '$2=="ai" && $1 !~ /^#/ {print $1}' "$DEVICES" 2>/dev/null)
  _list=""
  for _ip in $_ips; do _list="$_list $_ip,"; done
  _list=${_list%,}
  {
    printf '# geomask AI-DNS (auto-generated from /etc/geo-devices.list - do not edit)\n'
    printf '# DNS of AI-mode devices goes into the AI tunnel: no DNS leak, no geo mismatch.\n'
    printf '# idempotent include pattern (same as 20-https-dns-proxy-notrack.nft)\n'
    printf 'add table inet geomask_ai_dns\n'
    printf 'flush table inet geomask_ai_dns\n'
    printf 'add chain inet geomask_ai_dns pre_nat { type nat hook prerouting priority -110; policy accept; }\n'
    printf 'add chain inet geomask_ai_dns out_mark { type route hook output priority -150; policy accept; }\n'
    printf 'add rule inet geomask_ai_dns out_mark meta skuid %s mark set 0x64\n' "$_uid"
    if [ -n "$_list" ]; then
      printf 'add rule inet geomask_ai_dns pre_nat ip saddr { %s } meta l4proto { tcp, udp } th dport 53 dnat ip to 192.168.0.53:5353\n' "$_list"
    fi
  } > /tmp/geomask-aidns.nft 2>/dev/null || return 0
  if ! nft -c -f /tmp/geomask-aidns.nft >/dev/null 2>&1; then
    rm -f /tmp/geomask-aidns.nft
    echo "$(date +%FT%T) AI-DNS: generated rules failed syntax check" >> "$LOG"
    return 0
  fi
  cp /tmp/geomask-aidns.nft /usr/share/nftables.d/ruleset-post/98-geomask-ai-dns.nft 2>/dev/null
  rm -f /tmp/geomask-aidns.nft
  if [ "${_list}" != "$(cat /tmp/geomask-aidns-last 2>/dev/null)" ]; then
    printf '%s' "$_list" > /tmp/geomask-aidns-last
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    echo "$(date +%FT%T) AI-DNS: device list updated -> firewall reloaded" >> "$LOG"
  fi
  return 0
}

# (re)apply routing for all managed devices:
#   bypass -> direct (19900) | realtz -> normal mihomo path | ai -> AI tunnel (19900 -> table 101 -> dev AI)
_apply_routing() {
  # drop stale per-device rules first (we re-add per mode)
  if [ -f "$DEVICES" ]; then
    while read -r dip dmode dname; do
      case "$dip" in ''|'#'*) continue ;; esac
      ip rule del from "$dip" lookup main 2>/dev/null || true
      ip rule del from "$dip" lookup 101 2>/dev/null || true
    done < "$DEVICES"
    while read -r dip dmode dname; do
      case "$dip" in ''|'#'*) continue ;; esac
      if [ "$dmode" = "bypass" ]; then
        ip rule show | grep -q "from $dip" || ip rule add priority 19900 from "$dip" lookup main
      elif [ "$dmode" = "ai" ]; then
        _ai_tun_ensure
           ip rule show | grep -q "from $dip" || ip rule add priority 19900 from "$dip" lookup 101
      fi
    done < "$DEVICES"
  fi
  _hotplug_sync
  _aidns_sync
}

# provision AI tunnel on first use: hev-socks5-tunnel instance #2 (own TUN "AI",
# socks 127.0.0.1:7891) + network iface + firewall zone. The WORKING main tunnel
# is never restarted - hev-ai is a separate init.d service.
_ai_tun_ensure() {
  mkdir -p /etc/hev-socks5-tunnel
  if [ ! -f /etc/hev-socks5-tunnel/ai.yml ]; then
    cat > /etc/hev-socks5-tunnel/ai.yml <<'EOF'
tunnel:
  name: AI
  mtu: 8500
  multi-queue: false
  ipv4: 198.19.0.1
socks5:
  port: 7891
  address: 127.0.0.1
  udp: 'udp'
EOF
  fi
  if [ ! -x /etc/init.d/hev-ai ]; then
    cat > /etc/init.d/hev-ai <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/hev-socks5-tunnel /etc/hev-socks5-tunnel/ai.yml
  procd_set_param file /etc/hev-socks5-tunnel/ai.yml
  procd_set_param limits core="unlimited"
  procd_set_param limits nofile="1000000 1000000"
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param respawn
  procd_close_instance
}
EOF
    chmod +x /etc/init.d/hev-ai
  fi
  ip link show "$AI_TUN_DEV" >/dev/null 2>&1 || {
    /etc/init.d/hev-ai enable >/dev/null 2>&1
    /etc/init.d/hev-ai start >/dev/null 2>&1
    _i=0
    while [ $_i -lt 10 ] && ! ip link show "$AI_TUN_DEV" >/dev/null 2>&1; do
      sleep 1; _i=$((_i+1))
    done
  }
  uci -q get network.AI >/dev/null 2>&1 || {
    uci set network.AI=interface
    uci set network.AI.proto='none'
    uci set network.AI.device="$AI_TUN_DEV"
    uci commit network
  }
  if ! uci -q show firewall 2>/dev/null | grep -q "name='AI'"; then
    # clone the working Mihomo zone + its forwardings for the AI tunnel
    ZN=''
    for s in $(uci -q show firewall | sed -n 's/^\(firewall\.[^.]*\)=zone$/\1/p'); do
      [ "$(uci -q get "$s.name")" = "Mihomo" ] && { ZN="$s"; break; }
    done
    if [ -n "$ZN" ]; then
      NEW=$(uci add firewall zone)
      uci set "firewall.$NEW.name=AI"
      uci set "firewall.$NEW.input=$(uci -q get "$ZN.input")"
      uci set "firewall.$NEW.output=$(uci -q get "$ZN.output")"
      uci set "firewall.$NEW.forward=$(uci -q get "$ZN.forward")"
      uci set "firewall.$NEW.masq=$(uci -q get "$ZN.masq")"
      uci set "firewall.$NEW.mtu_fix=$(uci -q get "$ZN.mtu_fix")"
      uci set "firewall.$NEW.network=AI"
      for f in $(uci -q show firewall | sed -n 's/^\(firewall\.[^.]*\)=forwarding$/\1/p'); do
        [ "$(uci -q get "$f.src")" = "lan" ] && [ "$(uci -q get "$f.dest")" = "Mihomo" ] || continue
        NF=$(uci add firewall forwarding)
        uci set "firewall.$NF.src=lan"
        uci set "firewall.$NF.dest=AI"
      done
      for f in $(uci -q show firewall | sed -n 's/^\(firewall\.[^.]*\)=forwarding$/\1/p'); do
        [ "$(uci -q get "$f.src")" = "Mihomo" ] && [ "$(uci -q get "$f.dest")" = "lan" ] || continue
        NF=$(uci add firewall forwarding)
        uci set "firewall.$NF.src=AI"
        uci set "firewall.$NF.dest=lan"
      done
      uci commit firewall
      # uci forwarding lan->AI alone does NOT generate an accept rule (the zone
      # subnet is a /32 assigned by the TUN itself, so fw4 leaves accept_to_AI
      # empty and forwarded LAN packets are dropped). Drop-in adds the accept.
      mkdir -p /usr/share/nftables.d/ruleset-post
      cat > /usr/share/nftables.d/ruleset-post/99-ai-accept.nft <<'EOF'
table inet fw4 {
    chain accept_to_AI {
        iifname "br-lan" oifname "AI" counter accept comment "custom: LAN clients to AI tunnel"
        iifname "Wireguard" oifname "AI" counter accept comment "custom: WG peers to AI tunnel"
    }
}
EOF
      /etc/init.d/firewall reload >/dev/null 2>&1
    fi
  fi
  # table 101: LAN/host routes must stay local, only internet goes to AI tunnel
  ip route show table main | grep -v '^default' | while IFS= read -r _r; do
    ip route replace table 101 $_r 2>/dev/null
  done
  ip route replace table 101 default dev "$AI_TUN_DEV" 2>/dev/null
  echo "$(date +%FT%T) AI_TUN provisioned" >> "$LOG"
}

_hotplug_sync() {
  cat > /etc/hotplug.d/iface/99-default-vpn-route <<'EOF'
#!/bin/sh
# Route unmarked LAN traffic to Mihomo TUN; magitrickle marks take precedence.
# Devices from /etc/geo-devices.list with mode=bypass go DIRECT (real IP), never via VPN.
# Devices with mode=realtz follow normal mihomo routing (masked IP), only tz is real (PC-side).
# NOTE: runs inside netifd's ifup path -> MUST NOT block here (would stall PPPoE auth / WAN).
[ "$ACTION" = "ifup" ] || exit 0

apply_routes() {
  if ! ip route show table 100 | grep -q '^default'; then
    ip route show table main | grep -v '^default' | while IFS= read -r r; do
      ip route replace table 100 $r 2>/dev/null
    done
    ip route replace table 100 default dev Mihomo 2>/dev/null
  fi
  ip rule show | grep -q '32760:' || ip rule add priority 32760 iif br-lan lookup 100
  # --- ICMP bypass: 19901 stays ABOVE the magitrickle fwmark rule base
  #     (dynamic, observed 32558..32609) so ping to a marked IP never dies
  #     inside the TUN. Direct via pppoe-wan. Guard reseats the rule to
  #     (base - 100) when the base drifts, so presence is checked by SEMANTICS,
  #     never by the 19901 prefix (v1.6.2: no duplicates after a reseat). ---
  ip rule show | grep -q 'iif br-lan ipproto icmp lookup main' || ip rule add priority 19901 iif br-lan ipproto icmp lookup main
  # --- bypass-mode devices (19900 is safely above the magitrickle fwmark base,
  #     so marking cannot preempt a device rule; LAN stays local) ---
  if [ -f /etc/geo-devices.list ]; then
    while read -r dip dmode dname; do
      case "$dip" in ''|'#'*) continue ;; esac
      [ "$dmode" = "bypass" ] || continue
      ip rule show | grep -q "from $dip" || ip rule add priority 19900 from "$dip" lookup main
    done < /etc/geo-devices.list
    # --- ai-mode devices (19900 is safely above the magitrickle fwmark base, so the whole
    #     device goes through the AI tunnel; LAN routes stay local in table 101) ---
    if grep -qE '^[0-9.]+[[:space:]]+ai[[:space:]]' /etc/geo-devices.list; then
      if ip link show AI >/dev/null 2>&1; then
        if ! ip route show table 101 | grep -q '^default'; then
          ip route show table main | grep -v '^default' | while IFS= read -r r; do
            ip route replace table 101 $r 2>/dev/null
          done
          ip route replace table 101 default dev AI 2>/dev/null
        fi
        while read -r dip dmode dname; do
          case "$dip" in ''|'#'*) continue ;; esac
          [ "$dmode" = "ai" ] || continue
        ip rule show | grep -q "from $dip" || ip rule add priority 19900 from "$dip" lookup 101
        done < /etc/geo-devices.list
      fi
    fi
  fi
}

if ip link show Mihomo >/dev/null 2>&1; then
  apply_routes
else
  # Mihomo TUN not up yet: retry in BACKGROUND so netifd is never stalled (fixes PPPoE hangs).
  ( i=0; while [ $i -lt 20 ]; do
      ip link show Mihomo >/dev/null 2>&1 && { sleep 1; apply_routes; exit 0; }
      i=$((i+1)); sleep 1
    done ) >/dev/null 2>&1 &
fi
exit 0
EOF
  sh -n /etc/hotplug.d/iface/99-default-vpn-route 2>/dev/null || \
    echo '{"error":"hotplug syntax"}'
}

# ---- AI subscription (mihomo provider "de5") ----
cmd_ai_sub_get() {
  u=$(awk '/^  de5:/{f=1;next} f&&/^    url:/{gsub(/^[^"]*"/,"");gsub(/".*/,"");print;exit} f&&/^  [A-Za-z0-9_-]+:/{f=0} f&&/^[A-Za-z]/{f=0}' "$MIHOMO_CONF" 2>/dev/null)
  printf '{"url":"%s"}' "$(json_esc "$u")"
}

# patch provider url in mihomo config + hot-refresh via API (no mihomo restart)
# _mihomo_set_provider <provider> <url>
_mihomo_set_provider() {
  PN="$1"; URL="$2"
  case "$URL" in
    http://*|https://*) ;;
    *) printf '{"error":"url must start with http:// or https://"}'; return 1 ;;
  esac
  if printf '%s' "$URL" | grep -qE '[[:space:]"]'; then
    printf '{"error":"url contains forbidden characters"}'; return 1
  fi
  [ -f "$MIHOMO_CONF" ] || { printf '{"error":"mihomo config missing"}'; return 1; }
  grep -q "^  $PN:" "$MIHOMO_CONF" || { printf '{"error":"provider %s not found in config"}' "$(json_esc "$PN")"; return 1; }
  cp -p "$MIHOMO_CONF" "$MIHOMO_CONF.bak_subswitch_$(date +%s)"
  TMPF="$MIHOMO_CONF.subsw"
  _hwid=$(grep -A1 'x-hwid' "$MIHOMO_CONF" 2>/dev/null | sed -n 's/^[[:space:]]*-[[:space:]]*"\(.*\)"/\1/p' | head -1)
  if ! awk -v pn="^  $PN:" -v nu="$URL" -v hwid="$_hwid" '
    BEGIN { f=0; done=0 }
    $0 ~ pn { f=1; print; next }
    f && /^    url:/ { print "    url: \"" nu "\""; done=1; next }
    f && /^  [A-Za-z0-9_-]+:/ { f=0 }
    f && /^[A-Za-z]/ { f=0 }
    { print }
    END { exit done ? 0 : 1 }
  ' "$MIHOMO_CONF" > "$TMPF"; then
    rm -f "$TMPF"
    printf '{"error":"failed to patch provider url"}'; return 1
  fi
  if [ -n "$_hwid" ]; then
    awk -v pn="^  $PN:" -v hwid="$_hwid" '
      BEGIN { f=0; added=0 }
      $0 ~ pn { f=1; print; next }
      f && !added && /^    url:/ { print; print "    header:"; print "      x-hwid:"; print "        - \"" hwid "\""; added=1; next }
      f && /^  [A-Za-z0-9_-]+:/ { f=0 }
      f && /^[A-Za-z]/ { f=0 }
      { print }
    ' "$TMPF" > "$TMPF.hwid" && mv -f "$TMPF.hwid" "$TMPF"
  fi
  if mihomo -d /etc/mihomo -t >/dev/null 2>&1; then
    mv -f "$TMPF" "$MIHOMO_CONF"
  else
    rm -f "$TMPF"
    printf '{"error":"mihomo config test failed - old config kept"}'; return 1
  fi
  # apply to the RUNNING mihomo without restart:
  # PUT /configs with config path forces re-read of the config file,
  # which re-fetches the provider subscription (old node list replaced)
  if controller_curl -s -m15 -f -X PUT "$MIHOMO_API/configs" \
      -H 'Content-Type: application/json' \
      -d "{\"path\":\"$MIHOMO_CONF\"}" >/dev/null 2>&1; then
    WARN=''
  else
    WARN='mihomo reload failed - reload via service/restart needed'
  fi
  # verify the running provider actually serves nodes after reload
  sleep 2
  _n=$(controller_curl -s -m6 "$MIHOMO_API/providers/proxies/$PN" 2>/dev/null \
       | tr ',' '\n' | grep -c "\"provider-name\":\"$PN\"")
  case "${_n:-0}" in ''|*[!0-9]*) _n=0 ;; esac
  if [ "$_n" -eq 0 ]; then
    WARN='subscription returned no nodes - check the link, mihomo kept previous node list'
  fi
  echo "$(date +%FT%T) PROVIDER $PN <- $URL (nodes=$_n)" >> "$LOG"
  printf '{"ok":true,"provider":"%s","url":"%s","warn":"%s"}' \
    "$(json_esc "$PN")" "$(json_esc "$URL")" "$(json_esc "$WARN")"
}

cmd_ai_sub_set() {
  _mihomo_set_provider de5 "$1"
}

# ---- subscription registry (id|name|url) ----
_subs_json() {
  FIRST=1
  printf '['
  [ -f "$SUBS_FILE" ] || { printf ']'; return; }
  while IFS='|' read -r sid sname surl; do
    case "$sid" in ''|'#'*) continue ;; esac
    [ "$FIRST" -eq 1 ] || printf ','
    printf '{"id":"%s","name":"%s","url":"%s"}' \
      "$(json_esc "${sid:-}")" "$(json_esc "${sname:-}")" "$(json_esc "${surl:-}")"
    FIRST=0
  done < "$SUBS_FILE"
  printf ']'
}

_find_sub_url() { # _find_sub_url <id> -> url on stdout, rc=1 if not found
  [ -f "$SUBS_FILE" ] || return 1
  awk -F'|' -v id="$1" '$1==id {print $3; found=1; exit} END{exit found?0:1}' "$SUBS_FILE"
}

_sub_id_by_url() { # _sub_id_by_url <url> -> id, rc=1 if not found
  [ -f "$SUBS_FILE" ] || return 1
  awk -F'|' -v u="$1" '$3==u {print $1; found=1; exit} END{exit found?0:1}' "$SUBS_FILE"
}

cmd_subs_list() {
  # fresh/empty registry: auto-import the providers currently in mihomo config
  if [ ! -s "$SUBS_FILE" ] || ! grep -qE '^[^#]' "$SUBS_FILE" 2>/dev/null; then
    _subs_seed_internal
  fi
  printf '{"subs":%s}' "$(_subs_json)"
}

_subs_count() { grep -cE '^[^#]' "$SUBS_FILE" 2>/dev/null || echo 0; }

# import current config providers into the registry (skips urls already present)
_subs_seed_internal() {
  _subu=$(awk '/^  sub:/{f=1;next} f&&/^    url:/{gsub(/^[^"]*"/,"");gsub(/".*/,"");print;exit} f&&/^  [A-Za-z0-9_-]+:/{f=0} f&&/^[A-Za-z]/{f=0}' "$MIHOMO_CONF" 2>/dev/null)
  _de5u=$(awk '/^  de5:/{f=1;next} f&&/^    url:/{gsub(/^[^"]*"/,"");gsub(/".*/,"");print;exit} f&&/^  [A-Za-z0-9_-]+:/{f=0} f&&/^[A-Za-z]/{f=0}' "$MIHOMO_CONF" 2>/dev/null)
  if [ -n "$_subu" ]; then
    _subs_json | grep -Fq "$_subu" || cmd_sub_add "VPN (текущая)" "$_subu" >/dev/null
  fi
  if [ -n "$_de5u" ]; then
    _subs_json | grep -Fq "$_de5u" || cmd_sub_add "AI (текущая)" "$_de5u" >/dev/null
  fi
  echo "$(date +%FT%T) SUB seed (auto)" >> "$LOG"
}

cmd_subs_seed() {
  _subs_seed_internal
  printf '{"ok":true,"subs":%s}' "$(_subs_json)"
}

cmd_sub_add() {
  NAME="$1"; URL="$2"
  case "$URL" in
    http://*|https://*) ;;
    *) printf '{"error":"url must start with http:// or https://"}'; return 1 ;;
  esac
  if printf '%s' "$URL" | grep -qE '[[:space:]"]'; then
    printf '{"error":"url contains forbidden characters"}'; return 1
  fi
  [ -n "$NAME" ] || NAME=$(printf '%s' "$URL" | sed 's|^https\?://||; s|/.*||')
  NAME=$(printf '%s' "$NAME" | tr -d '|' | head -c 48)
  ID=$(date +%s | tail -c 9)
  while grep -q "^$ID|" "$SUBS_FILE" 2>/dev/null; do ID=$((ID+1)); done
  echo "$ID|$NAME|$URL" >> "$SUBS_FILE"
  echo "$(date +%FT%T) SUB add $ID $NAME" >> "$LOG"
  printf '{"ok":true,"subs":%s}' "$(_subs_json)"
}

cmd_sub_del() {
  ID="$1"
  case "$ID" in ''|*[!0-9]*) printf '{"error":"bad id"}'; return 1 ;; esac
  [ -f "$SUBS_FILE" ] || { printf '{"error":"registry empty"}'; return 1; }
  grep -v "^$ID|" "$SUBS_FILE" > "$SUBS_FILE.tmp" || true
  mv -f "$SUBS_FILE.tmp" "$SUBS_FILE"
  echo "$(date +%FT%T) SUB del $ID" >> "$LOG"
  printf '{"ok":true,"subs":%s}' "$(_subs_json)"
}

_mihomo_reload() { # re-read the config in the running core (no service restart)
  controller_curl -s -m15 -f -X PUT "$MIHOMO_API/configs" \
    -H 'Content-Type: application/json' -d "{\"path\":\"$MIHOMO_CONF\"}" >/dev/null 2>&1
  sleep 2
}

cmd_ai_sub_use() {
  ID="$1"
  URL=$(_find_sub_url "$ID") || { printf '{"error":"subscription not found"}'; return 1; }
  _mihomo_set_provider de5 "$URL"
  AI_NODE=$(_grp_node AI)
  printf '{"ok":true,"url":"%s","ai_node":"%s"}' "$(json_esc "$URL")" "$(json_esc "$AI_NODE")"
}

# v1.18.2: slots are resolved through the GROUP, not a hardcoded provider name - on a box that was
# migrated the default tunnel may be fed by "sub", on a fresh install it always is.
#   slot vpn        -> group VPN         (P2P-tolerant tunnel, the default one)
#   slot vpn_nop2p  -> group VPN-noP2P   (subscription whose provider forbids P2P; created on demand)
#   slot ai         -> group AI
_SLOT_PY='
import re, sys
cfg, group, url = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(cfg, encoding="utf-8").read()

def provider_of(grp):
    m = re.search(r"(?m)^  - name: %s\s*\n(?:^(?:    .*|\s*)\n)*" % re.escape(grp), t)
    if not m:
        return None, None
    blk = m.group(0)
    u = re.search(r"use:\n((?:\s+-\s+\S+\n?)+)", blk)
    if u:
        return re.findall(r"-\s+(\S+)", u.group(1))[0], m
    p = re.search(r"proxies:\n((?:\s+-.*\n?)+)", blk)
    return (None, m) if p else (None, m)

prov, gm = provider_of(group)
if prov:
    pm = re.search(r"(?m)^  %s:\n" % re.escape(prov))
    t2, n = re.subn(r"(?m)^(  %s:\n(?:.*\n)*?    url: )\"[^\"]*\"" % re.escape(prov),
                    lambda m: m.group(1) + "\\"" + url + "\\"", t, count=1)
    if n == 0:
        sys.stderr.write("provider %s has no url line\\n" % prov); sys.exit(2)
    print("updated:%s" % prov); sys.exit(0)

# no such group (or a group without a provider) - create provider + group, then point the rules
# that make sense for a P2P-tolerant tunnel at it
newp = "slot"
while re.search(r"(?m)^  %s:\n" % newp, t):
    newp = "slot%d" % (int(newp[4:]) + 1 if newp != "slot" else 2)
prov = newp
# v1.21.3: no provider health-check here on purpose - mihomo drops nodes that fail it from the
# group, which silently empties a lane and turns every rule using it into 502s.
tpl = ("  %s:\n    type: http\n    url: \\"%s\\"\n    interval: 3600\\n" % (prov, url))
am = re.search(r"(?m)^  de5:\n", t) or re.search(r"(?m)^  sub:\n", t)
if not am:
    sys.stderr.write("no proxy-providers anchor\\n"); sys.exit(2)
t = t[:am.start()] + tpl + t[am.start():]
grp = ("\\n  - name: %s\\n    type: url-test\\n    use:\\n      - %s\\n"
       "    url: \\"https://www.gstatic.com/generate_204\\"\\n    interval: 180\\n"
       "    tolerance: 50\\n    lazy: false\\n" % (group, prov))
gm2 = re.search(r"(?m)^  - name: AI\\s*\\n(?:^(?:    .*|\\s*)\\n)*", t)
if not gm2:
    sys.stderr.write("no AI group anchor\\n"); sys.exit(2)
t = t[:gm2.end()] + grp + t[gm2.end():]
if group == "VPN":
    if "RULE-SET,mtrickle_bulk" not in t:
        t = t.replace("  - RULE-SET,mtrickle,VPN-noP2P\\n",
                      "  - RULE-SET,mtrickle_bulk,VPN\\n  - RULE-SET,mtrickle,VPN-noP2P\\n", 1)
    t = t.replace(",RESERVE\\n", ",VPN\\n")
open(cfg, "w", encoding="utf-8", newline="").write(t)
print("created:%s" % prov)
'

_slot_use() { # _slot_use <group> <id>  -> assigns the registry subscription to that mihomo group
  _g="$1"; ID="$2"
  URL=$(_find_sub_url "$ID") || { printf '{"error":"subscription not found"}'; return 1; }
  _c="$(P /etc/mihomo/config.yaml)"
  cp -p "$_c" "$_c.bak_slot" 2>/dev/null
  _res=$(python3 -c "$_SLOT_PY" "$_c" "$_g" "$URL" 2>&1)
  if [ $? -ne 0 ]; then
    mv -f "$_c.bak_slot" "$_c" 2>/dev/null
    printf '{"ok":false,"error":"%s"}' "$(json_esc "$_res")"; return 1
  fi
  if ! /usr/bin/mihomo -t -d "$(dirname "$_c")" >/dev/null 2>&1; then
    mv -f "$_c.bak_slot" "$_c" 2>/dev/null
    printf '{"ok":false,"error":"mihomo config test failed - old config kept"}'; return 1
  fi
  rm -f "$_c.bak_slot"
  _mihomo_reload
  printf '{"ok":true,"slot":"%s","change":"%s","url":"%s","node":"%s"}' \
    "$_g" "$(json_esc "$_res")" "$(json_esc "$URL")" "$(json_esc "$(_grp_node "$_g")")"
}

cmd_vpn_sub_use()    { _slot_use VPN "$1"; }
cmd_vpnnp_sub_use()  { _slot_use VPN-noP2P "$1"; }

# ---------------- self-update (v1.7.0): check / status / apply ----------------
# check -> $UPD_CHECK (cache TTL), apply -> detached runner writes $UPD_STATUS.
# Flow: full backup -> download release artifact -> sh -n + version + sha256
# -> "sh new --reinstall --yes" (module files only, no service restarts) -> rpcd reload.

_upd_esc() { sed 's/\\/\\\\/g; s/"/\\"/g'; }   # stdin -> json-safe

_upd_mark() { # $1=file, $2=marker name; supports NAME="v" and NAME = 'v'
  [ -f "$1" ] || { printf 'none'; return 0; }
  sed -n "s/.*$2[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"'].*/\1/p" "$1" 2>/dev/null | head -1
}

_upd_core_ver() { # installed installer copy (may be absent)
  for f in /tmp/geomask.sh /root/geomask.sh; do
    [ -f "$f" ] || continue
    _v=$(sed -n 's/^GM_VERSION="\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1)
    [ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
  done
  printf 'none'
}

_upd_newer() { # $1 candidate > $2 current ? (numeric X.Y.Z, missing parts = 0)
  _a=$(printf '%s' "$1" | sed 's/^v//; s/[^0-9.].*$//')
  _b=$(printf '%s' "$2" | sed 's/^v//; s/[^0-9.].*$//')
  [ -n "$_a" ] && [ -n "$_b" ] || return 1
  _i=1
  while [ "$_i" -le 3 ]; do
    _x=$(printf '%s' "$_a" | cut -d. -f"$_i"); _y=$(printf '%s' "$_b" | cut -d. -f"$_i")
    _x=${_x:-0}; _y=${_y:-0}
    case "$_x$_y" in *[!0-9]*) return 1 ;; esac
    [ "$_x" -gt "$_y" ] && return 0
    [ "$_x" -lt "$_y" ] && return 1
    _i=$((_i+1))
  done
  return 1
}

_upd_bin_info() { # first existing path -> "file YYYY-MM-DD"
  for f in "$@"; do
    if [ -f "$f" ]; then printf 'file %s' "$(date -r "$f" +%F 2>/dev/null || printf '?')"; return 0; fi
  done
  printf 'not found'
}

_upd_stack_json() { # display-only versions of the managed stack
  _mv=none
  if command -v mihomo >/dev/null 2>&1; then
    _mv=$(mihomo -v 2>&1 | head -1 | tr -d '\r' | head -c 90)
    [ -n "$_mv" ] || _mv=none
  fi
  _o="{\"n\":\"mihomo\",\"v\":\"$(printf '%s' "$_mv" | _upd_esc)\"}"
  _o="$_o,{\"n\":\"magitrickle\",\"v\":\"$(_upd_bin_info /usr/bin/magitrickled)\"}"
  _o="$_o,{\"n\":\"hev-socks5-tunnel\",\"v\":\"$(_upd_bin_info /usr/sbin/hev-socks5-tunnel /usr/bin/hev-socks5-tunnel)\"}"
  _o="$_o,{\"n\":\"tg-ws-proxy\",\"v\":\"$(_upd_bin_info /usr/bin/tg-ws-proxy)\"}"
  _o="$_o,{\"n\":\"https-dns-proxy\",\"v\":\"$(_upd_bin_info /usr/sbin/https-dns-proxy)\"}"
  _o="$_o,{\"n\":\"zapret / nfqws\",\"v\":\"$(_upd_bin_info /opt/zapret/nfq/nfqws)\"}"
  printf '[%s]' "$_o"
}

# Live "installed versions" block + need flag for a given latest version. Sets _LBLK and _LNEED.
# v1.14.2: the update card used to serve these straight from the TTL cache, so after a deploy the
# panel kept showing the OLD installed versions for up to an hour (looked like "not updated").
_upd_local_block() { # $1 = latest version (no leading v)
  _core=$(_upd_core_ver)
  _panel=$(_upd_mark "$DEPLOY_JS" PANEL_VERSION); [ -n "$_panel" ] || _panel=none
  _guard=$(_upd_mark "$DEPLOY_GUARD" GUARD_VERSION); [ -n "$_guard" ] || _guard=none
  _backend=$(_upd_mark "$DEPLOY_BACKEND" BACKEND_VERSION); [ -n "$_backend" ] || _backend=none
  _LNEED=false
  # The "core" marker is an installer copy under /tmp and dies on every reboot, so it must NOT
  # decide whether an update is needed - otherwise a healthy router asks to reinstall after a
  # restart. The release identity comes from the deployed (flash) components instead.
  _cur=$_core
  for _cand in "$_backend" "$_panel" "$_guard"; do
    [ "$_cur" = "none" ] && [ -n "$_cand" ] && [ "$_cand" != "none" ] && _cur=$_cand
  done
  if [ "$_cur" = "none" ]; then _LNEED=true          # nothing deployed at all -> really needs install
  elif _upd_newer "$1" "$_cur"; then _LNEED=true
  elif [ "$_cur" = "$1" ] && { [ "$_panel" != "$1" ] || [ "$_guard" != "$1" ] || [ "$_backend" != "$1" ]; }; then
    _LNEED=true   # partial/misaligned deploy of the same release -> repair
  fi
  _LBLK=$(printf '{"core":"%s","panel":"%s","guard":"%s","backend":"%s"}' "$_core" "$_panel" "$_guard" "$_backend")
}

_upd_check_now() { # $1 = "force" bypasses the TTL cache
  mkdir -p "$UPD_DIR" 2>/dev/null
  _age=$(( $(date +%s) - $(date -r "$UPD_CHECK" +%s 2>/dev/null || echo 0) ))
  if [ "$1" != "force" ] && [ -s "$UPD_CHECK" ] && [ "$_age" -lt "$UPD_TTL" ]; then
    # cached GitHub answer, but installed versions are always recomputed live
    _lv=$(sed -n 's/.*"latest":{[^}]*"version":"\([^"]*\)".*/\1/p' "$UPD_CHECK" | head -1)
    if [ -n "$_lv" ]; then
      _upd_local_block "$_lv"
      sed -e 's#"local":{[^}]*}#"local":'"$_LBLK"'#' -e 's#"need":[a-z]*#"need":'"$_LNEED"'#' "$UPD_CHECK"
      return 0
    fi
    cat "$UPD_CHECK"; return 0
  fi
  _j=$(curl -fsS -m 10 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$UPD_REPO/releases/latest" 2>/dev/null)
  # GitHub answers pretty-printed JSON -> allow whitespace around ':'
  _tag=$(printf '%s' "$_j" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$_tag" ]; then
    _src=github
    _dig=$(printf '%s' "$_j" | sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\(sha256:[0-9a-f]*\)".*/\1/p' | head -1)
    _pub=$(printf '%s' "$_j" | sed -n 's/.*"published_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  else
    # fallback: version from raw master (no digest -> sha256 check skipped at apply)
    _rv=$(curl -fsS -m 12 "https://raw.githubusercontent.com/$UPD_REPO/master/geomask.sh" 2>/dev/null \
      | sed -n 's/^GM_VERSION="\([^"]*\)".*/\1/p' | head -1)
    [ -n "$_rv" ] || { printf '{"ok":false,"error":"version source unreachable"}'; return 1; }
    _tag="v$_rv"; _src=raw; _dig=""; _pub=""
  fi
  _ver=$(printf '%s' "$_tag" | sed 's/^v//')
  _upd_local_block "$_ver"
  _need=$_LNEED
  _now=$(date '+%F %T')
  printf '{"ok":true,"checked_at":"%s","src":"%s","local":%s,"latest":{"tag":"%s","version":"%s","digest":"%s","published":"%s"},"need":%s,"stack":%s}\n' \
    "$_now" "$_src" "$_LBLK" \
    "$_tag" "$_ver" "$_dig" "$_pub" "$_need" "$(_upd_stack_json)" > "$UPD_CHECK.tmp" \
    && mv -f "$UPD_CHECK.tmp" "$UPD_CHECK"
  cat "$UPD_CHECK"
}

_upd_running() {
  [ -f "$UPD_PIDF" ] || return 1
  _p=$(cat "$UPD_PIDF" 2>/dev/null)
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}

cmd_upd_check() { _upd_check_now "${1:-}"; printf '\n'; }

# v1.10.0: "stack state" for the panel - sync/last-run, guard events, pins, DPI strategy, health
cmd_stack() {
  LANIP=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
  [ -n "$LANIP" ] || LANIP=192.168.0.1
  _sync=$(cat /tmp/geomask-sync.state 2>/dev/null)
  case "$_sync" in '{'*'}'*) : ;; *) _sync='{"ts":"","changed":false,"reload":null,"mt":0,"ai":0,"moved":0}' ;; esac
  _sd=false; pgrep -f geomask-syncd.sh >/dev/null 2>&1 && _sd=true
  _sde=false; ls /etc/rc.d/ 2>/dev/null | grep -q geomask-syncd && _sde=true
  _sci=$(crontab -l 2>/dev/null | grep 'sync_mtrickle_mihomo.sh' | head -1 | awk '{print $1}')
  [ -n "$_sci" ] || _sci='*/5'
  _nse=false; crontab -l 2>/dev/null | grep -q 'geomask-nodescan$' && _nse=true
  _ns=$(cat /tmp/geomask-nodescan.state 2>/dev/null)
  case "$_ns" in '{'*'}'*) : ;; *) _ns=null ;; esac
  _guard=$(logread 2>/dev/null | grep geomask-guard | grep -v crond | tail -5 | while IFS= read -r _l; do printf '"%s",' "$(json_esc "$_l")"; done | sed 's/,$//')
  _pin=false; [ -e /root/.geomask-norestart ] && _pin=true
  _strat=$(json_esc "$(sed -n "/option NFQWS_OPT '/,+1p" /etc/config/zapret 2>/dev/null | tail -1 | tr -d " \t'")")
  _nu=$(grep -c . /opt/zapret/ipset/zapret-hosts-user.txt 2>/dev/null)
  _ne=$(grep -c . /opt/zapret/ipset/zapret-hosts-user-exclude.txt 2>/dev/null)
  _nc=$(grep -cE '#[[:space:]]*nochange' /opt/zapret/ipset/zapret-hosts-user-exclude.txt 2>/dev/null)
  _ng=$(grep -c . /opt/zapret/ipset/zapret-hosts-google.txt 2>/dev/null)
  _nr=$(grep -c . /opt/zapret/ipset/zapret-hosts-rkn.txt 2>/dev/null)
  _nt=$(pgrep -f tg-ws-proxy 2>/dev/null | wc -l)
  _land=false; wget -q -T 3 -O /dev/null http://127.0.0.1:8000/ 2>/dev/null && _land=true
  printf '{"ok":true,"sync":%s,"syncd":%s,"syncd_enabled":%s,"sync_interval":"%s","nodescan_enabled":%s,"nodescan":%s,"guard":[%s],"pin":%s,"strategy":"%s","lists":{"user":%d,"exclude":%d,"nochange":%d,"google":%d,"rkn":%d},"health":{"tg":%d,"landing":%s},"links":{"magitrickle":"http://%s:8080","zapret":"http://%s:7788","landing":"http://%s:8000","luci":"http://%s/"}}\n' \
    "$_sync" "$_sd" "$_sde" "$_sci" "$_nse" "$_ns" "$_guard" "$_pin" "$_strat" \
    "${_nu:-0}" "${_ne:-0}" "${_nc:-0}" "${_ng:-0}" "${_nr:-0}" \
    "${_nt:-0}" "$_land" "$LANIP" "$LANIP" "$LANIP" "$LANIP"
}

# v1.9.0: backup folder inventory for the panel (SMB link + files list, newest first)
# v1.9.4: UNC contains backslashes - MUST go through json_esc (raw \g breaks rpcd parsing)
cmd_backups() {
  DIR=/root/geomask-backups
  LANIP=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
  [ -n "$LANIP" ] || LANIP=192.168.0.1
  _sh=false
  grep -qF '[geomask-backups]' /etc/ksmbd/ksmbd.conf 2>/dev/null && _sh=true
  _unc=$(json_esc "$(printf '\\\\%s\\geomask-backups' "$LANIP")")
  _smbu=$(json_esc "$(printf 'smb://%s/geomask-backups' "$LANIP")")
  _files=''
  for f in $(ls -t "$DIR"/router-backup-*.tar.gz 2>/dev/null); do
    [ -f "$f" ] || continue
    _n=$(basename "$f")
    _sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    _t=$(date -r "$f" '+%F %T' 2>/dev/null)
    _files="$_files{\"n\":\"$_n\",\"s\":${_sz:-0},\"t\":\"$_t\"},"
  done
  _files=${_files%,}
  # v1.9.6: simple credentials (owner request); guest/no-password also works, share is read-only
  printf '{"ok":true,"dir":"%s","unc":"%s","smb":"%s","user":"backup","pass":"backup","share_ok":%s,"files":[%s]}\n' \
    "$DIR" "$_unc" "$_smbu" "$_sh" "$_files"
}

cmd_upd_status() {
  mkdir -p "$UPD_DIR" 2>/dev/null
  if [ -s "$UPD_STATUS" ]; then _b=$(cat "$UPD_STATUS"); else _b='{"phase":"idle"}'; fi
  # v1.8.0 console list: tail of steps.log as a "lines" JSON array (each say() appends there)
  _lines=$(tail -60 "$UPD_DIR/steps.log" 2>/dev/null | while IFS= read -r _l; do printf '"%s",' "$(json_esc "$_l")"; done | sed 's/,$//')
  printf '%s,"lines":[%s]}\n' "${_b%\}}" "$_lines"
}

cmd_upd_apply() {
  mkdir -p "$UPD_DIR" 2>/dev/null
  if _upd_running; then printf '{"ok":false,"err":"already running"}\n'; return 1; fi
  _upd_check_now "" >/dev/null 2>&1 || true
  [ -s "$UPD_CHECK" ] || { printf '{"ok":false,"err":"version source unreachable - check network"}\n'; return 1; }
  _tag=$(sed -n 's/.*"tag":"\([^"]*\)".*/\1/p' "$UPD_CHECK" | head -1)
  [ -n "$_tag" ] || { printf '{"ok":false,"err":"bad check cache"}\n'; return 1; }
  cat > "$UPD_DIR/run.sh" <<'RUNEOF'
#!/bin/sh
# geomask self-update runner (detached): backup -> download -> validate -> reinstall
# v1.8.0: every step appended to $D/steps.log (panel console list) + /root/geo-sync.log;
#         check cache removed after success so the page shows real fresh versions.
D=/tmp/geomask-upd
ST=$D/status.json
SL=$D/steps.log
LOGF=/root/geo-sync.log
say() { _t=$(date '+%F %T'); _j=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g'); printf '{"phase":"%s","msg":"%s","ts":"%s"}' "$1" "$_j" "$_t" > "$ST.tmp"; mv -f "$ST.tmp" "$ST"; printf '%s [%s] %s\n' "$_t" "$1" "$2" >> "$SL"; printf '%s GEOMASK-UPD [%s] %s\n' "$_t" "$1" "$2" >> "$LOGF"; }
trap 'rm -f "$D/pid"' EXIT
TAG="$1"
say queued "update to $TAG started"
say backup "creating full router backup (sysupgrade -b)..."
TS=$(date +%Y%m%d-%H%M%S)
BKD=/root/geomask-backups
BK=/tmp/geomask-bk-$TS.tar.gz
# purge BEFORE creating: files under /root are embedded by sysupgrade -b (nesting),
# and /tmp legacy copies bloat tmpfs. Retention on router: only the freshest backup.
mkdir -p "$BKD" 2>/dev/null
rm -f /tmp/router-backup-*.tar.gz "$BKD"/router-backup-*.tar.gz 2>/dev/null
if ! sysupgrade -b "$BK" >/dev/null 2>&1 || [ ! -s "$BK" ]; then
  say error "backup failed - update aborted"; exit 1
fi
SZ=$(wc -c < "$BK")
_md=$(md5sum "$BK" 2>/dev/null | awk '{print $1}')
BKF="$BKD/router-backup-$TS.tar.gz"
mv -f "$BK" "$BKF" 2>/dev/null || BKF="$BK"
[ -s "$BKF" ] || { say error "backup vanished after create - update aborted"; exit 1; }
echo "file=$BKF md5=$_md" > "$D/backup.info"
LANIP=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
say backup "backup OK: $BKF ($SZ bytes, md5 $_md)"
say backup "SMB (retention: freshest one): \\\\$LANIP\\geomask-backups\\${BKF##*/} - Windows: net use /user:backup backup (or no password), read-only; PC history: fetch_backup.ps1"
say download "downloading geomask $TAG..."
rm -f "$D/geomask.sh.new"
if ! curl -fsSL -m 90 -o "$D/geomask.sh.new" "https://cdn.jsdelivr.net/gh/kabzon93region/geomask@${TAG}/geomask.sh" && \
   ! curl -fsSL -m 90 -o "$D/geomask.sh.new" "https://github.com/kabzon93region/geomask/releases/download/${TAG}/geomask.sh"; then
  say error "download failed (jsdelivr + github)"; exit 1
fi
say download "downloaded $(wc -c < "$D/geomask.sh.new") bytes"
say validate "checking syntax (sh -n)..."
if ! sh -n "$D/geomask.sh.new"; then say error "syntax check failed"; exit 1; fi
NEWV=$(sed -n 's/^GM_VERSION="\([^"]*\)".*/\1/p' "$D/geomask.sh.new" | head -1)
if [ -z "$NEWV" ] || [ "v$NEWV" != "$TAG" ]; then
  say error "version mismatch (file=${NEWV:-none} tag=$TAG)"; exit 1
fi
DIG=$(sed -n 's/.*"digest":"\(sha256:[0-9a-f]*\)".*/\1/p' "$D/check.json" | head -1)
if [ -n "$DIG" ]; then
  ACT="sha256:$(sha256sum "$D/geomask.sh.new" | awk '{print $1}')"
  [ "$ACT" = "$DIG" ] || { say error "sha256 mismatch"; exit 1; }
  say validate "version $NEWV ok, sha256 matches release digest"
else
  say validate "version $NEWV ok (digest check skipped - no cached digest)"
fi
say apply "installing modules and panel (no service restarts)..."
if ! sh "$D/geomask.sh.new" --reinstall --yes >> "$D/upd.log" 2>&1; then
  say error "install failed - see $D/upd.log"; exit 1
fi
cp -f "$D/geomask.sh.new" /tmp/geomask.sh 2>/dev/null && chmod +x /tmp/geomask.sh 2>/dev/null
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
rm -f "$D/check.json"   # force fresh version check on the next page load
sleep 1
say done "updated to $NEWV - refresh the panel page (Ctrl+F5)"
RUNEOF
  printf '{"phase":"queued","msg":"starting update to %s","ts":"%s"}\n' "$_tag" "$(date '+%F %T')" > "$UPD_STATUS"
  sh "$UPD_DIR/run.sh" "$_tag" >/dev/null 2>&1 &
  echo $! > "$UPD_PIDF"
  printf '{"ok":true,"to":"%s"}\n' "$_tag"
}

# ---------- v1.12.0: node audit control + automation settings ----------
NODESCONF=/etc/geomask-nodes.conf
NODESBLOCK=/etc/geomask-node-block.txt
NODESCAN_TAG='# geomask-nodescan'
SYNC_TAG='geomask-sync'

# read key from nodes conf
_nconf() { sed -n "s/^$1=//p" "$NODESCONF" 2>/dev/null | head -1; }

cmd_nodes_get() {
  _en=false
  crontab -l 2>/dev/null | grep -q 'geomask-nodescan$' && _en=true
  _line=$(crontab -l 2>/dev/null | grep -F "$NODESCAN_TAG" | head -1)
  _min=$(printf '%s' "$_line" | awk '{print $1}')
  _hr=$(printf '%s' "$_line" | awk '{print $2}')
  [ -n "$_hr" ] || { _hr=3; _min=30; }
  _sched=$(printf '%02d:%02d' "${_hr:-3}" "${_min:-30}" 2>/dev/null || echo '03:30')
  _st=$(cat /tmp/geomask-nodescan.state 2>/dev/null)
  case "$_st" in '{'*'}'*) : ;; *) _st=null ;; esac
  _blk=$(while IFS= read -r _l; do [ -n "$_l" ] && printf '"%s",' "$(json_esc "$_l")"; done < "$NODESBLOCK" 2>/dev/null | sed 's/,$//')
  _lastlog=$(grep NODESCAN "$LOG" 2>/dev/null | tail -3 | while IFS= read -r _l; do printf '"%s",' "$(json_esc "$_l")"; done | sed 's/,$//')
  printf '{"ok":true,"enabled":%s,"schedule":"%s","state":%s,"conf":{"bad_countries":"%s","bad_asns":"%s","base_filter":"%s","sub_provider":"%s"},"blocked":[%s],"log":[%s]}\n' \
    "$_en" "$_sched" "$_st" \
    "$(_nconf bad_countries)" "$(_nconf bad_asns)" "$(_nconf base_filter)" "$(_nconf sub_provider)" \
    "$_blk" "$_lastlog"
}

# args: enabled(0|1) HH:MM countries asns base provider
cmd_nodes_set() {
  _en=$1; _sched=$2; _cc=$3; _as=$4; _base=$5; _prov=$6
  case "$_en" in 0|1) : ;; *) printf '{"ok":false,"error":"bad enabled"}\n'; return 1;; esac
  printf '%s' "$_sched" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$' || { printf '{"ok":false,"error":"bad schedule (HH:MM)"}\n'; return 1; }
  [ -z "$_cc" ] || printf '%s' "$_cc" | grep -qE '^([A-Z][A-Z],)*[A-Z][A-Z]$' || { printf '{"ok":false,"error":"bad countries (AA,BB)"}\n'; return 1; }
  [ -z "$_as" ] || printf '%s' "$_as" | grep -qE '^(AS?[0-9]+,)*AS?[0-9]+$' || { printf '{"ok":false,"error":"bad asns"}\n'; return 1; }
  printf '%s' "$_base" | grep -qE '["'"'"'\\]' && { printf '{"ok":false,"error":"base filter: no quotes/backslashes"}\n'; return 1; }
  [ -z "$_prov" ] && _prov=sub
  printf '%s' "$_prov" | grep -qE '^[a-z0-9_-]+$' || { printf '{"ok":false,"error":"bad provider name"}\n'; return 1; }
  # write conf (full template; keep-as-is logic preserved, user values)
  cat > "$NODESCONF" <<EOF
# geomask node-scan configuration (edited via panel $(date '+%F %T'))
bad_countries=$_cc
bad_asns=$_as
base_filter=$_base
sub_provider=$_prov
EOF
  _hr=${_sched%:*}; _min=${_sched#*:}
  # cron line (hour/min: cron wants numbers; strip leading zeros to be safe)
  _hrn=$(printf '%s' "$_hr" | sed 's/^0//'); _minn=$(printf '%s' "$_min" | sed 's/^0//')
  [ -n "$_hrn" ] || _hrn=0
  _tmp=/tmp/gm-cron.$$
  crontab -l 2>/dev/null | grep -vF "$NODESCAN_TAG" > "$_tmp" || true
  if [ "$_en" = 1 ]; then
    printf '%s %s * * * /usr/bin/geomask-node-scan.sh >/dev/null 2>&1 %s\n' "$_minn" "$_hrn" "$NODESCAN_TAG" >> "$_tmp" 2>/dev/null
  fi
  crontab "$_tmp" && rm -f "$_tmp" || { printf '{"ok":false,"error":"crontab write failed"}\n'; return 1; }
  printf '%s NODESCAN cfg saved via panel (enabled=%s sched=%s)\n' "$(date '+%F %T')" "$_en" "$_sched" >> "$LOG"
  printf '{"ok":true,"enabled":"%s","schedule":"%s"}\n' "$_en" "$_sched"
}

# sync insurance cron interval: */N minutes (N: 1,2,3,5,10,15,30)
cmd_sync_set() {
  case "$1" in 1|2|3|5|10|15|30) : ;; *) printf '{"ok":false,"error":"bad interval"}\n'; return 1;; esac
  _tmp=/tmp/gm-cron.$$
  crontab -l 2>/dev/null | grep -vF "/root/sync_mtrickle_mihomo.sh" > "$_tmp" || true
  printf '*/%s * * * * %s # %s\n' "$1" "$SYNCLISTS" "$SYNC_TAG" >> "$_tmp"
  crontab "$_tmp" && rm -f "$_tmp" || { printf '{"ok":false,"error":"crontab write failed"}\n'; return 1; }
  printf '%s SYNC cron set to */%s\n' "$(date '+%F %T')" "$1" >> "$LOG"
  printf '{"ok":true,"interval":"*/%s"}\n' "$1"
}

# event watchdog on/off
cmd_syncd_set() {
  case "$1" in on|off) : ;; *) printf '{"ok":false,"error":"bad arg"}\n'; return 1;; esac
  if [ "$1" = off ]; then
    /etc/init.d/geomask-syncd stop >/dev/null 2>&1; /etc/init.d/geomask-syncd disable >/dev/null 2>&1
  else
    /etc/init.d/geomask-syncd enable >/dev/null 2>&1; /etc/init.d/geomask-syncd restart >/dev/null 2>&1
  fi
  sleep 1
  _run=false; pgrep -f geomask-syncd.sh >/dev/null 2>&1 && _run=true
  if [ "$1" = on ]; then
    [ "$_run" = true ] || { printf '{"ok":false,"running":%s}\n' "$_run"; return 1; }
  else
    [ "$_run" = false ] || { printf '{"ok":false,"running":%s}\n' "$_run"; return 1; }
  fi
  printf '{"ok":true,"running":%s}\n' "$_run"
}

# mihomo restart pin on/off
cmd_pin_set() {
  case "$1" in on|off) : ;; *) printf '{"ok":false,"error":"bad arg"}\n'; return 1;; esac
  if [ "$1" = on ]; then
    printf 'restarts forbidden by owner - VPN must stay up\n' > /root/.geomask-norestart
    printf '%s PIN set (mihomo --restart disabled)\n' "$(date '+%F %T')" >> "$LOG"
  else
    rm -f /root/.geomask-norestart
    printf '%s PIN removed (restarts allowed; be careful)\n' "$(date '+%F %T')" >> "$LOG"
  fi
  _p=false; [ -e /root/.geomask-norestart ] && _p=true
  printf '{"ok":true,"pin":%s}\n' "$_p"
}


# v1.13.0: lists template status (bundled MagiTrickle groups snapshot vs current config)
cmd_lists_get() {
  _tpl=/etc/geomask/lists/magitrickle-groups.yaml
  _cfg=/etc/magitrickle/state/config.yaml
  _tp=false; [ -s "$_tpl" ] && _tp=true
  _tg=$(grep -c '^- id:' "$_tpl" 2>/dev/null); [ -n "$_tg" ] || _tg=0
  _tr=$(grep -c '^  - id:' "$_tpl" 2>/dev/null); [ -n "$_tr" ] || _tr=0
  _cg=$(grep -c '^- id:' "$_cfg" 2>/dev/null); [ -n "$_cg" ] || _cg=0
  _cr=$(grep -c '^  - id:' "$_cfg" 2>/dev/null); [ -n "$_cr" ] || _cr=0
  _run=false; pgrep -f magitrickled >/dev/null 2>&1 && _run=true
  printf '{"ok":true,"template_present":%s,"template_version":"%s","template_groups":%s,"template_rules":%s,"current_groups":%s,"current_rules":%s,"magitrickle_running":%s}\n' \
    "$_tp" "$BACKEND_VERSION" "$_tg" "$_tr" "$_cg" "$_cr" "$_run"
}

# v1.13.0: restore MagiTrickle groups from the template (backup config.yaml, splice, restart+sync)
cmd_lists_seed() {
  _tpl=/etc/geomask/lists/magitrickle-groups.yaml
  _py=/usr/bin/geomask-seed-lists.py
  [ -s "$_tpl" ] || { printf '{"ok":false,"error":"template missing"}\n'; return 1; }
  [ -f "$_py" ] || { printf '{"ok":false,"error":"seeder missing"}\n'; return 1; }
  /etc/init.d/magitrickle stop >/dev/null 2>&1 || true
  _out=$(python3 "$_py" 2>&1); _rc=$?
  /etc/init.d/magitrickle start >/dev/null 2>&1 || true
  sleep 2
  sh /root/sync_mtrickle_mihomo.sh >/dev/null 2>&1 || true
  controller_curl -s -X PUT http://127.0.0.1:9090/configs -H 'Content-Type: application/json' \
    -d '{"path":"/etc/mihomo/config.yaml"}' >/dev/null 2>&1 || true
  _ok=false; printf '%s' "$_out" | grep -q '^CHANGED' && _ok=true
  printf '{"ok":%s,"rc":%s,"result":"%s"}\n' "$_ok" "$_rc" "$(json_esc "$_out")"
}

# v1.14.0: youtube edge watchdog - status / mode switch / manual release
YT_WATCH=/usr/bin/geomask-ytwatch.sh
YT_CONF=/etc/geomask-ytwatch.conf

cmd_yt_get() {
  [ -x "$YT_WATCH" ] || { printf '{"ok":false,"error":"ytwatch not installed"}\n'; return 1; }
  _j=$(sh "$YT_WATCH" --status 2>/dev/null)
  case "$_j" in '{'*'}'*) : ;; *) _j='{"error":"no status"}' ;; esac
  _mode=$(sed -n 's/^mode=//p' "$YT_CONF" 2>/dev/null | head -1)
  printf '%s\n' "$_j" | sed "s#\"mode\":[^,]*#\"mode\":\"${_mode:-auto}\",\"ok\":true#"
}

cmd_yt_mode() {
  case "$1" in auto|blanket) : ;; *) printf '{"ok":false,"error":"bad mode"}\n'; return 1 ;; esac
  [ -x "$YT_WATCH" ] || { printf '{"ok":false,"error":"ytwatch not installed"}\n'; return 1; }
  _out=$(sh "$YT_WATCH" --mode "$1" 2>&1); _rc=$?
  printf '%s\n' "$_out" | tail -1
  return $_rc
}

cmd_yt_reset() {
  [ -x "$YT_WATCH" ] || { printf '{"ok":false,"error":"ytwatch not installed"}\n'; return 1; }
  sh "$YT_WATCH" --reset >/dev/null 2>&1
  printf '{"ok":true}\n'
}

# v1.15.0: torrent admin (tracker ruleset + DIRECT listener)
TORRENT_SH=/usr/bin/geomask-torrent.sh

_torrent_missing() { printf '{"ok":false,"error":"torrent admin not installed"}\n'; }

cmd_torrent_get() {
  [ -x "$TORRENT_SH" ] || { _torrent_missing; return 1; }
  sh "$TORRENT_SH" --status 2>/dev/null
}
cmd_torrent_refresh() {
  [ -x "$TORRENT_SH" ] || { _torrent_missing; return 1; }
  sh "$TORRENT_SH" --refresh 2>/dev/null | tail -1
}
cmd_torrent_listener() {
  case "$1" in on|off) : ;; *) printf '{"ok":false,"error":"bad state"}\n'; return 1 ;; esac
  [ -x "$TORRENT_SH" ] || { _torrent_missing; return 1; }
  sh "$TORRENT_SH" --listener "$1" 2>/dev/null | tail -1
}
cmd_torrent_extra() {
  [ -x "$TORRENT_SH" ] || { _torrent_missing; return 1; }
  sh "$TORRENT_SH" --extra "$1" 2>/dev/null | tail -1
}

case "$1" in
  status)     cmd_status ;;
  leases)     cmd_leases ;;
  log)        cmd_log ;;
  backups)    cmd_backups ;;
  stack)      cmd_stack ;;
  nodescan)   # kick the node audit in background (returns immediately; panel re-reads stack)
    ( /usr/bin/geomask-node-scan.sh >/dev/null 2>&1 & )
    printf '{"ok":true,"started":true}\n' ;;
  nodes_get)  cmd_nodes_get ;;
  nodes_set)  cmd_nodes_set "$2" "$3" "$4" "$5" "$6" "$7" ;;
  sync_set)   cmd_sync_set "$2" ;;
  syncd_set)  cmd_syncd_set "$2" ;;
  pin_set)    cmd_pin_set "$2" ;;
  lists_get)  cmd_lists_get ;;
  lists_seed) cmd_lists_seed ;;
  yt_get)     cmd_yt_get ;;
  yt_mode)    cmd_yt_mode "$2" ;;
  yt_reset)   cmd_yt_reset ;;
  torrent_get)      cmd_torrent_get ;;
  torrent_refresh)  cmd_torrent_refresh ;;
  torrent_listener) cmd_torrent_listener "$2" ;;
  torrent_extra)    cmd_torrent_extra "$2" ;;
  sync_lists) cmd_sync_lists ;;
  aidns)      cmd_aidns_apply ;;
  google)     cmd_google ;;
  global)     cmd_global "$2" ;;
  ipv6)       cmd_ipv6 "$2" ;;
  dev_add)    cmd_dev_add "$2" "$3" "$4" "$5" ;;
  dev_del)    cmd_dev_del "$2" ;;
  ai_sub_get) cmd_ai_sub_get ;;
  ai_sub_set) cmd_ai_sub_set "$2" ;;
  subs_list)  cmd_subs_list ;;
  sub_add)    cmd_sub_add "$2" "$3" ;;
  sub_del)    cmd_sub_del "$2" ;;
  ai_sub_use)   cmd_ai_sub_use "$2" ;;
  vpn_sub_use)  cmd_vpn_sub_use "$2" ;;
  vpnnp_sub_use) cmd_vpnnp_sub_use "$2" ;;
  upd_check)    cmd_upd_check "$2" ;;
  upd_status)   cmd_upd_status ;;
  upd_apply)    cmd_upd_apply ;;
  *) printf '{"error":"usage"}'; exit 1 ;;
esac

ASSET_EOF
  save_stream /usr/libexec/rpcd/geo-sync 755 <<'ASSET_EOF'
#!/bin/sh
# rpcd plugin for geo-sync (LuCI "Гео-маскировка и AI")
# NOTE: router timezone commands removed - tz is per-PC (GeoSync.ps1), not needed on the router.

. /usr/share/libubox/jshn.sh

BACKEND="/usr/bin/geo-backend.sh"

list_methods() {
	json_init
	json_add_object "status";     json_close_object
	json_add_object "leases";     json_close_object
	json_add_object "log";        json_close_object
	json_add_object "backups";    json_close_object
	json_add_object "stack";      json_close_object
	json_add_object "nodescan";   json_close_object
	json_add_object "nodes_get";  json_close_object
	json_add_object "nodes_set";  json_add_string "enabled" "string"; json_add_string "schedule" "string"; json_add_string "countries" "string"; json_add_string "asns" "string"; json_add_string "base" "string"; json_add_string "provider" "string"; json_close_object
	json_add_object "sync_set";   json_add_string "interval" "string"; json_close_object
	json_add_object "syncd_set";  json_add_string "state" "string"; json_close_object
	json_add_object "pin_set";    json_add_string "state" "string"; json_close_object
	json_add_object "lists_get";  json_close_object
	json_add_object "lists_seed"; json_close_object
	json_add_object "yt_get";     json_close_object
	json_add_object "yt_mode";    json_add_string "mode" "string"; json_close_object
	json_add_object "yt_reset";   json_close_object
	json_add_object "torrent_get"; json_close_object
	json_add_object "torrent_refresh"; json_close_object
	json_add_object "torrent_listener"; json_add_string "state" "string"; json_close_object
	json_add_object "torrent_extra"; json_add_string "hosts" "string"; json_close_object
	json_add_object "sync_lists"; json_close_object
	json_add_object "aidns";      json_close_object
	json_add_object "google";     json_close_object
	json_add_object "global";     json_add_string "mode" "string"; json_close_object
	json_add_object "ipv6";       json_add_string "state" "string"; json_close_object
	json_add_object "dev_add";    json_add_string "ip" "string"; json_add_string "mode" "string"; json_add_string "mac" "string"; json_add_string "name" "string"; json_close_object
	json_add_object "dev_del";    json_add_string "ip" "string"; json_close_object
	json_add_object "ai_sub_get"; json_close_object
	json_add_object "ai_sub_set"; json_add_string "url" "string"; json_close_object
	json_add_object "subs_list";  json_close_object
	json_add_object "subs_seed"; json_close_object
	json_add_object "sub_add";    json_add_string "name" "string"; json_add_string "url" "string"; json_close_object
	json_add_object "sub_del";    json_add_string "id" "string"; json_close_object
	json_add_object "ai_sub_use";   json_add_string "id" "string"; json_close_object
	json_add_object "vpn_sub_use";  json_add_string "id" "string"; json_close_object
	json_add_object "vpnnp_sub_use"; json_add_string "id" "string"; json_close_object
	json_add_object "upd_check";    json_add_string "force" "string"; json_close_object
	json_add_object "upd_status";   json_close_object
	json_add_object "upd_apply";    json_close_object
	json_dump
}

call_method() {
	local input method
	method="$1"
	input="$(cat)"
	json_load "$input" 2>/dev/null
	case "$method" in
		status)     "$BACKEND" status ;;
		leases)     "$BACKEND" leases ;;
		log)        "$BACKEND" log ;;
		backups)    "$BACKEND" backups ;;
		stack)      "$BACKEND" stack ;;
		nodescan)   "$BACKEND" nodescan ;;
		nodes_get)  "$BACKEND" nodes_get ;;
		nodes_set)  json_get_var enabled enabled; json_get_var schedule schedule; json_get_var countries countries; json_get_var asns asns; json_get_var base base; json_get_var provider provider; "$BACKEND" nodes_set "$enabled" "$schedule" "$countries" "$asns" "$base" "$provider" ;;
		sync_set)   json_get_var interval interval; "$BACKEND" sync_set "$interval" ;;
		syncd_set)  json_get_var state state; "$BACKEND" syncd_set "$state" ;;
		pin_set)    json_get_var state state; "$BACKEND" pin_set "$state" ;;
		lists_get)  "$BACKEND" lists_get ;;
		lists_seed) "$BACKEND" lists_seed ;;
		yt_get)     "$BACKEND" yt_get ;;
		yt_mode)    json_get_var mode mode; "$BACKEND" yt_mode "$mode" ;;
		yt_reset)   "$BACKEND" yt_reset ;;
		torrent_get)      "$BACKEND" torrent_get ;;
		torrent_refresh)  "$BACKEND" torrent_refresh ;;
		torrent_listener) json_get_var state state; "$BACKEND" torrent_listener "$state" ;;
		torrent_extra)    json_get_var hosts hosts; "$BACKEND" torrent_extra "$hosts" ;;
		sync_lists) "$BACKEND" sync_lists ;;
		aidns)      "$BACKEND" aidns ;;
		google)     "$BACKEND" google ;;
		global)     json_get_var mode mode;   "$BACKEND" global "$mode" ;;
		ipv6)       json_get_var state state; "$BACKEND" ipv6 "$state" ;;
		dev_add)    json_get_var ip ip; json_get_var mode mode; json_get_var mac mac; json_get_var name name; "$BACKEND" dev_add "$ip" "$mode" "$mac" "$name" ;;
		dev_del)    json_get_var ip ip; "$BACKEND" dev_del "$ip" ;;
		ai_sub_get) "$BACKEND" ai_sub_get ;;
		ai_sub_set) json_get_var url url; "$BACKEND" ai_sub_set "$url" ;;
		subs_list)  "$BACKEND" subs_list ;;
		subs_seed)  "$BACKEND" subs_seed ;;
		sub_add)    json_get_var name name; json_get_var url url; "$BACKEND" sub_add "$name" "$url" ;;
		sub_del)    json_get_var id id; "$BACKEND" sub_del "$id" ;;
		ai_sub_use)   json_get_var id id; "$BACKEND" ai_sub_use "$id" ;;
		vpn_sub_use)  json_get_var id id; "$BACKEND" vpn_sub_use "$id" ;;
		vpnnp_sub_use) json_get_var id id; "$BACKEND" vpnnp_sub_use "$id" ;;
		upd_check)    json_get_var force force; "$BACKEND" upd_check "$force" ;;
		upd_status)   "$BACKEND" upd_status ;;
		upd_apply)    "$BACKEND" upd_apply ;;
		*) echo '{"error":"unknown method"}'; return 1 ;;
	esac
}

case "$1" in
	list) list_methods ;;
	call)
		t="/tmp/geo-rpc.$$"
		call_method "$2" > "$t" 2>/dev/null
		sz="$(wc -c < "$t" 2>/dev/null | tr -d ' ')"
		if [ "${sz:-0}" -gt 400000 ]; then
			echo '{"error":"too big"}'
		else
			cat "$t"
		fi
		rm -f "$t"
		;;
	*) echo '{"error":"usage: geo-sync {list|call <method>}"}'; exit 1 ;;
esac

ASSET_EOF
  save_stream /usr/share/rpcd/acl.d/luci-app-geo-sync.json 644 <<'ASSET_EOF'
{
	"luci-app-geo-sync": {
		"description": "Grant access to geo masking + AI routing panel",
		"read": {
			"ubus": {
				"geo-sync": [ "status", "leases", "log", "backups", "stack", "nodes_get", "ai_sub_get", "subs_list", "upd_check", "upd_status", "lists_get", "yt_get", "torrent_get" ],
				"system": [ "info" ]
			}
		},
		"write": {
			"ubus": {
				"geo-sync": [ "sync_lists", "aidns", "google", "global", "ipv6", "dev_add", "dev_del", "ai_sub_set", "sub_add", "sub_del", "ai_sub_use", "vpn_sub_use", "vpnnp_sub_use", "subs_seed", "upd_apply", "nodescan", "nodes_set", "sync_set", "syncd_set", "pin_set", "lists_seed", "yt_mode", "yt_reset", "torrent_refresh", "torrent_listener", "torrent_extra" ]
			}
		}
	}
}

ASSET_EOF
  save_stream /usr/share/luci/menu.d/luci-app-geo-sync.json 644 <<'ASSET_EOF'
{
	"admin/services/geo-sync": {
		"title": "Гео-маскировка и AI",
		"order": 59,
		"action": {
			"type": "view",
			"path": "geo-sync/main"
		},
		"depends": {
			"acl": [ "luci-app-geo-sync" ]
		}
	}
}

ASSET_EOF
  save_stream /www/luci-static/resources/view/geo-sync/main.js 644 <<'ASSET_EOF'
'use strict';
'require view';
'require rpc';
'require ui';

var callStatus = rpc.declare({ object: 'geo-sync', method: 'status', expect: {} });
var callLeases = rpc.declare({ object: 'geo-sync', method: 'leases', expect: {} });
var callLog    = rpc.declare({ object: 'geo-sync', method: 'log',    expect: {} });
var callBackups = rpc.declare({ object: 'geo-sync', method: 'backups', expect: {} });
var callStack  = rpc.declare({ object: 'geo-sync', method: 'stack', expect: {} });
var callNodescan = rpc.declare({ object: 'geo-sync', method: 'nodescan', expect: {} });
var callLists  = rpc.declare({ object: 'geo-sync', method: 'sync_lists', expect: {} });
var callGoogle = rpc.declare({ object: 'geo-sync', method: 'google',  expect: {} });
/* params as OBJECT (not array): array form expects positional args and would
   wrap {mode:...} into {"mode":{...}} breaking rpcd json_get_var */
var callGlobal = rpc.declare({ object: 'geo-sync', method: 'global',  params: { mode: null }, expect: {} });
var callIpv6   = rpc.declare({ object: 'geo-sync', method: 'ipv6',    params: { state: null }, expect: {} });
var callDevAdd = rpc.declare({ object: 'geo-sync', method: 'dev_add', params: { ip: null, mode: null, mac: null, name: null }, expect: {} });
var callDevDel = rpc.declare({ object: 'geo-sync', method: 'dev_del', params: { ip: null }, expect: {} });
var callAiSubGet = rpc.declare({ object: 'geo-sync', method: 'ai_sub_get', expect: {} });
var callAiSubSet = rpc.declare({ object: 'geo-sync', method: 'ai_sub_set', params: { url: null }, expect: {} });
var callSubsList = rpc.declare({ object: 'geo-sync', method: 'subs_list', expect: {} });
var callSubsSeed = rpc.declare({ object: 'geo-sync', method: 'subs_seed', expect: {} });
var callSubAdd   = rpc.declare({ object: 'geo-sync', method: 'sub_add',   params: { name: null, url: null }, expect: {} });
var callSubDel   = rpc.declare({ object: 'geo-sync', method: 'sub_del',   params: { id: null }, expect: {} });
var callAiSubUse   = rpc.declare({ object: 'geo-sync', method: 'ai_sub_use',   params: { id: null }, expect: {} });
var callVpnSubUse  = rpc.declare({ object: 'geo-sync', method: 'vpn_sub_use',  params: { id: null }, expect: {} });
var callVpnnpSubUse = rpc.declare({ object: 'geo-sync', method: 'vpnnp_sub_use', params: { id: null }, expect: {} });
var callUpdCheck   = rpc.declare({ object: 'geo-sync', method: 'upd_check',    params: { force: null }, expect: {} });
var callUpdStatus  = rpc.declare({ object: 'geo-sync', method: 'upd_status',   expect: {} });
var callUpdApply   = rpc.declare({ object: 'geo-sync', method: 'upd_apply',    expect: {} });
var callNodesGet   = rpc.declare({ object: 'geo-sync', method: 'nodes_get',   expect: {} });
var callNodesSet   = rpc.declare({ object: 'geo-sync', method: 'nodes_set',   params: { enabled: null, schedule: null, countries: null, asns: null, base: null, provider: null }, expect: {} });
var callSyncSet    = rpc.declare({ object: 'geo-sync', method: 'sync_set',    params: { interval: null }, expect: {} });
var callSyncdSet   = rpc.declare({ object: 'geo-sync', method: 'syncd_set',   params: { state: null }, expect: {} });
var callPinSet     = rpc.declare({ object: 'geo-sync', method: 'pin_set',     params: { state: null }, expect: {} });
var callListsGet   = rpc.declare({ object: 'geo-sync', method: 'lists_get',   expect: {} });
var callListsSeed  = rpc.declare({ object: 'geo-sync', method: 'lists_seed',  expect: {} });
var callYtGet      = rpc.declare({ object: 'geo-sync', method: 'yt_get',      expect: {} });
var callYtMode     = rpc.declare({ object: 'geo-sync', method: 'yt_mode',     params: { mode: null }, expect: {} });
var callYtReset    = rpc.declare({ object: 'geo-sync', method: 'yt_reset',    expect: {} });
var callTorGet     = rpc.declare({ object: 'geo-sync', method: 'torrent_get', expect: {} });
var callTorRefresh = rpc.declare({ object: 'geo-sync', method: 'torrent_refresh', expect: {} });
var callTorListener= rpc.declare({ object: 'geo-sync', method: 'torrent_listener', params: { state: null }, expect: {} });
var callTorExtra   = rpc.declare({ object: 'geo-sync', method: 'torrent_extra', params: { hosts: null }, expect: {} });
var PANEL_VERSION = '1.21.7';

/* Copy text to clipboard over plain http (LuCI): execCommand fallback for non-secure context. */
function copyToClipboard(txt, btn) {
	function flash(ok) {
		if (!btn) return;
		var old = btn.textContent;
		btn.textContent = ok ? 'Скопировано ✓' : 'Не удалось';
		setTimeout(function () { btn.textContent = old; }, 1600);
	}
	function fallback() {
		var ta = document.createElement('textarea');
		ta.value = txt;
		ta.style.position = 'fixed'; ta.style.left = '-1000px';
		document.body.appendChild(ta); ta.focus(); ta.select();
		var ok = false;
		try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
		document.body.removeChild(ta);
		flash(ok);
	}
	if (window.isSecureContext && navigator.clipboard) {
		navigator.clipboard.writeText(txt).then(function () { flash(true); }, fallback);
	} else {
		fallback();
	}
}

var CCNAME = {
	DE: 'Германия', NL: 'Нидерланды', FI: 'Финляндия', LV: 'Латвия', LT: 'Литва',
	EE: 'Эстония', PL: 'Польша', DK: 'Дания', SE: 'Швеция', NO: 'Норвегия',
	US: 'США', TR: 'Турция', AL: 'Албания', FR: 'Франция', IT: 'Италия',
	ES: 'Испания', AT: 'Австрия', CH: 'Швейцария', GB: 'Великобритания'
};

var STYLE = [
	'.gs-wrap{display:flex;flex-direction:column;gap:14px;max-width:960px}',
	'.gs-hero{background:linear-gradient(135deg,#0d419d22,#1f6feb11);border:1px solid #1f6feb55;border-radius:12px;padding:18px}',
	'.gs-hero h2{margin:0 0 4px;font-size:17px}',
	'.gs-hero .gs-sub{color:#8b949e;font-size:13px}',
	'.gs-duo{display:flex;gap:12px;flex-wrap:wrap;margin-top:14px}',
	'.gs-sub-card{flex:1;min-width:280px;background:var(--bg-color,#161b22);border:1px solid var(--border-color,#30363d);border-radius:10px;padding:14px 16px}',
	'.gs-sub-card .gs-ent{font-size:11px;text-transform:uppercase;letter-spacing:.5px;color:#8b949e}',
	'.gs-sub-card .gs-node{font-size:15px;font-weight:600;margin:6px 0 2px}',
	'.gs-sub-card .gs-meta{font-size:12px;color:#8b949e}',
	'.gs-cc{display:inline-block;min-width:30px;text-align:center;font-size:11px;font-weight:700;letter-spacing:.4px;color:#58a6ff;background:#1f6feb22;border:1px solid #1f6feb55;border-radius:6px;padding:2px 7px;margin-right:8px;vertical-align:1px}',
	'.gs-counters{display:flex;gap:12px;flex-wrap:wrap;margin-top:12px}',
	'.gs-counter{flex:1;min-width:150px;background:#0d1117;border:1px solid #30363d;border-radius:9px;padding:12px 14px}',
	'.gs-counter .gs-num{font-size:26px;font-weight:700;line-height:1.1}',
	'.gs-counter .gs-cap{font-size:12px;color:#8b949e;margin-top:3px}',
	'.gs-card{background:var(--bg-color,#161b22);border:1px solid var(--border-color,#30363d);border-radius:10px;padding:16px}',
	'.gs-card h3{margin:0 0 10px;font-size:15px}',
	'.gs-row{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:7px 0;flex-wrap:wrap}',
	'.gs-label{color:var(--text-color,#c9d1d9)}',
	'.gs-val{font-weight:600}',
	'.gs-badge{display:inline-block;padding:2px 9px;border-radius:20px;font-size:12px;font-weight:600}',
	'.gs-on{background:#1f6feb33;color:#58a6ff;border:1px solid #1f6feb66}',
	'.gs-ok{background:#23863633;color:#3fb950;border:1px solid #23863666}',
	'.gs-off{background:#f8514922;color:#f85149;border:1px solid #f8514966}',
	'.gs-warn{background:#d2992222;color:#d29922;border:1px solid #d2992266}',
	'.gs-seg{display:inline-flex;border:1px solid #30363d;border-radius:8px;overflow:hidden}',
	'.gs-seg div{padding:5px 14px;cursor:pointer;font-size:13px}',
	'.gs-seg .gs-active{background:#1f6feb;color:#fff}',
	'.gs-btn{padding:6px 16px;border-radius:7px;border:1px solid #30363d;background:#21262d;color:#c9d1d9;cursor:pointer;font-size:13px}',
	'.gs-btn:hover{background:#30363d}',
	'.gs-btn-primary{background:#1f6feb;border-color:#1f6feb;color:#fff}',
	'.gs-btn-primary:hover{background:#388bfd}',
	'.gs-btn-warn{border-color:#f8514966;color:#f85149}',
	'.gs-btn:disabled{opacity:.55;cursor:default}',
	'.gs-actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}',
	'.gs-log{background:#0d1117;color:#8b949e;font-family:monospace;font-size:12px;padding:10px;border-radius:7px;max-height:220px;overflow:auto;white-space:pre-wrap}',
	'.gs-table{width:100%;border-collapse:collapse;font-size:13px}',
	'.gs-table td,.gs-table th{padding:6px 8px;border-bottom:1px solid #30363d;text-align:left}',
	'.gs-subs{width:100%;table-layout:fixed}',
	'.gs-subs td{overflow-wrap:anywhere;vertical-align:middle}',
	'.gs-subs td:first-child{width:126px;font-weight:600}',
	'.gs-subs td:nth-child(2){font-family:monospace;font-size:12px;color:#8b949e}',
	'.gs-subs td:nth-child(3){width:104px}',
	'.gs-subs td:nth-child(3) .gs-badge{white-space:nowrap}',
	'.gs-subs td:last-child{width:272px;white-space:normal}',
	'.gs-subs .gs-btn-use{background:#21262d;border-color:#30363d;color:#c9d1d9;padding:5px 9px;margin:0 4px 4px 0}',
	'.gs-btn-vpn-on{background:#1f6feb;border-color:#58a6ff;color:#fff}',
	'.gs-btn-vpn-on:hover{background:#388bfd}',
	'.gs-btn-ai-on{background:#238636;border-color:#3fb950;color:#fff}',
	'.gs-btn-ai-on:hover{background:#2ea043}',
	'.gs-subs .gs-btn-use:hover{background:#30363d}',
	'.gs-subs .gs-btn-warn{padding:5px 10px}',
	'.gs-input{background:#0d1117;border:1px solid #30363d;color:#c9d1d9;border-radius:6px;padding:6px 9px;font-size:13px}',
	'.gs-hint{color:#8b949e;font-size:12px;margin-top:6px}',
	'.gs-out{background:#0d1117;color:#8b949e;font-family:monospace;font-size:12px;padding:9px 11px;border-radius:7px;margin-top:10px;white-space:pre-wrap;max-height:130px;overflow:auto}',
	'.gs-mono{font-family:monospace}',
	'.gs-upd-meta{color:#8b949e;font-size:12px}',
	'.gs-stack{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:12px;color:#8b949e;margin-top:6px}',
	'.gs-stack span b{color:#c9d1d9;font-weight:600}',
	'.gs-upd-status{margin-top:8px;font-size:13px;min-height:18px}',
	'.gs-console{background:#0d1117;border:1px solid #30363d;border-radius:8px;padding:10px 12px;margin-top:8px;font-family:ui-monospace,Consolas,monospace;font-size:12px;line-height:1.5;max-height:300px;overflow-y:auto;white-space:pre-wrap;color:#c9d1d9}',
	'.gs-console .c-err{color:#f85149}',
	'.gs-console .c-done{color:#3fb950}',
	'.gs-console .c-run{color:#d29922}',
	'.gs-console .c-dim{color:#8b949e}',
	'.gs-log .c-err{color:#f85149}',
	'.gs-log .c-done{color:#3fb950}',
	'.gs-log .c-run{color:#d29922}',
	'.gs-log .c-dim{color:#8b949e}',
	'.gs-bk{margin-top:10px;border-top:1px solid #30363d;padding-top:6px}',
	'.gs-bk h4{margin:2px 0 4px;font-size:13px;color:#e6edf3}',
	'.gs-tabs{display:flex;gap:6px;flex-wrap:wrap;border-bottom:2px solid #1f6feb44;padding-bottom:0}',
	'.gs-tab{padding:7px 16px;border:1px solid #30363d;border-bottom:none;border-radius:9px 9px 0 0;background:#161b22;color:#8b949e;cursor:pointer;font-size:13px;font-weight:600}',
	'.gs-tab:hover{background:#1c2129}',
	'.gs-tab.gs-tab-active{background:#0d419d33;color:#58a6ff;border-color:#1f6feb88}',
	'.gs-panels{display:flex;flex-direction:column;gap:14px;padding-top:14px}',
	'.gs-panel{display:flex;flex-direction:column;gap:14px}',
	'.gs-check{display:inline-flex;align-items:center;gap:8px;cursor:pointer;font-size:13px}',
	'.gs-text{background:#0d1117;border:1px solid #30363d;color:#c9d1d9;border-radius:6px;padding:6px 9px;font-size:13px;font-family:monospace}',
	'.gs-blocklist{background:#0d1117;border:1px solid #30363d;border-radius:7px;padding:8px 11px;font-family:monospace;font-size:12px;color:#8b949e;max-height:180px;overflow:auto;white-space:pre-wrap;margin-top:6px}'
].join('\n');

function injectStyle() {
	if (document.getElementById('gs-style')) return;
	var s = document.createElement('style');
	s.id = 'gs-style';
	s.textContent = STYLE;
	document.head.appendChild(s);
}

function badge(on, yes, no) {
	return E('span', { 'class': 'gs-badge ' + (on ? 'gs-on' : 'gs-off') }, on ? yes : no);
}

function badgeKlass(on, okCls, offCls, yes, no) {
	return E('span', { 'class': 'gs-badge ' + (on ? okCls : offCls) }, on ? yes : no);
}

/* Strip emoji from mihomo node names (flags, pictographs, VS16, ZWJ) - LuCI font
   renders them as tofu boxes, so we show clean text instead. */
function cleanName(s) {
	if (!s) return '';
	var out = String(s)
		.replace(/[\u{1F1E6}-\u{1F1FF}]/gu, '')   /* regional indicators (flag halves) */
		.replace(/[\u{1F300}-\u{1FAFF}]/gu, '')   /* pictographs: gamepad, rockets etc */
		.replace(/[\u{2600}-\u{27BF}]/gu, '')     /* misc symbols & dingbats */
		.replace(/[\u{FE0E}\u{FE0F}\u{200D}\u{200B}]/gu, '') /* VS15/VS16, ZWJ, ZWSP */
		.replace(/\s{2,}/g, ' ')
		.trim();
	return out || String(s).trim();
}

/* Country badge as plain text (code chip) - no flag emoji, renders everywhere. */
function flagOf(s) {
	/* the first flag emoji in a node name, e.g. "🇦🇱 Албания-1" -> "🇦🇱" */
	var m = String(s || '').match(/[\u{1F1E6}-\u{1F1FF}][\u{1F1E6}-\u{1F1FF}]/u);
	return m ? m[0] : '';
}

function ccBadge(cc, name) {
	/* cleanName() strips flags from the node text on purpose; the badge is where the flag
	   belongs, so it is taken from the raw name and kept here (owner, 31.10: "пропали банеры") */
	var f = flagOf(name);
	return E('span', { 'class': 'gs-cc' }, (f ? f + ' ' : '') + (cc || '—'));
}

var E = (function(raw) {
	return function() {
		var a = Array.prototype.slice.call(arguments), i = a.length - 1;
		if (i >= 1 && (typeof a[i] === 'string' || typeof a[i] === 'number')) a[i] = [ String(a[i]) ];
		return raw.apply(null, a);
	};
})(window.E);

return view.extend({
	/* v1.12.2: this panel saves via its own per-card buttons (rpc -> backend), no
	   UCI form here - hide the generic LuCI apply/save/reset footer so it cannot
	   be mistaken for the way to commit our fields. */
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		injectStyle();
		return Promise.all([ callStatus(), callLeases(), callLog(), callAiSubGet(), callSubsList(),
			callUpdCheck({ force: null }), callUpdStatus(), callBackups(), callStack(), callNodesGet(), callListsGet(), callYtGet(), callTorGet() ]);
	},

	render: function(all) {
		var st = all[0] || {}, leases = (all[1] || {}).leases || [], lg = (all[2] || {}).log || '';
		var aicfg = all[3] || {};
		var subs = (all[4] || {}).subs || [];
		var upd = all[5] || {};
		var upds = all[6] || {};
		var bks = all[7] || {};
		var stk = all[8] || {};
		var nd = all[9] || {};
		var lt = all[10] || {};
		var yt = all[11] || {};
		var tor = all[12] || {};
		var view = this;
		if (view._updTimer) { clearInterval(view._updTimer); view._updTimer = null; }
		var wrap = E('div', { 'class': 'gs-wrap' });

		/* ===================== TABS shell (v1.12.0) ===================== */
		var TABS = [
			['obzor', 'Обзор'], ['dev', 'Устройства'], ['subs', 'Подписки'],
			['lists', 'Списки и синк'], ['nodes', 'Узлы подписки'],
			['bk', 'Бэкапы'], ['upd', 'Обновление'], ['set', 'Настройки']
		];
		var curTab = 'obzor';
		try { curTab = localStorage.getItem('gs-tab') || 'obzor'; } catch (e) {}
		var panels = {}, tabBtns = [];
		var tabbar = E('div', { 'class': 'gs-tabs' });
		var panelBox = E('div', { 'class': 'gs-panels' });
		TABS.forEach(function(t) {
			var btn = E('button', { 'class': 'gs-tab', 'click': function() { showTab(t[0]); } }, t[1]);
			tabBtns.push([t[0], btn]);
			tabbar.appendChild(btn);
			var p = E('div', { 'class': 'gs-panel' });
			panels[t[0]] = p;
			panelBox.appendChild(p);
		});
		function showTab(id) {
			curTab = id;
			try { localStorage.setItem('gs-tab', id); } catch (e) {}
			tabBtns.forEach(function(tb) { tb[1].classList.toggle('gs-tab-active', tb[0] === id); });
			TABS.forEach(function(t) { panels[t[0]].style.display = (t[0] === id) ? '' : 'none'; });
		}
		wrap.appendChild(tabbar);
		wrap.appendChild(panelBox);
		showTab(panels[curTab] ? curTab : 'obzor');

		/* ===================== HERO: dual subscription ===================== */
		var aiCc = st.ai_cc || '', vpnCc = st.vpn_nop2p_cc || '', laneCc = st.vpn_cc || '';
		var aiSub = E('div', { 'class': 'gs-sub-card' }, [
			E('div', { 'class': 'gs-ent' }, 'ИИ · Google / OpenAI / Claude → AI-подписка'),
			E('div', { 'class': 'gs-node' }, [ ccBadge(aiCc, st.ai_node), cleanName(st.ai_node) || '—' ]),
			E('div', { 'class': 'gs-meta' }, 'Подписка de5 · выход ' + ((CCNAME[aiCc] || aiCc) ? (CCNAME[aiCc] || aiCc) : '—') +
				(st.google ? ' · Google видит: ' + st.google : '')),
			E('div', { 'class': 'gs-meta' }, 'DNS AI-устройств: ' + (
				st.aidns === 1 ? 'через AI-туннель (утечки нет)' :
				st.aidns === 2 ? 'ПРОБЛЕМА — не через туннель (проверьте шаг aidns)' : 'не настроено (утечка DNS!)'))
		]);
		var vpnSub = E('div', { 'class': 'gs-sub-card' }, [
			E('div', { 'class': 'gs-ent' }, 'VPN-noP2P · доменные списки MagiTrickle'),
			E('div', { 'class': 'gs-node' }, [ ccBadge(vpnCc, st.vpn_nop2p_node), cleanName(st.vpn_nop2p_node) || '—' ]),
			E('div', { 'class': 'gs-meta' }, 'Слот VPN-noP2P · выход ' + ((CCNAME[vpnCc] || vpnCc) ? (CCNAME[vpnCc] || vpnCc) : '—') +
				' · сюда нельзя торренты'),
			E('div', { 'class': 'gs-meta' }, 'IP-правил на этом пути: быть не должно (проверка geomask --check)')
		]);
		var laneSub = E('div', { 'class': 'gs-sub-card' }, [
			E('div', { 'class': 'gs-ent' }, 'VPN · полоса для P2P и IP-списков'),
			E('div', { 'class': 'gs-node' }, [ ccBadge(laneCc, st.vpn_node), cleanName(st.vpn_node) || 'не настроена' ]),
			E('div', { 'class': 'gs-meta' }, 'Слот VPN · выход ' + ((CCNAME[laneCc] || laneCc) ? (CCNAME[laneCc] || laneCc) : '—')),
			E('div', { 'class': 'gs-meta' }, 'mtrickle_bulk (IP), пины googlevideo, ответы входящим пирам')
		]);

		var counters = E('div', { 'class': 'gs-counters' }, [
			E('div', { 'class': 'gs-counter' }, [ E('div', { 'class': 'gs-num' }, String(st.ai_rules != null ? st.ai_rules : '—')),
				E('div', { 'class': 'gs-cap' }, 'правил ИИ-пути (ai.yaml → AI)') ]),
			E('div', { 'class': 'gs-counter' }, [ E('div', { 'class': 'gs-num' }, String(st.mt_rules != null ? st.mt_rules : '—')),
				E('div', { 'class': 'gs-cap' }, 'правил общего пути (mtrickle.yaml → VPN)') ]),
			E('div', { 'class': 'gs-counter' }, [ E('div', { 'class': 'gs-num' }, String(st.n_bypass != null ? st.n_bypass : (st.devices || []).length)),
				E('div', { 'class': 'gs-cap' }, 'мимо VPN (реальный IP)') ])
		]);

		var hero = E('div', { 'class': 'gs-hero' }, [
			E('h2', {}, 'Гео-маскировка и маршрутизация AI'),
			E('div', { 'class': 'gs-sub' }, 'Google и ИИ-сервисы идут через AI-подписку (какую страну видит Google — показывает блок выше), всё остальное — через общую VPN.'),
			E('div', { 'class': 'gs-duo' }, [ laneSub, aiSub, vpnSub ]),
			counters
		]);
		panels.obzor.appendChild(hero);

		/* ===================== Subscriptions registry ===================== */
		function maskUrl(u) {
			if (!u) return '—';
			return String(u).replace(/\/[^/]*$/, '/...');
		}
		function subRow(s) {
			var isVpn = !!(st.vpn_sub && st.vpn_sub === s.id);
			var isVpnNP = !!(st.vpn_nop2p_sub && st.vpn_nop2p_sub === s.id);
			var isAi = !!(st.ai_sub && st.ai_sub === s.id);
			var dest = [];
			if (isVpn)   dest.push(E('span', { 'class': 'gs-badge gs-on' }, 'VPN'));
			if (isAi)    dest.push(E('span', { 'class': 'gs-badge gs-ok' }, 'AI'));
			if (isVpnNP) dest.push(E('span', { 'class': 'gs-badge gs-warn' }, 'VPN-noP2P'));
			if (!dest.length) dest = ['—'];
			var bV = { 'class': 'gs-btn gs-btn-use' + (isVpn ? ' gs-btn-vpn-on' : ''), 'title': isVpn ? 'Эта подписка держит слот VPN (P2P разрешён)' : 'Отдать слот VPN (полоса для торрентов и IP-списков) этой подписке' };
			bV.click = function() {
				if (!confirm('Отдать слот VPN этой подписке?\n\nНа неё перейдут правила по IP (mtrickle_bulk), пины зависших YouTube-рёбер и ответы входящим пирам. Полоса создаётся автоматически, если её ещё нет.')) return;
				view.act(callVpnSubUse, { id: s.id }, 'Подписка применена для VPN');
			};
			var bN = { 'class': 'gs-btn gs-btn-use' + (isVpnNP ? ' gs-btn-vpn-on' : ''), 'title': isVpnNP ? 'Эта подписка держит слот VPN-noP2P (провайдер запрещает торренты)' : 'Отдать слот VPN-noP2P (общий VPN по доменным спискам) этой подписке' };
			bN.click = function() {
				if (!confirm('Отдать слот VPN-noP2P этой подписке?\n\nНа неё останутся только доменные правила (mtrickle) и STUN. Убедитесь, что провайдер этой подписки разрешает трафик из ваших списков.')) return;
				view.act(callVpnnpSubUse, { id: s.id }, 'Подписка применена для VPN-noP2P');
			};
			var bA = { 'class': 'gs-btn gs-btn-use' + (isAi ? ' gs-btn-ai-on' : ''), 'title': isAi ? 'Эта подписка используется для AI-маршрутов' : 'Переключить AI-маршруты на эту подписку', 'click': function() { view.act(callAiSubUse, { id: s.id }, 'Подписка применена для AI'); } };
			var bD = { 'class': 'gs-btn gs-btn-warn', 'title': 'Убрать из реестра', 'click': function() { view.act(callSubDel, { id: s.id }, 'Подписка удалена'); } };
			return E('tr', {}, [
				E('td', {}, s.name || s.id),
				E('td', { 'class': 'gs-subs-url' }, maskUrl(s.url)),
				E('td', {}, dest),
				E('td', { 'class': 'gs-subs-actions' }, [
					E('button', bV, '→ VPN'),
					E('button', bA, '→ AI'),
					E('button', bN, '→ VPN-noP2P'),
					E('button', bD, 'Удалить')
				])
			]);
		}
		var subNameIn = E('input', { 'class': 'gs-input', 'style': 'width:150px', 'placeholder': 'Например: США' });
		var subUrlIn  = E('input', { 'class': 'gs-input', 'style': 'flex:1;min-width:260px', 'placeholder': 'https://... ссылка подписки' });
		var btnSubAdd = E('button', { 'class': 'gs-btn gs-btn-primary',
			'click': function() {
				var u = (subUrlIn.value || '').trim();
				if (!/^https?:\/\//.test(u)) {
					ui.addNotification(null, E('p', {}, 'Ссылка должна начинаться с http:// или https://'), 'warning');
					return;
				}
				btnSubAdd.disabled = true; btnSubAdd.textContent = 'Добавление…';
				callSubAdd({ name: subNameIn.value || '', url: u }).then(function(res) {
					btnSubAdd.disabled = false; btnSubAdd.textContent = 'Добавить';
					if (res && res.error) { ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'error'); return; }
					subNameIn.value = ''; subUrlIn.value = '';
					ui.addNotification(null, E('p', {}, 'Подписка добавлена в реестр'), 'info');
					return view.reload();
				}).catch(function(e) {
					btnSubAdd.disabled = false; btnSubAdd.textContent = 'Добавить';
					ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error');
				});
			} }, 'Добавить');
		var btnSubSeed = E('button', { 'class': 'gs-btn',
			'title': 'Импортировать текущие подписки из конфига mihomo в реестр',
			'click': function() {
				btnSubSeed.disabled = true; btnSubSeed.textContent = 'Импорт…';
				callSubsSeed().then(function(res) {
					btnSubSeed.disabled = false; btnSubSeed.textContent = 'Подтянуть текущие из конфига';
					if (res && res.error) { ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'error'); return; }
					ui.addNotification(null, E('p', {}, 'Текущие подписки добавлены в реестр'), 'info');
					return view.reload();
				}).catch(function(e) {
					btnSubSeed.disabled = false; btnSubSeed.textContent = 'Подтянуть текущие из конфига';
					ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error');
				});
			} }, 'Подтянуть текущие из конфига');
		var subsCard = E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Подписки'),
			E('div', { 'class': 'gs-hint', 'style': 'margin:0 0 8px' },
				'Реестр подписок. В колонке «Назначение» показано, чем подписка занята СЕЙЧАС. Три слота: ' +
				'«VPN-noP2P» — общий VPN по доменным спискам (сюда нельзя торренты: провайдер это запрещает), ' +
				'«VPN» — полоса для всего, что выглядит как P2P (правила по IP, пины зависших YouTube-рёбер, ' +
				'ответы входящим пирам), «AI» — Google и AI-сервисы. Кнопка активного слота подсвечена. ' +
				'Переключение — через API mihomo, без перезапуска и обрыва соединений.'),
			E('table', { 'class': 'gs-table gs-subs' },
				[ E('tr', {}, [ E('th', {}, 'Имя'), E('th', {}, 'Ссылка'), E('th', {}, 'Назначение'), E('th', {}, '') ]) ]
					.concat(subs.map(subRow))),
			E('div', { 'class': 'gs-row', 'style': 'margin-top:10px' }, [ subNameIn, subUrlIn, btnSubAdd ]),
			E('div', { 'class': 'gs-row' }, [ btnSubSeed ])
		]);
		panels.subs.appendChild(subsCard);

		/* ===================== ACTIONS: sync / google check ===================== */
		var listsOut = E('div', {});
		var btnLists = E('button', { 'class': 'gs-btn gs-btn-primary',
			'click': function() {
				btnLists.disabled = true; btnLists.textContent = 'Синхронизация…';
				callLists().then(function(res) {
					btnLists.disabled = false; btnLists.textContent = 'Синхронизировать списки сейчас';
					var out = (res && res.output) ? res.output : '(нет вывода)';
					listsOut.textContent = out;
					ui.addNotification(null, E('p', {}, 'Списки синхронизированы: ИИ=' +
						(res && res.ai_rules) + ', VPN=' + (res && res.mt_rules)), 'info');
					return view.reload();
				}).catch(function(e) {
					btnLists.disabled = false; btnLists.textContent = 'Синхронизировать списки сейчас';
					ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error');
				});
			} }, 'Синхронизировать списки сейчас');

		var btnGoogle = E('button', { 'class': 'gs-btn',
			'click': function() {
				btnGoogle.disabled = true; btnGoogle.textContent = 'Проверка Google…';
				callGoogle().then(function(res) {
					btnGoogle.disabled = false; btnGoogle.textContent = 'Что видит Google?';
					var cc = res && res.google ? res.google : '(нет ответа)';
					ui.addNotification(null, E('p', {}, 'Google видит: ' + cc), 'info');
					return view.reload();
				}).catch(function(e) {
					btnGoogle.disabled = false; btnGoogle.textContent = 'Что видит Google?';
					ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error');
				});
			} }, 'Что видит Google?');

		var btnScan = E('button', { 'class': 'gs-btn',
			'click': function() {
				btnScan.disabled = true; btnScan.textContent = 'Проверка…';
				callNodescan().then(function() {
					btnScan.textContent = 'Проверить узлы сейчас';
					ui.addNotification(null, E('p', {}, 'Аудит узлов запущен в фоне (до ~1 минуты); итог появится в этой карточке после обновления.'), 'info');
					setTimeout(function() { view.reload(); }, 45000);
				}).catch(function(e) {
					btnScan.disabled = false; btnScan.textContent = 'Проверить узлы сейчас';
					ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error');
				});
			} }, 'Проверить узлы сейчас');

		var syncCard = E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Синхронизация и проверка'),
			E('div', { 'class': 'gs-hint', 'style': 'margin:0 0 6px' },
				'Событийный сторож применяет изменения списков magitrickle в mihomo за секунды после сохранения ' +
				'(cron каждые 5 минут остался страховкой). Кнопка ниже — ручной синк "всей силы", если не доверяете автомату.'),
			(function() {
				var s = stk.sync || {}, rows = [];
				var syncTxt;
				if (stk.ok !== true) { syncTxt = 'нет данных (бэкенд stack не ответит?)'; }
				else {
					var last = s.ts ? (s.ts + (s.changed
						? (' — обновлено: VPN=' + (s.mt || '?') + ', AI=' + (s.ai || '?')
							+ (s.moved ? (', в AI по маске: ' + s.moved) : '')
							+ ', mihomo ' + (s.reload ? 'перечитил' : 'НЕ перечитал (!)'))
						: ' — без изменений')) : 'после загрузки синков ещё не было';
					syncTxt = (stk.syncd ? 'сторож активен · ' : 'СТОРОЖ НЕ РАБОТАЕТ (только cron) · ') + last;
				}
				rows.push(E('div', { 'class': 'gs-row' }, [
					E('span', { 'class': 'gs-label' }, 'Автосинк списков'),
					E('span', { 'class': (stk.syncd ? 'gs-val' : 'gs-val gs-badge gs-warn') }, syncTxt)
				]));
				if (stk.ok === true) {
					var ns = stk.nodescan;
					rows.push(E('div', { 'class': 'gs-row' }, [
						E('span', { 'class': 'gs-label' }, 'Узлы подписки (аудит)'),
						E('span', { 'class': 'gs-val gs-upd-meta' },
							ns ? (ns.ts + ' · узлов ' + ns.total + ', с РФ-меткой ' + ns.blocked
								+ (ns.changed ? ' (фильтр обновлён)' : '') + (ns.errors ? ' · сбоевlookup: ' + ns.errors : ''))
								: 'ночной скан ещё не запускался (03:30)')
					]));
					var L = stk.lists || {}, H = stk.health || {};
					rows.push(E('div', { 'class': 'gs-row' }, [
						E('span', { 'class': 'gs-label' }, 'DPI (zapret)'),
						E('span', { 'class': 'gs-val gs-mono gs-upd-meta' },
							(String(stk.strategy || '?') + ' · списки: user=' + (L.user || 0)
								+ ' excl=' + (L.exclude || 0) + (L.nochange ? ' #nochange✓' : ' #nochange✗')
								+ ' google=' + (L.google || 0) + ' rkn=' + (L.rkn || 0))
						)
					]));
					rows.push(E('div', { 'class': 'gs-row' }, [
						E('span', { 'class': 'gs-label' }, 'Пины/здоровье'),
						E('span', { 'class': 'gs-val gs-upd-meta' },
							(stk.pin ? 'рестарты mihomo запрещены пином' : 'пинов нет')
							+ ' · tg-прокси: ' + (H.tg || 0) + ' · лендинг: ' + (H.landing ? 'ок' : 'НЕ отвечает'))
					]));
					var gl = stk.guard || [];
					rows.push(E('div', { 'class': 'gs-row', 'style': 'align-items:flex-start' }, [
						E('span', { 'class': 'gs-label' }, 'Страж маршрутизации'),
						E('span', { 'class': 'gs-val gs-mono gs-upd-meta', 'style': 'white-space:pre-wrap;font-size:11px' },
							gl.length ? gl.slice(-3).join('\n') : 'тихий (последних событий нет)')
					]));
					var K = stk.links || {};
					var lnk = function(t, u) { return u ? E('a', { 'href': u, 'target': '_blank', 'style': 'color:#58a6ff' }, t) : null; };
					rows.push(E('div', { 'class': 'gs-row' }, [
						E('span', { 'class': 'gs-label' }, 'Панели'),
						E('span', {}, [ lnk('MagiTrickle', K.magitrickle), ' · ', lnk('Zapret DPI', K.zapret),
							' · ', lnk('Лендинг', K.landing), ' · ', lnk('LuCI', K.luci) ] || '')
					]));
				}
				return E('div', { 'style': 'margin:0 0 8px' }, rows);
			})(),
			E('div', { 'class': 'gs-actions' }, [ btnLists, btnGoogle, btnScan ]),
			listsOut
		]);
		panels.lists.appendChild(syncCard);

		/* ===================== Routing ===================== */
		var globalSeg = E('div', { 'class': 'gs-seg' }, [
			E('div', { 'class': st.global === 'DIRECT' ? 'gs-active' : '',
				'click': function() { view.act(callGlobal, { mode: 'DIRECT' }); } }, 'DIRECT'),
			E('div', { 'class': st.global === 'VPN' ? 'gs-active' : '',
				'click': function() { view.act(callGlobal, { mode: 'VPN' }); } }, 'VPN')
		]);
		var routeCard = E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Маршрутизация'),
			E('div', { 'class': 'gs-row' }, [ E('span', { 'class': 'gs-label' }, 'Глобальный режим (трафик мимо списков)'),
				globalSeg ]),
			E('div', { 'class': 'gs-hint' }, 'DIRECT — мимо списков напрямую (локальные сервисы свободны). VPN — весь остаток через общую подписку.')
		]);
		panels.obzor.appendChild(routeCard);

		/* ===================== IPv6 ===================== */
		var v6Card = E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'IPv6'),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'IPv6-стек (утечка реального IP мимо VPN)'),
				badgeKlass(st.ipv6 === 1, 'gs-warn', 'gs-ok', 'включён — УТЕЧКА', 'выключен'),
				E('button', { 'class': 'gs-btn' + (st.ipv6 ? ' gs-btn-warn' : ''),
					'click': function() { view.act(callIpv6, { state: st.ipv6 ? 'off' : 'on' }); } },
					st.ipv6 ? 'Отключить' : 'Включить')
			]),
			E('div', { 'class': 'gs-hint' }, 'Отключение снимает глобальные IPv6-адреса с роутера и LAN-устройств, утечка закрывается полностью.')
		]);
		panels.obzor.appendChild(v6Card);

		/* ===================== Per-device geo policy ===================== */
		var MODEINFO = {
			bypass: { label: 'Мимо VPN', klass: 'gs-warn',
				hint: 'Реальный IP и часовой пояс ПК. Трафик напрямую или через zapret — mihomo не используется.' },
			realtz: { label: 'Через VPN, часовой пояс ПК свой', klass: 'gs-ok',
				hint: 'IP маскирован через mihomo, но часовой пояс самого ПК не трогается (GeoSync.ps1 на этом ПК выключен).' },
			ai: { label: 'Через AI-подписку', klass: 'gs-on',
				hint: 'ВЕСЬ трафик устройства идёт через AI-подписку (сейчас: Германия). Отдельный туннель AI, VPN не прерывается.' }
		};
		var modeSel = E('select', { 'class': 'gs-input', 'style': 'width:220px' }, [
			E('option', { 'value': 'bypass' }, 'Мимо VPN (реальный IP)'),
			E('option', { 'value': 'realtz' }, 'Через VPN, часовой пояс ПК свой'),
			E('option', { 'value': 'ai' }, 'Через AI-подписку (весь трафик)')
		]);
		var ipIn = E('input', { 'class': 'gs-input', 'style': 'width:130px', 'placeholder': 'IP' });
		var nameIn = E('input', { 'class': 'gs-input', 'style': 'width:150px', 'placeholder': 'Имя' });
		var leaseSel = E('select', { 'class': 'gs-input',
			'change': function(ev) {
				var parts = ev.target.value.split('|');
				if (parts[0]) ipIn.value = parts[0];
				if (parts[1]) nameIn.value = parts[2] || parts[1];
			} },
			[ E('option', { 'value': '' }, '— из DHCP-leases —') ].concat(
				leases.map(function(l) { return E('option', { 'value': l.ip + '|' + l.mac + '|' + (l.name || '') }, l.ip + '  ' + (l.name || l.mac)); })));
		var devRows = (st.devices || []).map(function(x) {
			var mi = MODEINFO[x.mode] || { label: x.mode || '—', klass: 'gs-badge', hint: '' };
			return E('tr', {}, [
				E('td', {}, x.ip),
				E('td', {}, x.name || ''),
				E('td', {}, E('span', { 'class': 'gs-badge ' + mi.klass, 'title': mi.hint }, mi.label)),
				E('td', {}, E('button', { 'class': 'gs-btn gs-btn-warn',
					'click': function() { view.act(callDevDel, { ip: x.ip }); } }, 'Убрать'))
			]);
		});
		var devTable = E('table', { 'class': 'gs-table' },
			[ E('tr', {}, [ E('th', {}, 'IP'), E('th', {}, 'Имя'), E('th', {}, 'Режим'), E('th', {}, '') ]) ].concat(devRows));
		var devCard = E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Персональные режимы устройств'),
			E('div', { 'class': 'gs-hint', 'style': 'margin:0 0 8px' },
				'По умолчанию все устройства маскируются: IP идёт через mihomo, а часовой пояс каждого ПК настраивает его ОС. ' +
				'Здесь задаются исключения: мимо VPN / через VPN / весь трафик через AI-подписку' +
				(st.n_ai != null ? ' (сейчас через AI: ' + st.n_ai + ', туннель AI: ' + (st.ai_tun ? 'поднят' : 'нет') + ')' : '') + '.'),
			(st.ai_tun && !st.ai_listener) ? E('div', { 'class': 'gs-hint', 'style': 'color:#d29922' },
				'Внимание: слушатель AI-устройств (порт 7891) не активен — перезапустите mihomo один раз, когда будет удобно: sh /etc/init.d/mihomo restart. До этого устройства с режимом «Через AI» не получат трафик.') : E('div', {}),
			devTable,
			E('div', { 'class': 'gs-row', 'style': 'margin-top:10px' }, [ leaseSel, modeSel ]),
			E('div', { 'class': 'gs-row' }, [ ipIn, nameIn,
				E('button', { 'class': 'gs-btn', 'click': function() {
					if (!ipIn.value) { ui.addNotification(null, E('p', {}, 'Укажите IP'), 'warning'); return; }
					view.act(callDevAdd, { ip: ipIn.value, mode: modeSel.value, mac: (leaseSel.value.split('|')[1] || ''), name: nameIn.value || ipIn.value });
					ipIn.value = ''; nameIn.value = ''; leaseSel.value = '';
				} }, 'Добавить')
			])
		]);
		panels.dev.appendChild(devCard);

		/* ===================== Log ===================== */
		var logCard = E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Журнал'),
			(function() {
				/* v1.12.3: same semantic colors as the update console */
				var box = E('pre', { 'class': 'gs-log' });
				String(lg || '(пусто)').split('\n').forEach(function(l) {
					var cls = 'c-dim';
					if (/\[error\]|FAILED|FAIL\b|abort/i.test(l)) cls = 'c-err';
					else if (/\bwarn/i.test(l)) cls = 'c-run';
					else if (/\[done\]|updated to|SYNC changed|no change/i.test(l)) cls = 'c-done';
					box.appendChild(E('div', { 'class': cls }, l));
				});
				return box;
			})()
		]);
		panels.obzor.appendChild(logCard);

		/* ===================== Updates (bottom - rarely used block) ===================== */
		var updStatus = E('div', { 'class': 'gs-upd-status' });
		var updLog = E('pre', { 'class': 'gs-console' });
		updLog.style.display = 'none';
		var lastLogKey = null;
		function updLineClass(l) {
			/* colors carry meaning: red=error, yellow=real warning, green=finished,
			   dim=normal process step (was yellow before v1.12.3 - read as false warnings) */
			if (/\[error\]|FAILED|fail\b/i.test(l)) return 'c-err';
			if (/\bwarn(ing)?\b/i.test(l)) return 'c-run';
			if (l.indexOf('[done]') >= 0 || /updated to|filter updated|no change/.test(l)) return 'c-done';
			return 'c-dim';
		}
		function updRenderLines(lines) {
			lines = lines || [];
			var key = lines.join('\n');
			if (key === lastLogKey) return;
			lastLogKey = key;
			updLog.textContent = '';
			if (!lines.length) { updLog.style.display = 'none'; return; }
			updLog.style.display = '';
			lines.forEach(function(l) { updLog.appendChild(E('div', { 'class': updLineClass(l) }, l)); });
			updLog.scrollTop = updLog.scrollHeight;
		}
		/* --- backups folder (SMB-shareable, v1.9.0) --- */
		var bkBox = E('div', { 'class': 'gs-bk' });
		function fmtSize(b) {
			b = +b || 0;
			return (b >= 1048576) ? (b / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(b / 1024)) + ' KB';
		}
		function renderBk(b) {
			b = b || {};
			bkBox.textContent = '';
			bkBox.appendChild(E('h4', {}, 'Резервные копии (папка на роутере, SMB-шар)'));
			if (b.share_ok === false)
				bkBox.appendChild(E('div', { 'class': 'gs-row' }, [ E('span', { 'class': 'gs-badge gs-warn' },
					'SMB-шар geomask-backups не найден — прогоните шаг geo в geomask') ]));
			var unc = b.unc || '', smbu = b.smb || '';
			bkBox.appendChild(E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Папка'),
				E('span', { 'class': 'gs-val gs-mono' }, unc || b.dir || '—'),
				E('span', {}, [
					E('button', { 'class': 'gs-btn', 'click': function () { copyToClipboard(unc, this); } }, 'Копировать (Windows)'),
					E('button', { 'class': 'gs-btn', 'click': function () { copyToClipboard(smbu, this); } }, 'Копировать (smb://)')
				])
			]));
			var files = b.files || [];
			if (!files.length) {
				bkBox.appendChild(E('div', { 'class': 'gs-hint' },
					'Свежей копии нет — она создаётся автоматически перед каждым обновлением и при geomask --backup.'));
			} else {
				files.forEach(function (f) {
					bkBox.appendChild(E('div', { 'class': 'gs-row' }, [
						E('span', { 'class': 'gs-val gs-mono' }, String(f.n || '')),
						E('span', { 'class': 'gs-upd-meta' }, fmtSize(f.s) + ' · ' + String(f.t || '')),
						E('span', {}, E('button', { 'class': 'gs-btn', 'click': function () { copyToClipboard(unc + '\\' + String(f.n || ''), this); } }, 'Копировать путь к файлу'))
					]));
				});
			}
			bkBox.appendChild(E('div', { 'class': 'gs-hint' },
				'Хранится самая свежая копия (роутер экономит место); полная история — на ПК: geomask\\fetch_backup.ps1. ' +
				'Провод Windows: Win+R → вставить скопированный путь. Восстановление: LuCI → System → Backup / Flash Firmware → Restore.'));
			if (b.user && b.pass) {
				var nu = 'net use ' + unc + ' /user:' + b.user + ' ' + b.pass + ' /persistent:yes';
				bkBox.appendChild(E('div', { 'class': 'gs-row' }, [
					E('span', { 'class': 'gs-label' }, 'Windows: вход backup / backup (или без пароля — гость)'),
					E('span', { 'class': 'gs-mono gs-upd-meta' }, b.user + ' / ' + b.pass),
					E('span', {}, E('button', { 'class': 'gs-btn', 'click': function () { copyToClipboard(nu, this); } }, 'Копировать net use'))
				]));
			}
		}
		renderBk(bks);
		var latest = upd.latest || {}, loc = upd.local || {};
		var stack = upd.stack || [];
		var updErr = upd.error || null;
		var coreV = loc.core || 'none', latV = latest.version || '',
			latTag = (latest.tag || '').replace(/^v/, '');   /* display without the tag 'v': 1.7.3 */
		var UPD_RUNNING = ['queued', 'backup', 'download', 'validate', 'apply'];

		function verRow(label, val, hint) {
			return E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, label),
				E('span', { 'class': 'gs-val gs-mono' }, val || '—'),
				hint || E('span', {})
			]);
		}

		function updPoll() {
			if (view._updTimer) clearInterval(view._updTimer);
			view._updTimer = setInterval(function() {
				callUpdStatus().then(function(s) {
					s = s || {};
					var ph = s.phase || 'idle';
					updRenderLines(s.lines);
					if (ph === 'done') {
						clearInterval(view._updTimer); view._updTimer = null;
						updStatus.style.color = '';
						updStatus.textContent = '';
						updStatus.appendChild(E('span', { 'class': 'gs-badge gs-ok' }, 'Готово: ' + (s.msg || '')));
						updStatus.appendChild(' ');
						updStatus.appendChild(E('button', { 'class': 'gs-btn gs-btn-primary',
							'click': function() { location.reload(); } }, 'Обновить страницу'));
						callBackups().then(function(b) { renderBk(b || {}); });
					} else if (ph === 'error') {
						clearInterval(view._updTimer); view._updTimer = null;
						updStatus.style.color = '#f85149';
						updStatus.textContent = 'Ошибка: ' + (s.msg || 'unknown');
					} else if (UPD_RUNNING.indexOf(ph) >= 0) {
						updStatus.style.color = '#d29922';
						updStatus.textContent = (s.msg || ph) + '  [' + (s.ts || '') + ']';
					}
				});
			}, 2000);
		}

		var updChildren = [
			E('h3', {}, 'Обновления'),
			E('div', { 'class': 'gs-hint', 'style': 'margin:0 0 8px' },
				'Проверка версий — при открытии страницы (кэш 1 ч) и по кнопке. ' +
				'Обновление geomask: полный бэкап роутера → скачивание релиза с GitHub (sha256) → ' +
				'установка модулей и панели без перезапуска сервисов → после «Готово» обнови страницу (Ctrl+F5). ' +
				'Каждый шаг пишется отдельной строкой в консоль ниже и в общий журнал (/root/geo-sync.log). ' +
				'Бэкап перед обновлением хранится в папке «Резервные копии» ниже (SMB-шар на роутере, ' +
				'самая свежая копия; полная история на ПК — geomask\\fetch_backup.ps1); восстановление — ' +
				'LuCI System → Backup / Flash Firmware → Restore.')
		];
		if (updErr) {
			updChildren.push(E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Проверка версий'),
				E('span', { 'class': 'gs-badge gs-warn' }, 'ошибка'),
				E('span', { 'class': 'gs-upd-meta' }, String(updErr))
			]));
		} else {
			updChildren.push(verRow('geomask (ядро)', coreV,
				(latV && coreV !== 'none' && coreV !== latV && !upd.need) ? E('span', { 'class': 'gs-upd-meta' }, 'локальная новее релиза') : null));
			updChildren.push(verRow('Админка LuCI', loc.panel,
				(loc.panel && loc.backend && loc.panel !== loc.backend) ? E('span', { 'class': 'gs-badge gs-warn' }, 'панель≠бэкенд') : null));
			updChildren.push(verRow('geomask-guard', loc.guard));
			updChildren.push(E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Доступно на GitHub'),
				latV ? E('span', { 'class': 'gs-val gs-upd-latest' }, latTag) : E('span', {}, '—'),
				upd.need === true
					? E('span', { 'class': 'gs-badge gs-warn' }, 'доступно обновление')
					: E('span', { 'class': 'gs-badge gs-ok' }, 'актуально')
			]));
			/* The GitHub answer is cached for an hour on purpose (unauthenticated API allows
			   ~60 requests/hour), so a release published minutes ago stays invisible. This
			   button forces one live poll. */
			var btnUpdPoll = E('button', { 'class': 'gs-btn', 'click': function() {
				btnUpdPoll.disabled = true; btnUpdPoll.textContent = 'Проверяю…';
				callUpdCheck({ force: 'force' }).then(function() {
					btnUpdPoll.disabled = false; btnUpdPoll.textContent = 'Проверить сейчас';
					return view.reload();
				}).catch(function(e) {
					btnUpdPoll.disabled = false; btnUpdPoll.textContent = 'Проверить сейчас';
					ui.addNotification(null, E('p', {}, 'Не удалось проверить: ' + e), 'error');
				});
			} }, 'Проверить сейчас');
			updChildren.push(E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-hint' }, 'опрос GitHub кэшируется на 60 мин — кнопка ниже опрашивает его напрямую'),
				btnUpdPoll
			]));
			if (upd.need === true) {
				var btnUpd = E('button', { 'class': 'gs-btn gs-btn-primary', 'click': function() {
					if (!confirm('Обновить geomask до ' + latTag + '?\n\n' +
						'Будет создан полный бэкап роутера, файлы модулей и панель заменятся на ' + latTag + '.\n' +
						'Сервисы (mihomo, magitrickle и т.д.) не перезапускаются.')) return;
					btnUpd.disabled = true; btnUpd.textContent = 'Запуск…';
					callUpdApply().then(function(res) {
						btnUpd.disabled = false; btnUpd.textContent = 'Обновить до ' + latTag;
						if (res && (res.error || res.ok === false)) {
							updStatus.style.color = '#f85149';
							updStatus.textContent = 'Ошибка: ' + (res.error || res.err || 'отклонено');
							return;
						}
						updStatus.style.color = '#d29922';
						updStatus.textContent = 'Обновление запущено…';
						updPoll();
					}).catch(function(e) {
						btnUpd.disabled = false; btnUpd.textContent = 'Обновить до ' + latTag;
						updStatus.style.color = '#f85149';
						updStatus.textContent = 'Ошибка: ' + e;
					});
				} }, 'Обновить до ' + latTag);
				updChildren.push(E('div', { 'class': 'gs-actions' }, [ btnUpd ]));
			}
			updChildren.push(E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Стек (справочно)'),
				(function() {
					var btnCh = E('button', { 'class': 'gs-btn', 'click': function() {
						btnCh.disabled = true; btnCh.textContent = 'Проверка…';
						callUpdCheck({ force: '1' }).then(function() { return view.reload(); })
							.catch(function() { btnCh.disabled = false; btnCh.textContent = 'Проверить ещё раз'; });
					} }, 'Проверить ещё раз');
					return btnCh;
				})()
			]));
			updChildren.push(E('div', { 'class': 'gs-stack' }, stack.length
				? stack.map(function(s) { return E('span', {}, [ E('b', {}, (s.n || '?') + ': '), String(s.v || '?') ]); })
				: [ E('span', {}, 'нет данных') ]));
			if (upd.checked_at) updChildren.push(E('div', { 'class': 'gs-upd-meta' },
				'Проверено: ' + upd.checked_at + ' · источник: ' + (upd.src || '?') + (upd.need === true && latest.digest ? ' · sha256: ' + String(latest.digest).slice(0, 19) + '…' : '')));
		}
		updChildren.push(updStatus);
		updChildren.push(updLog);
		var updCard = E('div', { 'class': 'gs-card' }, updChildren);
		panels.upd.appendChild(updCard);
		updRenderLines((upds || {}).lines);
		if (UPD_RUNNING.indexOf((upds || {}).phase) >= 0) {
			updStatus.style.color = '#d29922';
			updStatus.textContent = 'Идет обновление… подробности в консоли ниже.';
			updPoll();
		}

		/* ===================== Backups as own tab card (v1.12.0) ===================== */
		panels.bk.appendChild(E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Резервные копии'),
			bkBox
		]));

		/* ===================== Automation (lists tab) ===================== */
		var selInt = E('select', { 'class': 'gs-input' });
		['1', '2', '3', '5', '10', '15', '30'].forEach(function(v) {
			var op = E('option', { value: v }, 'каждые ' + v + ' мин');
			if (stk.sync_interval && String(stk.sync_interval).replace('*/', '') === v) op.selected = true;
			selInt.appendChild(op);
		});
		var btnInt = E('button', { 'class': 'gs-btn', 'click': function() {
			btnInt.disabled = true;
			callSyncSet({ interval: selInt.value }).then(function(res) {
				btnInt.disabled = false;
				if (res && res.error) { ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'error'); return; }
				ui.addNotification(null, E('p', {}, 'Cron-страховка синка: каждые ' + selInt.value + ' мин'), 'info');
				return view.reload();
			}).catch(function(e) { btnInt.disabled = false; ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error'); });
		} }, 'Применить');
		var btnSyncd = stk.syncd_enabled
			? E('button', { 'class': 'gs-btn gs-btn-warn', 'click': function() {
				btnSyncd.disabled = true;
				callSyncdSet({ state: 'off' }).then(function() { view.reload(); }).catch(function() { btnSyncd.disabled = false; });
			} }, 'Выключить сторож')
			: E('button', { 'class': 'gs-btn gs-btn-primary', 'click': function() {
				btnSyncd.disabled = true;
				callSyncdSet({ state: 'on' }).then(function() { view.reload(); }).catch(function() { btnSyncd.disabled = false; });
			} }, 'Включить сторож');
		panels.lists.appendChild(E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Автоматизация применения списков'),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Событийный сторож (применяет за секунды)'),
				E('span', { 'class': 'gs-badge ' + (stk.syncd ? 'gs-ok' : 'gs-off') }, stk.syncd ? 'работает' : 'не запущен'),
				btnSyncd
			]),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Cron-страховка (полный прогон)'),
				E('span', { 'class': 'gs-val gs-mono' }, String(stk.sync_interval || '*/5')),
				E('span', {}, [selInt, btnInt])
			]),
			E('div', { 'class': 'gs-hint' }, 'Сторож реагирует на сохранение списков в MagiTrickle; cron — гарантия на случай сбоя события.')
		]));

		/* ===================== Lists template (lists tab, v1.13.0) ===================== */
		var btnSeed = E('button', { 'class': 'gs-btn gs-btn-warn', 'click': function() {
			if (!confirm('Восстановить списки MagiTrickle из шаблона geomask? Текущие группы будут перезаписаны (config.yaml сохранится в бэкап), MagiTrickle перезапустится на несколько секунд.')) return;
			btnSeed.disabled = true; btnSeed.textContent = 'Восстановление…';
			callListsSeed().then(function(res) {
				btnSeed.disabled = false; btnSeed.textContent = 'Восстановить из шаблона';
				if (res && res.ok) ui.addNotification(null, E('p', {}, 'Списки восстановлены из шаблона'), 'info');
				else ui.addNotification(null, E('p', {}, 'Ошибка восстановления: ' + ((res && res.result) || 'см. журнал')), 'error');
				return view.reload();
			}).catch(function(e) { btnSeed.disabled = false; btnSeed.textContent = 'Восстановить из шаблона'; ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error'); });
		} }, 'Восстановить из шаблона');
		panels.lists.appendChild(E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Шаблоны списков (резерв восстановления)'),
			E('div', { 'class': 'gs-hint', 'style': 'margin:0 0 8px' },
				'geomask хранит снимок всех групп MagiTrickle (To VPN / To Not VPN / Google+AI / Geoblock / Youtube и др.) — без секретов. ' +
				'После переустановки или сброса (инцидент B-018) кнопка ниже вернет списки к этому снимку. Тонкая правка доменов — в панели MagiTrickle (:8080).'),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Шаблон'),
				E('span', { 'class': 'gs-badge ' + (lt.template_present ? 'gs-ok' : 'gs-off') }, lt.template_present ? ('v' + (lt.template_version || '?')) : 'отсутствует'),
				E('span', { 'class': 'gs-val gs-mono' }, 'групп ' + (lt.template_groups || 0) + ' · правил ' + (lt.template_rules || 0))
			]),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Сейчас в MagiTrickle'),
				E('span', { 'class': 'gs-val gs-mono' }, 'групп ' + (lt.current_groups || 0) + ' · правил ' + (lt.current_rules || 0)),
				E('span', { 'class': 'gs-badge ' + (lt.magitrickle_running ? 'gs-ok' : 'gs-off') }, lt.magitrickle_running ? 'работает' : 'остановлен')
			]),
			E('div', { 'class': 'gs-row' }, [ btnSeed ])
		]));

		/* ===================== YouTube edges watchdog (lists tab, v1.14.0) ===================== */
		var ytAuto = (yt.mode || 'auto') === 'auto';
		var setMode = function(m, btn) {
			btn.disabled = true;
			callYtMode({ mode: m }).then(function(res) {
				btn.disabled = false;
				if (res && res.ok) ui.addNotification(null, E('p', {}, m === 'auto' ? 'Режим авто: битые рёбра уходят в VPN, остальные через запрет (DPI)' : 'Режим blanket: весь googlevideo в VPN'), 'info');
				else ui.addNotification(null, E('p', {}, 'Не удалось переключить режим'), 'error');
				return view.reload();
			}).catch(function(e) { btn.disabled = false; ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error'); });
		};
		var btnYtAuto = E('button', { 'class': 'gs-btn' + (ytAuto ? '' : ' gs-btn-primary'), 'click': function() { setMode('auto', btnYtAuto); } }, 'Авто (битые — в VPN)');
		var btnYtAll = E('button', { 'class': 'gs-btn' + (ytAuto ? '' : ' gs-btn-primary'), 'click': function() { setMode('blanket', btnYtAll); } }, 'Весь googlevideo в VPN');
		var btnYtRel = E('button', { 'class': 'gs-btn gs-btn-warn', 'click': function() {
			if (!confirm('Отпустить все автотопинги? Рёбра вернутся на прямой путь через запрет (DPI).')) return;
			btnYtRel.disabled = true;
			callYtReset().then(function() { view.reload(); }).catch(function(e) { btnYtRel.disabled = false; ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error'); });
		} }, 'Отпустить пины сейчас');
		var ytPins = yt.pinned_hosts || [];
		panels.lists.appendChild(E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'YouTube: рёбра googlevideo'),
			E('div', { 'class': 'gs-hint', 'style': 'margin:0 0 8px' },
				'Google раздаёт адреса рёбер динамически и часть из них блокируется по IP, поэтому статический список всегда отстаёт. ' +
				'В режиме «Авто» рёбра идут напрямую через запрет (DPI), а watchdog каждые 5 минут читает ошибки соединений mihomo и ' +
				'кладёт реально падающие хосты в группу «GoogleVideo VPN» (видно в MagiTrickle :8080). Ночью пины отпускаются. ' +
				'Картинки (ytimg/ggpht) и сам youtube.com — всегда напрямую через запрет.'),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Режим'),
				E('span', { 'class': 'gs-badge ' + (ytAuto ? 'gs-ok' : 'gs-off') }, ytAuto ? 'авто' : 'весь в VPN'),
				btnYtAuto, btnYtAll
			]),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Сейчас в VPN'),
				E('span', { 'class': 'gs-val gs-mono' }, ytPins.length ? (ytPins.length + ' ребра') : '—'),
				E('span', { 'class': 'gs-hint' }, 'порог ' + (yt.threshold || 2) + ' ошибок за ' + (yt.window_min || 30) + ' мин, максимум ' + (yt.max_pins || 40))
			]),
			ytPins.length ? E('div', { 'class': 'gs-blocklist' }, ytPins.join('\n')) : null,
			(function(){
				var st = yt.stalled || {}, ks = Object.keys(st).sort();
				return E('div', { 'class': 'gs-row' }, [
					E('span', { 'class': 'gs-label' }, 'Зависшие рёбра'),
					E('span', { 'class': 'gs-badge ' + (ks.length ? 'gs-warn' : 'gs-ok') }, ks.length ? (ks.length + ' без данных') : 'нет'),
					E('span', { 'class': 'gs-hint' }, 'считается зависшим: живёт >' + (yt.stall_min_age || 25) + ' с и скачано <' +
						Math.round((yt.stall_max_bytes || 10000)/1024) + ' КБ — такое ребро пинится в VPN')
				]);
			})(),
			(function(){
				var st = yt.stalled || {}, ks = Object.keys(st).sort();
				return ks.length ? E('div', { 'class': 'gs-blocklist' }, ks.join('\n')) : null;
			})(),
			E('div', { 'class': 'gs-row' }, [ btnYtRel ])
		]));

		/* ===================== Torrents (lists tab, v1.15.0) ===================== */
		var torOn = !!tor.listener_present;
		var setListener = function(state, btn) {
			btn.disabled = true;
			callTorListener({ state: state }).then(function(res) {
				btn.disabled = false;
				if (res && res.ok) ui.addNotification(null, E('p', {}, state === 'on' ? 'Слушатель включён' : 'Слушатель выключен'), 'info');
				else ui.addNotification(null, E('p', {}, 'Не удалось изменить (см. /root/geo-sync.log)'), 'error');
				return view.reload();
			}).catch(function(e) { btn.disabled = false; ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error'); });
		};
		var btnTorOff = E('button', { 'class': 'gs-btn gs-btn-warn', 'click': function() {
			if (!confirm('Выключить слушатель? Клиенты, указавшие его как прокси, потеряют обход VPN-подписки и пойдут по обычным правилам.')) return;
			setListener('off', btnTorOff);
		} }, 'Выключить слушатель');
		var btnTorOn = E('button', { 'class': 'gs-btn' + (torOn ? '' : ' gs-btn-primary'), 'click': function() { setListener('on', btnTorOn); } }, 'Включить слушатель');
		var btnTorUpd = E('button', { 'class': 'gs-btn', 'click': function() {
			btnTorUpd.disabled = true; btnTorUpd.textContent = 'Обновляю…';
			callTorRefresh().then(function(res) {
				btnTorUpd.disabled = false; btnTorUpd.textContent = 'Обновить списки трекеров';
				ui.addNotification(null, E('p', {}, (res && res.changed) ? ('Список пересобран: доменов ' + res.domains + ', IP ' + res.raw_ips) : 'Изменений нет'), 'info');
				return view.reload();
			}).catch(function(e) { btnTorUpd.disabled = false; btnTorUpd.textContent = 'Обновить списки трекеров'; ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error'); });
		} }, 'Обновить списки трекеров');
		var inTorExtra = E('textarea', { 'class': 'gs-text', rows: 3, style: 'width:100%;font-family:monospace' });
		inTorExtra.value = (tor.extras || []).join('\n');
		var btnTorExtra = E('button', { 'class': 'gs-btn', 'click': function() {
			btnTorExtra.disabled = true;
			callTorExtra({ hosts: inTorExtra.value }).then(function(res) {
				btnTorExtra.disabled = false;
				if (res && res.ok) ui.addNotification(null, E('p', {}, 'Сохранено, правил: ' + res.domains), 'info');
				else ui.addNotification(null, E('p', {}, 'Отклонено: ' + ((res && res.rejected || []).join(', ') || 'ошибка')), 'error');
				return view.reload();
			}).catch(function(e) { btnTorExtra.disabled = false; ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error'); });
		} }, 'Сохранить и пересобрать');
		panels.lists.appendChild(E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Торренты и трекеры'),
			E('div', { 'class': 'gs-hint', 'style': 'margin:0 0 8px' },
				'Ни одно торрент-соединение не должно идти через обычную VPN-подписку — провайдер это ' +
				'запрещает и 31.10 заблокировал подписку, увидев BitTorrent в туннеле. Клиент указывает ' +
				'прокси на локальный слушатель с жёсткой политикой: торренты уходят в AI-подписку ' +
				'(ограничений на P2P у неё нет), а AI-домены через тот же слушатель попадают в AI — ' +
				'утечка в DIRECT исключена по построению. Дополнительно: домены трекеров закреплены ' +
				'ruleset\'ом (DIRECT), а ответы входящим пирам — правилом SRC-PORT (AI), потому что ' +
				'1300 IP-CIDR хостинговых групп уводят пиров на OVH/Hetzner/DO в VPN.'),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Слушатель'),
				E('span', { 'class': 'gs-badge ' + (torOn ? 'gs-ok' : 'gs-off') },
					torOn ? ('работает :' + (tor.listener_port || 7894) + ' → ' + (tor.listener_policy || 'без политики')) : 'выключен'),
				E('span', { 'class': 'gs-val gs-mono' }, tor.proxy_hint || ''),
				(torOn ? btnTorOff : btnTorOn)
			]),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Список трекеров'),
				E('span', { 'class': 'gs-val gs-mono' }, 'доменов ' + (tor.domains || 0) + ' · IP ' + (tor.raw_ips || 0)),
				E('span', { 'class': 'gs-badge ' + (tor.provider_loaded ? 'gs-ok' : 'gs-off') }, 'в mihomo: ' + (tor.provider_loaded || 0)),
				btnTorUpd
			]),
			E('div', { 'class': 'gs-hint', 'style': 'margin:6px 0 4px' },
				'Свои домены (по строке). Пересобираются вместе с публичными списками: ' +
				((tor.sources || []).join(' , ') || '—')),
			inTorExtra,
			E('div', { 'class': 'gs-row' }, [ btnTorExtra ])
		]));

		/* ===================== Node audit (nodes tab, v1.12.0) ===================== */
		var conf = nd.conf || {};
		var chkEn = E('input', { type: 'checkbox' }); chkEn.checked = (nd.enabled !== false);
		var inSched = E('input', { 'class': 'gs-text', type: 'text', value: nd.schedule || '03:30', size: 6 });
		var inCC = E('input', { 'class': 'gs-text', type: 'text', value: conf.bad_countries || '', size: 14 });
		var inAS = E('input', { 'class': 'gs-text', type: 'text', value: conf.bad_asns || '', size: 24 });
		var inBase = E('input', { 'class': 'gs-text', type: 'text', value: conf.base_filter || '', size: 40 });
		var inProv = E('input', { 'class': 'gs-text', type: 'text', value: conf.sub_provider || 'sub', size: 8 });
		var btnSave = E('button', { 'class': 'gs-btn gs-btn-primary', 'click': function() {
			btnSave.disabled = true; btnSave.textContent = 'Сохранение…';
			callNodesSet({
				enabled: chkEn.checked ? '1' : '0',
				schedule: inSched.value.trim(), countries: inCC.value.trim(), asns: inAS.value.trim(),
				base: inBase.value.trim(), provider: inProv.value.trim()
			}).then(function(res) {
				btnSave.disabled = false; btnSave.textContent = 'Сохранить';
				if (res && res.error) { ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'error'); return; }
				ui.addNotification(null, E('p', {}, 'Настройки аудита сохранены'), 'info');
				return view.reload();
			}).catch(function(e) { btnSave.disabled = false; btnSave.textContent = 'Сохранить'; ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error'); });
		} }, 'Сохранить');
		var btnRun = E('button', { 'class': 'gs-btn', 'click': function() {
			btnRun.disabled = true; btnRun.textContent = 'Запущен…';
			callNodescan().then(function() {
				ui.addNotification(null, E('p', {}, 'Аудит запущен (до ~1 минуты), затем фильтр применится сам'), 'info');
				setTimeout(function() { view.reload(); }, 45000);
			}).catch(function(e) { btnRun.disabled = false; ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error'); });
		} }, 'Проверить сейчас');
		var nst = nd.state || {};
		var blocked = nd.blocked || [];
		panels.nodes.appendChild(E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Ночной аудит узлов подписки'),
			E('div', { 'class': 'gs-hint', 'style': 'margin:0 0 8px' },
				'Сканер скачивает подписку, проверяет адрес каждого сервера по гео-реестрам (страна и владелец сети), ' +
				'и собирает exclude-filter группы VPN: узлы с «плохой» сетью блокируются точным именем, чистые — разблокируются. ' +
				'Трафик при этом не переключается; конфиг применяется только после успешной проверки mihomo -t.'),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Последний прогон'),
				E('span', { 'class': 'gs-val' }, nst.ts ? (nst.ts + ' · узлов ' + nst.total + ' · заблокировано ' + nst.blocked
					+ (nst.errors ? ' · сбоев проверки ' + nst.errors : '') + (nst.changed ? ' · фильтр обновлён' : ''))
					: 'ещё не запускался')
			]),
			E('div', { 'class': 'gs-row' }, [
				E('label', { 'class': 'gs-check' }, [chkEn, E('span', {}, 'Аудит по расписанию (ночью)')]),
				E('span', { 'class': 'gs-label' }, 'Время (ЧЧ:ММ)'), inSched, btnRun
			]),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Плохие страны'), inCC,
				E('span', { 'class': 'gs-label' }, 'Плохие сети (ASN)'), inAS,
				E('span', { 'class': 'gs-label' }, 'Провайдер'), inProv
			]),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Базовый фильтр имён'), inBase, btnSave
			]),
			E('div', { 'class': 'gs-hint' }, 'Страны: AA,BB (ISO-2). ASN: AS123456,AS234. Без кавычек и обратных слэшей.'),
			E('div', { 'class': 'gs-blocklist' }, blocked.length ? blocked.join('\n') : 'заблокированных узлов нет'),
			E('div', { 'class': 'gs-upd-meta' }, (nd.log || []).join('\n'))
		]));

		/* ===================== Settings tab ===================== */
		var btnPin = stk.pin
			? E('button', { 'class': 'gs-btn gs-btn-warn', 'click': function() {
				if (!confirm('Снять запрет рестарта mihomo? Панельные операции с --restart снова станут возможны.')) return;
				btnPin.disabled = true;
				callPinSet({ state: 'off' }).then(function() { view.reload(); }).catch(function() { btnPin.disabled = false; });
			} }, 'Снять пин')
			: E('button', { 'class': 'gs-btn', 'click': function() {
				btnPin.disabled = true;
				callPinSet({ state: 'on' }).then(function() { view.reload(); }).catch(function() { btnPin.disabled = false; });
			} }, 'Запретить рестарты');
		var K = stk.links || {};
		function linkRow(label, url) {
			return E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, label),
				url ? E('a', { 'href': url, 'target': '_blank', 'class': 'gs-mono' }, url) : E('span', {}, '—')
			]);
		}
		panels.set.appendChild(E('div', { 'class': 'gs-card' }, [
			E('h3', {}, 'Прочее'),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Пин «не рестартить mihomo»'),
				E('span', { 'class': 'gs-badge ' + (stk.pin ? 'gs-on' : 'gs-off') }, stk.pin ? 'установлен' : 'снят'),
				btnPin
			]),
			E('div', { 'class': 'gs-hint' }, 'С пином безопасные операции панели не трогают живой VPN-трафик рестартами. Снимайте только осознанно.'),
			linkRow('MagiTrickle (группы доменов)', K.magitrickle),
			linkRow('Zapret DPI (стратегии)', K.zapret),
			linkRow('Лендинг портов', K.landing),
			linkRow('LuCI', K.luci),
			E('div', { 'class': 'gs-row' }, [
				E('span', { 'class': 'gs-label' }, 'Версия панели'),
				E('span', { 'class': 'gs-val gs-mono' }, PANEL_VERSION)
			])
		]));

		return wrap;
	},

	act: function(rpcFn, params, okMsg) {
		var view = this;
		return rpcFn(params).then(function(res) {
			if (res && res.error) { ui.addNotification(null, E('p', {}, 'Ошибка: ' + res.error), 'error'); return; }
			if (okMsg) ui.addNotification(null, E('p', {}, okMsg), 'info');
			return view.reload();
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, 'Ошибка: ' + e), 'error');
		});
	},

	reload: function() {
		var view = this;
		return Promise.all([ callStatus(), callLeases(), callLog(), callAiSubGet(), callSubsList(),
			callUpdCheck({ force: null }), callUpdStatus(), callBackups(), callStack(), callNodesGet(), callListsGet(), callYtGet(), callTorGet() ]).then(function(all) {
			var newView = view.render(all);
			var old = document.querySelector('.gs-wrap');
			if (old && old.parentNode) old.parentNode.replaceChild(newView, old);
		});
	}
});

ASSET_EOF
  info "reloading rpcd + luci menu..."
  initd rpcd reload 2>/dev/null || true
  sleep 1
  # procd can coalesce the uninstall+install reload pair in --reinstall and drop
  # the second signal -> geo-sync stays unregistered; re-send until it appears.
  ubus list 2>/dev/null | grep -qx 'geo-sync' || { initd rpcd reload 2>/dev/null || true; sleep 2; }
  ubus list 2>/dev/null | grep -qx 'geo-sync' || { initd rpcd reload 2>/dev/null || true; sleep 2; }
  ensure_smb_share
  return 0
}
step2_verify() { step2_check; }

# ============================================================ STEP 3: mihomo 2-subscription config
MIHOMO_CONF=/etc/mihomo/config.yaml

step3_check() {
  _need=0
  if ! have mihomo; then bad "mihomo binary missing"; return 1; fi
  _c="$(P $MIHOMO_CONF)"
  if [ ! -s "$_c" ]; then bad "$MIHOMO_CONF missing (шаг subs при запуске создаст конфиг и спросит обе ссылки)"; return 1; fi
  _np=$(grep -c 'type: http' "$_c" 2>/dev/null || echo 0)
  if [ "$_np" -ge 2 ] 2>/dev/null; then info "proxy-providers: $_np (need >=2)"; else bad "proxy-providers: $_np (need 2: VPN + AI)"; _need=1; fi
  for g in VPN-noP2P AI; do
    if grep -q "name: $g$" "$_c" 2>/dev/null; then info "slot $g: present"; else bad "slot $g: missing"; _need=1; fi
  done
  grep -qE '^  - name: VPN$' "$_c" 2>/dev/null \
    && info "default tunnel group VPN: present (main lists ride the P2P-tolerant subscription)" \
    || info "default tunnel group VPN: absent (single tunnel - main lists ride VPN-noP2P)"
  grep -q 'RULE-SET,ai,AI' "$_c" 2>/dev/null && info "rule ai->AI: present" || { bad "rule ai->AI missing"; _need=1; }
  grep -qE 'RULE-SET,mtrickle,(VPN|VPN-noP2P)' "$_c" 2>/dev/null \
    && info "rule mtrickle->$(grep -oE 'RULE-SET,mtrickle,[A-Za-z0-9_-]+' "$_c" | head -1 | cut -d, -f3): present" \
    || { bad "rule mtrickle->VPN missing"; _need=1; }
  grep -q 'ai-devices' "$_c" 2>/dev/null && info "listeners (ai-devices): present" || { bad "listeners (ai-devices:7891) missing"; _need=1; }
  if grep -q 'torrent-direct' "$_c" 2>/dev/null; then
    # v1.18.0: with the P2P-tolerant "VPN" lane configured, no IP rule can reach the restricted
    # slot, so the listener may be rule-based (and AI domains through it still land in AI). Without
    # the lane the listener MUST carry a fixed policy - that is what blocked the subscription.
    _tp=$(awk '/name: torrent-direct/{f=1;next} f&&/^[^ ]/{exit} f&&/^    proxy:/{sub(/^[^:]*:[[:space:]]*/,"");print;exit}' "$_c")
    if grep -q 'name: VPN$' "$_c" 2>/dev/null; then
      info "listener (torrent-direct:7894, rule-based + VPN lane): present"
    else
      case "$_tp" in
        AI|DIRECT) info "listener (torrent-direct:7894 -> $_tp): present" ;;
        '')        bad "torrent listener has no fixed policy and no VPN lane - peers can reach the restricted sub"; _need=1 ;;
        *)         bad "torrent listener policy is '$_tp' - expected AI or DIRECT (or configure the VPN lane)"; _need=1 ;;
      esac
    fi
  else warn "torrent-direct listener missing (torrent clients cannot be pinned away from the VPN sub)"; fi
  grep -qE '^  - SRC-PORT,41552,(VPN|AI|DIRECT)$' "$_c" 2>/dev/null \
    && info "torrent peer guard (SRC-PORT): present" \
    || warn "SRC-PORT,41552 guard missing - incoming peers may still be routed to the VPN sub"
  grep -q 'ports: \[443, 8443, 5228\]' "$_c" 2>/dev/null && info "sniffer TLS 5228 (Google push): present" || { bad "sniffer TLS 5228 missing (B-017: Google push уходит DIRECT)"; _need=1; }
  grep -q '^ipv6: false' "$_c" 2>/dev/null && info "mihomo ipv6: false" || warn "mihomo ipv6: true — на роутере IPv6 отключён, рекомендуется false"
  grep -q 'DOMAIN-SUFFIX,youtube.com)),REJECT' "$_c" 2>/dev/null && info "QUIC reject (видео -> TCP): present" || warn "QUIC reject rules missing (B-016: тротлинг QUIC-видео)"
  grep -qE 'RULE-SET,ytvpn,(VPN|VPN-noP2P)' "$_c" 2>/dev/null && info "ytvpn rule: present" || warn "ytvpn rule missing (IP-blocked googlevideo edges won't route to a tunnel)"
  # v1.14.4: torrents must never be swallowed by the VPN lists (owner policy 30.10)
  # v1.21.7: the owner moved torrent/tracker domains from DIRECT onto the P2P-tolerant VPN
  # lane, so either target is correct now - only a missing ruleset is a problem.
  grep -qE 'RULE-SET,torrentdirect,(DIRECT|VPN)' "$_c" 2>/dev/null \
    && info "torrentdirect rule: present ($(awk -F, '/RULE-SET,torrentdirect/{print $3; exit}' "$_c"))" \
    || warn "torrentdirect rule missing (tracker domains can still go to the wrong subscription)"
  # v1.17.0: lane invariant. A torrent peer is always a bare IP, so no IP rule may reach the
  # subscription that forbids P2P. When the P2P-tolerant "VPN" lane exists the IP ruleset must be
  # split out into mtrickle_bulk.yaml and routed there.
  if grep -q 'name: VPN$' "$_c" 2>/dev/null; then
    if grep -qE '^\s*-\s*IP-CIDR' "$(P /etc/mihomo/ruleset/mtrickle.yaml)" 2>/dev/null; then
      bad "mtrickle.yaml still contains IP-CIDR rules - P2P peers can reach the restricted VPN-noP2P sub"
      _need=1
    else info "lane invariant: mtrickle.yaml has no IP rules"; fi
    grep -q 'RULE-SET,mtrickle_bulk,VPN' "$_c" 2>/dev/null \
      && info "lane: IP ruleset -> VPN (P2P-tolerant)" \
      || { bad "lane: mtrickle_bulk -> VPN rule missing"; _need=1; }
    grep -q 'RULE-SET,ytvpn,VPN' "$_c" 2>/dev/null \
      && info "lane: youtube edge pins -> VPN" \
      || warn "ytvpn pins still go to VPN-noP2P (bulk video traffic on a sub that may dislike it)"
  else
    info "lane: VPN not configured (single tunnel - IP rules stay on VPN-noP2P)"
  fi
  # v1.19.0: a port or protocol match is not a protocol classifier - any client can pick that
  # port, so nothing address-shaped may be routed to the subscription that forbids P2P.
  # Only meaningful when a separate P2P-tolerant lane exists: on a single-tunnel box the one
  # group is both, and port rules have nowhere else to go.
  if grep -qE '^  - name: VPN-noP2P$' "$_c" 2>/dev/null && grep -qE '^  - name: VPN$' "$_c" 2>/dev/null; then
    _np_bad=$(awk '/^rules:/{f=1;next} f&&/^[^ ]/{exit} f' "$_c" \
      | grep -E 'VPN-noP2P$' | grep -cE 'SRC-PORT|DST-PORT|IP-CIDR|NETWORK')
    if [ "${_np_bad:-0}" -gt 0 ]; then
      bad "$_np_bad rule(s) send ports/IPs/protocols to VPN-noP2P - a torrent client can just pick that port"
      _need=1
    else info "restricted slot takes domain rules only (no port/IP/protocol matches)"; fi
  fi
  if grep -qE '^  - DST-PORT,(6969|1337|2710|8081|451|5944),' "$_c" 2>/dev/null; then
    bad "legacy blanket P2P DST-PORT rule present - it sits above the ai ruleset and hijacks AI relays on those ports"
    _need=1
  else
    info "no blanket P2P port rules (trackers pinned by torrentdirect only)"
  fi
  for rf in /etc/mihomo/ruleset/mtrickle.yaml /etc/mihomo/ruleset/ai.yaml /etc/mihomo/ruleset/ytdirect.yaml /etc/mihomo/ruleset/ytvpn.yaml /etc/mihomo/ruleset/torrentdirect.yaml; do
    if [ -s "$(P "$rf")" ]; then info "ruleset: $rf ($(grep -c 'DOMAIN-SUFFIX' "$(P "$rf")" 2>/dev/null || echo '?') suffixes)"; else warn "ruleset empty/missing: $rf (sync step will create)"; fi
  done
  if mihomo -d /etc/mihomo -t >/dev/null 2>&1; then info "mihomo -t: PASS"; else bad "mihomo -t: FAIL"; _need=1; fi
  return $_need
}
step3_apply() {
  _c="$(P $MIHOMO_CONF)"
  _vpnu="$GM_VPN_URL"; _aiu="$GM_AI_URL"
  if [ -s "$_c" ]; then
    [ -z "$_vpnu" ] && _vpnu=$(_prov_url "$_c" sub)
    [ -z "$_aiu" ]  && _aiu=$(_prov_url "$_c" de5)
  fi
  if [ -z "$_vpnu" ] || [ -z "$_aiu" ]; then
    # fresh router (no config / no flags): ask for both subscription URLs interactively
    if [ "$GM_AUTO" != 1 ] && [ "$GM_YES" != 1 ] && [ -t 0 ]; then
      info "Подписки не заданы — введите ссылки (общая VPN-подписка и AI-подписка)"
      _vpnu=$(prompt_url "Ссылка на ОБЩУЮ VPN-подписку" "" "") || { bad "URL VPN-подписки не задан"; return 1; }
      _aiu=$(prompt_url "Ссылка на AI-подписку (для Google/AI)" "" "") || { bad "URL AI-подписки не задан"; return 1; }
    else
      bad "subscription URLs unknown - pass --vpn-url and --ai-url (or keep existing config)"
      return 1
    fi
  fi
  info "VPN provider URL: $(_maskurl "$_vpnu")"
  info "AI  provider URL: $(_maskurl "$_aiu")"
  ask "  Write mihomo config with these 2 providers (backup kept)?" || { warn "skipped"; return 1; }
  write_mihomo_config "$_vpnu" "$_aiu" || return 1
  if [ "$GM_RESTART" = 1 ]; then
    safe_mihomo_restart || true
  elif api_refresh_provider sub "$_vpnu" && api_refresh_provider de5 "$_aiu"; then
    info "providers refreshed via API (no restart, VPN stays up)"
  elif svc_alive mihomo; then
    warn "mihomo is running: restart later to apply (rerun with --restart)"
  else
    info "starting mihomo..."
    initd mihomo start >/dev/null 2>&1 || true
  fi
  return 0
}
step3_verify() { step3_check; }

# write a fresh 2-provider mihomo config: write_mihomo_config <vpn_url> <ai_url>
# validates with `mihomo -t`, keeps backup of the previous config; no restart here.
write_mihomo_config() {
  _c="$(P $MIHOMO_CONF)"
  _vpnu="$1"; _aiu="$2"
  # --- existing 2-subscription config: keep it as-is (custom rules, headers, sniffer)
  #     and only patch provider urls / ensure the ai-devices listener ---
  if [ -s "$_c" ] && grep -q '^  sub:' "$_c" && grep -q '^  de5:' "$_c" \
     && grep -q 'name: VPN' "$_c" && grep -q 'name: AI' "$_c"; then
    _curv=$(_prov_url "$_c" sub)
    _cura=$(_prov_url "$_c" de5)
    if [ -n "${_vpnu:-}" ] && [ "$_vpnu" != "$_curv" ]; then _swap=1; fi
    if [ -n "${_aiu:-}" ] && [ "$_aiu" != "$_cura" ]; then _swap=1; fi
    if [ "${_swap:-0}" = 1 ]; then
      cp -p "$_c" "$_c.bak_geomask_$(date +%s)" || true
      if ! awk -v pn="^  $([ "$_vpnu" != "$_curv" ] && echo sub || echo de5):" -v nu="$([ "$_vpnu" != "$_curv" ] && printf '%s' "$_vpnu" || printf '%s' "$_aiu")" '
        BEGIN{f=0;done=0}
        $0 ~ pn {f=1; print; next}
        f && /^    url:/{print "    url: \"" nu "\""; done=1; next}
        f && /^  [A-Za-z0-9_-]+:/{f=0}
        f && /^[A-Za-z]/{f=0}
        {print}
        END{exit done?0:1}' "$_c" > "$_c.urlnew"; then
        rm -f "$_c.urlnew"; bad "provider url patch failed"; return 1
      fi
      mihomo -d /etc/mihomo -t >/dev/null 2>&1 && mv -f "$_c.urlnew" "$_c" || { rm -f "$_c.urlnew"; bad "mihomo -t failed - config kept"; return 1; }
      info "provider url(s) updated in place (sub=$( [ "$_vpnu" != "$_curv" ] && echo sub || echo de5))"
    fi
    if ! grep -q 'ai-devices' "$_c"; then
      cp -p "$_c" "$_c.bak_geomask_$(date +%s)" || true
      awk 'BEGIN{d=0}
        /^proxy-providers:/ && !d {print "listeners:";print "  - name: ai-devices";print "    type: mixed";print "    port: 7891";print "    listen: 127.0.0.1";print "    proxy: AI";print "  - name: torrent-direct";print "    type: mixed";print "    port: 7894";print "    listen: 192.168.0.1";print "";d=1}
        {print}' "$_c" > "$_c.zmnew" || return 1
      if mihomo -d /etc/mihomo -t >/dev/null 2>&1; then
        mv -f "$_c.zmnew" "$_c"; info "listeners block added to existing config (custom rules preserved)"
      else
        rm -f "$_c.zmnew"; bad "mihomo -t failed after adding listeners - config kept"; return 1
      fi
    else
      # v1.14.4: config already had listeners - make sure the torrent DIRECT one exists
      if ! grep -q 'torrent-direct' "$_c"; then
        cp -p "$_c" "$_c.bak_geomask_$(date +%s)" || true
        awk 'BEGIN{d=0} {print} (!d && $0 ~ /^    proxy: AI$/) {
              print "  - name: torrent-direct"; print "    type: mixed"; print "    port: 7894";
              print "    listen: 192.168.0.1"; d=1 }' "$_c" > "$_c.tdnew" || return 1
        if mihomo -d /etc/mihomo -t >/dev/null 2>&1; then
          mv -f "$_c.tdnew" "$_c"; info "torrent-direct listener added (listeners already present)"
        else
          rm -f "$_c.tdnew"; bad "mihomo -t failed after adding torrent-direct - config kept"; return 1
        fi
      else
        info "existing 2-subscription config kept as-is (ai-devices + torrent-direct present)"
      fi
    fi
    return 0
  fi
  _hwid=$(grep -A1 'x-hwid' "$_c" 2>/dev/null | sed -n 's/^[[:space:]]*-[[:space:]]*"\(.*\)"/\1/p' | head -1)
  _tmpconf="$_c.zmnew"
  {
    printf '%s\n' 'mixed-port: 7890'
    printf '%s\n' 'allow-lan: true'
    printf '%s\n' 'bind-address: "0.0.0.0"'
    printf '%s\n' 'tcp-concurrent: true'
    printf '%s\n' 'mode: rule'
    printf '%s\n' 'log-level: info'
    printf '%s\n' 'ipv6: false'
    printf '%s\n' 'external-controller: 0.0.0.0:9090'
    printf '%s\n' 'external-ui: ui'
    printf '%s\n' 'unified-delay: true'
    printf '%s\n' 'find-process-mode: off'
    printf '%s\n' 'profile:'
    printf '%s\n' '  store-selected: true'
    printf '%s\n' '  store-fake-ip: true'
    printf '\n'
    printf '%s\n' 'listeners:'
    printf '%s\n' '  - name: ai-devices'
    printf '%s\n' '    type: mixed'
    printf '%s\n' '    port: 7891'
    printf '%s\n' '    listen: 127.0.0.1'
    printf '%s\n' '    proxy: AI'
    printf '%s\n' '  # torrent clients point here (SOCKS5/HTTP). Fresh installs have no RESERVE lane,'
    printf '%s\n' '  # so a fixed policy is REQUIRED: without it the rule chain decides and peers on'
    printf '%s\n' '  # hosting-provider IPs land on the VPN sub (that is what got it blocked, 31.10).'
    printf '%s\n' '  # DIRECT keeps P2P off the VPN sub entirely; switch to AI if your VPN sub is the'
    printf '%s\n' '  # only usable tunnel, or drop the policy once a RESERVE lane takes the IP rules.'
    printf '%s\n' '  - name: torrent-direct'
    printf '%s\n' '    type: mixed'
    printf '%s\n' '    port: 7894'
    printf '%s\n' '    listen: 192.168.0.1'
    printf '%s\n' '    proxy: DIRECT'
    printf '\n'
    printf '%s\n' 'proxy-providers:'
    printf '%s\n' '  sub:'
    printf '%s\n' '    type: http'
    printf '%s\n' '    proxy: DIRECT'
    if [ -n "${_hwid:-}" ]; then
      printf '%s\n' '    header:'
      printf '%s\n' '      x-hwid:'
      printf '%s\n' "        - \"$_hwid\""
    fi
    printf '%s\n' "    url: \"$_vpnu\""
    printf '%s\n' '    interval: 3600'
    # NO provider health-check on purpose (v1.21.3): mihomo removes nodes that fail it from the
    # group, so a slow or briefly unreachable subscription silently empties the lane and every
    # rule pointing at it starts returning 502. The proxy-group tests are enough.
    printf '%s\n' '  de5:'
    printf '%s\n' '    type: http'
    printf '%s\n' '    proxy: DIRECT'
    printf '%s\n' "    url: \"$_aiu\""
    printf '%s\n' '    interval: 3600'
    printf '\n'
    printf '%s\n' 'proxy-groups:'
    printf '%s\n' '  # slot VPN-noP2P: the subscription whose provider forbids P2P (default tunnel).'
    printf '%s\n' '  # A second, P2P-tolerant tunnel (slot VPN -> group "VPN") is created by the panel'
    printf '%s\n' '  # when a subscription is assigned to it; IP rules then move over there.'
    printf '%s\n' '  - name: VPN-noP2P'
    printf '%s\n' '    type: url-test'
    printf '%s\n' '    use:'
    printf '%s\n' '      - sub'
    printf '%s\n' '    exclude-filter: "Россия|Мобильный|РФ|Авто|Russia|Mobile|Auto|Албания|Хорватия|Литва|Латвия|Дания|Финляндия|Нидерланды-(5|13|16|18)($|[^0-9])|Германия-[234]($|[^0-9])|США-1($|[^0-9])|Турция"'
    printf '%s\n' '    url: "https://www.gstatic.com/generate_204"'
    printf '%s\n' '    interval: 180'
    printf '%s\n' '    tolerance: 50'
    printf '%s\n' '    lazy: false'
    printf '%s\n' '  - name: AI'
    printf '%s\n' '    type: url-test'
    printf '%s\n' '    use:'
    printf '%s\n' '      - de5'
    printf '%s\n' '    url: "https://www.gstatic.com/generate_204"'
    printf '%s\n' '    interval: 180'
    printf '%s\n' '    tolerance: 50'
    printf '%s\n' '    lazy: false'
    printf '\n'
    printf '%s\n' 'rule-providers:'
    printf '%s\n' '  ai:'
    printf '%s\n' '    type: file'
    printf '%s\n' '    behavior: classical'
    printf '%s\n' '    path: /etc/mihomo/ruleset/ai.yaml'
    printf '%s\n' '  mtrickle:'
    printf '%s\n' '    type: file'
    printf '%s\n' '    behavior: classical'
    printf '%s\n' '    path: /etc/mihomo/ruleset/mtrickle.yaml'
    printf '%s\n' '  ytdirect:'
    printf '%s\n' '    type: file'
    printf '%s\n' '    behavior: classical'
    printf '%s\n' '    path: /etc/mihomo/ruleset/ytdirect.yaml'
    printf '%s\n' '  ytvpn:'
    printf '%s\n' '    type: file'
    printf '%s\n' '    behavior: classical'
    printf '%s\n' '    path: /etc/mihomo/ruleset/ytvpn.yaml'
    printf '%s\n' '  torrentdirect:'
    printf '%s\n' '    type: file'
    printf '%s\n' '    behavior: classical'
    printf '%s\n' '    path: /etc/mihomo/ruleset/torrentdirect.yaml'
    printf '\n'
    printf '%s\n' 'rules:'
    printf '%s\n' '  # AUTO-SYNC from magitrickle: /root/sync_mtrickle_mihomo.sh - DO NOT EDIT MANUALLY'
    printf '%s\n' '  # v1.15.0: no blanket DST-PORT rules for P2P - they sat ABOVE the ai ruleset and'
    printf '%s\n' '  # hijacked AI relays that happen to use those ports. Trackers are pinned by the'
    printf '%s\n' '  # torrentdirect ruleset below (managed by geomask-torrent.sh).'
    printf '%s\n' '  # v1.20.0: the old hand-written "DOMAIN-SUFFIX,rutracker.*,DIRECT" pins were removed.'
    printf '%s\n' '  # Torrent sites belong in a MagiTrickle group on a direct interface - that is the'
    printf '%s\n' '  # single place where direction is decided; a pin above the rules silently outranks'
    printf '%s\n' '  # whatever group the owner puts the domain in.'
    printf '%s\n' '  # QUIC forced to TCP for video hosts (RKN UDP-443 throttle, B-016)'
    printf '%s\n' '  - AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,googlevideo.com)),REJECT'
    printf '%s\n' '  - AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,youtube.com)),REJECT'
    printf '%s\n' '  - AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,youtu.be)),REJECT'
    printf '%s\n' '  - RULE-SET,ytvpn,VPN-noP2P'
    printf '%s\n' '  - RULE-SET,ytdirect,DIRECT'
    printf '%s\n' '  - DOMAIN-SUFFIX,cloudflare-ech.com,AI'
    printf '%s\n' '  - RULE-SET,ai,AI'
    printf '%s\n' '  # torrent tracker endpoints (public lists) - DIRECT, after ai so the AI policy always wins'
    printf '%s\n' '  - RULE-SET,torrentdirect,VPN'
    printf '%s\n' '  # torrent client listening port: peers that dial US must not reach the VPN slot;'
    printf '%s\n' '  # with a RESERVE/VPN lane configured geomask repoints this to that lane'
    printf '%s\n' '  - SRC-PORT,41552,AI'
    printf '%s\n' '  - RULE-SET,mtrickle,VPN-noP2P'
    printf '%s\n' '  # STUN: stop WebRTC leaking the real (RU) IP, keep calls working'
    printf '%s\n' '  - AND,((NETWORK,udp),(DST-PORT,3478)),VPN-noP2P'
    printf '%s\n' '  - AND,((NETWORK,udp),(DST-PORT,19302)),VPN-noP2P'
    printf '%s\n' '  - MATCH,GLOBAL'
    printf '\n'
    printf '%s\n' 'sniffer:'
    printf '%s\n' '  enable: true'
    printf '%s\n' '  parse-pure-ip: true'
    printf '%s\n' '  override-destination: true'
    printf '%s\n' '  sniff:'
    printf '%s\n' '    HTTP:'
    printf '%s\n' '      ports: [80, 8080-8880]'
    printf '%s\n' '    TLS:'
    printf '%s\n' '      ports: [443, 8443, 5228]'
    printf '%s\n' '    QUIC:'
    printf '%s\n' '      ports: [443, 8443]'
  } > "$_tmpconf" || { bad "cannot write $_tmpconf"; return 1; }
  # ruleset files must exist before mihomo -t
  mkdir -p "$(P /etc/mihomo/ruleset)"
  for rf in mtrickle ai ytdirect ytvpn; do
    [ -s "$(P /etc/mihomo/ruleset/$rf.yaml)" ] || printf 'payload: []\n' > "$(P /etc/mihomo/ruleset/$rf.yaml)"
  done
  if mihomo -d /etc/mihomo -t >/dev/null 2>&1; then
    info "mihomo -t on new config: PASS"
  else
    bad "mihomo -t FAILED on new config - keeping old"; rm -f "$_tmpconf"; return 1
  fi
  if [ -f "$_c" ]; then cp -p "$_c" "$_c.bak_geomask_$(date +%s 2>/dev/null || echo bak)"; fi
  mv -f "$_tmpconf" "$_c" || { bad "cannot install new config"; return 1; }
  info "config installed"
  return 0
}

# runtime provider refresh through mihomo API - NO restart, VPN stays up
api_refresh_provider() { # api_refresh_provider <name> <url>
  [ -n "${2:-}" ] || return 1
  # re-read config from file (re-fetches provider subscription)
  controller_curl -s -m15 -f -X PUT "http://127.0.0.1:9090/configs" \
    -H 'Content-Type: application/json' \
    -d "{\"path\":\"/etc/mihomo/config.yaml\"}" >/dev/null 2>&1
}

# ============================================================ SAFETY layer
# full settings backup (restorable via LuCI) - MANDATORY before any router change
# v1.9.0: stored persistently in /root/geomask-backups/ (retention: freshest one - replaced by
#         the next successful backup; full history lives on the PC via fetch_backup.ps1).
#         Built in /tmp first, then moved: sysupgrade -b archives /root, so an existing copy
#         must not be present while the new one is created (that nesting bloated archives in
#         v1.6-1.8). The folder is published read-only over SMB (share 'geomask-backups',
#         see ensure_smb_share) and linked from the panel.
ensure_backup() { # -> path on stdout, rc=1 on failure
  _ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo bak)
  _dir="$(P /root/geomask-backups)"
  mkdir -p "$_dir" 2>/dev/null
  # remove previous copies BEFORE creating: they live under /root, which sysupgrade -b
  # archives - leaving them in place embeds them into the new archive (observed 19->28 MB).
  # If creation then fails there is no on-router copy; caller aborts the change and the PC
  # history (fetch_backup.ps1) remains.
  rm -f "$_dir"/router-backup-*.tar.gz 2>/dev/null
  _out=""
  if have sysupgrade; then
    _tmp="$(P /tmp)/geomask-bk-$_ts.tar.gz"
    if sysupgrade -b "$_tmp" >/dev/null 2>&1 && [ -s "$_tmp" ]; then _out="$_tmp"; fi
  fi
  if [ -z "$_out" ]; then
    _out="$(P /tmp)/geomask-bk-$_ts-min.tar.gz"
    tar czf "$_out" -C "$(P /)" etc 2>/dev/null || _out=""
  fi
  if [ -z "$_out" ] || [ ! -s "$_out" ]; then
    bad "cannot create backup"
    return 1
  fi
  _dest="$_dir/router-backup-$_ts.tar.gz"
  mv -f "$_out" "$_dest" || { bad "cannot store backup into $_dir"; return 1; }
  chmod 644 "$_dest" 2>/dev/null
  printf '%s' "$_dest"
  return 0
}

# publish the backup folder over SMB via the existing ksmbd server (guest, read-only for
# this share only). Safe no-op when ksmbd is absent. Only touch ksmbd when config changes.
SMB_SHARE_NAME=geomask-backups
BACKUP_DIR=/root/geomask-backups
ensure_smb_share() {
  _init=""
  for c in ksmbd1 ksmbd; do
    [ -x "$(P /etc/init.d/$c)" ] && _init=$c && break
  done
  [ -n "$_init" ] || { info "ksmbd not installed - SMB share for backups skipped (folder still local)"; return 0; }
  have uci || { warn "no uci - SMB share skipped"; return 0; }
  mkdir -p "$(P $BACKUP_DIR)" 2>/dev/null
  chmod 755 "$(P $BACKUP_DIR)" 2>/dev/null
  # uci show lists unnamed sections as ksmbd.@share[N] - match any name chars up to '='
  _secs=$(uci show ksmbd 2>/dev/null | sed -n 's/^\(ksmbd\.[^=]*\)=share$/\1/p')
  # purge leftover share sections without a name (older bug wrote an empty 'config share')
  for s in $_secs; do
    _sn=$(uci -q get "$s.name" 2>/dev/null)
    [ -z "$_sn" ] && uci delete "$s" 2>/dev/null
  done
  # find our share; drop duplicated sections with the same name (1.9.2 created a dupe)
  _found=""
  _dups=""
  for s in $(uci show ksmbd 2>/dev/null | sed -n 's/^\(ksmbd\.[^=]*\)=share$/\1/p'); do
    _sn=$(uci -q get "$s.name" 2>/dev/null)
    [ "$_sn" = "$SMB_SHARE_NAME" ] || continue
    if [ -z "$_found" ]; then _found=$s; else _dups="$_dups $s"; fi
  done
  _changed=0
  if [ -n "$_dups" ]; then
    for s in $_dups; do uci delete "$s" 2>/dev/null; done
    uci commit ksmbd
    _changed=1
    info "SMB share '$SMB_SHARE_NAME': duplicate sections removed"
  fi
  if [ -z "$_found" ]; then
    _sec=$(uci add ksmbd share 2>/dev/null)
    [ -n "$_sec" ] || { warn "uci add failed - SMB share skipped"; return 0; }
    uci set "ksmbd.$_sec.name=$SMB_SHARE_NAME"
    uci set "ksmbd.$_sec.path=$BACKUP_DIR"
    uci set "ksmbd.$_sec.read_only=yes"
    uci set "ksmbd.$_sec.guest_ok=yes"
    uci commit ksmbd
    _found="ksmbd.$_sec"
    _changed=1
    info "SMB share '$SMB_SHARE_NAME' -> $BACKUP_DIR (guest, read-only): created (section $_sec)"
  else
    _p=$(uci -q get "$_found.path" 2>/dev/null)
    if [ "$_p" != "$BACKUP_DIR" ]; then
      uci set "$_found.path=$BACKUP_DIR"
      uci set "$_found.read_only=yes"
      uci set "$_found.guest_ok=yes"
      uci commit ksmbd
      _changed=1
      info "SMB share '$SMB_SHARE_NAME': path fixed -> $BACKUP_DIR"
    else
      # path ok, but v1.9.0/1.9.1 may have stored quoted values ('1') - normalize to yes
      _ro=$(uci -q get "$_found.read_only" 2>/dev/null)
      case "$_ro" in
        1|yes) : ;;
        *) uci set "$_found.read_only=yes"; uci set "$_found.guest_ok=yes"; uci commit ksmbd; _changed=1 ;;
      esac
    fi
  fi
  # v1.9.5: force user root (share under /root is unreachable for the guest uid)
  _fr=$(uci -q get "$_found.force_root" 2>/dev/null)
  [ "$_fr" = 1 ] || { uci set "$_found.force_root=1"; uci commit ksmbd; _changed=1; }
  # v1.9.6: simple access per owner request - user `backup` password `backup`; guest (no
  # password at all) also accepted: the share is read-only either way, LAN-scoped.
  # (Windows blocks insecure-guest mappings in some setups -> the simple pair is the fallback.)
  have ksmbd.adduser && ksmbd.adduser backup -p backup >/dev/null 2>&1
  if [ "$_changed" = 1 ]; then
    # restart ONLY the file server (not the network stack); verify right away
    "/etc/init.d/$_init" restart >/dev/null 2>&1 || true
    sleep 2
  fi
  if grep -qF "[$SMB_SHARE_NAME]" "$(P /etc/ksmbd/ksmbd.conf)" 2>/dev/null; then
    info "SMB share present in ksmbd.conf: \\\\$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)\\$SMB_SHARE_NAME"
  else
    warn "share [$SMB_SHARE_NAME] not found in /etc/ksmbd/ksmbd.conf - check LuCI -> ksmbd"
  fi
  return 0
}

# dry-run: start a COPY of the mihomo config on shifted ports in a temp dir.
# rc=0 only if mihomo actually starts with the new config. Never touches live service.
mihomo_trial_run() {
  _c="$(P $MIHOMO_CONF)"
  [ -s "$_c" ] || { bad "config missing for trial"; return 1; }
  _td="$(P /tmp)/gm-trial-$$"
  rm -rf "$_td"; mkdir -p "$_td"
  cp -a "$(dirname "$_c")/." "$_td/" 2>/dev/null || cp -a "$(P /etc/mihomo)" "$_td" 2>/dev/null || {
    warn "trial: cannot copy mihomo dir"; rm -rf "$_td"; return 1; }
  sed -i -e 's/^mixed-port:.*/mixed-port: 17890/' \
         -e 's/^external-controller:.*/external-controller: 0.0.0.0:19090/' \
         -e 's/^[[:space:]]*port: 7891/    port: 17901/' \
         -e "s|path: /etc/mihomo/|path: $_td/|g" "$_td/config.yaml" 2>/dev/null
  mihomo -d "$_td" -f config.yaml > "$_td/trial.log" 2>&1 &
  _tp=$!
  sleep 3
  if kill -0 "$_tp" 2>/dev/null; then
    info "trial run: OK (config starts, no restart done)"
    kill "$_tp" 2>/dev/null
    wait "$_tp" 2>/dev/null
    rm -rf "$_td"
    return 0
  fi
  bad "trial run FAILED - live mihomo NOT touched"
  sed 's/^/    | /' "$_td/trial.log" 2>/dev/null | tail -5
  rm -rf "$_td"
  return 1
}

# restart mihomo and verify it really came back (pid + API). NO silent failures.
mihomo_restart_verified() {
  initd mihomo restart >/dev/null 2>&1
  sleep 3
  if ! svc_alive mihomo; then
    bad "mihomo did NOT come back after restart!"
    return 1
  fi
  if ! controller_curl -s -m3 "http://127.0.0.1:9090/version" 2>/dev/null | grep -qi 'mihomo\|meta'; then
    bad "mihomo API not responding after restart!"
    return 1
  fi
  info "mihomo restarted and verified (pid $(pidof mihomo))"
  return 0
}

# full safe mihomo restart: backup -> trial -> restart -> verify -> rollback on failure
safe_mihomo_restart() {
  _c="$(P $MIHOMO_CONF)"
  if [ "$GM_RESTART" != 1 ]; then
    warn "restart skipped (no --restart); will apply at next mihomo start"
    return 0
  fi
  _bk=$(ensure_backup) || { bad "no backup - restart ABORTED"; return 1; }
  info "backup: $_bk"
  cp -p "$_c" "$_c.pre-restart" 2>/dev/null || true
  if ! mihomo_trial_run; then
    bad "trial failed - live mihomo NOT restarted; config left for manual review"
    return 1
  fi
  if mihomo_restart_verified; then
    info "restart verified OK"
    return 0
  fi
  bad "restart FAILED - rolling back config and re-starting"
  if [ -s "$_c.pre-restart" ]; then
    cp -p "$_c.pre-restart" "$_c"
    /etc/init.d/mihomo restart >/dev/null 2>&1
    sleep 3
    if svc_alive mihomo; then
      info "rollback OK: previous config restored, mihomo running"
    else
      bad "rollback FAILED - RESTORE FROM BACKUP: $_bk"
    fi
  else
    bad "no pre-restart copy; RESTORE FROM BACKUP: $_bk"
  fi
  return 1
}

# ============================================================ STEP 4: AI-DNS - no DNS leak for AI devices
# Browsing of AI-mode devices goes through the AI tunnel, but their DNS used to be
# resolved by the router itself and left via the real ISP IP -> DNS leak: geo checkers
# see "page from <AI country>, DNS from <ISP country>" and flag VPN usage.
# This step puts DNS of AI-mode devices into the same AI tunnel:
#   device DNS (any dst, port 53)
#     --DNAT (nat priority -110; wins over ALL other DNS interception on this router)-->
#     192.168.0.53:53 (2nd dnsmasq) -> 127.0.0.1:5055 (2nd DoH worker as user dnsai)
#     --nft mark 0x64 (skuid)--> ip rule fwmark 0x64 table 101 -> dev AI (exit = AI node)
# Permanent opt-out: touch /etc/geomask-aidns.off  (step becomes a no-op)

AIDNS_IP=192.168.0.53
AIDNS_PORT=5055
AIDNS_DNS_PORT=5353
AIDNS_USER=dnsai
AIDNS_MARK=0x64
AIDNS_RULE_PREF=19902

aidns_user_exists() { grep -q "^$AIDNS_USER:" "$(P /etc/passwd)" 2>/dev/null; }

aidns_generate_nft() { # (re)write the nft include from the current ai device list
  _uid=$(cat "$(P /etc/geomask-aidns.uid)" 2>/dev/null)
  [ -n "$_uid" ] || _uid=$(awk -F: -v u="$AIDNS_USER" '$1==u{print $3}' "$(P /etc/passwd)" 2>/dev/null)
  [ -n "$_uid" ] || _uid=65533
  _ips=$(awk '$2=="ai" && $1 !~ /^#/ {print $1}' "$(P /etc/geo-devices.list)" 2>/dev/null)
  _list=""
  for _ip in $_ips; do _list="$_list $_ip,"; done
  _list=${_list%,}
  {
    printf '# geomask AI-DNS (auto-generated from /etc/geo-devices.list - do not edit)\n'
    printf '# DNS of AI-mode devices goes into the AI tunnel: no DNS leak, no geo mismatch.\n'
    printf '# idempotent include pattern (same as 20-https-dns-proxy-notrack.nft)\n'
    printf 'add table inet geomask_ai_dns\n'
    printf 'flush table inet geomask_ai_dns\n'
    printf 'add chain inet geomask_ai_dns pre_nat { type nat hook prerouting priority -110; policy accept; }\n'
    printf 'add chain inet geomask_ai_dns out_mark { type route hook output priority -150; policy accept; }\n'
    printf 'add rule inet geomask_ai_dns out_mark meta skuid %s mark set %s\n' "$_uid" "$AIDNS_MARK"
    if [ -n "$_list" ]; then
      printf 'add rule inet geomask_ai_dns pre_nat ip saddr { %s } meta l4proto { tcp, udp } th dport 53 dnat ip to %s:%s\n' "$_list" "$AIDNS_IP" "$AIDNS_DNS_PORT"
    fi
  } > /tmp/geomask-aidns.nft
  if nft -c -f /tmp/geomask-aidns.nft >/dev/null 2>&1; then
    save_stream /usr/share/nftables.d/ruleset-post/98-geomask-ai-dns.nft 644 < /tmp/geomask-aidns.nft
    rm -f /tmp/geomask-aidns.nft
    return 0
  fi
  rm -f /tmp/geomask-aidns.nft
  bad "generated AI-DNS nft rules failed syntax check"
  return 1
}

step4_check() {
  _need=0
  if [ -f "$(P /etc/geomask-aidns.off)" ]; then
    info "AI-DNS: disabled (/etc/geomask-aidns.off present)"
    return 0
  fi
  aidns_user_exists && info "user $AIDNS_USER: present" || { warn "user $AIDNS_USER: missing"; _need=1; }
  [ -x "$(P /usr/sbin/https-dns-proxy)" ] && info "https-dns-proxy: present" || { warn "https-dns-proxy: missing"; _need=1; }
  if have netstat; then
    netstat -ltnu 2>/dev/null | grep -q "127.0.0.1:$AIDNS_PORT " && info "AI DoH worker (:$AIDNS_PORT): listening" || { warn "AI DoH worker not listening on :$AIDNS_PORT"; _need=1; }
    netstat -ltnu 2>/dev/null | grep -q "$AIDNS_IP:$AIDNS_DNS_PORT " && info "AI dnsmasq ($AIDNS_IP:$AIDNS_DNS_PORT): listening" || { warn "AI dnsmasq not listening on $AIDNS_IP:$AIDNS_DNS_PORT"; _need=1; }
  else
    warn "netstat unavailable - listener checks skipped"
  fi
  _alias=$(ip -4 addr show br-lan 2>/dev/null)
  if [ -z "$_alias" ]; then
    warn "cannot read br-lan addresses (ip unavailable?)"
  elif printf '%s' "$_alias" | grep -q " $AIDNS_IP/"; then
    info "alias $AIDNS_IP on br-lan: present"
  else
    warn "alias $AIDNS_IP missing on br-lan"; _need=1
  fi
  ip rule show 2>/dev/null | grep -q "fwmark $AIDNS_MARK" && info "ip rule fwmark $AIDNS_MARK -> table 101: present" || { warn "ip rule fwmark $AIDNS_MARK -> 101 missing"; _need=1; }
  nft list table inet geomask_ai_dns >/dev/null 2>&1 && info "nft AI-DNS table: loaded" || { warn "nft AI-DNS table missing"; _need=1; }
  _aiips=$(awk '$2=="ai" && $1 !~ /^#/ {print $1}' "$(P /etc/geo-devices.list)" 2>/dev/null)
  if [ -z "$_aiips" ]; then
    info "ai-mode devices: none (nothing to DNAT)"
  else
    _tbl=$(nft list table inet geomask_ai_dns 2>/dev/null)
    if [ -z "$_tbl" ]; then
      warn "AI-DNS DNAT: cannot read rules (nft list empty)"
    else
      _miss=0
      for _ip in $_aiips; do
        printf '%s' "$_tbl" | grep -q "$_ip" || _miss=1
      done
      if [ "$_miss" = 0 ]; then info "AI-DNS DNAT: all ai devices covered"
      else warn "AI-DNS DNAT: some ai devices missing from rules"; _need=1; fi
    fi
  fi
  return $_need
}
step4_apply() {
  if [ -f "$(P /etc/geomask-aidns.off)" ]; then info "AI-DNS disabled by flag - nothing to do"; return 0; fi
  _bk=$(ensure_backup) || { bad "no backup - ABORTED"; return 1; }
  info "backup: $_bk"
  # 1) dedicated user for the AI DoH worker (sockets get marked by uid)
  if ! aidns_user_exists; then
    _uid=65533
    while awk -F: -v u="$_uid" '$3==u{found=1} END{exit found?0:1}' "$(P /etc/passwd)" 2>/dev/null; do _uid=$((_uid-1)); done
    printf '%s:x:%s:%s:geomask AI-DNS:/var/run/%s:/bin/false\n' "$AIDNS_USER" "$_uid" "$_uid" "$AIDNS_USER" >> "$(P /etc/passwd)"
    grep -q "^$AIDNS_USER:" "$(P /etc/group)" 2>/dev/null || printf '%s:x:%s:\n' "$AIDNS_USER" "$_uid" >> "$(P /etc/group)"
    save_stream /etc/geomask-aidns.uid 644 <<ASSET_EOF
$_uid
ASSET_EOF
    info "user $AIDNS_USER created (uid $_uid)"
  fi
  # 2) alias IP on br-lan for the AI dnsmasq
  if ! ip -4 addr show br-lan 2>/dev/null | grep -q " $AIDNS_IP/"; then
    if ! uci -q get network.lanai >/dev/null; then uci set network.lanai=interface; fi
    uci set network.lanai.proto='static'
    uci set network.lanai.device='br-lan'
    uci set network.lanai.ipaddr="$AIDNS_IP"
    uci set network.lanai.netmask='255.255.255.0'
    uci commit network
    /etc/init.d/network reload >/dev/null 2>&1 || warn "network reload rc!=0 - alias may need reboot"
    sleep 1
    ip -4 addr show br-lan | grep -q " $AIDNS_IP/" && info "alias $AIDNS_IP: up" || warn "alias $AIDNS_IP: NOT up"
  fi
  # 3) AI DoH worker (second https-dns-proxy instance, runs as dnsai)
  save_stream /etc/init.d/ai-doh 755 <<'ASSET_EOF'
#!/bin/sh /etc/rc.common
# geomask: DNS-over-HTTPS worker for AI-mode devices (marked -> AI tunnel)
START=21
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command /usr/sbin/https-dns-proxy -a 127.0.0.1 -p 5055 -r https://cloudflare-dns.com/dns-query -u dnsai -g dnsai
  procd_set_param respawn
  procd_close_instance
}
ASSET_EOF
  # 4) AI dnsmasq (upstream = the AI DoH worker; RU-domain resolvers copied from main dnsmasq)
  {
    printf 'listen-address=%s\n' "$AIDNS_IP"
    printf 'bind-interfaces\n'
    printf 'port=%s\n' "$AIDNS_DNS_PORT"
    printf 'no-resolv\n'
    printf 'no-poll\n'
    printf 'cache-size=1000\n'
    printf 'domain-needed\n'
    printf 'bogus-priv\n'
    printf 'server=127.0.0.1#%s\n' "$AIDNS_PORT"
    _s=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)
    for _e in $_s; do case "$_e" in /*) printf 'server=%s\n' "$_e" ;; esac; done
  } > "$(P /etc/dnsmasq-ai.conf)"
  save_stream /etc/init.d/dnsmasq-ai 755 <<'ASSET_EOF'
#!/bin/sh /etc/rc.common
# geomask: dnsmasq for AI-mode devices (upstream = AI DoH worker in the AI tunnel)
START=61
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command /usr/sbin/dnsmasq -C /etc/dnsmasq-ai.conf -k
  procd_set_param respawn
  procd_close_instance
}
ASSET_EOF
  # 5) nft rules (DNAT for ai devices + mark for dnsai sockets)
  aidns_generate_nft || return 1
  # 6) ip rule: marked DNS sockets go through the AI tunnel
  ip rule show 2>/dev/null | grep -q "fwmark $AIDNS_MARK" || ip rule add pref "$AIDNS_RULE_PREF" fwmark "$AIDNS_MARK" table 101
  # 7) services on + reload firewall to apply nft file
  initd ai-doh enable >/dev/null 2>&1 || true
  initd dnsmasq-ai enable >/dev/null 2>&1 || true
  initd ai-doh restart >/dev/null 2>&1 || warn "ai-doh did not start"
  initd dnsmasq-ai restart >/dev/null 2>&1 || warn "dnsmasq-ai did not start"
  /etc/init.d/firewall reload >/dev/null 2>&1 || warn "firewall reload failed"
  sleep 1
  return 0
}
step4_verify() { step4_check; }

# ============================================================ STEP 5: magitrickle -> mihomo sync
# v1.13.0: write the bundled lists template + seeder to the router (idempotent; asset injected once).
write_lists_assets() {
  mkdir -p "$(P /etc/geomask/lists)" 2>/dev/null || true
  save_stream /etc/geomask/lists/magitrickle-groups.yaml 644 <<'ASSET_EOF'
# geomask MagiTrickle groups template (recovery snapshot).
# Source of truth for domain lists: To VPN / To Not VPN / Google+AI to DE /
# Geoblock / Block / Youtube / CDN+social groups, etc. No secrets here.
# Restore: geomask.sh --seed-lists  (or panel card). See docs/LISTS.md.
groups:
- id: 22cf88fd
  name: To VPN
  color: '#3e738a'
  interface: Mihomo
  enable: true
  rules:
  - id: f9ed4e6e
    name: ""
    type: namespace
    rule: ipleak.net
    enable: true
  - id: de368371
    name: ""
    type: namespace
    rule: frcapi.com
    enable: true
  - id: 7aecb530
    name: ""
    type: namespace
    rule: cdn77.org
    enable: true
  - id: bb582e2f
    name: ""
    type: namespace
    rule: myip.ru
    enable: true
  - id: 9f9e0157
    name: ""
    type: namespace
    rule: 2ip.io
    enable: true
  - id: 8daa42c5
    name: ""
    type: namespace
    rule: androidayuda.com
    enable: true
  - id: a07e88e9
    name: ""
    type: namespace
    rule: context7.com
    enable: true
  - id: cb17bf22
    name: ""
    type: subnet
    rule: 98.91.39.95
    enable: true
  - id: "47294e11"
    name: ""
    type: namespace
    rule: daluobo.cc.cd
    enable: true
  - id: 22d5693e
    name: ""
    type: namespace
    rule: friendlycaptcha.com
    enable: true
  - id: 088a70a0
    name: ""
    type: namespace
    rule: pinterest.com
    enable: true
  - id: 7a117352
    name: ""
    type: namespace
    rule: afi-b.com
    enable: true
  - id: a4fe23e1
    name: ""
    type: namespace
    rule: skool.com
    enable: true
  - id: 17d97b75
    name: ""
    type: namespace
    rule: tripo3d.com
    enable: true
  - id: cdec40ff
    name: ""
    type: namespace
    rule: tripo3d.ai
    enable: true
  - id: bc4cdb06
    name: ""
    type: namespace
    rule: flashforge.com
    enable: true
  - id: 946686f4
    name: ""
    type: namespace
    rule: voxelshare.com
    enable: true
  - id: d2b1c9bd
    name: ""
    type: namespace
    rule: payermax.com
    enable: true
  - id: "66438416"
    name: ""
    type: namespace
    rule: waffo.com
    enable: true
  - id: b1772b3b
    name: ""
    type: regex
    rule: coinbase
    enable: true
  - id: ea69906b
    name: ""
    type: namespace
    rule: coinbase.com
    enable: true
  - id: 9fd48bdb
    name: ""
    type: namespace
    rule: ggsel.com
    enable: false
  - id: 0479f6a4
    name: ""
    type: regex
    rule: opencode
    enable: true
  - id: d02135a3
    name: ""
    type: namespace
    rule: topazlabs.com
    enable: true
  - id: 59d48483
    name: ""
    type: namespace
    rule: api.topazlabs.com
    enable: true
  - id: a60fbcbc
    name: ""
    type: namespace
    rule: platform.xiaomimimo.com
    enable: true
  - id: d9c46ad2
    name: ""
    type: namespace
    rule: xiaomimimo.com
    enable: true
  - id: 6085bee7
    name: ""
    type: namespace
    rule: xiaomi.com
    enable: true
  - id: dae84152
    name: intrdb video CDN
    type: namespace
    rule: intrdb.com
    enable: true
  - id: 9815fbf5
    name: turkserial failback CDN
    type: namespace
    rule: turkserial.co
    enable: true
  - id: 8809d769
    name: ""
    type: namespace
    rule: xiaoji.com
    enable: true
  - id: 844f429d
    name: ""
    type: namespace
    rule: youwo.com
    enable: true
  - id: "95333205"
    name: ""
    type: namespace
    rule: vgabc.com
    enable: true
  - id: 8adcb093
    name: ""
    type: namespace
    rule: bigeyes.com
    enable: true
  - id: 8f76e2ca
    name: ""
    type: namespace
    rule: masnet.cn
    enable: true
  - id: 6def1391
    name: ""
    type: namespace
    rule: mx520.com
    enable: true
  - id: 826694f0
    name: ""
    type: namespace
    rule: mac520.com
    enable: true
  - id: 559bdcd4
    name: ""
    type: namespace
    rule: dutils.com
    enable: true
  - id: e1bd0b06
    name: ""
    type: namespace
    rule: zztfly.com
    enable: true
  - id: 1cc6f80d
    name: ""
    type: namespace
    rule: gog-statics.com
    enable: true
  - id: bff2ea15
    name: gh-zztfly-5099
    type: subnet
    rule: 114.117.130.195
    enable: true
  - id: 7fc1fa99
    name: ""
    type: namespace
    rule: tinyhost.shop
    enable: true
- id: 45228c2d
  name: To Not VPN
  color: '#a72450'
  interface: pppoe-wan
  enable: true
  rules:
  - id: 8d4ea28d
    name: ""
    type: namespace
    rule: tinkoff.ru
    enable: true
  - id: db0f2c2d
    name: ""
    type: namespace
    rule: tbank.ru
    enable: true
  - id: 3e09bd86
    name: ""
    type: namespace
    rule: registry.npmmirror.com
    enable: true
  - id: e47c7f49
    name: ""
    type: namespace
    rule: registry.npmjs.org
    enable: true
  - id: cd92d963
    name: ""
    type: namespace
    rule: ggsel.com
    enable: true
  - id: 292c311f
    name: ""
    type: namespace
    rule: sberbank.ru
    enable: true
  - id: 38503cdd
    name: ""
    type: namespace
    rule: sber.ru
    enable: true
  - id: 91ef97df
    name: ""
    type: namespace
    rule: spasibosberbank.ru
    enable: true
  - id: 80b3ddeb
    name: ""
    type: namespace
    rule: alfabank.ru
    enable: true
  - id: b91b5e46
    name: ""
    type: namespace
    rule: vtb.ru
    enable: true
  - id: 0a5c25f6
    name: ""
    type: namespace
    rule: vtb24.ru
    enable: true
  - id: dcfb4175
    name: ""
    type: namespace
    rule: open.ru
    enable: true
  - id: e441afd5
    name: ""
    type: namespace
    rule: gazprombank.ru
    enable: true
  - id: d961fd92
    name: ""
    type: namespace
    rule: gpb.ru
    enable: true
  - id: d61080ad
    name: ""
    type: namespace
    rule: psb.ru
    enable: true
  - id: 37a833d6
    name: ""
    type: namespace
    rule: sovcombank.ru
    enable: true
  - id: 8abcc792
    name: ""
    type: namespace
    rule: mtsbank.ru
    enable: true
  - id: b616f748
    name: ""
    type: namespace
    rule: rshb.ru
    enable: true
  - id: e92d489d
    name: ""
    type: namespace
    rule: dom.rf
    enable: true
  - id: 7da565c2
    name: ""
    type: namespace
    rule: uralsib.ru
    enable: true
  - id: 4cc5fb3f
    name: ""
    type: namespace
    rule: rencredit.ru
    enable: true
  - id: 0996a785
    name: ""
    type: namespace
    rule: akbars.ru
    enable: true
  - id: 0ca4e9b0
    name: ""
    type: namespace
    rule: absolutbank.ru
    enable: true
  - id: d03ea5b7
    name: ""
    type: namespace
    rule: raiffeisen.ru
    enable: true
  - id: ebe7cec2
    name: ""
    type: namespace
    rule: credit-europe.ru
    enable: true
  - id: 7c81ccb0
    name: ""
    type: namespace
    rule: pochtabank.ru
    enable: true
  - id: 8256ed24
    name: ""
    type: namespace
    rule: nspk.ru
    enable: true
  - id: aca3f21b
    name: ""
    type: namespace
    rule: mir.ru
    enable: true
  - id: 2d7422fd
    name: ""
    type: namespace
    rule: yoomoney.ru
    enable: true
  - id: 05fb3b09
    name: ""
    type: namespace
    rule: qiwi.com
    enable: true
  - id: d35436cd
    name: ""
    type: namespace
    rule: robokassa.ru
    enable: true
  - id: 558163b9
    name: ""
    type: namespace
    rule: plat.ru
    enable: true
  - id: 1b812025
    name: ""
    type: namespace
    rule: paymaster.ru
    enable: true
  - id: 932e18d5
    name: ""
    type: namespace
    rule: cloudpayments.com
    enable: true
  - id: ab8fa7f7
    name: ""
    type: namespace
    rule: ozon.ru
    enable: true
  - id: 948becc9
    name: ""
    type: namespace
    rule: ozone.ru
    enable: true
  - id: "7165e147"
    name: ""
    type: namespace
    rule: ozon.travel
    enable: true
  - id: de6003de
    name: ""
    type: namespace
    rule: wildberries.ru
    enable: true
  - id: 46c30fe3
    name: ""
    type: namespace
    rule: wb.ru
    enable: true
  - id: 240fd0ae
    name: ""
    type: namespace
    rule: wbbasket.ru
    enable: true
  - id: fdcbba20
    name: ""
    type: namespace
    rule: yandex.ru
    enable: true
  - id: 964c77bc
    name: ""
    type: namespace
    rule: yandex.net
    enable: true
  - id: 8f550b52
    name: ""
    type: namespace
    rule: bask.ru
    enable: true
  - id: 0cada529
    name: ""
    type: namespace
    rule: megamarket.ru
    enable: true
  - id: 28fa5bf5
    name: ""
    type: namespace
    rule: kuper.ru
    enable: true
  - id: 55e08ca0
    name: ""
    type: namespace
    rule: sbermarket.ru
    enable: true
  - id: 448e0dfa
    name: ""
    type: namespace
    rule: aliexpress.ru
    enable: true
  - id: de4fb761
    name: ""
    type: namespace
    rule: lamoda.ru
    enable: true
  - id: 9f16c171
    name: ""
    type: namespace
    rule: citilink.ru
    enable: true
  - id: 65f22d26
    name: ""
    type: namespace
    rule: dns-shop.ru
    enable: true
  - id: 92f8da5e
    name: ""
    type: namespace
    rule: mvideo.ru
    enable: true
  - id: b5c2acfc
    name: ""
    type: namespace
    rule: goldapple.ru
    enable: true
  - id: 6bfdd2e6
    name: ""
    type: namespace
    rule: letual.ru
    enable: true
  - id: 8394660e
    name: ""
    type: namespace
    rule: rivegauche.ru
    enable: true
  - id: 0091aedf
    name: ""
    type: namespace
    rule: sportmaster.ru
    enable: true
  - id: b181fd8b
    name: ""
    type: namespace
    rule: detmir.ru
    enable: true
  - id: 53ec566e
    name: ""
    type: namespace
    rule: avito.ru
    enable: true
  - id: e0982db7
    name: ""
    type: namespace
    rule: auto.ru
    enable: true
  - id: ecc7666d
    name: ""
    type: namespace
    rule: drom.ru
    enable: true
  - id: 9bd87da4
    name: ""
    type: namespace
    rule: youla.ru
    enable: true
  - id: 7c102d3f
    name: ""
    type: namespace
    rule: utkonos.ru
    enable: true
  - id: 289a06d8
    name: ""
    type: namespace
    rule: vprok.ru
    enable: true
  - id: 18364a79
    name: ""
    type: namespace
    rule: samokat.tech
    enable: true
  - id: 0be4e2ab
    name: ""
    type: namespace
    rule: samokat.org
    enable: true
  - id: c6db9167
    name: ""
    type: namespace
    rule: 5ka.ru
    enable: true
  - id: 8d90c891
    name: ""
    type: namespace
    rule: lenta.com
    enable: true
  - id: d0703250
    name: ""
    type: namespace
    rule: magnit.ru
    enable: true
  - id: de4358f0
    name: ""
    type: namespace
    rule: ostrovok.ru
    enable: true
  - id: 6b2401db
    name: ""
    type: namespace
    rule: litres.ru
    enable: true
  - id: 05d3808c
    name: ""
    type: namespace
    rule: qwencloud.com
    enable: true
  - id: fe8e435f
    name: ""
    type: namespace
    rule: qwencloudapi.com
    enable: true
  - id: 0391daed
    name: ""
    type: namespace
    rule: deepseek.com
    enable: true
- id: "01828314"
  name: Google+AI to DE
  color: '#2b8a3e'
  interface: Mihomo
  enable: true
  rules:
  - id: 6ed54722
    name: ""
    type: namespace
    rule: plati.market
    enable: false
  - id: 4570170b
    name: ""
    type: namespace
    rule: myip.com
    enable: true
  - id: a57b2bf5
    name: ""
    type: namespace
    rule: claudeusercontent.com
    enable: true
  - id: 6cb021b1
    name: ""
    type: namespace
    rule: didit.me
    enable: true
  - id: 39c4593e
    name: ""
    type: regex
    rule: Wanttopay
    enable: true
  - id: 7d7ed4ea
    name: ""
    type: namespace
    rule: wanttopay.net
    enable: true
  - id: 0e5ce512
    name: ""
    type: namespace
    rule: whatismyipaddress.com
    enable: true
  - id: 283de0f9
    name: ""
    type: namespace
    rule: ngc.nvidia.com
    enable: true
  - id: a7a4eea3
    name: ""
    type: namespace
    rule: docs.nvidia.com
    enable: true
  - id: 308aac2e
    name: ""
    type: namespace
    rule: catalog.ngc.nvidia.com
    enable: true
  - id: 6ef3842d
    name: ""
    type: namespace
    rule: build.nvidia.com
    enable: true
  - id: 2facda6d
    name: ""
    type: namespace
    rule: install.launcher.omniverse.nvidia.com
    enable: true
  - id: a05c4423
    name: ""
    type: namespace
    rule: api.nvidia.com
    enable: true
  - id: c0033664
    name: ""
    type: namespace
    rule: developer.nvidia.com
    enable: true
  - id: eb9b7734
    name: ""
    type: namespace
    rule: whatismyip.com
    enable: true
  - id: e06c65c4
    name: ""
    type: namespace
    rule: ipleak.net
    enable: false
  - id: e1358f75
    name: ""
    type: namespace
    rule: browser-intake-datadoghq.com
    enable: true
  - id: 87e8ecaa
    name: ""
    type: namespace
    rule: suno.com
    enable: true
  - id: bb4f3493
    name: ""
    type: namespace
    rule: suno.ai
    enable: true
  - id: e8ef4897
    name: ""
    type: namespace
    rule: accounts.google.com
    enable: true
  - id: f2ea8f1d
    name: ""
    type: namespace
    rule: admin.google.com
    enable: true
  - id: db23c7a2
    name: ""
    type: domain
    rule: ai.google.dev
    enable: true
  - id: 6658a94e
    name: ""
    type: domain
    rule: aida.googleapis.com
    enable: true
  - id: 99fca637
    name: ""
    type: domain
    rule: aisandbox-pa.googleapis.com
    enable: true
  - id: 6d14b119
    name: ""
    type: domain
    rule: aistudio.google.com
    enable: true
  - id: 63d84cf9
    name: ""
    type: domain
    rule: android.clients.google.com
    enable: true
  - id: 660738f2
    name: ""
    type: domain
    rule: antigravity-pa.googleapis.com
    enable: true
  - id: 21bd9144
    name: ""
    type: namespace
    rule: antigravity.google
    enable: true
  - id: 8254f164
    name: ""
    type: domain
    rule: antigravity.googleapis.com
    enable: true
  - id: caa47aa1
    name: ""
    type: namespace
    rule: apis.google.com
    enable: true
  - id: e34742d3
    name: ""
    type: domain
    rule: bard.google.com
    enable: true
  - id: 65fa1585
    name: ""
    type: namespace
    rule: calendar.google.com
    enable: true
  - id: 955982b8
    name: ""
    type: namespace
    rule: chat.google.com
    enable: true
  - id: f8e2c0f3
    name: ""
    type: domain
    rule: clients6.google.com
    enable: true
  - id: "68798700"
    name: ""
    type: namespace
    rule: contacts.google.com
    enable: true
  - id: 80b6320c
    name: ""
    type: namespace
    rule: deepmind.google
    enable: true
  - id: cf1f5a2b
    name: ""
    type: namespace
    rule: docs.google.com
    enable: true
  - id: bcf98d42
    name: ""
    type: namespace
    rule: drive.google.com
    enable: true
  - id: 193ceee4
    name: ""
    type: namespace
    rule: earth.google.com
    enable: true
  - id: bdefdb62
    name: ""
    type: namespace
    rule: firebase.googleapis.com
    enable: true
  - id: 0ab35812
    name: ""
    type: domain
    rule: firebaseinstallations.googleapis.com
    enable: true
  - id: 1d6cf596
    name: ""
    type: namespace
    rule: firebaseremoteconfig.googleapis.com
    enable: true
  - id: 788370fd
    name: ""
    type: namespace
    rule: fonts.googleapis.com
    enable: true
  - id: 6609ead6
    name: ""
    type: namespace
    rule: fonts.gstatic.com
    enable: true
  - id: 97905d20
    name: ""
    type: domain
    rule: geller-pa.googleapis.com
    enable: true
  - id: 36929e1a
    name: ""
    type: namespace
    rule: gemini.google
    enable: true
  - id: 295487d9
    name: ""
    type: domain
    rule: gemini.google.com
    enable: true
  - id: 87139cbd
    name: ""
    type: namespace
    rule: generativeai.google
    enable: true
  - id: acf7910a
    name: ""
    type: domain
    rule: generativelanguage.googleapis.com
    enable: true
  - id: e405149c
    name: ""
    type: namespace
    rule: google-analytics.com
    enable: true
  - id: 397a0952
    name: ""
    type: namespace
    rule: google.com
    enable: true
  - id: a34cd9b7
    name: ""
    type: namespace
    rule: google.de
    enable: true
  - id: 889b2726
    name: ""
    type: namespace
    rule: google.ru
    enable: true
  - id: 8144cc75
    name: ""
    type: namespace
    rule: googleadservices.com
    enable: true
  - id: 4d13f88e
    name: ""
    type: namespace
    rule: googleapis.com
    enable: true
  - id: 74a80404
    name: ""
    type: namespace
    rule: googleplay.com
    enable: true
  - id: 6edf6808
    name: ""
    type: namespace
    rule: googlesyndication.com
    enable: true
  - id: 6cb84b7d
    name: ""
    type: namespace
    rule: googletagmanager.com
    enable: true
  - id: 3f7411e5
    name: ""
    type: namespace
    rule: googletagservices.com
    enable: true
  - id: 9ee21330
    name: ""
    type: namespace
    rule: googleusercontent.com
    enable: true
  - id: d66148c7
    name: ""
    type: namespace
    rule: gstatic.com
    enable: true
  - id: 7cb9292a
    name: ""
    type: namespace
    rule: gvt2.com
    enable: true
  - id: 8445733b
    name: ""
    type: namespace
    rule: hangouts.google.com
    enable: true
  - id: 00c3e4c8
    name: ""
    type: domain
    rule: hangouts.googleapis.com
    enable: true
  - id: ca147ef6
    name: ""
    type: namespace
    rule: jnn-pa.googleapis.com
    enable: true
  - id: 53f1b1ef
    name: ""
    type: namespace
    rule: jules.google
    enable: true
  - id: fae453e5
    name: ""
    type: domain
    rule: jules.google.com
    enable: true
  - id: 1d5c148c
    name: ""
    type: namespace
    rule: keep.google.com
    enable: true
  - id: 1c85ce94
    name: ""
    type: namespace
    rule: labs.google
    enable: true
  - id: 27b913e7
    name: ""
    type: domain
    rule: lh3.googleusercontent.com
    enable: true
  - id: 250415ff
    name: ""
    type: namespace
    rule: lookerstudio.google.com
    enable: true
  - id: f6380170
    name: ""
    type: namespace
    rule: mail.google.com
    enable: true
  - id: f626cc6b
    name: ""
    type: domain
    rule: makersuite.google.com
    enable: true
  - id: 5f8069c9
    name: ""
    type: domain
    rule: meet.google.com
    enable: true
  - id: b7bd9b57
    name: ""
    type: domain
    rule: meetings.clients6.google.com
    enable: true
  - id: 8905bfaf
    name: ""
    type: domain
    rule: meetings.googleapis.com
    enable: true
  - id: 7e975b49
    name: ""
    type: namespace
    rule: mtalk.google.com
    enable: true
  - id: 6191ea90
    name: ""
    type: namespace
    rule: myaccount.google.com
    enable: true
  - id: 24e5064b
    name: ""
    type: namespace
    rule: news.google.com
    enable: true
  - id: ef1c73af
    name: ""
    type: namespace
    rule: notebooklm.google
    enable: true
  - id: bfab92ae
    name: ""
    type: domain
    rule: notebooklm.google.com
    enable: true
  - id: 9365763d
    name: ""
    type: namespace
    rule: oauth2.googleapis.com
    enable: true
  - id: d3d7b6d4
    name: ""
    type: namespace
    rule: one.google.com
    enable: true
  - id: f6c533db
    name: ""
    type: namespace
    rule: pay.google.com
    enable: true
  - id: 3ecc608d
    name: ""
    type: namespace
    rule: photos.google.com
    enable: true
  - id: 0692386b
    name: ""
    type: domain
    rule: play-fe.googleapis.com
    enable: true
  - id: c5f90b82
    name: ""
    type: domain
    rule: play-games.googleusercontent.com
    enable: true
  - id: 25b3386e
    name: ""
    type: domain
    rule: play-lh.googleusercontent.com
    enable: true
  - id: 7f777c27
    name: ""
    type: domain
    rule: play.google.com
    enable: true
  - id: 2778f3dd
    name: ""
    type: domain
    rule: play.googleapis.com
    enable: true
  - id: d3b3b905
    name: ""
    type: domain
    rule: proactivebackend-pa.googleapis.com
    enable: true
  - id: 7449aa76
    name: ""
    type: domain
    rule: prod-lt-playstoregatewayadapter-pa.googleapis.com
    enable: true
  - id: "669883e9"
    name: ""
    type: domain
    rule: robinfrontend-pa.googleapis.com
    enable: true
  - id: 19b03dd4
    name: ""
    type: namespace
    rule: securetoken.googleapis.com
    enable: true
  - id: e907d21a
    name: ""
    type: namespace
    rule: sheets.google.com
    enable: true
  - id: 9d3699ab
    name: ""
    type: namespace
    rule: slides.google.com
    enable: true
  - id: 50779ba1
    name: ""
    type: domain
    rule: speechs3proto2-pa.googleapis.com
    enable: true
  - id: b6a6e0b1
    name: ""
    type: domain
    rule: stitch.withgoogle.com
    enable: true
  - id: 657819f7
    name: ""
    type: namespace
    rule: storage.cloud.google.com
    enable: true
  - id: ff5707ea
    name: ""
    type: namespace
    rule: storage.googleapis.com
    enable: true
  - id: b2599790
    name: ""
    type: domain
    rule: stream.meet.google.com
    enable: true
  - id: e442f27d
    name: ""
    type: namespace
    rule: suggestqueries.google.com
    enable: true
  - id: 3acbb96e
    name: ""
    type: namespace
    rule: voice.google.com
    enable: true
  - id: e4c09e80
    name: ""
    type: domain
    rule: cursor
    enable: true
  - id: af9bd339
    name: ""
    type: namespace
    rule: cursor.com
    enable: true
  - id: 394058b4
    name: ""
    type: namespace
    rule: cursor.sh
    enable: true
  - id: 4306c777
    name: ""
    type: namespace
    rule: cursorapi.com
    enable: true
  - id: 7996de88
    name: ""
    type: namespace
    rule: cursor-cdn.com
    enable: true
  - id: 9565a24f
    name: ""
    type: namespace
    rule: antigravity-unleash.goog
    enable: true
  - id: 011a964c
    name: ""
    type: namespace
    rule: deepmind.com
    enable: true
  - id: 4568f436
    name: ""
    type: subnet
    rule: 142.250.82.0/24
    enable: true
  - id: 66e9276a
    name: ""
    type: subnet6
    rule: 2001:4860:4864:4:8000::/128
    enable: true
  - id: b917b657
    name: ""
    type: subnet6
    rule: 2001:4860:4864:5::/64
    enable: true
  - id: e6d282dd
    name: ""
    type: subnet6
    rule: 2001:4860:4864:6::/64
    enable: true
  - id: ab1288a6
    name: ""
    type: subnet
    rule: 74.125.247.128/32
    enable: true
  - id: 561a44fa
    name: ""
    type: subnet
    rule: 74.125.250.0/24
    enable: true
  - id: 39458eeb
    name: ""
    type: domain
    rule: beacons.gvt2.com
    enable: true
  - id: d03f6ad7
    name: ""
    type: domain
    rule: connectivitycheck.gstatic.com
    enable: true
  - id: 5fe37ca4
    name: ""
    type: namespace
    rule: gvt1.com
    enable: true
  - id: 6447d604
    name: ""
    type: namespace
    rule: anthropic.com
    enable: true
  - id: 2ce89cf7
    name: ""
    type: namespace
    rule: chatgpt.com
    enable: true
  - id: a0d4bce4
    name: ""
    type: namespace
    rule: claude.ai
    enable: true
  - id: "38561e94"
    name: ""
    type: namespace
    rule: claude.com
    enable: true
  - id: cb1e4dc6
    name: ""
    type: domain
    rule: lookerstudio.google.com
    enable: true
  - id: f082d0ef
    name: ""
    type: domain
    rule: news.google.com
    enable: true
  - id: 6362ec89
    name: ""
    type: namespace
    rule: oaistatic.com
    enable: true
  - id: 2b854003
    name: ""
    type: namespace
    rule: oaiusercontent.com
    enable: true
  - id: b6a8ce13
    name: ""
    type: namespace
    rule: openai.com
    enable: true
  - id: 1d9b369d
    name: ""
    type: namespace
    rule: sora.com
    enable: true
  - id: 614cbc0c
    name: ""
    type: domain
    rule: suggestqueries.google.com
    enable: true
  - id: 33d879c9
    name: ""
    type: namespace
    rule: statsig.com
    enable: true
  - id: 5bad7a87
    name: ""
    type: namespace
    rule: statsigapi.net
    enable: true
  - id: 0a152f3c
    name: ""
    type: namespace
    rule: gvt3.com
    enable: true
  - id: 2d2e7df4
    name: ""
    type: namespace
    rule: accountsettingsmobile-pa.googleapis.com
    enable: true
  - id: 7faf7542
    name: ""
    type: namespace
    rule: beacons.gcp.gvt2.com
    enable: true
  - id: 69de9929
    name: ""
    type: namespace
    rule: beacons2.gvt2.com
    enable: true
  - id: 2947ba97
    name: ""
    type: namespace
    rule: beacons3.gvt2.com
    enable: true
  - id: b79a00d5
    name: ""
    type: namespace
    rule: beacons4.gvt2.com
    enable: true
  - id: 7fe9c23a
    name: ""
    type: namespace
    rule: beacons5.gvt2.com
    enable: true
  - id: 8ddd1ae7
    name: ""
    type: namespace
    rule: beacons5.gvt3.com
    enable: true
  - id: 1f1d2b29
    name: ""
    type: namespace
    rule: clients2.google.com
    enable: true
  - id: 06da6d9e
    name: ""
    type: namespace
    rule: clients4.google.com
    enable: true
  - id: 05d90be0
    name: ""
    type: namespace
    rule: developer.android.com
    enable: true
  - id: 490b540b
    name: ""
    type: namespace
    rule: inbox.google.com
    enable: true
  - id: eecf0bdf
    name: ""
    type: namespace
    rule: lh3.google.com
    enable: true
  - id: 76955d47
    name: ""
    type: namespace
    rule: mail-attachment.googleusercontent.com
    enable: true
  - id: 1935cc9f
    name: ""
    type: namespace
    rule: myactivity.google.com
    enable: true
  - id: d7a4b3b8
    name: ""
    type: namespace
    rule: notifications-pa.googleapis.com
    enable: true
  - id: 0fefd578
    name: ""
    type: namespace
    rule: ogads-pa.clients6.google.com
    enable: true
  - id: "28900186"
    name: ""
    type: namespace
    rule: optimizationguide-pa.googleapis.com
    enable: true
  - id: 2cb5c6ff
    name: ""
    type: namespace
    rule: peoplestack-pa.googleapis.com
    enable: true
  - id: 752f3b1e
    name: ""
    type: namespace
    rule: safebrowsing.google.com
    enable: true
  - id: b7b53c4f
    name: ""
    type: namespace
    rule: ssl.gstatic.com
    enable: true
  - id: 0ed91278
    name: ""
    type: namespace
    rule: takeout.google.com
    enable: true
  - id: 21c2068c
    name: ""
    type: namespace
    rule: www.google-analytics.com
    enable: true
  - id: 52354cd0
    name: ""
    type: namespace
    rule: www.gstatic.com
    enable: true
  - id: 500794ad
    name: ""
    type: namespace
    rule: android.com
    enable: true
  - id: a2e9b3a3
    name: ""
    type: namespace
    rule: oaistatsig.com
    enable: true
  - id: 9111f999
    name: ""
    type: namespace
    rule: auth0.com
    enable: true
  - id: f8819ccc
    name: ""
    type: namespace
    rule: revenuecat.com
    enable: true
  - id: f44e9055
    name: ""
    type: namespace
    rule: cloudflare-dns.com
    enable: true
  - id: 244a8e8a
    name: ""
    type: namespace
    rule: plati.io
    enable: true
  - id: 5d421000
    name: ""
    type: namespace
    rule: plati.market
    enable: true
  - id: 3a0fab5e
    name: ""
    type: namespace
    rule: platimapayments.com
    enable: true
  - id: dc26ad90
    name: ""
    type: namespace
    rule: digiseller.ru
    enable: true
  - id: 60872bdf
    name: ""
    type: namespace
    rule: digiseller.com
    enable: true
  - id: 581d2877
    name: ""
    type: namespace
    rule: openrouter.ai
    enable: true
  - id: 80e43f8e
    name: ""
    type: namespace
    rule: x.ai
    enable: true
  - id: 60616a1d
    name: ""
    type: namespace
    rule: groq.com
    enable: true
  - id: f1538a11
    name: ""
    type: namespace
    rule: auth0.com
    enable: true
  - id: 584917b1
    name: ""
    type: namespace
    rule: gpt3-openai.com
    enable: true
  - id: 67dcb040
    name: chatgpt-app-ms
    type: domain
    rule: d.docs.live.net
    enable: true
  - id: b7d236c7
    name: chatgpt-app-ms
    type: domain
    rule: mobile.events.data.microsoft.com
    enable: true
  - id: 44fe918a
    name: ""
    type: namespace
    rule: adobe.io
    enable: true
  - id: bda6caa7
    name: ""
    type: namespace
    rule: affinity.studio
    enable: true
  - id: f69bf5b6
    name: ""
    type: namespace
    rule: camelai.com
    enable: true
  - id: 629f737c
    name: ""
    type: namespace
    rule: cerebras.ai
    enable: true
  - id: 7ae446fd
    name: ""
    type: namespace
    rule: chatgpt.site
    enable: true
  - id: b4b05615
    name: ""
    type: namespace
    rule: cici.com
    enable: true
  - id: bd8d85fc
    name: ""
    type: namespace
    rule: claudemcpclient.com
    enable: true
  - id: f25e5c6a
    name: ""
    type: namespace
    rule: codeium.com
    enable: true
  - id: b361cc1d
    name: ""
    type: namespace
    rule: codeiumdata.com
    enable: true
  - id: 4d468af5
    name: ""
    type: namespace
    rule: copilot.microsoft.com
    enable: true
  - id: 9da728e3
    name: ""
    type: namespace
    rule: cursorvm.com
    enable: true
  - id: a730f2c7
    name: ""
    type: namespace
    rule: deepl.app
    enable: true
  - id: c1a0edb4
    name: ""
    type: namespace
    rule: deepl.com
    enable: true
  - id: 607bc5d5
    name: ""
    type: namespace
    rule: designer.microsoft.com
    enable: true
  - id: 783d5c37
    name: ""
    type: namespace
    rule: dola.com
    enable: true
  - id: eb736fb8
    name: ""
    type: namespace
    rule: elevenlabs.io
    enable: true
  - id: ac069b03
    name: ""
    type: namespace
    rule: elevenmusic.io
    enable: true
  - id: 945828dc
    name: ""
    type: namespace
    rule: elevenreader.io
    enable: true
  - id: 03a4a85c
    name: ""
    type: namespace
    rule: flow.google
    enable: true
  - id: 5fd12a29
    name: ""
    type: namespace
    rule: genspark.ai
    enable: true
  - id: fec6289e
    name: ""
    type: namespace
    rule: grok.com
    enable: true
  - id: da23872c
    name: ""
    type: namespace
    rule: hume.ai
    enable: true
  - id: 908bad9b
    name: ""
    type: namespace
    rule: kaleido.ai
    enable: true
  - id: e1963943
    name: ""
    type: namespace
    rule: manus.im
    enable: true
  - id: 87c8f972
    name: ""
    type: namespace
    rule: manuscdn.com
    enable: true
  - id: ec987954
    name: ""
    type: namespace
    rule: mchost.guru
    enable: true
  - id: 288df689
    name: ""
    type: namespace
    rule: meta.ai
    enable: true
  - id: 79d4e2a1
    name: ""
    type: namespace
    rule: monica.im
    enable: true
  - id: 86a38b1a
    name: ""
    type: namespace
    rule: notebook.google
    enable: true
  - id: fbfdc146
    name: ""
    type: namespace
    rule: opal.google
    enable: true
  - id: 705d772a
    name: ""
    type: namespace
    rule: opencode.ai
    enable: true
  - id: "976790e4"
    name: ""
    type: namespace
    rule: playground.google
    enable: true
  - id: beb65251
    name: ""
    type: namespace
    rule: ecosia.org
    enable: true
  - id: 85a2b9bb
    name: ""
    type: namespace
    rule: featureassets.org
    enable: true
  - id: 50d43277
    name: ""
    type: namespace
    rule: googleapis.com
    enable: true
  - id: 138ed6f7
    name: ""
    type: namespace
    rule: reve.art
    enable: true
  - id: 30d02f8f
    name: ""
    type: namespace
    rule: reve.com
    enable: true
  - id: 8e3e6b3f
    name: ""
    type: namespace
    rule: todesktop.com
    enable: true
  - id: b098cd07
    name: ""
    type: namespace
    rule: trae.ai
    enable: true
  - id: f0db93e2
    name: ""
    type: namespace
    rule: tria.ge
    enable: true
  - id: 8793b0ce
    name: ""
    type: namespace
    rule: windsurf.com
    enable: true
  - id: 98b2b254
    name: ""
    type: subnet
    rule: 45.155.204.190/32
    enable: true
  - id: 4c3350e1
    name: ""
    type: subnet
    rule: 95.182.120.241/32
    enable: true
  - id: a9cf4da0
    name: ""
    type: namespace
    rule: githubcopilot.com
    enable: true
  - id: f6488fbb
    name: ""
    type: namespace
    rule: mistral.ai
    enable: true
  - id: 0ae0c103
    name: ""
    type: namespace
    rule: cohere.com
    enable: true
  - id: ea76612a
    name: ""
    type: namespace
    rule: perplexity.ai
    enable: true
  - id: 4a7220f4
    name: ""
    type: namespace
    rule: together.ai
    enable: true
  - id: 75b7d1f6
    name: ""
    type: namespace
    rule: fireworks.ai
    enable: true
- id: a8dac476
  name: Steam
  color: '#665e6b'
  interface: Mihomo
  enable: true
  rules:
  - id: d611024f
    name: ""
    type: namespace
    rule: store.steampowered.com
    enable: true
- id: fa4931ca
  name: wardogs
  color: '#304876'
  interface: pppoe-wan
  enable: false
  rules:
  - id: 868693ac
    name: ""
    type: namespace
    rule: api.epicgames.dev
    enable: true
  - id: f8ef618a
    name: ""
    type: namespace
    rule: firstlook.gg
    enable: true
  - id: f8ed1c91
    name: ""
    type: namespace
    rule: live.wardogs.bulkhead.pragmaengine.com
    enable: true
- id: 2a385eed
  name: Anime
  color: '#54f282'
  interface: Mihomo
  enable: true
  rules:
  - id: 1cff86c9
    name: ""
    type: namespace
    rule: kodikres.com
    enable: true
  - id: 8cabd98f
    name: ""
    type: namespace
    rule: snsv.ru
    enable: true
  - id: 55e94872
    name: ""
    type: namespace
    rule: kodik.com
    enable: true
  - id: 6e9c2cc9
    name: ""
    type: namespace
    rule: kodikplayer.com
    enable: true
  - id: 4207d10e
    name: ""
    type: namespace
    rule: kimberlite.io
    enable: true
  - id: 59789bf6
    name: ""
    type: namespace
    rule: yummyani.me
    enable: true
  - id: a41829de
    name: ""
    type: namespace
    rule: solodcdn.com
    enable: true
  - id: c2e163ce
    name: ""
    type: namespace
    rule: anixmirai.com
    enable: true
  - id: c48c6d8c
    name: ""
    type: namespace
    rule: adultmult.tv
    enable: true
  - id: e60b052a
    name: ""
    type: namespace
    rule: amedia.site
    enable: true
  - id: 487de374
    name: ""
    type: namespace
    rule: anilib.me
    enable: true
  - id: af6e13a0
    name: ""
    type: namespace
    rule: anilibria.org
    enable: true
  - id: 740573a2
    name: ""
    type: namespace
    rule: anilibria.tv
    enable: true
  - id: 64fba30b
    name: ""
    type: namespace
    rule: anilibria.uno
    enable: true
  - id: e4944b36
    name: ""
    type: namespace
    rule: anilibria.wtf
    enable: true
  - id: f603651b
    name: ""
    type: namespace
    rule: animaunt.org
    enable: true
  - id: 4e9b811e
    name: ""
    type: namespace
    rule: anime-portal.su
    enable: true
  - id: 488716c2
    name: ""
    type: namespace
    rule: animebest.org
    enable: true
  - id: fe2d94c2
    name: ""
    type: namespace
    rule: animedia.tv
    enable: true
  - id: 39a14ec6
    name: ""
    type: namespace
    rule: animego.org
    enable: true
  - id: 9b693527
    name: ""
    type: namespace
    rule: animespirit.ru
    enable: true
  - id: a81b8de0
    name: ""
    type: namespace
    rule: anistar.org
    enable: true
  - id: 1046fd78
    name: ""
    type: namespace
    rule: anistars.ru
    enable: true
  - id: 5fd34274
    name: ""
    type: namespace
    rule: bato.to
    enable: true
  - id: 84ed429b
    name: ""
    type: domain
    rule: danbooru.donmai.us
    enable: true
  - id: "59464021"
    name: ""
    type: domain
    rule: delivery.2d.net.co
    enable: true
  - id: 182a47af
    name: ""
    type: namespace
    rule: dorama.live
    enable: true
  - id: ced49bec
    name: ""
    type: namespace
    rule: doramalive.ru
    enable: true
  - id: 9e3571fa
    name: ""
    type: namespace
    rule: doramy.club
    enable: true
  - id: 78051d11
    name: ""
    type: namespace
    rule: e621.net
    enable: true
  - id: 0b47e02c
    name: ""
    type: namespace
    rule: ficbook.net
    enable: true
  - id: 7d8bc51e
    name: ""
    type: namespace
    rule: gelbooru.com
    enable: true
  - id: 8fbeb502
    name: ""
    type: namespace
    rule: jut-su.net
    enable: true
  - id: 1906c103
    name: ""
    type: namespace
    rule: jut.su
    enable: true
  - id: 41e7d8b1
    name: ""
    type: namespace
    rule: kara.su
    enable: true
  - id: "05238453"
    name: ""
    type: namespace
    rule: kemono.su
    enable: true
  - id: 87fa95a8
    name: ""
    type: namespace
    rule: manga-chan.me
    enable: true
  - id: dd32226a
    name: ""
    type: namespace
    rule: mangadex.org
    enable: true
  - id: d68a9cef
    name: ""
    type: namespace
    rule: mangahub.ru
    enable: true
  - id: 53d4290f
    name: ""
    type: namespace
    rule: mangapark.net
    enable: true
  - id: 9d14516b
    name: ""
    type: namespace
    rule: myanimelist.net
    enable: true
  - id: 03d42fb2
    name: ""
    type: namespace
    rule: mydoramy.club
    enable: true
  - id: 685b4fab
    name: ""
    type: namespace
    rule: shikimori.me
    enable: true
  - id: 3af3569b
    name: ""
    type: namespace
    rule: shikimori.one
    enable: true
  - id: d3a02828
    name: ""
    type: namespace
    rule: shiza-project.com
    enable: true
  - id: 1b4a929e
    name: ""
    type: namespace
    rule: slashlib.me
    enable: true
  - id: 444c3885
    name: ""
    type: namespace
    rule: sovetromantica.com
    enable: true
  - id: db988be3
    name: ""
    type: namespace
    rule: vndb.org
    enable: true
  - id: aafa286b
    name: ""
    type: namespace
    rule: yande.re
    enable: true
  - id: 0acb98db
    name: ""
    type: namespace
    rule: anixsekai.com
    enable: true
  - id: 0acb98dc
    name: ""
    type: namespace
    rule: anixart.ru
    enable: true
  - id: 0acb98dd
    name: ""
    type: namespace
    rule: anixart.tv
    enable: true
  - id: 0acb98de
    name: ""
    type: namespace
    rule: anixart.app
    enable: true
  - id: 0acb98df
    name: ""
    type: namespace
    rule: anixart.cc
    enable: true
  - id: 0acb98e0
    name: ""
    type: namespace
    rule: anix.tv
    enable: true
  - id: 0acb98e1
    name: ""
    type: namespace
    rule: anixart-app.com
    enable: true
  - id: 0acb98e2
    name: ""
    type: namespace
    rule: anixapp.com
    enable: true
  - id: 0acb98e3
    name: ""
    type: namespace
    rule: anixart.me
    enable: true
  - id: 0acb98e4
    name: ""
    type: namespace
    rule: anixart.site
    enable: true
  - id: 0acb9bf6
    name: ""
    type: namespace
    rule: kodik.xyz
    enable: true
  - id: 0acb9bf7
    name: ""
    type: namespace
    rule: kodik.site
    enable: true
  - id: 0acb9bf8
    name: ""
    type: namespace
    rule: kodik-api.com
    enable: true
  - id: 0acb9bf9
    name: ""
    type: namespace
    rule: aniboom.one
    enable: true
  - id: 0acb9bfa
    name: ""
    type: namespace
    rule: anivibe.com
    enable: true
  - id: 0acb9bfb
    name: ""
    type: namespace
    rule: kodik.biz
    enable: true
  - id: 0acb9bfc
    name: ""
    type: namespace
    rule: kodik.info
    enable: true
  - id: 0acb9bfd
    name: ""
    type: namespace
    rule: kodik.cc
    enable: true
  - id: 0acb9bfe
    name: ""
    type: namespace
    rule: kodikdb.com
    enable: true
  - id: 0acb9bff
    name: ""
    type: namespace
    rule: sibnet.ru
    enable: true
  - id: 0acb9c00
    name: ""
    type: namespace
    rule: collaps.org
    enable: true
  - id: 0acb9c01
    name: ""
    type: namespace
    rule: anilibria.top
    enable: true
  - id: 2f563e30
    name: ""
    type: namespace
    rule: jsdelivr.net
    enable: true
  - id: 6b5932d7
    name: ""
    type: namespace
    rule: emoji.gg
    enable: true
- id: eeaa3c27
  name: Block
  color: '#b054f2'
  interface: Mihomo
  enable: true
  rules:
  - id: de234534
    name: ""
    type: namespace
    rule: 10minutemail.com
    enable: true
  - id: e89ec1d1
    name: ""
    type: namespace
    rule: 1337x.to
    enable: true
  - id: fff19258
    name: ""
    type: namespace
    rule: 4freerussia.org
    enable: true
  - id: 7c547050
    name: ""
    type: namespace
    rule: 4pna.com
    enable: true
  - id: b7d339fd
    name: ""
    type: namespace
    rule: 5sim.net
    enable: true
  - id: d8e0d283
    name: ""
    type: namespace
    rule: 7tv.app
    enable: true
  - id: b4bae82e
    name: ""
    type: namespace
    rule: 7tv.io
    enable: true
  - id: 28d7ef14
    name: ""
    type: namespace
    rule: abook-club.ru
    enable: true
  - id: 2094ba81
    name: ""
    type: domain
    rule: academy.terrasoft.ua
    enable: true
  - id: 3a784f5f
    name: ""
    type: namespace
    rule: adguard-vpn.com
    enable: true
  - id: 47dd97ec
    name: ""
    type: namespace
    rule: adguard.com
    enable: true
  - id: e2967c70
    name: ""
    type: namespace
    rule: adminforge.de
    enable: true
  - id: d7571d60
    name: ""
    type: namespace
    rule: ahrefs.com
    enable: true
  - id: db63896e
    name: ""
    type: namespace
    rule: allegro.pl
    enable: true
  - id: 1f6a635c
    name: ""
    type: namespace
    rule: amdm.ru
    enable: true
  - id: 5f736010
    name: ""
    type: namespace
    rule: amnezia.org
    enable: true
  - id: 9b56ce84
    name: ""
    type: namespace
    rule: amx.com
    enable: true
  - id: "35471978"
    name: ""
    type: namespace
    rule: anidub.com
    enable: true
  - id: a1c6d426
    name: ""
    type: namespace
    rule: annas-archive.org
    enable: true
  - id: eeb75c92
    name: ""
    type: namespace
    rule: any.do
    enable: true
  - id: 3c2a286e
    name: ""
    type: namespace
    rule: aol.com
    enable: true
  - id: 5673c462
    name: ""
    type: domain
    rule: api.service-kp.com
    enable: true
  - id: 8f7dd8e8
    name: ""
    type: namespace
    rule: apkmirror.com
    enable: true
  - id: 84a85682
    name: ""
    type: namespace
    rule: archive.ph
    enable: true
  - id: 607d2609
    name: ""
    type: namespace
    rule: archiveofourown.org
    enable: true
  - id: e74f859d
    name: ""
    type: namespace
    rule: as6723.net
    enable: true
  - id: 307e2cf4
    name: ""
    type: domain
    rule: atv4.dnskp.cc
    enable: true
  - id: "38530420"
    name: ""
    type: namespace
    rule: audiobookbay.lu
    enable: true
  - id: 8ccf55e8
    name: ""
    type: namespace
    rule: avira.com
    enable: true
  - id: ae2de82e
    name: ""
    type: namespace
    rule: babook.org
    enable: true
  - id: e5b31ff6
    name: ""
    type: namespace
    rule: baginya.org
    enable: true
  - id: c6a75ff7
    name: ""
    type: namespace
    rule: bcbits.com
    enable: true
  - id: 9f5e26f8
    name: ""
    type: namespace
    rule: bestchange.ru
    enable: true
  - id: 8797870a
    name: ""
    type: namespace
    rule: bluehost.com
    enable: true
  - id: 6a40f661
    name: ""
    type: namespace
    rule: booktracker.org
    enable: true
  - id: 8fb77417
    name: ""
    type: namespace
    rule: boominfo.org
    enable: true
  - id: b822eac0
    name: ""
    type: namespace
    rule: booth.pm
    enable: true
  - id: e1bca93f
    name: ""
    type: domain
    rule: booth.pximg.net
    enable: true
  - id: 5fe3a5e5
    name: ""
    type: namespace
    rule: botnadzor.org
    enable: true
  - id: "99882877"
    name: ""
    type: namespace
    rule: bt4gprx.com
    enable: true
  - id: "79190376"
    name: ""
    type: namespace
    rule: btdig.com
    enable: true
  - id: 97a588bb
    name: ""
    type: namespace
    rule: bufferbloat.net
    enable: true
  - id: 0bc259ab
    name: ""
    type: namespace
    rule: carnegieendowment.org
    enable: true
  - id: ebbcf7a5
    name: ""
    type: namespace
    rule: cbilling.eu
    enable: true
  - id: 03a587a9
    name: ""
    type: namespace
    rule: cbilling.vip
    enable: true
  - id: ce7bb025
    name: ""
    type: namespace
    rule: cdnbunny.org
    enable: true
  - id: cada4cea
    name: ""
    type: namespace
    rule: censortracker.org
    enable: true
  - id: c93a8e0b
    name: ""
    type: namespace
    rule: charhub.io
    enable: true
  - id: 123343fe
    name: ""
    type: namespace
    rule: chess.com
    enable: true
  - id: a1fa0869
    name: ""
    type: namespace
    rule: chesscomfiles.com
    enable: true
  - id: 6fb0e694
    name: ""
    type: namespace
    rule: chub.ai
    enable: true
  - id: 40573abb
    name: ""
    type: namespace
    rule: cloudtorrents.com
    enable: true
  - id: 7d6a850d
    name: ""
    type: namespace
    rule: cnd2exp.online
    enable: true
  - id: c1d16ac0
    name: ""
    type: namespace
    rule: cock.li
    enable: true
  - id: 4a0fb242
    name: ""
    type: namespace
    rule: codelinaro.org
    enable: true
  - id: 6ff04f05
    name: ""
    type: namespace
    rule: coinpayments.net
    enable: true
  - id: 9c87ad61
    name: ""
    type: namespace
    rule: coinsbee.com
    enable: true
  - id: c3e81af3
    name: ""
    type: namespace
    rule: coldfilm.city
    enable: true
  - id: ae33bcb8
    name: ""
    type: namespace
    rule: coldfilm.ink
    enable: true
  - id: bcc5bca7
    name: ""
    type: namespace
    rule: coldfilm.xyz
    enable: true
  - id: 600b56f1
    name: ""
    type: namespace
    rule: coursera.org
    enable: true
  - id: 9997ac29
    name: ""
    type: namespace
    rule: croxyproxy.com
    enable: true
  - id: bf68695c
    name: ""
    type: namespace
    rule: cub.red
    enable: true
  - id: b458cdfd
    name: ""
    type: namespace
    rule: cyberghostvpn.com
    enable: true
  - id: 121008a1
    name: ""
    type: namespace
    rule: deckbrew.xyz
    enable: true
  - id: 9aa6bb2f
    name: ""
    type: namespace
    rule: decrypt.day
    enable: true
  - id: 1510acc4
    name: ""
    type: namespace
    rule: deepstatemap.live
    enable: true
  - id: 9eb51da8
    name: ""
    type: namespace
    rule: depositphotos.com
    enable: true
  - id: 1ac07481
    name: ""
    type: namespace
    rule: designify.com
    enable: true
  - id: 1c3e3aea
    name: ""
    type: namespace
    rule: deviantart.com
    enable: true
  - id: "93644382"
    name: ""
    type: namespace
    rule: digash.live
    enable: true
  - id: 7cb32d8e
    name: ""
    type: namespace
    rule: digikey.com
    enable: true
  - id: 06f6a420
    name: ""
    type: namespace
    rule: dpidetector.org
    enable: true
  - id: 45be1e5a
    name: ""
    type: namespace
    rule: dreamhost.com
    enable: true
  - id: a4488cf9
    name: ""
    type: namespace
    rule: dub.sh
    enable: true
  - id: 3a6a3940
    name: ""
    type: namespace
    rule: edu-cisco.org
    enable: true
  - id: 11fc14e3
    name: ""
    type: namespace
    rule: ef.com
    enable: true
  - id: 8b81fef4
    name: ""
    type: namespace
    rule: ef.edu
    enable: true
  - id: 5682d0ee
    name: ""
    type: namespace
    rule: eggertspiele.de
    enable: true
  - id: 6064dc7a
    name: ""
    type: namespace
    rule: element14.com
    enable: true
  - id: 4f1d79ab
    name: ""
    type: domain
    rule: elements.envato.com
    enable: true
  - id: c7b4c2b0
    name: ""
    type: domain
    rule: epidemz.net.co
    enable: true
  - id: 7996ebd9
    name: ""
    type: namespace
    rule: everand.com
    enable: true
  - id: 77d543fd
    name: ""
    type: namespace
    rule: exler.es
    enable: true
  - id: 7b6b0409
    name: ""
    type: namespace
    rule: f95-zone.to
    enable: true
  - id: 12877f5b
    name: ""
    type: namespace
    rule: fast-torrent.club
    enable: true
  - id: d0c07d31
    name: ""
    type: namespace
    rule: filmitorrent.net
    enable: true
  - id: aab361ff
    name: ""
    type: namespace
    rule: filmix.ac
    enable: true
  - id: af758e7f
    name: ""
    type: namespace
    rule: filmix.biz
    enable: true
  - id: bc2c9db3
    name: ""
    type: namespace
    rule: filmix.day
    enable: true
  - id: 7bd28e99
    name: ""
    type: namespace
    rule: filmix.fan
    enable: true
  - id: 64372a2e
    name: ""
    type: namespace
    rule: filmix.fm
    enable: true
  - id: dbbedc3c
    name: ""
    type: namespace
    rule: filmix.la
    enable: true
  - id: 18b21e4b
    name: ""
    type: namespace
    rule: flibusta.is
    enable: true
  - id: 1047eded
    name: ""
    type: namespace
    rule: flibusta.net
    enable: true
  - id: ecf28b33
    name: ""
    type: namespace
    rule: flipboard.com
    enable: true
  - id: bfd0586f
    name: ""
    type: namespace
    rule: flisland.net
    enable: true
  - id: 529b7c67
    name: ""
    type: namespace
    rule: fls.guru
    enable: true
  - id: b2155ab6
    name: ""
    type: namespace
    rule: forklog.com
    enable: true
  - id: fd5eecb3
    name: ""
    type: domain
    rule: forum.ru-board.com
    enable: true
  - id: 1850dea5
    name: ""
    type: namespace
    rule: freedomletters.org
    enable: true
  - id: e8016e08
    name: ""
    type: namespace
    rule: gagadget.com
    enable: true
  - id: e56bc1b1
    name: ""
    type: namespace
    rule: gamedistribution.com
    enable: true
  - id: 128531f4
    name: ""
    type: namespace
    rule: gamesrepack.com
    enable: true
  - id: d0c8b68c
    name: ""
    type: namespace
    rule: getoutline.org
    enable: true
  - id: f7e78131
    name: ""
    type: namespace
    rule: gifyu.com
    enable: true
  - id: 7ccddff2
    name: ""
    type: namespace
    rule: git.new
    enable: true
  - id: 2119a5a9
    name: ""
    type: namespace
    rule: godaddy.com
    enable: true
  - id: 2086076f
    name: ""
    type: namespace
    rule: gofile.io
    enable: true
  - id: e13124de
    name: ""
    type: namespace
    rule: gonitro.com
    enable: true
  - id: 9fb09bdb
    name: ""
    type: namespace
    rule: goodreads.com
    enable: true
  - id: e9dbf8c9
    name: ""
    type: namespace
    rule: gr-assets.com
    enable: true
  - id: 2f50d1c1
    name: ""
    type: namespace
    rule: hackernoon.com
    enable: true
  - id: 0d0d857b
    name: ""
    type: namespace
    rule: hackmd.io
    enable: true
  - id: d0616a5c
    name: ""
    type: namespace
    rule: halooglasi.com
    enable: true
  - id: 05c3d598
    name: ""
    type: namespace
    rule: hdkinoteatr.com
    enable: true
  - id: 74d00d03
    name: ""
    type: namespace
    rule: hdstudio.org
    enable: true
  - id: ace1c799
    name: ""
    type: namespace
    rule: hostgator.com
    enable: true
  - id: 4583e8e9
    name: ""
    type: namespace
    rule: iditelesombase.org
    enable: true
  - id: 4b9f26a9
    name: ""
    type: namespace
    rule: ign.com
    enable: true
  - id: 92bc55a0
    name: ""
    type: namespace
    rule: iichan.hk
    enable: true
  - id: b0bdd4a2
    name: ""
    type: namespace
    rule: ilook.tv
    enable: true
  - id: 10f96dc0
    name: ""
    type: namespace
    rule: incy.cc
    enable: true
  - id: c013f083
    name: ""
    type: namespace
    rule: indiehackers.com
    enable: true
  - id: 34a3097d
    name: ""
    type: namespace
    rule: infineon.com
    enable: true
  - id: 8cc55a84
    name: ""
    type: namespace
    rule: insearch.site
    enable: true
  - id: 41e530d5
    name: ""
    type: domain
    rule: interactivebrokers.co.uk
    enable: true
  - id: ff8d7283
    name: ""
    type: namespace
    rule: ionos.com
    enable: true
  - id: 646887ce
    name: ""
    type: namespace
    rule: iptv.online
    enable: true
  - id: b179502a
    name: ""
    type: namespace
    rule: itch.io
    enable: true
  - id: 8024e599
    name: ""
    type: namespace
    rule: kamatera.com
    enable: true
  - id: b6e33a9d
    name: ""
    type: namespace
    rule: kilo.ai
    enable: true
  - id: 3b473d9f
    name: ""
    type: namespace
    rule: kilocode.ai
    enable: true
  - id: f481984f
    name: ""
    type: namespace
    rule: kino.pub
    enable: true
  - id: 35ab034f
    name: ""
    type: namespace
    rule: kinogo.ec
    enable: true
  - id: 5b2a50b6
    name: ""
    type: namespace
    rule: kinogo.uk
    enable: true
  - id: 9edd7472
    name: ""
    type: namespace
    rule: kinopub.me
    enable: true
  - id: d5b9ebe0
    name: ""
    type: namespace
    rule: kinovod.net
    enable: true
  - id: c389171a
    name: ""
    type: namespace
    rule: kinozal.guru
    enable: true
  - id: 1ca6075d
    name: ""
    type: namespace
    rule: kinozal.me
    enable: true
  - id: de05c7e0
    name: ""
    type: namespace
    rule: kinozal.tv
    enable: true
  - id: 0a9dc387
    name: ""
    type: namespace
    rule: kinozaltv.life
    enable: true
  - id: 71b4644b
    name: ""
    type: namespace
    rule: knews.kg
    enable: true
  - id: 90939f10
    name: ""
    type: namespace
    rule: knowyourmeme.com
    enable: true
  - id: 40340a69
    name: ""
    type: namespace
    rule: kupujemprodajem.com
    enable: true
  - id: a368b5ef
    name: ""
    type: namespace
    rule: kym-cdn.com
    enable: true
  - id: 86a210d3
    name: ""
    type: namespace
    rule: lantern.io
    enable: true
  - id: b33be5b6
    name: ""
    type: namespace
    rule: le-production.tv
    enable: true
  - id: 3fa18dfe
    name: ""
    type: namespace
    rule: leafletjs.com
    enable: true
  - id: f6fc3ba0
    name: ""
    type: domain
    rule: lib.rus.ec
    enable: true
  - id: e616cae3
    name: ""
    type: namespace
    rule: libgen.li
    enable: true
  - id: ebfe7e83
    name: ""
    type: namespace
    rule: licdn.com
    enable: true
  - id: 2b99458a
    name: ""
    type: namespace
    rule: linear.app
    enable: true
  - id: 42dac2fb
    name: ""
    type: namespace
    rule: lingq.com
    enable: true
  - id: 5cae2e47
    name: ""
    type: namespace
    rule: linkedin.com
    enable: true
  - id: 3c9bd0a2
    name: ""
    type: namespace
    rule: linktr.ee
    enable: true
  - id: c18fd327
    name: ""
    type: namespace
    rule: livetv.sx
    enable: true
  - id: eb9de29d
    name: ""
    type: namespace
    rule: liveuamap.com
    enable: true
  - id: e1d0d123
    name: ""
    type: namespace
    rule: lolz.guru
    enable: true
  - id: 003601ec
    name: ""
    type: namespace
    rule: lostfilm.download
    enable: true
  - id: 781ed346
    name: ""
    type: namespace
    rule: lostfilm.tv
    enable: true
  - id: ccd8925b
    name: ""
    type: namespace
    rule: lostfilm.tw
    enable: true
  - id: c445a3e0
    name: ""
    type: namespace
    rule: lostfilm.uno
    enable: true
  - id: 3396f34f
    name: ""
    type: namespace
    rule: lostfilmtv2.site
    enable: true
  - id: ff30929a
    name: ""
    type: namespace
    rule: lu4.org
    enable: true
  - id: 5219e39e
    name: ""
    type: namespace
    rule: lucid.app
    enable: true
  - id: 14a199bb
    name: ""
    type: namespace
    rule: magaz.global
    enable: true
  - id: 2fc0dc74
    name: ""
    type: domain
    rule: mail-api.proton.me
    enable: true
  - id: d2978fe3
    name: ""
    type: namespace
    rule: mailfence.com
    enable: true
  - id: 639e3517
    name: ""
    type: namespace
    rule: mailo.com
    enable: true
  - id: be8f36e7
    name: ""
    type: namespace
    rule: make.com
    enable: true
  - id: 365b7f62
    name: ""
    type: namespace
    rule: malwarebytes.com
    enable: true
  - id: 91986f73
    name: ""
    type: namespace
    rule: mashable.com
    enable: true
  - id: eea70dca
    name: ""
    type: namespace
    rule: medium.com
    enable: true
  - id: b0d3e9ba
    name: ""
    type: namespace
    rule: mega.nz
    enable: true
  - id: a82a4c8a
    name: ""
    type: namespace
    rule: megapeer.ru
    enable: true
  - id: a9b1a422
    name: ""
    type: namespace
    rule: megapeer.vip
    enable: true
  - id: e816e327
    name: ""
    type: namespace
    rule: metacritic.com
    enable: true
  - id: 9f28c8e8
    name: ""
    type: namespace
    rule: metal-archives.com
    enable: true
  - id: eaf4aeb9
    name: ""
    type: namespace
    rule: modrinth.com
    enable: true
  - id: 46aa75fa
    name: ""
    type: namespace
    rule: monolisa.dev
    enable: true
  - id: 3bcdf3f5
    name: ""
    type: namespace
    rule: more.fm
    enable: true
  - id: 4c08a73d
    name: ""
    type: namespace
    rule: mullvad.net
    enable: true
  - id: 2ceefe26
    name: ""
    type: namespace
    rule: musicbrainz.org
    enable: true
  - id: 8363a488
    name: ""
    type: namespace
    rule: musixmatch.com
    enable: true
  - id: 835b2e04
    name: ""
    type: namespace
    rule: mw2.wiki
    enable: true
  - id: 61820c98
    name: ""
    type: namespace
    rule: navalny.com
    enable: true
  - id: ea15fdde
    name: ""
    type: domain
    rule: neformat.com.ua
    enable: true
  - id: ab92834e
    name: ""
    type: namespace
    rule: networksolutions.com
    enable: true
  - id: af1b55c9
    name: ""
    type: namespace
    rule: nhl.com
    enable: true
  - id: c853cbaa
    name: ""
    type: namespace
    rule: nih.gov
    enable: true
  - id: ab6a21af
    name: ""
    type: namespace
    rule: nippon.com
    enable: true
  - id: 867f5a39
    name: ""
    type: namespace
    rule: nnmclub.to
    enable: true
  - id: 5351d5f5
    name: ""
    type: namespace
    rule: nnmstatic.win
    enable: true
  - id: 9c28150f
    name: ""
    type: namespace
    rule: notepad-plus-plus.org
    enable: true
  - id: 018742bb
    name: ""
    type: namespace
    rule: novaline.fm
    enable: true
  - id: 8b20edee
    name: ""
    type: namespace
    rule: ntc.party
    enable: true
  - id: b5e26ceb
    name: ""
    type: namespace
    rule: ohmyswift.ru
    enable: true
  - id: 6e83f98c
    name: ""
    type: namespace
    rule: okx.com
    enable: true
  - id: 34b416d1
    name: ""
    type: namespace
    rule: olx.ua
    enable: true
  - id: 348c1bba
    name: ""
    type: namespace
    rule: omv-extras.org
    enable: true
  - id: 1654981d
    name: ""
    type: namespace
    rule: onlinesim.io
    enable: true
  - id: e39bde45
    name: ""
    type: namespace
    rule: opensanctions.org
    enable: true
  - id: d764966d
    name: ""
    type: namespace
    rule: opensea.io
    enable: true
  - id: c205a4d1
    name: ""
    type: namespace
    rule: opentrackr.org
    enable: true
  - id: 562c39c9
    name: ""
    type: namespace
    rule: pages.dev
    enable: true
  - id: 9fba914b
    name: ""
    type: namespace
    rule: pb.wtf
    enable: true
  - id: 36e08273
    name: ""
    type: namespace
    rule: pimpletv.ru
    enable: true
  - id: d0a16c51
    name: ""
    type: namespace
    rule: piratbit.top
    enable: true
  - id: 317a23cb
    name: ""
    type: namespace
    rule: pixabay.com
    enable: true
  - id: 7d37b954
    name: ""
    type: namespace
    rule: pixiv.net
    enable: true
  - id: 33fd106b
    name: ""
    type: namespace
    rule: polymarket.com
    enable: true
  - id: 21a100b2
    name: ""
    type: namespace
    rule: primevue.org
    enable: true
  - id: 646472bc
    name: ""
    type: namespace
    rule: privatekeys.pw
    enable: true
  - id: 9d1644cb
    name: ""
    type: namespace
    rule: prnt.sc
    enable: true
  - id: b7ebe068
    name: ""
    type: namespace
    rule: pronouns.page
    enable: true
  - id: 381ee0fe
    name: ""
    type: namespace
    rule: prostovpn.org
    enable: true
  - id: a2f6c070
    name: ""
    type: namespace
    rule: proton.me
    enable: true
  - id: eb808f75
    name: ""
    type: namespace
    rule: psiphon.ca
    enable: true
  - id: 7744cae9
    name: ""
    type: namespace
    rule: pvpessence.com
    enable: true
  - id: 2cd8619f
    name: ""
    type: namespace
    rule: quora.com
    enable: true
  - id: 88a02adc
    name: ""
    type: domain
    rule: quora.com.cdn.cloudflare.net
    enable: true
  - id: 0f659175
    name: ""
    type: namespace
    rule: radiojar.com
    enable: true
  - id: f48683b1
    name: ""
    type: namespace
    rule: redshieldvpn.com
    enable: true
  - id: 1cc2734d
    name: ""
    type: namespace
    rule: refactoring.guru
    enable: true
  - id: b552f9b0
    name: ""
    type: namespace
    rule: render-state.to
    enable: true
  - id: b1d5b260
    name: ""
    type: namespace
    rule: rentry.co
    enable: true
  - id: 17a9c686
    name: ""
    type: namespace
    rule: restream.io
    enable: true
  - id: 7a3ba340
    name: ""
    type: domain
    rule: rf.dobrochan.net
    enable: true
  - id: 4e530ed7
    name: ""
    type: namespace
    rule: riperam.org
    enable: true
  - id: c86e9de0
    name: ""
    type: namespace
    rule: riseup.net
    enable: true
  - id: 9b8111e4
    name: ""
    type: namespace
    rule: rublacklist.net
    enable: true
  - id: 9ecc4af7
    name: ""
    type: namespace
    rule: ruscryde.net
    enable: true
  - id: 5bd2b0ab
    name: ""
    type: namespace
    rule: rustorka.com
    enable: true
  - id: 40c0597a
    name: ""
    type: namespace
    rule: rutor.info
    enable: true
  - id: f6d05035
    name: ""
    type: namespace
    rule: rutor.is
    enable: true
  - id: a46da691
    name: ""
    type: namespace
    rule: rutor.org
    enable: true
  - id: 51bd7f01
    name: ""
    type: namespace
    rule: rutracker.cc
    enable: true
  - id: f303389f
    name: ""
    type: namespace
    rule: rutracker.net
    enable: true
  - id: c01924e4
    name: ""
    type: namespace
    rule: rutracker.wiki
    enable: true
  - id: edecb858
    name: ""
    type: namespace
    rule: sap.com
    enable: true
  - id: 623f1ed5
    name: ""
    type: namespace
    rule: saverudata.net
    enable: true
  - id: 4eb8da68
    name: ""
    type: namespace
    rule: sci-hub.se
    enable: true
  - id: 8f5d9647
    name: ""
    type: namespace
    rule: sci-hub.st
    enable: true
  - id: 58d870db
    name: ""
    type: namespace
    rule: scrollrevealjs.org
    enable: true
  - id: 6bb067ad
    name: ""
    type: namespace
    rule: scryde.io
    enable: true
  - id: bbc886ef
    name: ""
    type: namespace
    rule: scryde.net
    enable: true
  - id: aa179397
    name: ""
    type: namespace
    rule: scryde.ru
    enable: true
  - id: edfa3314
    name: ""
    type: namespace
    rule: scryde.world
    enable: true
  - id: 475429b9
    name: ""
    type: namespace
    rule: scryde1.net
    enable: true
  - id: e33039de
    name: ""
    type: namespace
    rule: scryde10.net
    enable: true
  - id: 6bedba24
    name: ""
    type: namespace
    rule: scryde11.net
    enable: true
  - id: bbf93c13
    name: ""
    type: namespace
    rule: scryde12.net
    enable: true
  - id: "40477558"
    name: ""
    type: namespace
    rule: scryde2.net
    enable: true
  - id: 8413e45a
    name: ""
    type: namespace
    rule: scryde3.net
    enable: true
  - id: f26ac057
    name: ""
    type: namespace
    rule: scryde4.net
    enable: true
  - id: 9d0a18eb
    name: ""
    type: namespace
    rule: scryde5.net
    enable: true
  - id: abf43772
    name: ""
    type: namespace
    rule: scryde6.net
    enable: true
  - id: da522f41
    name: ""
    type: namespace
    rule: scryde7.net
    enable: true
  - id: 7f458b54
    name: ""
    type: namespace
    rule: scryde8.net
    enable: true
  - id: 6ad8fab8
    name: ""
    type: namespace
    rule: scryde9.net
    enable: true
  - id: c91464be
    name: ""
    type: namespace
    rule: searchfloor.org
    enable: true
  - id: f0481219
    name: ""
    type: namespace
    rule: seasonvar.ru
    enable: true
  - id: "36746047"
    name: ""
    type: namespace
    rule: selezen.org
    enable: true
  - id: 26a0d838
    name: ""
    type: namespace
    rule: showip.net
    enable: true
  - id: 6851b8e8
    name: ""
    type: namespace
    rule: signal.org
    enable: true
  - id: d025eedf
    name: ""
    type: namespace
    rule: simplex.chat
    enable: true
  - id: 13f6af6e
    name: ""
    type: namespace
    rule: simplex.im
    enable: true
  - id: 08fca317
    name: ""
    type: namespace
    rule: simplix.info
    enable: true
  - id: 86e732e5
    name: ""
    type: namespace
    rule: skiff.com
    enable: true
  - id: 106facf8
    name: ""
    type: namespace
    rule: skladchik.com
    enable: true
  - id: d30d8c2c
    name: ""
    type: namespace
    rule: sklatchiki.ru
    enable: true
  - id: 65cc93d4
    name: ""
    type: namespace
    rule: slifki.biz
    enable: true
  - id: b7c72e9a
    name: ""
    type: namespace
    rule: sms-activate.io
    enable: true
  - id: 29a2e30f
    name: ""
    type: namespace
    rule: sndcdn.com
    enable: true
  - id: 4c97d193
    name: ""
    type: namespace
    rule: sophos.com
    enable: true
  - id: 9260789b
    name: ""
    type: namespace
    rule: soundcloud.cloud
    enable: true
  - id: 050c1bd4
    name: ""
    type: namespace
    rule: soundcloud.com
    enable: true
  - id: 8c7e61d9
    name: ""
    type: namespace
    rule: speedtest.net
    enable: true
  - id: b31c3d47
    name: ""
    type: namespace
    rule: spreadthesign.com
    enable: true
  - id: 68c91f64
    name: ""
    type: namespace
    rule: squietpc.com
    enable: true
  - id: 9b6471ef
    name: ""
    type: namespace
    rule: startmail.com
    enable: true
  - id: 5b703d59
    name: ""
    type: namespace
    rule: startpage.com
    enable: true
  - id: 4c2d8543
    name: ""
    type: domain
    rule: static.lostfilm.top
    enable: true
  - id: d1e0a2c8
    name: ""
    type: namespace
    rule: statology.org
    enable: true
  - id: af86c93a
    name: ""
    type: namespace
    rule: steamstat.info
    enable: true
  - id: bf069881
    name: ""
    type: namespace
    rule: supersliv.biz
    enable: true
  - id: f6637062
    name: ""
    type: namespace
    rule: surfshark.com
    enable: true
  - id: bb7b5935
    name: ""
    type: namespace
    rule: swissinfo.ch
    enable: true
  - id: f80800e3
    name: ""
    type: namespace
    rule: te-st.org
    enable: true
  - id: e104a489
    name: ""
    type: namespace
    rule: temu.com
    enable: true
  - id: 103b667d
    name: ""
    type: namespace
    rule: thepiratebay.org
    enable: false
  - id: dfc364b8
    name: ""
    type: namespace
    rule: thetvdb.com
    enable: true
  - id: 7b6b5252
    name: ""
    type: namespace
    rule: threema.ch
    enable: true
  - id: 188e4eea
    name: ""
    type: namespace
    rule: tiptop-vpn.com
    enable: true
  - id: 05ccf89b
    name: ""
    type: namespace
    rule: torproject.org
    enable: true
  - id: 910a0742
    name: ""
    type: namespace
    rule: torrentgalaxy.to
    enable: true
  - id: 6abfbbaf
    name: ""
    type: namespace
    rule: trellix.com
    enable: true
  - id: c73bbe37
    name: ""
    type: namespace
    rule: trueblackmetalradio.com
    enable: true
  - id: d8d6ff8d
    name: ""
    type: namespace
    rule: turbobit.net
    enable: true
  - id: 41a47b9f
    name: ""
    type: namespace
    rule: tuta.com
    enable: true
  - id: bbb8713a
    name: ""
    type: namespace
    rule: tuta.io
    enable: true
  - id: d59e1532
    name: ""
    type: namespace
    rule: tvdevinfo.com
    enable: true
  - id: 3a98b040
    name: ""
    type: namespace
    rule: twin.me
    enable: true
  - id: bb63ca3f
    name: ""
    type: namespace
    rule: twinlife-systems.com
    enable: true
  - id: 5ff571b7
    name: ""
    type: namespace
    rule: twinme.com
    enable: true
  - id: cab367b8
    name: ""
    type: namespace
    rule: twirpx.com
    enable: true
  - id: 2def5b07
    name: ""
    type: namespace
    rule: ua
    enable: true
  - id: 0de12732
    name: ""
    type: namespace
    rule: ukr.net
    enable: true
  - id: 8bcc40c5
    name: ""
    type: namespace
    rule: ukrtelcdn.net
    enable: true
  - id: 31635a56
    name: ""
    type: namespace
    rule: unsplash.com
    enable: true
  - id: 562f2678
    name: ""
    type: namespace
    rule: urlr.me
    enable: true
  - id: 516df713
    name: ""
    type: namespace
    rule: viber.com
    enable: true
  - id: 6940c9e6
    name: ""
    type: namespace
    rule: vice.com
    enable: true
  - id: f19304c1
    name: ""
    type: namespace
    rule: visualcapitalist.com
    enable: true
  - id: 9e53b77c
    name: ""
    type: namespace
    rule: vpngate.net
    enable: true
  - id: 88a9e2d5
    name: ""
    type: namespace
    rule: vpngen.org
    enable: true
  - id: 1e9bcb05
    name: ""
    type: namespace
    rule: vpnlove.me
    enable: true
  - id: 750a70f5
    name: ""
    type: namespace
    rule: vpnpay.io
    enable: true
  - id: fb670a56
    name: ""
    type: namespace
    rule: webmd.com
    enable: true
  - id: ac053903
    name: ""
    type: namespace
    rule: webtoons.com
    enable: true
  - id: 894fc97b
    name: ""
    type: domain
    rule: wiki.fextralife.com
    enable: true
  - id: b5c35931
    name: ""
    type: namespace
    rule: wilsoncenter.org
    enable: true
  - id: 7d056ccb
    name: ""
    type: namespace
    rule: windows10spotlight.com
    enable: true
  - id: 400fdc58
    name: ""
    type: namespace
    rule: zbigz.com
    enable: true
  - id: d37cff7c
    name: ""
    type: namespace
    rule: zendesk.com
    enable: true
- id: 58544d63
  name: Cloudflare
  color: '#f2de54'
  interface: Mihomo
  enable: true
  rules:
  - id: 802ab845
    name: ""
    type: subnet
    rule: 103.21.244.0/22
    enable: true
  - id: 1b607012
    name: ""
    type: subnet
    rule: 103.22.200.0/22
    enable: true
  - id: 3236d29c
    name: ""
    type: subnet
    rule: 103.31.4.0/22
    enable: true
  - id: 2f878992
    name: ""
    type: subnet
    rule: 104.16.0.0/13
    enable: true
  - id: bd01006d
    name: ""
    type: subnet
    rule: 104.24.0.0/14
    enable: true
  - id: 23de60f6
    name: ""
    type: subnet
    rule: 108.162.192.0/18
    enable: true
  - id: a539c2e8
    name: ""
    type: subnet
    rule: 131.0.72.0/22
    enable: true
  - id: 1bd3d939
    name: ""
    type: subnet
    rule: 141.101.64.0/18
    enable: true
  - id: 90a02cb4
    name: ""
    type: subnet
    rule: 162.158.0.0/15
    enable: true
  - id: 48d5666f
    name: ""
    type: subnet
    rule: 172.64.0.0/13
    enable: true
  - id: 8a2abe42
    name: ""
    type: subnet
    rule: 173.245.48.0/20
    enable: true
  - id: a432a84d
    name: ""
    type: subnet
    rule: 188.114.96.0/20
    enable: true
  - id: 6e007d85
    name: ""
    type: subnet
    rule: 190.93.240.0/20
    enable: true
  - id: a357b022
    name: ""
    type: subnet
    rule: 197.234.240.0/22
    enable: true
  - id: 6b61f5ca
    name: ""
    type: subnet
    rule: 198.41.128.0/17
    enable: true
  - id: 4218986b
    name: ""
    type: subnet6
    rule: 2400:cb00::/32
    enable: true
  - id: 832a0d67
    name: ""
    type: subnet6
    rule: 2405:8100::/32
    enable: true
  - id: bb79d84b
    name: ""
    type: subnet6
    rule: 2405:b500::/32
    enable: true
  - id: 8847b2b5
    name: ""
    type: subnet6
    rule: 2606:4700::/32
    enable: true
  - id: 154dac98
    name: ""
    type: subnet6
    rule: 2803:f800::/32
    enable: true
  - id: e550f064
    name: ""
    type: subnet6
    rule: 2a06:98c0::/29
    enable: true
  - id: 7cf3bf84
    name: ""
    type: subnet6
    rule: 2c0f:f248::/32
    enable: true
  - id: e0fd5ebc
    name: ""
    type: namespace
    rule: cdnjs.com
    enable: true
  - id: 21d26f4e
    name: ""
    type: namespace
    rule: cloudflare.com
    enable: true
  - id: bbcc2176
    name: ""
    type: namespace
    rule: cloudflarestatus.com
    enable: true
  - id: 21f25ab9
    name: ""
    type: domain
    rule: one.one.one.one
    enable: true
- id: d917ad35
  name: Cloudfront
  color: '#54d7f2'
  interface: Mihomo
  enable: true
  rules:
  - id: 692782b5
    name: ""
    type: subnet
    rule: 108.138.0.0/15
    enable: true
  - id: 5d1b350b
    name: ""
    type: subnet
    rule: 108.156.0.0/14
    enable: true
  - id: c86a3e80
    name: ""
    type: subnet
    rule: 111.13.171.128/26
    enable: true
  - id: 2290a40e
    name: ""
    type: subnet
    rule: 111.13.171.192/26
    enable: true
  - id: 6b1c151b
    name: ""
    type: subnet
    rule: 111.13.185.32/27
    enable: true
  - id: eb8a80b8
    name: ""
    type: subnet
    rule: 111.13.185.64/27
    enable: true
  - id: 54c7d5ce
    name: ""
    type: subnet
    rule: 116.129.226.0/25
    enable: true
  - id: 5bcb383c
    name: ""
    type: subnet
    rule: 116.129.226.128/26
    enable: true
  - id: 0fdbde29
    name: ""
    type: subnet
    rule: 118.193.97.128/25
    enable: true
  - id: c7cd8438
    name: ""
    type: subnet
    rule: 118.193.97.64/26
    enable: true
  - id: 41b79476
    name: ""
    type: subnet
    rule: 119.147.182.0/25
    enable: true
  - id: 00e0bc38
    name: ""
    type: subnet
    rule: 119.147.182.128/26
    enable: true
  - id: d17f0e20
    name: ""
    type: subnet
    rule: 120.232.236.0/25
    enable: true
  - id: e566e45e
    name: ""
    type: subnet
    rule: 120.232.236.128/26
    enable: true
  - id: 9c17baef
    name: ""
    type: subnet
    rule: 120.253.240.192/26
    enable: true
  - id: 17ccb311
    name: ""
    type: subnet
    rule: 120.253.241.160/27
    enable: true
  - id: db41b566
    name: ""
    type: subnet
    rule: 120.253.245.128/26
    enable: true
  - id: bbe8fa88
    name: ""
    type: subnet
    rule: 120.253.245.192/27
    enable: true
  - id: e5d45fd9
    name: ""
    type: subnet
    rule: 120.52.12.64/26
    enable: true
  - id: 36eb5dec
    name: ""
    type: subnet
    rule: 120.52.153.192/26
    enable: true
  - id: 4e1e54bc
    name: ""
    type: subnet
    rule: 120.52.22.96/27
    enable: true
  - id: c8a3ae5b
    name: ""
    type: subnet
    rule: 120.52.39.128/27
    enable: true
  - id: 5655e322
    name: ""
    type: subnet
    rule: 13.113.196.64/26
    enable: true
  - id: 8fca0496
    name: ""
    type: subnet
    rule: 13.113.203.0/24
    enable: true
  - id: 069faca6
    name: ""
    type: subnet
    rule: 13.124.199.0/24
    enable: true
  - id: 682e267b
    name: ""
    type: subnet
    rule: 13.134.24.0/23
    enable: true
  - id: 09b2f84d
    name: ""
    type: subnet
    rule: 13.134.94.0/23
    enable: true
  - id: 6abbd377
    name: ""
    type: subnet
    rule: 13.203.133.0/26
    enable: true
  - id: a33eb536
    name: ""
    type: subnet
    rule: 13.210.67.128/26
    enable: true
  - id: 842acd4c
    name: ""
    type: subnet
    rule: 13.224.0.0/14
    enable: true
  - id: 16d321f0
    name: ""
    type: subnet
    rule: 13.228.69.0/24
    enable: true
  - id: 8106d495
    name: ""
    type: subnet
    rule: 13.233.177.192/26
    enable: true
  - id: bb9c7a1f
    name: ""
    type: subnet
    rule: 13.249.0.0/16
    enable: true
  - id: bf0203e8
    name: ""
    type: subnet
    rule: 13.32.0.0/15
    enable: true
  - id: ee6a6a97
    name: ""
    type: subnet
    rule: 13.35.0.0/16
    enable: true
  - id: 9eb0d04f
    name: ""
    type: subnet
    rule: 13.54.63.128/26
    enable: true
  - id: eeca0167
    name: ""
    type: subnet
    rule: 13.59.250.0/26
    enable: true
  - id: 24cd2cb1
    name: ""
    type: subnet
    rule: 130.176.0.0/17
    enable: true
  - id: 55c90030
    name: ""
    type: subnet
    rule: 130.176.128.0/18
    enable: true
  - id: c0ea3e58
    name: ""
    type: subnet
    rule: 130.176.192.0/19
    enable: true
  - id: 52067cf9
    name: ""
    type: subnet
    rule: 130.176.224.0/20
    enable: true
  - id: 70161f30
    name: ""
    type: subnet
    rule: 143.204.0.0/16
    enable: true
  - id: 14f0d38d
    name: ""
    type: subnet
    rule: 144.220.0.0/16
    enable: true
  - id: 986fd8b7
    name: ""
    type: subnet
    rule: 15.158.0.0/16
    enable: true
  - id: 8f51348f
    name: ""
    type: subnet
    rule: 15.188.184.0/24
    enable: true
  - id: 609cf212
    name: ""
    type: subnet
    rule: 15.207.13.128/25
    enable: true
  - id: d51adca6
    name: ""
    type: subnet
    rule: 15.207.213.128/25
    enable: true
  - id: 54fa34c6
    name: ""
    type: subnet
    rule: 18.154.0.0/15
    enable: true
  - id: 7f4ef773
    name: ""
    type: subnet
    rule: 18.160.0.0/15
    enable: true
  - id: ea4ae480
    name: ""
    type: subnet
    rule: 18.164.0.0/15
    enable: true
  - id: 43be9884
    name: ""
    type: subnet
    rule: 18.172.0.0/15
    enable: true
  - id: 4ecac99f
    name: ""
    type: subnet
    rule: 18.175.65.0/24
    enable: true
  - id: 1bc2472d
    name: ""
    type: subnet
    rule: 18.175.66.0/24
    enable: true
  - id: f2cb0b1c
    name: ""
    type: subnet
    rule: 18.175.67.0/24
    enable: true
  - id: fc312462
    name: ""
    type: subnet
    rule: 18.192.142.0/23
    enable: true
  - id: 2ecdaf02
    name: ""
    type: subnet
    rule: 18.199.68.0/22
    enable: true
  - id: 2e43dce3
    name: ""
    type: subnet
    rule: 18.199.72.0/22
    enable: true
  - id: 120e4961
    name: ""
    type: subnet
    rule: 18.199.76.0/22
    enable: true
  - id: c108b69a
    name: ""
    type: subnet
    rule: 18.200.212.0/23
    enable: true
  - id: edd0cff6
    name: ""
    type: subnet
    rule: 18.216.170.128/25
    enable: true
  - id: 2a64fb5b
    name: ""
    type: subnet
    rule: 18.229.220.192/26
    enable: true
  - id: 6edc1262
    name: ""
    type: subnet
    rule: 18.230.229.0/24
    enable: true
  - id: b0708dc2
    name: ""
    type: subnet
    rule: 18.230.230.0/25
    enable: true
  - id: b4d8fb81
    name: ""
    type: subnet
    rule: 18.238.0.0/15
    enable: true
  - id: 980d1716
    name: ""
    type: subnet
    rule: 18.244.0.0/15
    enable: true
  - id: 64329b68
    name: ""
    type: subnet
    rule: 18.64.0.0/14
    enable: true
  - id: 810af529
    name: ""
    type: subnet
    rule: 18.68.0.0/16
    enable: true
  - id: 97780bf6
    name: ""
    type: subnet
    rule: 180.163.57.0/25
    enable: true
  - id: 90192bc1
    name: ""
    type: subnet
    rule: 180.163.57.128/26
    enable: true
  - id: 56857bce
    name: ""
    type: subnet6
    rule: 2001:3fc6:20::/43
    enable: true
  - id: a1ea5afe
    name: ""
    type: subnet
    rule: 204.246.164.0/22
    enable: true
  - id: 3957bf83
    name: ""
    type: subnet
    rule: 204.246.168.0/22
    enable: true
  - id: 4c3bfb42
    name: ""
    type: subnet
    rule: 204.246.172.0/24
    enable: true
  - id: cb0a114d
    name: ""
    type: subnet
    rule: 204.246.173.0/24
    enable: true
  - id: 5c217e35
    name: ""
    type: subnet
    rule: 204.246.174.0/23
    enable: true
  - id: fc12a2dd
    name: ""
    type: subnet
    rule: 204.246.176.0/20
    enable: true
  - id: c52f5215
    name: ""
    type: subnet
    rule: 205.251.202.0/23
    enable: true
  - id: 1164fa54
    name: ""
    type: subnet
    rule: 205.251.204.0/23
    enable: true
  - id: 1b2e55ca
    name: ""
    type: subnet
    rule: 205.251.206.0/23
    enable: true
  - id: 43511a35
    name: ""
    type: subnet
    rule: 205.251.208.0/20
    enable: true
  - id: fc245e39
    name: ""
    type: subnet
    rule: 205.251.249.0/24
    enable: true
  - id: 5e8cd2e0
    name: ""
    type: subnet
    rule: 205.251.250.0/23
    enable: true
  - id: 287f4460
    name: ""
    type: subnet
    rule: 205.251.252.0/23
    enable: true
  - id: 72451e4b
    name: ""
    type: subnet
    rule: 205.251.254.0/24
    enable: true
  - id: 0305701b
    name: ""
    type: subnet
    rule: 216.137.32.0/19
    enable: true
  - id: 57225c23
    name: ""
    type: subnet
    rule: 23.228.212.0/24
    enable: true
  - id: b1d33795
    name: ""
    type: subnet
    rule: 23.228.213.0/24
    enable: true
  - id: "99167055"
    name: ""
    type: subnet
    rule: 23.228.214.0/24
    enable: true
  - id: 995bc13b
    name: ""
    type: subnet
    rule: 23.228.220.0/24
    enable: true
  - id: dd20ab9d
    name: ""
    type: subnet
    rule: 23.228.221.0/24
    enable: true
  - id: 6a9c26ae
    name: ""
    type: subnet
    rule: 23.228.222.0/24
    enable: true
  - id: 7a9a840b
    name: ""
    type: subnet
    rule: 23.228.223.0/24
    enable: true
  - id: 463ac571
    name: ""
    type: subnet
    rule: 23.228.244.0/24
    enable: true
  - id: 34715aca
    name: ""
    type: subnet
    rule: 23.228.246.0/24
    enable: true
  - id: 08c44c90
    name: ""
    type: subnet
    rule: 23.228.247.0/24
    enable: true
  - id: 4b9243eb
    name: ""
    type: subnet
    rule: 23.228.248.0/24
    enable: true
  - id: 93edd174
    name: ""
    type: subnet
    rule: 23.228.249.0/24
    enable: true
  - id: 8157a4a0
    name: ""
    type: subnet
    rule: 23.228.250.0/24
    enable: true
  - id: 1065c7d2
    name: ""
    type: subnet
    rule: 23.228.251.0/24
    enable: true
  - id: 92abd840
    name: ""
    type: subnet
    rule: 23.234.192.0/18
    enable: true
  - id: 10d0723d
    name: ""
    type: subnet
    rule: 23.91.0.0/19
    enable: true
  - id: 4339b846
    name: ""
    type: subnet
    rule: 24.110.128.0/17
    enable: true
  - id: f8609d4f
    name: ""
    type: subnet
    rule: 24.110.32.0/19
    enable: true
  - id: 7eda6fb9
    name: ""
    type: subnet6
    rule: 2400:7fc0:500::/40
    enable: true
  - id: 530a2d2f
    name: ""
    type: subnet6
    rule: 2404:c2c0:500::/40
    enable: true
  - id: 27ae708e
    name: ""
    type: subnet6
    rule: 2409:8c00:2421:300::/56
    enable: true
  - id: 5a37cdb8
    name: ""
    type: subnet6
    rule: 2409:8c00:2421:400::/56
    enable: true
  - id: 42a6bef4
    name: ""
    type: subnet6
    rule: 2600:9000:1000::/36
    enable: true
  - id: 37e8be75
    name: ""
    type: subnet6
    rule: 2600:9000:2000::/36
    enable: true
  - id: ba0fe0ad
    name: ""
    type: subnet6
    rule: 2600:9000:3000::/36
    enable: true
  - id: 1a075f0c
    name: ""
    type: subnet6
    rule: 2600:9000:4000::/36
    enable: true
  - id: 0f9ac99e
    name: ""
    type: subnet6
    rule: 2600:9000:5200::/40
    enable: true
  - id: 0e9284df
    name: ""
    type: subnet6
    rule: 2600:9000:5308::/45
    enable: true
  - id: 247e2276
    name: ""
    type: subnet6
    rule: 2600:9000:5310::/44
    enable: true
  - id: 85a18292
    name: ""
    type: subnet6
    rule: 2600:9000:5320::/43
    enable: true
  - id: 9426c50f
    name: ""
    type: subnet6
    rule: 2600:9000:5340::/42
    enable: true
  - id: 51acdbb0
    name: ""
    type: subnet6
    rule: 2600:9000:5380::/41
    enable: true
  - id: 396aba6c
    name: ""
    type: subnet6
    rule: 2600:9000:6000::/36
    enable: true
  - id: 8a555b24
    name: ""
    type: subnet6
    rule: 2600:9000:ddd::/48
    enable: true
  - id: 85e02e37
    name: ""
    type: subnet6
    rule: 2600:9000:eee::/48
    enable: true
  - id: a468af47
    name: ""
    type: subnet6
    rule: 2600:9000:f000::/38
    enable: true
  - id: 3b49c3c0
    name: ""
    type: subnet6
    rule: 2600:9000:f400::/40
    enable: true
  - id: 579d1aaa
    name: ""
    type: subnet6
    rule: 2600:9000:f500::/43
    enable: true
  - id: 61cd5738
    name: ""
    type: subnet6
    rule: 2600:9000:f520::/44
    enable: true
  - id: 94c2aedd
    name: ""
    type: subnet6
    rule: 2600:9000:f534::/46
    enable: true
  - id: ab82beef
    name: ""
    type: subnet6
    rule: 2600:9000:f538::/45
    enable: true
  - id: bc4e8446
    name: ""
    type: subnet6
    rule: 2600:9000:f540::/42
    enable: true
  - id: da0b8978
    name: ""
    type: subnet6
    rule: 2600:9000:f580::/41
    enable: true
  - id: 9a378d31
    name: ""
    type: subnet6
    rule: 2600:9000:f600::/39
    enable: true
  - id: 23a979a7
    name: ""
    type: subnet6
    rule: 2600:9000:f800::/37
    enable: true
  - id: 7d933364
    name: ""
    type: subnet6
    rule: 2600:9000:fff::/48
    enable: true
  - id: 4c54abd4
    name: ""
    type: subnet6
    rule: 2600:f0f0:5504::/46
    enable: true
  - id: 3cf1e49c
    name: ""
    type: subnet6
    rule: 2600:f0f0:601::/48
    enable: true
  - id: 358f7564
    name: ""
    type: subnet6
    rule: 2600:f0f0:602::/47
    enable: true
  - id: 2e145def
    name: ""
    type: subnet
    rule: 3.10.17.128/25
    enable: true
  - id: 619630b4
    name: ""
    type: subnet
    rule: 3.101.158.0/23
    enable: true
  - id: baac8200
    name: ""
    type: subnet
    rule: 3.107.43.128/25
    enable: true
  - id: c01f71db
    name: ""
    type: subnet
    rule: 3.107.44.0/25
    enable: true
  - id: 491812f3
    name: ""
    type: subnet
    rule: 3.107.44.128/25
    enable: true
  - id: cd4397d9
    name: ""
    type: subnet
    rule: 3.11.53.0/24
    enable: true
  - id: ee4fd9f1
    name: ""
    type: subnet
    rule: 3.128.93.0/24
    enable: true
  - id: 41e4298e
    name: ""
    type: subnet
    rule: 3.134.215.0/24
    enable: true
  - id: 2986b460
    name: ""
    type: subnet
    rule: 3.146.232.0/22
    enable: true
  - id: b2dffbe8
    name: ""
    type: subnet
    rule: 3.147.164.0/22
    enable: true
  - id: 082789ae
    name: ""
    type: subnet
    rule: 3.147.244.0/22
    enable: true
  - id: 2ddc0e3e
    name: ""
    type: subnet
    rule: 3.160.0.0/14
    enable: true
  - id: 5ecbcb58
    name: ""
    type: subnet
    rule: 3.164.0.0/18
    enable: true
  - id: f60f5d14
    name: ""
    type: subnet
    rule: 3.164.128.0/17
    enable: true
  - id: 242a9385
    name: ""
    type: subnet
    rule: 3.164.64.0/18
    enable: true
  - id: 9a69be55
    name: ""
    type: subnet
    rule: 3.165.0.0/16
    enable: true
  - id: 1cb052e5
    name: ""
    type: subnet
    rule: 3.166.0.0/15
    enable: true
  - id: 5b79e5a6
    name: ""
    type: subnet
    rule: 3.168.0.0/14
    enable: true
  - id: 62eb7b47
    name: ""
    type: subnet
    rule: 3.172.0.0/18
    enable: true
  - id: 28514ab0
    name: ""
    type: subnet
    rule: 3.172.64.0/18
    enable: true
  - id: e64f7b69
    name: ""
    type: subnet
    rule: 3.173.0.0/17
    enable: true
  - id: db272c62
    name: ""
    type: subnet
    rule: 3.173.128.0/18
    enable: true
  - id: b62b6abc
    name: ""
    type: subnet
    rule: 3.173.192.0/18
    enable: true
  - id: ee9abe6e
    name: ""
    type: subnet
    rule: 3.174.0.0/15
    enable: true
  - id: d0fc7410
    name: ""
    type: subnet
    rule: 3.231.2.0/25
    enable: true
  - id: fbdbb8b9
    name: ""
    type: subnet
    rule: 3.234.232.224/27
    enable: true
  - id: 03dc6357
    name: ""
    type: subnet
    rule: 3.236.169.192/26
    enable: true
  - id: c2093083
    name: ""
    type: subnet
    rule: 3.236.48.0/23
    enable: true
  - id: faf8443f
    name: ""
    type: subnet
    rule: 3.29.40.128/26
    enable: true
  - id: cd0f47bb
    name: ""
    type: subnet
    rule: 3.29.40.192/26
    enable: true
  - id: 4a720e0a
    name: ""
    type: subnet
    rule: 3.29.40.64/26
    enable: true
  - id: 8358eaba
    name: ""
    type: subnet
    rule: 3.29.57.0/26
    enable: true
  - id: e837c745
    name: ""
    type: subnet
    rule: 3.35.130.128/25
    enable: true
  - id: 1343c846
    name: ""
    type: subnet
    rule: 34.195.252.0/24
    enable: true
  - id: ce16e2e6
    name: ""
    type: subnet
    rule: 34.216.51.0/25
    enable: true
  - id: c9112083
    name: ""
    type: subnet
    rule: 34.223.12.224/27
    enable: true
  - id: 26f80846
    name: ""
    type: subnet
    rule: 34.223.80.192/26
    enable: true
  - id: 5d12ef71
    name: ""
    type: subnet
    rule: 34.226.14.0/24
    enable: true
  - id: 9de46320
    name: ""
    type: subnet
    rule: 35.158.136.0/24
    enable: true
  - id: ee2e65ae
    name: ""
    type: subnet
    rule: 35.162.63.192/26
    enable: true
  - id: 71a1a5ab
    name: ""
    type: subnet
    rule: 35.167.191.128/26
    enable: true
  - id: "0336e156"
    name: ""
    type: subnet
    rule: 35.93.168.0/23
    enable: true
  - id: ba378030
    name: ""
    type: subnet
    rule: 35.93.170.0/23
    enable: true
  - id: c18a726b
    name: ""
    type: subnet
    rule: 35.93.172.0/23
    enable: true
  - id: 7963c729
    name: ""
    type: subnet
    rule: 36.103.232.0/25
    enable: true
  - id: 3d232983
    name: ""
    type: subnet
    rule: 36.103.232.128/26
    enable: true
  - id: b021ce3e
    name: ""
    type: subnet
    rule: 43.218.56.128/26
    enable: true
  - id: 99b6da55
    name: ""
    type: subnet
    rule: 43.218.56.192/26
    enable: true
  - id: f794edba
    name: ""
    type: subnet
    rule: 43.218.56.64/26
    enable: true
  - id: 0f906abb
    name: ""
    type: subnet
    rule: 43.218.71.0/26
    enable: true
  - id: 05db424d
    name: ""
    type: subnet
    rule: 44.220.194.0/23
    enable: true
  - id: 63379ade
    name: ""
    type: subnet
    rule: 44.220.196.0/23
    enable: true
  - id: cc3057aa
    name: ""
    type: subnet
    rule: 44.220.198.0/23
    enable: true
  - id: e351f3ed
    name: ""
    type: subnet
    rule: 44.220.200.0/23
    enable: true
  - id: ecddf34c
    name: ""
    type: subnet
    rule: 44.220.202.0/23
    enable: true
  - id: 6adedc1a
    name: ""
    type: subnet
    rule: 44.222.66.0/24
    enable: true
  - id: 12654a00
    name: ""
    type: subnet
    rule: 44.227.178.0/24
    enable: true
  - id: d4144835
    name: ""
    type: subnet
    rule: 44.234.108.128/25
    enable: true
  - id: 283b86bc
    name: ""
    type: subnet
    rule: 44.234.90.252/30
    enable: true
  - id: c646c4c8
    name: ""
    type: subnet
    rule: 47.129.82.0/24
    enable: true
  - id: 0086ca8c
    name: ""
    type: subnet
    rule: 47.129.83.0/24
    enable: true
  - id: 584bb2ac
    name: ""
    type: subnet
    rule: 47.129.84.0/24
    enable: true
  - id: 250c176f
    name: ""
    type: subnet
    rule: 51.44.234.0/23
    enable: true
  - id: 55c09d3a
    name: ""
    type: subnet
    rule: 51.44.236.0/23
    enable: true
  - id: b3b31a23
    name: ""
    type: subnet
    rule: 51.44.238.0/23
    enable: true
  - id: a156cc18
    name: ""
    type: subnet
    rule: 51.74.192.0/18
    enable: true
  - id: afa22fbf
    name: ""
    type: subnet
    rule: 52.124.128.0/17
    enable: true
  - id: c0a48780
    name: ""
    type: subnet
    rule: 52.15.127.128/26
    enable: true
  - id: 1d742c65
    name: ""
    type: subnet
    rule: 52.199.127.192/26
    enable: true
  - id: a0b21c25
    name: ""
    type: subnet
    rule: 52.212.248.0/26
    enable: true
  - id: 81da19db
    name: ""
    type: subnet
    rule: 52.220.191.0/26
    enable: true
  - id: b3dca8dc
    name: ""
    type: subnet
    rule: 52.222.128.0/17
    enable: true
  - id: 23778e7d
    name: ""
    type: subnet
    rule: 52.46.0.0/18
    enable: true
  - id: 2cf232a0
    name: ""
    type: subnet
    rule: 52.47.139.0/24
    enable: true
  - id: 1505f0bd
    name: ""
    type: subnet
    rule: 52.52.191.128/26
    enable: true
  - id: c09f5bb0
    name: ""
    type: subnet
    rule: 52.56.127.0/25
    enable: true
  - id: 6a7967e7
    name: ""
    type: subnet
    rule: 52.57.254.0/24
    enable: true
  - id: 442355dd
    name: ""
    type: subnet
    rule: 52.66.194.128/26
    enable: true
  - id: e7e9a24b
    name: ""
    type: subnet
    rule: 52.78.247.128/26
    enable: true
  - id: 32bf8698
    name: ""
    type: subnet
    rule: 52.82.128.0/19
    enable: true
  - id: 5b7a084f
    name: ""
    type: subnet
    rule: 52.84.0.0/15
    enable: true
  - id: c420bcaf
    name: ""
    type: subnet
    rule: 54.182.0.0/16
    enable: true
  - id: b427103c
    name: ""
    type: subnet
    rule: 54.192.0.0/16
    enable: true
  - id: 9413ee1e
    name: ""
    type: subnet
    rule: 54.230.0.0/17
    enable: true
  - id: 4e300952
    name: ""
    type: subnet
    rule: 54.230.128.0/18
    enable: true
  - id: "53820765"
    name: ""
    type: subnet
    rule: 54.230.200.0/21
    enable: true
  - id: baae40d1
    name: ""
    type: subnet
    rule: 54.230.208.0/20
    enable: true
  - id: d685966d
    name: ""
    type: subnet
    rule: 54.230.224.0/19
    enable: true
  - id: 9b87751d
    name: ""
    type: subnet
    rule: 54.233.255.128/26
    enable: true
  - id: c9a90648
    name: ""
    type: subnet
    rule: 54.239.128.0/18
    enable: true
  - id: "86973532"
    name: ""
    type: subnet
    rule: 54.239.192.0/19
    enable: true
  - id: "54424064"
    name: ""
    type: subnet
    rule: 54.240.128.0/18
    enable: true
  - id: c1b7a53a
    name: ""
    type: subnet
    rule: 56.125.46.0/24
    enable: true
  - id: 2c6fd9ed
    name: ""
    type: subnet
    rule: 56.125.47.0/32
    enable: true
  - id: b88210ff
    name: ""
    type: subnet
    rule: 56.125.48.0/24
    enable: true
  - id: d85936d7
    name: ""
    type: subnet
    rule: 57.182.253.0/24
    enable: true
  - id: e6a76025
    name: ""
    type: subnet
    rule: 57.183.42.0/25
    enable: true
  - id: c8d9ff2c
    name: ""
    type: subnet
    rule: 58.254.138.0/25
    enable: true
  - id: 934379f4
    name: ""
    type: subnet
    rule: 58.254.138.128/26
    enable: true
  - id: 4f5b5d29
    name: ""
    type: subnet
    rule: 64.252.128.0/18
    enable: true
  - id: db4d2e4c
    name: ""
    type: subnet
    rule: 64.252.64.0/18
    enable: true
  - id: a9ba0040
    name: ""
    type: subnet
    rule: 65.8.0.0/16
    enable: true
  - id: 56b0c72a
    name: ""
    type: subnet
    rule: 65.9.0.0/17
    enable: true
  - id: "60772637"
    name: ""
    type: subnet
    rule: 65.9.128.0/18
    enable: true
  - id: da04c74f
    name: ""
    type: subnet
    rule: 70.132.0.0/18
    enable: true
  - id: 19cf4970
    name: ""
    type: subnet
    rule: 71.152.0.0/17
    enable: true
  - id: a6c6f6a7
    name: ""
    type: subnet
    rule: 99.79.169.0/24
    enable: true
  - id: 31c05fdb
    name: ""
    type: subnet
    rule: 99.84.0.0/16
    enable: true
  - id: "572244e2"
    name: ""
    type: subnet
    rule: 99.86.0.0/16
    enable: true
  - id: ed5719c5
    name: ""
    type: namespace
    rule: cloudfront.net
    enable: true
- id: b969c6b4
  name: Digitalocean
  color: '#f254a9'
  interface: Mihomo
  enable: true
  rules:
  - id: f3809351
    name: ""
    type: subnet
    rule: 103.253.144.0/22
    enable: true
  - id: c0d8c19f
    name: ""
    type: subnet
    rule: 104.131.0.0/16
    enable: true
  - id: 82ccf3b4
    name: ""
    type: subnet
    rule: 104.236.0.0/16
    enable: true
  - id: e3e86a3d
    name: ""
    type: subnet
    rule: 104.248.0.0/16
    enable: true
  - id: cdede69d
    name: ""
    type: subnet
    rule: 107.170.0.0/16
    enable: true
  - id: 47710fb4
    name: ""
    type: subnet
    rule: 128.199.0.0/16
    enable: true
  - id: ecc727a6
    name: ""
    type: subnet
    rule: 129.212.129.0/24
    enable: true
  - id: 0b485760
    name: ""
    type: subnet
    rule: 129.212.130.0/24
    enable: true
  - id: 30b7a235
    name: ""
    type: subnet
    rule: 129.212.132.0/22
    enable: true
  - id: 46881fa8
    name: ""
    type: subnet
    rule: 129.212.136.0/21
    enable: true
  - id: 63083bad
    name: ""
    type: subnet
    rule: 129.212.144.0/20
    enable: true
  - id: b08878e6
    name: ""
    type: subnet
    rule: 129.212.160.0/21
    enable: true
  - id: 8656c3a5
    name: ""
    type: subnet
    rule: 129.212.168.0/22
    enable: true
  - id: 02cb6498
    name: ""
    type: subnet
    rule: 129.212.174.0/24
    enable: true
  - id: fcfa6bd9
    name: ""
    type: subnet
    rule: 129.212.176.0/20
    enable: true
  - id: c1d110b6
    name: ""
    type: subnet
    rule: 129.212.192.0/18
    enable: true
  - id: fdcf99ba
    name: ""
    type: subnet
    rule: 134.122.0.0/17
    enable: true
  - id: 625ab296
    name: ""
    type: subnet
    rule: 134.199.128.0/17
    enable: true
  - id: 6ff826a2
    name: ""
    type: subnet
    rule: 134.209.0.0/16
    enable: true
  - id: 3a568cef
    name: ""
    type: subnet
    rule: 137.184.0.0/17
    enable: true
  - id: 50bf3161
    name: ""
    type: subnet
    rule: 137.184.128.0/18
    enable: true
  - id: ebbae449
    name: ""
    type: subnet
    rule: 137.184.192.0/19
    enable: true
  - id: c3553b62
    name: ""
    type: subnet
    rule: 137.184.224.0/20
    enable: true
  - id: 233fb855
    name: ""
    type: subnet
    rule: 137.184.240.0/21
    enable: true
  - id: df5d8d02
    name: ""
    type: subnet
    rule: 137.184.248.0/22
    enable: true
  - id: 3e268b8d
    name: ""
    type: subnet
    rule: 137.184.252.0/24
    enable: true
  - id: 965c42d3
    name: ""
    type: subnet
    rule: 137.184.254.0/23
    enable: true
  - id: c37fd5e6
    name: ""
    type: subnet
    rule: 138.197.0.0/17
    enable: true
  - id: 7f62e0ff
    name: ""
    type: subnet
    rule: 138.197.128.0/18
    enable: true
  - id: 6c1b27a7
    name: ""
    type: subnet
    rule: 138.197.192.0/19
    enable: true
  - id: 35c1e489
    name: ""
    type: subnet
    rule: 138.197.224.0/20
    enable: true
  - id: 1c2a8bf3
    name: ""
    type: subnet
    rule: 138.197.240.0/22
    enable: true
  - id: "80493254"
    name: ""
    type: subnet
    rule: 138.197.252.0/22
    enable: true
  - id: 258e9417
    name: ""
    type: subnet
    rule: 138.68.0.0/19
    enable: true
  - id: a18b68c1
    name: ""
    type: subnet
    rule: 138.68.128.0/17
    enable: true
  - id: 7e0975d6
    name: ""
    type: subnet
    rule: 138.68.32.0/24
    enable: true
  - id: cc9799ab
    name: ""
    type: subnet
    rule: 138.68.34.0/24
    enable: true
  - id: bc9b019c
    name: ""
    type: subnet
    rule: 138.68.36.0/22
    enable: true
  - id: d3fee702
    name: ""
    type: subnet
    rule: 138.68.40.0/21
    enable: true
  - id: 401b01a0
    name: ""
    type: subnet
    rule: 138.68.48.0/20
    enable: true
  - id: efef38a6
    name: ""
    type: subnet
    rule: 138.68.64.0/18
    enable: true
  - id: 05de6bc3
    name: ""
    type: subnet
    rule: 139.59.0.0/16
    enable: true
  - id: c5881fd2
    name: ""
    type: subnet
    rule: 141.0.169.0/24
    enable: true
  - id: 5d64eca6
    name: ""
    type: subnet
    rule: 141.0.170.0/24
    enable: true
  - id: 62b08b99
    name: ""
    type: subnet
    rule: 142.93.0.0/16
    enable: true
  - id: 496eec57
    name: ""
    type: subnet
    rule: 143.110.128.0/17
    enable: true
  - id: dfc0a921
    name: ""
    type: subnet
    rule: 143.198.0.0/17
    enable: true
  - id: d11aa463
    name: ""
    type: subnet
    rule: 143.198.128.0/18
    enable: true
  - id: bc5a8c77
    name: ""
    type: subnet
    rule: 143.198.192.0/19
    enable: true
  - id: c75b05bf
    name: ""
    type: subnet
    rule: 143.198.224.0/20
    enable: true
  - id: eac560f3
    name: ""
    type: subnet
    rule: 143.198.240.0/21
    enable: true
  - id: c9bf5860
    name: ""
    type: subnet
    rule: 143.198.248.0/22
    enable: true
  - id: 3ed45d56
    name: ""
    type: subnet
    rule: 143.244.128.0/18
    enable: true
  - id: 6fb2a9fb
    name: ""
    type: subnet
    rule: 143.244.196.0/22
    enable: true
  - id: 7233ae1a
    name: ""
    type: subnet
    rule: 143.244.200.0/21
    enable: true
  - id: 58cf2706
    name: ""
    type: subnet
    rule: 143.244.208.0/21
    enable: true
  - id: 4342b193
    name: ""
    type: subnet
    rule: 143.244.217.0/24
    enable: true
  - id: 68c83afe
    name: ""
    type: subnet
    rule: 143.244.218.0/23
    enable: true
  - id: 73f91d04
    name: ""
    type: subnet
    rule: 143.244.220.0/22
    enable: true
  - id: eefb9082
    name: ""
    type: subnet
    rule: 144.126.192.0/18
    enable: true
  - id: 5eca075c
    name: ""
    type: subnet
    rule: 146.185.128.0/18
    enable: true
  - id: 81ac9b5c
    name: ""
    type: subnet
    rule: 146.190.0.0/17
    enable: true
  - id: 46127d98
    name: ""
    type: subnet
    rule: 146.190.128.0/19
    enable: true
  - id: 57420ca9
    name: ""
    type: subnet
    rule: 146.190.160.0/20
    enable: true
  - id: 34d3e509
    name: ""
    type: subnet
    rule: 146.190.176.0/22
    enable: true
  - id: 2a63c0c4
    name: ""
    type: subnet
    rule: 146.190.184.0/21
    enable: true
  - id: 8d767f8c
    name: ""
    type: subnet
    rule: 146.190.192.0/18
    enable: true
  - id: b40fe85b
    name: ""
    type: subnet
    rule: 147.182.128.0/17
    enable: true
  - id: 0d17cba1
    name: ""
    type: subnet
    rule: 152.42.128.0/17
    enable: true
  - id: c14b19d5
    name: ""
    type: subnet
    rule: 157.230.0.0/16
    enable: true
  - id: b72df550
    name: ""
    type: subnet
    rule: 157.245.0.0/16
    enable: true
  - id: bfa75099
    name: ""
    type: subnet
    rule: 159.203.0.0/16
    enable: true
  - id: 8fe4f528
    name: ""
    type: subnet
    rule: 159.223.0.0/17
    enable: true
  - id: 54256b41
    name: ""
    type: subnet
    rule: 159.223.128.0/18
    enable: true
  - id: 5ffd3132
    name: ""
    type: subnet
    rule: 159.223.192.0/19
    enable: true
  - id: d1e4ca89
    name: ""
    type: subnet
    rule: 159.223.224.0/20
    enable: true
  - id: 17f7b7d1
    name: ""
    type: subnet
    rule: 159.223.240.0/21
    enable: true
  - id: b88cf9ce
    name: ""
    type: subnet
    rule: 159.223.248.0/22
    enable: true
  - id: 2a07213e
    name: ""
    type: subnet
    rule: 159.65.0.0/16
    enable: true
  - id: 023041cb
    name: ""
    type: subnet
    rule: 159.89.0.0/19
    enable: true
  - id: b4339635
    name: ""
    type: subnet
    rule: 159.89.128.0/17
    enable: true
  - id: 585ee163
    name: ""
    type: subnet
    rule: 159.89.32.0/20
    enable: true
  - id: 6a1910fb
    name: ""
    type: subnet
    rule: 159.89.48.0/21
    enable: true
  - id: 1ce6b17d
    name: ""
    type: subnet
    rule: 159.89.56.0/24
    enable: true
  - id: e95d18b9
    name: ""
    type: subnet
    rule: 159.89.58.0/23
    enable: true
  - id: 7b14802c
    name: ""
    type: subnet
    rule: 159.89.60.0/22
    enable: true
  - id: cbef91f7
    name: ""
    type: subnet
    rule: 159.89.64.0/18
    enable: true
  - id: 01d9146b
    name: ""
    type: subnet
    rule: 161.35.0.0/16
    enable: true
  - id: 1442c4b7
    name: ""
    type: subnet
    rule: 162.243.0.0/17
    enable: true
  - id: 6183622c
    name: ""
    type: subnet
    rule: 162.243.128.0/19
    enable: true
  - id: 54c3b318
    name: ""
    type: subnet
    rule: 162.243.160.0/20
    enable: true
  - id: d86d601f
    name: ""
    type: subnet
    rule: 162.243.184.0/21
    enable: true
  - id: 9472c275
    name: ""
    type: subnet
    rule: 162.243.192.0/18
    enable: true
  - id: d3f463df
    name: ""
    type: subnet
    rule: 163.47.8.0/22
    enable: true
  - id: 28ae0c45
    name: ""
    type: subnet
    rule: 164.90.128.0/18
    enable: true
  - id: 2734b720
    name: ""
    type: subnet
    rule: 164.90.192.0/19
    enable: true
  - id: 57cfd9dd
    name: ""
    type: subnet
    rule: 164.90.224.0/20
    enable: true
  - id: acf9405e
    name: ""
    type: subnet
    rule: 164.90.240.0/21
    enable: true
  - id: 09840dc0
    name: ""
    type: subnet
    rule: 164.90.248.0/23
    enable: true
  - id: 260f9d13
    name: ""
    type: subnet
    rule: 164.90.250.0/24
    enable: true
  - id: 844451d0
    name: ""
    type: subnet
    rule: 164.90.252.0/22
    enable: true
  - id: 4d74b4be
    name: ""
    type: subnet
    rule: 164.92.128.0/17
    enable: true
  - id: 07180f7d
    name: ""
    type: subnet
    rule: 164.92.64.0/18
    enable: true
  - id: ccbc1b1c
    name: ""
    type: subnet
    rule: 165.22.0.0/16
    enable: true
  - id: ba3fa684
    name: ""
    type: subnet
    rule: 165.227.0.0/16
    enable: true
  - id: a0203247
    name: ""
    type: subnet
    rule: 165.232.128.0/18
    enable: true
  - id: 84849ef6
    name: ""
    type: subnet
    rule: 165.232.32.0/19
    enable: true
  - id: 211daf4c
    name: ""
    type: subnet
    rule: 165.232.64.0/18
    enable: true
  - id: 474e43b4
    name: ""
    type: subnet
    rule: 165.245.128.0/17
    enable: true
  - id: dfaa00a7
    name: ""
    type: subnet
    rule: 167.172.0.0/16
    enable: true
  - id: 8a4b2860
    name: ""
    type: subnet
    rule: 167.71.0.0/16
    enable: true
  - id: 7acb773f
    name: ""
    type: subnet
    rule: 167.99.0.0/16
    enable: true
  - id: 9cd5da08
    name: ""
    type: subnet
    rule: 168.144.0.0/17
    enable: true
  - id: ae805dd9
    name: ""
    type: subnet
    rule: 168.144.128.0/18
    enable: true
  - id: 094436c7
    name: ""
    type: subnet
    rule: 168.144.192.0/22
    enable: true
  - id: c1a0e633
    name: ""
    type: subnet
    rule: 168.144.208.0/20
    enable: true
  - id: 6fa22a11
    name: ""
    type: subnet
    rule: 168.144.224.0/24
    enable: true
  - id: 1b3982a7
    name: ""
    type: subnet
    rule: 168.144.240.0/20
    enable: true
  - id: 962b2bbf
    name: ""
    type: subnet
    rule: 170.64.128.0/17
    enable: true
  - id: df4b946f
    name: ""
    type: subnet
    rule: 174.138.0.0/17
    enable: true
  - id: 4f8ba7a6
    name: ""
    type: subnet
    rule: 178.128.0.0/16
    enable: true
  - id: d054364e
    name: ""
    type: subnet
    rule: 178.62.0.0/16
    enable: true
  - id: eba078ba
    name: ""
    type: subnet
    rule: 185.14.184.0/22
    enable: true
  - id: 59d9b6b4
    name: ""
    type: subnet
    rule: 188.166.0.0/16
    enable: true
  - id: de82b606
    name: ""
    type: subnet
    rule: 188.226.128.0/17
    enable: true
  - id: 68d71543
    name: ""
    type: subnet
    rule: 192.241.128.0/17
    enable: true
  - id: 2fe6953f
    name: ""
    type: subnet
    rule: 192.34.56.0/21
    enable: true
  - id: 3f8fccf2
    name: ""
    type: subnet
    rule: 192.81.208.0/20
    enable: true
  - id: 3d120aaf
    name: ""
    type: subnet
    rule: 198.199.64.0/18
    enable: true
  - id: 5d808789
    name: ""
    type: subnet
    rule: 198.211.96.0/19
    enable: true
  - id: 28cd1470
    name: ""
    type: subnet
    rule: 201.79.0.0/20
    enable: true
  - id: df88c171
    name: ""
    type: subnet
    rule: 204.48.16.0/20
    enable: true
  - id: d2e27587
    name: ""
    type: subnet
    rule: 206.189.0.0/16
    enable: true
  - id: ce297357
    name: ""
    type: subnet
    rule: 206.81.0.0/19
    enable: true
  - id: cebcacb2
    name: ""
    type: subnet
    rule: 207.154.192.0/18
    enable: true
  - id: e0f9a6d9
    name: ""
    type: subnet
    rule: 208.68.36.0/22
    enable: true
  - id: 396b0c4e
    name: ""
    type: subnet
    rule: 209.38.0.0/16
    enable: true
  - id: e5611558
    name: ""
    type: subnet
    rule: 209.97.128.0/18
    enable: true
  - id: e17c08d8
    name: ""
    type: subnet
    rule: 24.144.64.0/21
    enable: true
  - id: 9722c8aa
    name: ""
    type: subnet
    rule: 24.144.72.0/24
    enable: true
  - id: 0a1508b9
    name: ""
    type: subnet
    rule: 24.144.76.0/22
    enable: true
  - id: 7409c262
    name: ""
    type: subnet
    rule: 24.144.80.0/20
    enable: true
  - id: d427b483
    name: ""
    type: subnet
    rule: 24.144.96.0/19
    enable: true
  - id: 9ec24efe
    name: ""
    type: subnet
    rule: 24.199.64.0/18
    enable: true
  - id: 9458f70e
    name: ""
    type: subnet6
    rule: 2400:6180:100::/40
    enable: true
  - id: "78579365"
    name: ""
    type: subnet6
    rule: 2400:6180:10::/48
    enable: true
  - id: ad6cb8eb
    name: ""
    type: subnet6
    rule: 2400:6180::/48
    enable: true
  - id: a7a8cb79
    name: ""
    type: subnet6
    rule: 2604:a880:2::/48
    enable: true
  - id: 43a393b3
    name: ""
    type: subnet6
    rule: 2604:a880:400::/48
    enable: true
  - id: 517e8543
    name: ""
    type: subnet6
    rule: 2604:a880:4::/46
    enable: true
  - id: 072014fe
    name: ""
    type: subnet6
    rule: 2604:a880:800::/48
    enable: true
  - id: cddbcf14
    name: ""
    type: subnet6
    rule: 2604:a880:8::/48
    enable: true
  - id: f9d879e3
    name: ""
    type: subnet6
    rule: 2604:a880::/47
    enable: true
  - id: ec132d74
    name: ""
    type: subnet6
    rule: 2604:a880:cad::/48
    enable: true
  - id: 5081f3f5
    name: ""
    type: subnet6
    rule: 2a03:b0c0::/46
    enable: true
  - id: 119badee
    name: ""
    type: subnet6
    rule: 2a03:b0c0:fffc::/48
    enable: true
  - id: ffda2939
    name: ""
    type: subnet6
    rule: 2a03:b0c0:ffff::/48
    enable: true
  - id: 4af4ee32
    name: ""
    type: subnet
    rule: 37.139.0.0/19
    enable: true
  - id: fe273d20
    name: ""
    type: subnet
    rule: 45.55.0.0/16
    enable: true
  - id: 22ec7aee
    name: ""
    type: subnet
    rule: 46.101.0.0/16
    enable: true
  - id: 74c7635a
    name: ""
    type: subnet
    rule: 5.101.96.0/20
    enable: true
  - id: 9609aad3
    name: ""
    type: subnet
    rule: 64.225.0.0/17
    enable: true
  - id: b81e0a93
    name: ""
    type: subnet
    rule: 64.226.64.0/18
    enable: true
  - id: 91f35a26
    name: ""
    type: subnet
    rule: 64.227.0.0/17
    enable: true
  - id: 28a05aa6
    name: ""
    type: subnet
    rule: 64.227.128.0/18
    enable: true
  - id: c4811d7e
    name: ""
    type: subnet
    rule: 64.23.128.0/17
    enable: true
  - id: d07ab764
    name: ""
    type: subnet
    rule: 67.205.128.0/18
    enable: true
  - id: d116e5bb
    name: ""
    type: subnet
    rule: 67.207.64.0/23
    enable: true
  - id: 7ec17bc7
    name: ""
    type: subnet
    rule: 67.207.66.0/24
    enable: true
  - id: 1da20c2b
    name: ""
    type: subnet
    rule: 67.207.68.0/22
    enable: true
  - id: 3df2dfea
    name: ""
    type: subnet
    rule: 67.207.72.0/21
    enable: true
  - id: 1a870c20
    name: ""
    type: subnet
    rule: 67.207.80.0/20
    enable: true
  - id: 63ad2890
    name: ""
    type: subnet
    rule: 68.183.0.0/16
    enable: true
  - id: a0710874
    name: ""
    type: subnet
    rule: 69.55.48.0/22
    enable: true
  - id: 1a2573e0
    name: ""
    type: subnet
    rule: 69.55.54.0/23
    enable: true
  - id: 9dc20cb5
    name: ""
    type: subnet
    rule: 69.55.58.0/23
    enable: true
  - id: 2c8a5ce1
    name: ""
    type: subnet
    rule: 69.55.60.0/22
    enable: true
  - id: 91b82f65
    name: ""
    type: subnet
    rule: 80.240.128.0/20
    enable: true
  - id: f33be05c
    name: ""
    type: subnet
    rule: 82.196.0.0/20
    enable: true
  - id: "29044215"
    name: ""
    type: subnet
    rule: 95.85.0.0/18
    enable: true
  - id: e870be82
    name: ""
    type: namespace
    rule: digitalocean.com
    enable: true
- id: 09f5a624
  name: Discord
  color: '#7cf254'
  interface: Mihomo
  enable: false
  rules:
  - id: 77d8ac47
    name: ""
    type: subnet
    rule: 104.16.0.0/12
    enable: true
  - id: 49182d7b
    name: ""
    type: subnet
    rule: 138.128.136.0/21
    enable: true
  - id: 7b90867b
    name: ""
    type: subnet
    rule: 34.0.0.0/15
    enable: true
  - id: e0928008
    name: ""
    type: subnet
    rule: 34.2.0.0/15
    enable: true
  - id: 229a785a
    name: ""
    type: subnet
    rule: 35.192.0.0/12
    enable: true
  - id: 0755994e
    name: ""
    type: subnet
    rule: 35.208.0.0/12
    enable: true
  - id: e2e3d582
    name: ""
    type: subnet
    rule: 5.200.14.128/25
    enable: true
  - id: 883d237c
    name: ""
    type: subnet
    rule: 66.22.192.0/18
    enable: true
  - id: dd8b686e
    name: ""
    type: namespace
    rule: dis.gd
    enable: true
  - id: c74a0961
    name: ""
    type: namespace
    rule: discord-activities.com
    enable: true
  - id: e03f08de
    name: ""
    type: namespace
    rule: discord.co
    enable: true
  - id: 4468b6dc
    name: ""
    type: namespace
    rule: discord.com
    enable: true
  - id: a667dd40
    name: ""
    type: namespace
    rule: discord.design
    enable: true
  - id: 4529c06e
    name: ""
    type: namespace
    rule: discord.dev
    enable: true
  - id: 87e92383
    name: ""
    type: namespace
    rule: discord.gg
    enable: true
  - id: 655e5f9c
    name: ""
    type: namespace
    rule: discord.gift
    enable: true
  - id: ba8285b7
    name: ""
    type: namespace
    rule: discord.gifts
    enable: true
  - id: dcb4a594
    name: ""
    type: namespace
    rule: discord.media
    enable: true
  - id: c609c5cb
    name: ""
    type: namespace
    rule: discord.new
    enable: true
  - id: 92f2801b
    name: ""
    type: namespace
    rule: discord.store
    enable: true
  - id: 82834b72
    name: ""
    type: namespace
    rule: discord.tools
    enable: true
  - id: 1c449b4c
    name: ""
    type: namespace
    rule: discordactivities.com
    enable: true
  - id: 8cb87dd0
    name: ""
    type: namespace
    rule: discordapp.com
    enable: true
  - id: 03da96ca
    name: ""
    type: namespace
    rule: discordapp.net
    enable: true
  - id: b79cf908
    name: ""
    type: namespace
    rule: discordmerch.com
    enable: true
  - id: 8e7620d8
    name: ""
    type: namespace
    rule: discordpartygames.com
    enable: true
  - id: 49d9f5b8
    name: ""
    type: namespace
    rule: discordsays.com
    enable: true
- id: 9a2c6777
  name: Geoblock
  color: '#5b54f2'
  interface: Mihomo
  enable: true
  rules:
  - id: 55a65355
    name: ""
    type: namespace
    rule: onthe.io
    enable: true
  - id: b0855347
    name: ""
    type: namespace
    rule: marketscreener.com
    enable: true
  - id: a6edb542
    name: ""
    type: namespace
    rule: 4pda.to
    enable: true
  - id: 4014945a
    name: ""
    type: namespace
    rule: 4pda.ws
    enable: true
  - id: 0d2e07b7
    name: ""
    type: domain
    rule: a-vrv.akamaized.net
    enable: true
  - id: f7043384
    name: ""
    type: namespace
    rule: abercrombie.com
    enable: true
  - id: "590405e0"
    name: ""
    type: namespace
    rule: adidas.com
    enable: true
  - id: f164f808
    name: ""
    type: namespace
    rule: adobe.com
    enable: true
  - id: dcff74fe
    name: ""
    type: namespace
    rule: adobe.net
    enable: true
  - id: d744b50a
    name: ""
    type: domain
    rule: ai-chat.bsg.brave.com
    enable: true
  - id: 83dbd78f
    name: ""
    type: namespace
    rule: ai.com
    enable: true
  - id: 76f2858a
    name: ""
    type: namespace
    rule: aircanada.com
    enable: true
  - id: 55d043d2
    name: ""
    type: namespace
    rule: akc.org
    enable: true
  - id: 9683ce3f
    name: ""
    type: namespace
    rule: all3dp.com
    enable: true
  - id: 05e65e80
    name: ""
    type: namespace
    rule: alphacoders.com
    enable: true
  - id: 79f7cff1
    name: ""
    type: namespace
    rule: alza.hu
    enable: true
  - id: a5f07eb8
    name: ""
    type: namespace
    rule: amazfitwatchfaces.com
    enable: true
  - id: 2a993382
    name: ""
    type: namespace
    rule: amplitude.com
    enable: true
  - id: 667ac0fb
    name: ""
    type: namespace
    rule: analog.com
    enable: true
  - id: 805016fb
    name: ""
    type: namespace
    rule: andrevi.ch
    enable: true
  - id: 5124d5b3
    name: ""
    type: namespace
    rule: ansys.com
    enable: true
  - id: bf01deb4
    name: ""
    type: domain
    rule: anthropic.qualtrics.com
    enable: true
  - id: edb2209d
    name: ""
    type: domain
    rule: api.jetbrains.ai
    enable: true
  - id: af279ac5
    name: ""
    type: domain
    rule: api.themoviedb.org
    enable: true
  - id: 8275ac00
    name: ""
    type: namespace
    rule: arc.net
    enable: true
  - id: d28c8ae5
    name: ""
    type: namespace
    rule: arduino.cc
    enable: true
  - id: 044e71ea
    name: ""
    type: domain
    rule: assets.heroku.com
    enable: true
  - id: 187f5886
    name: ""
    type: namespace
    rule: atlassian.com
    enable: true
  - id: 337c9720
    name: ""
    type: namespace
    rule: att.com
    enable: true
  - id: 3410f974
    name: ""
    type: namespace
    rule: augmentcode.com
    enable: true
  - id: 0ebfe3bb
    name: ""
    type: namespace
    rule: autodesk.com
    enable: true
  - id: 976689ea
    name: ""
    type: domain
    rule: backend-v2.crixet.com
    enable: true
  - id: 912cfdea
    name: ""
    type: namespace
    rule: bell-sw.com
    enable: true
  - id: 3efba041
    name: ""
    type: namespace
    rule: bestbuy.com
    enable: true
  - id: 6b6736ff
    name: ""
    type: namespace
    rule: bitdefender.com
    enable: true
  - id: de6095a0
    name: ""
    type: namespace
    rule: bitnami.com
    enable: true
  - id: 676400c0
    name: ""
    type: namespace
    rule: blinkshot.io
    enable: true
  - id: 75e684d6
    name: ""
    type: namespace
    rule: bosch.com
    enable: true
  - id: 4b33534d
    name: ""
    type: namespace
    rule: boschaftermarket.com
    enable: true
  - id: 40d63787
    name: ""
    type: namespace
    rule: boschautoparts.com
    enable: true
  - id: 11a2af00
    name: ""
    type: namespace
    rule: brawlstarsgame.com
    enable: true
  - id: 97d58163
    name: ""
    type: namespace
    rule: broadcom.com
    enable: true
  - id: 1eb0ba93
    name: ""
    type: namespace
    rule: broncosportforum.com
    enable: true
  - id: 0f30b7f0
    name: ""
    type: namespace
    rule: btod.com
    enable: true
  - id: 2652e758
    name: ""
    type: namespace
    rule: buanzo.org
    enable: true
  - id: 984b3a36
    name: ""
    type: namespace
    rule: buf.build
    enable: true
  - id: 136fd729
    name: ""
    type: domain
    rule: builds.parsec.app
    enable: true
  - id: 8e2acc64
    name: ""
    type: namespace
    rule: buymeacoffee.com
    enable: true
  - id: f5a83e07
    name: ""
    type: namespace
    rule: canva.com
    enable: true
  - id: a347cf37
    name: ""
    type: namespace
    rule: canva.dev
    enable: true
  - id: bc3a8f6c
    name: ""
    type: namespace
    rule: capacitorjs.com
    enable: true
  - id: 4aac3374
    name: ""
    type: namespace
    rule: carrefouruae.com
    enable: true
  - id: 1e6c3ac7
    name: ""
    type: namespace
    rule: cats.com
    enable: true
  - id: 76c34922
    name: ""
    type: domain
    rule: cdn.web-platform.io
    enable: true
  - id: 4062a45d
    name: ""
    type: namespace
    rule: cdromance.org
    enable: true
  - id: bc82608f
    name: ""
    type: namespace
    rule: cdw.com
    enable: true
  - id: d52cb0e3
    name: ""
    type: namespace
    rule: chainreactioncycles.com
    enable: true
  - id: 9c5bacda
    name: ""
    type: namespace
    rule: chaos.com
    enable: true
  - id: 8b23f1b0
    name: ""
    type: namespace
    rule: chat.com
    enable: true
  - id: 7ab9d9c2
    name: ""
    type: domain
    rule: chat.openai.com.cdn.cloudflare.net
    enable: true
  - id: 75220dab
    name: ""
    type: namespace
    rule: cisco.com
    enable: true
  - id: dec8d804
    name: ""
    type: namespace
    rule: cisecurity.org
    enable: true
  - id: 7d1861ff
    name: ""
    type: namespace
    rule: citrix.com
    enable: true
  - id: bd7d947c
    name: ""
    type: namespace
    rule: clamav.net
    enable: true
  - id: c03e6fbf
    name: ""
    type: namespace
    rule: clashofclans.com
    enable: true
  - id: a55111ca
    name: ""
    type: namespace
    rule: clashroyaleapp.com
    enable: true
  - id: f580c7db
    name: ""
    type: namespace
    rule: clevelandclinic.org
    enable: true
  - id: 76a4201f
    name: ""
    type: namespace
    rule: clickup.com
    enable: true
  - id: b3c18dfe
    name: ""
    type: domain
    rule: clip.opus.pro
    enable: true
  - id: c6c87250
    name: ""
    type: domain
    rule: code.gist.build
    enable: true
  - id: 527efc7e
    name: ""
    type: namespace
    rule: coingate.com
    enable: true
  - id: a4491fd2
    name: ""
    type: domain
    rule: community.sophos.com
    enable: true
  - id: da1a190e
    name: ""
    type: domain
    rule: connect.ngrok-agent.com
    enable: true
  - id: 585c4950
    name: ""
    type: namespace
    rule: contabo.com
    enable: true
  - id: f28340dc
    name: ""
    type: namespace
    rule: corsair.com
    enable: true
  - id: 5bad01f2
    name: ""
    type: namespace
    rule: cpu-monkey.com
    enable: true
  - id: fd4f7030
    name: ""
    type: namespace
    rule: credly.com
    enable: true
  - id: b8728a35
    name: ""
    type: namespace
    rule: crunchyroll.com
    enable: true
  - id: 320ffaf5
    name: ""
    type: namespace
    rule: cvedetails.com
    enable: true
  - id: 438eaedb
    name: ""
    type: namespace
    rule: daemon-tools.cc
    enable: true
  - id: d3ef38d4
    name: ""
    type: domain
    rule: dashboard.algolia.com
    enable: true
  - id: 643ed644
    name: ""
    type: domain
    rule: dashboard.gitguardian.com
    enable: true
  - id: baeaee11
    name: ""
    type: domain
    rule: data-cdn.mbamupdates.com
    enable: true
  - id: f1240abf
    name: ""
    type: domain
    rule: data.cline.bot
    enable: true
  - id: 273a31c4
    name: ""
    type: namespace
    rule: deezer.com
    enable: true
  - id: 0114ec95
    name: ""
    type: namespace
    rule: dell.com
    enable: true
  - id: a6cd2fb5
    name: ""
    type: namespace
    rule: dellcdn.com
    enable: true
  - id: a4e7b1a1
    name: ""
    type: namespace
    rule: devexpress.com
    enable: true
  - id: e7f6ec08
    name: ""
    type: namespace
    rule: diabrowser.com
    enable: true
  - id: 25d9d9e1
    name: ""
    type: namespace
    rule: digitalcontent.sky
    enable: true
  - id: 3d90bcf1
    name: ""
    type: namespace
    rule: disctech.com
    enable: true
  - id: eab2be5f
    name: ""
    type: namespace
    rule: disneyplus.com
    enable: true
  - id: 724ed205
    name: ""
    type: domain
    rule: docs.liquibase.com
    enable: true
  - id: 441fcc5a
    name: ""
    type: namespace
    rule: document360.com
    enable: true
  - id: d981d1b8
    name: ""
    type: namespace
    rule: document360.io
    enable: true
  - id: 26b9f56a
    name: ""
    type: domain
    rule: download3.omnissa.com
    enable: true
  - id: aaec9c52
    name: ""
    type: domain
    rule: downloads.intercomcdn.com
    enable: true
  - id: 0b14b7c0
    name: ""
    type: namespace
    rule: ducati.com
    enable: true
  - id: 3cc71b66
    name: ""
    type: namespace
    rule: dyson.com
    enable: true
  - id: af699bd9
    name: ""
    type: namespace
    rule: easydmarc.com
    enable: true
  - id: 8368b2b9
    name: ""
    type: namespace
    rule: editorx.com
    enable: true
  - id: e4ed1f29
    name: ""
    type: namespace
    rule: eneba.com
    enable: true
  - id: c5ee0dc6
    name: ""
    type: namespace
    rule: etsy.com
    enable: true
  - id: 6e6c9cec
    name: ""
    type: domain
    rule: exchanger.bits.media
    enable: true
  - id: a1f4b8e9
    name: ""
    type: namespace
    rule: expandrive.com
    enable: true
  - id: c463e077
    name: ""
    type: namespace
    rule: extremetech.com
    enable: true
  - id: b3167c3d
    name: ""
    type: namespace
    rule: f1.com
    enable: true
  - id: 181e19ab
    name: ""
    type: namespace
    rule: fast.com
    enable: true
  - id: df07a17d
    name: ""
    type: namespace
    rule: filebin.net
    enable: true
  - id: 2cb602f5
    name: ""
    type: domain
    rule: files.manus.cdn
    enable: true
  - id: b80c9b5c
    name: ""
    type: namespace
    rule: fivetran.com
    enable: true
  - id: fb7d7113
    name: ""
    type: namespace
    rule: flir.com
    enable: true
  - id: 55aed5c3
    name: ""
    type: namespace
    rule: flir.eu
    enable: true
  - id: d6eb5bc2
    name: ""
    type: namespace
    rule: flourish.studio
    enable: true
  - id: 529848d3
    name: ""
    type: namespace
    rule: fluke.com
    enable: true
  - id: a7989a30
    name: ""
    type: namespace
    rule: flukenetworks.com
    enable: true
  - id: 1a6b35a4
    name: ""
    type: namespace
    rule: flyertalk.com
    enable: true
  - id: fdb9e787
    name: ""
    type: domain
    rule: footballapi.pulselive.com
    enable: true
  - id: ac3730f6
    name: ""
    type: namespace
    rule: force-user-content.com
    enable: true
  - id: be19357d
    name: ""
    type: namespace
    rule: force.com
    enable: true
  - id: 23f0e512
    name: ""
    type: namespace
    rule: formula1.com
    enable: true
  - id: 61bbdc4e
    name: ""
    type: domain
    rule: forum.netgate.com
    enable: true
  - id: 11f70f5a
    name: ""
    type: namespace
    rule: framer.app
    enable: true
  - id: f86808c0
    name: ""
    type: namespace
    rule: framer.com
    enable: true
  - id: b02b0592
    name: ""
    type: namespace
    rule: framercanvas.com
    enable: true
  - id: 0dd1f16c
    name: ""
    type: namespace
    rule: framercdn.com
    enable: true
  - id: e1848a4e
    name: ""
    type: namespace
    rule: framerstatic.com
    enable: true
  - id: 42573c87
    name: ""
    type: namespace
    rule: framerusercontent.com
    enable: true
  - id: 72c1f9ee
    name: ""
    type: namespace
    rule: freeimages.com
    enable: true
  - id: 499ea0fa
    name: ""
    type: namespace
    rule: fxnetworks.com
    enable: true
  - id: 0e075e28
    name: ""
    type: namespace
    rule: g2a.com
    enable: true
  - id: 65324ff5
    name: ""
    type: namespace
    rule: gamestop.com
    enable: true
  - id: f0a6fec5
    name: ""
    type: domain
    rule: gaming.amazon.com
    enable: true
  - id: 5fe21b93
    name: ""
    type: namespace
    rule: geforcenow.com
    enable: true
  - id: bbb347d4
    name: ""
    type: domain
    rule: geolocation.onetrust.com
    enable: true
  - id: 6f339956
    name: ""
    type: namespace
    rule: getoutline.com
    enable: true
  - id: eb350cbf
    name: ""
    type: namespace
    rule: gfn.am
    enable: true
  - id: b56ff57d
    name: ""
    type: domain
    rule: ghostrc.game.idtech.services
    enable: true
  - id: cdb7f498
    name: ""
    type: domain
    rule: global.fncstatic.com
    enable: true
  - id: 40e4538f
    name: ""
    type: namespace
    rule: glpals.com
    enable: true
  - id: fa83ab13
    name: ""
    type: namespace
    rule: gofund.me
    enable: true
  - id: f1eede96
    name: ""
    type: namespace
    rule: gofundme.com
    enable: true
  - id: 18b32e61
    name: ""
    type: namespace
    rule: gonift.com
    enable: true
  - id: 0b1a0449
    name: ""
    type: namespace
    rule: gpsonextra.net
    enable: true
  - id: df9ef8cd
    name: ""
    type: namespace
    rule: gpu-monkey.com
    enable: true
  - id: 9617044e
    name: ""
    type: domain
    rule: gql.twitch.tv
    enable: true
  - id: 57b05b9a
    name: ""
    type: namespace
    rule: grafana.com
    enable: true
  - id: 7b3a950e
    name: ""
    type: namespace
    rule: graylog.org
    enable: true
  - id: 60e10d15
    name: ""
    type: namespace
    rule: grizzlysms.com
    enable: true
  - id: 36788a56
    name: ""
    type: domain
    rule: grok.x.com
    enable: true
  - id: 2f51527a
    name: ""
    type: namespace
    rule: groupon.com
    enable: true
  - id: 596068a5
    name: ""
    type: namespace
    rule: guilded.gg
    enable: true
  - id: fdd90589
    name: ""
    type: namespace
    rule: habr.com
    enable: true
  - id: 923a46c3
    name: ""
    type: namespace
    rule: hashicorp.com
    enable: true
  - id: "380098e7"
    name: ""
    type: namespace
    rule: haydaygame.com
    enable: true
  - id: c24236d9
    name: ""
    type: namespace
    rule: hbomax.com
    enable: true
  - id: dbfd8022
    name: ""
    type: namespace
    rule: hc-ping.com
    enable: true
  - id: 9c529333
    name: ""
    type: namespace
    rule: hchk.io
    enable: true
  - id: "94e00152"
    name: ""
    type: namespace
    rule: healthline.com
    enable: true
  - id: 041a67ea
    name: ""
    type: namespace
    rule: herokucdn.com
    enable: true
  - id: bbcb4f2e
    name: ""
    type: namespace
    rule: hollisterco.com
    enable: true
  - id: 13cf9cd1
    name: ""
    type: namespace
    rule: home-connect.com
    enable: true
  - id: d1018ec4
    name: ""
    type: domain
    rule: home.by.me
    enable: true
  - id: f62014ad
    name: ""
    type: namespace
    rule: hostinger.com
    enable: true
  - id: 11200dcd
    name: ""
    type: namespace
    rule: hotels.com
    enable: true
  - id: 445d3675
    name: ""
    type: namespace
    rule: housebrand.com
    enable: true
  - id: 2c1bd93f
    name: ""
    type: namespace
    rule: htmhell.dev
    enable: true
  - id: 6c02cf7d
    name: ""
    type: namespace
    rule: httptoolkit.com
    enable: true
  - id: a0c3f26e
    name: ""
    type: namespace
    rule: hybrid-analysis.com
    enable: true
  - id: af4a84a7
    name: ""
    type: namespace
    rule: ibm.com
    enable: true
  - id: b89068ed
    name: ""
    type: namespace
    rule: iedb.org
    enable: true
  - id: dd3182d6
    name: ""
    type: namespace
    rule: iherb.com
    enable: true
  - id: d3b17ef0
    name: ""
    type: domain
    rule: image.tmdb.org
    enable: true
  - id: ebef3d31
    name: ""
    type: namespace
    rule: imgur.com
    enable: true
  - id: 82cd2205
    name: ""
    type: namespace
    rule: indeed.com
    enable: true
  - id: 456172db
    name: ""
    type: namespace
    rule: intel.com
    enable: true
  - id: f182f4fa
    name: ""
    type: namespace
    rule: intel.de
    enable: true
  - id: "71557668"
    name: ""
    type: namespace
    rule: intel.nl
    enable: true
  - id: 0cf46d19
    name: ""
    type: domain
    rule: intelix.sophos.com
    enable: true
  - id: 227a28b0
    name: ""
    type: namespace
    rule: intercom.io
    enable: true
  - id: 3ca5c72e
    name: ""
    type: namespace
    rule: intuit.com
    enable: true
  - id: 0a6a6266
    name: ""
    type: namespace
    rule: intuitibits.com
    enable: true
  - id: abb5dcf7
    name: ""
    type: namespace
    rule: itninja.com
    enable: true
  - id: 11564b29
    name: ""
    type: namespace
    rule: jamf.com
    enable: true
  - id: 5931b09d
    name: ""
    type: namespace
    rule: jetbrains.com
    enable: true
  - id: ab97a174
    name: ""
    type: namespace
    rule: jetbrains.space
    enable: true
  - id: 5c8d2b3a
    name: ""
    type: namespace
    rule: jetbrains.team
    enable: true
  - id: b7f0426a
    name: ""
    type: namespace
    rule: joesandbox.com
    enable: true
  - id: 02a90adb
    name: ""
    type: namespace
    rule: keysight.com
    enable: true
  - id: 960b00d8
    name: ""
    type: namespace
    rule: kinogo.la
    enable: true
  - id: 610d5149
    name: ""
    type: namespace
    rule: klarna.com
    enable: true
  - id: 00d8139e
    name: ""
    type: namespace
    rule: kmail-lists.com
    enable: true
  - id: 78568d93
    name: ""
    type: namespace
    rule: lambdalabs.com
    enable: true
  - id: bd660d16
    name: ""
    type: namespace
    rule: langdock.com
    enable: true
  - id: b90e5e78
    name: ""
    type: namespace
    rule: last.fm
    enable: true
  - id: a166ecaa
    name: ""
    type: namespace
    rule: ldoceonline.com
    enable: true
  - id: 41b61e83
    name: ""
    type: namespace
    rule: legalshield.com
    enable: true
  - id: 53c4b4de
    name: ""
    type: namespace
    rule: lgeapi.com
    enable: true
  - id: 6f75b014
    name: ""
    type: namespace
    rule: lgthinq.com
    enable: true
  - id: d325dea0
    name: ""
    type: namespace
    rule: lidarr.audio
    enable: true
  - id: e4cf3849
    name: ""
    type: namespace
    rule: lifehacker.com
    enable: true
  - id: 7579ab53
    name: ""
    type: namespace
    rule: lightning.ai
    enable: true
  - id: d03f3a3d
    name: ""
    type: namespace
    rule: lyst.com
    enable: true
  - id: 1d78ac6f
    name: ""
    type: namespace
    rule: mailerlite.com
    enable: true
  - id: d3cf23c6
    name: ""
    type: namespace
    rule: mailinator.com
    enable: true
  - id: 1dd0bf30
    name: ""
    type: namespace
    rule: manybooks.net
    enable: true
  - id: 059dca52
    name: ""
    type: namespace
    rule: marvelsnap.com
    enable: true
  - id: 1279f86c
    name: ""
    type: namespace
    rule: mattermost.com
    enable: true
  - id: 6ed3b9b8
    name: ""
    type: namespace
    rule: max.com
    enable: true
  - id: f336ac30
    name: ""
    type: namespace
    rule: medicalnewstoday.com
    enable: true
  - id: c81b7aba
    name: ""
    type: namespace
    rule: meetup.com
    enable: true
  - id: e6fd1e5b
    name: ""
    type: namespace
    rule: metopera.org
    enable: true
  - id: f4abcf6d
    name: ""
    type: namespace
    rule: middlewareinventory.com
    enable: true
  - id: 1ade501a
    name: ""
    type: namespace
    rule: mintmobile.com
    enable: true
  - id: 61e4e932
    name: ""
    type: domain
    rule: miracleptr.wordpress.com
    enable: true
  - id: c48c83c0
    name: ""
    type: namespace
    rule: mixcloud.com
    enable: true
  - id: ba260183
    name: ""
    type: namespace
    rule: monoprice.com
    enable: true
  - id: 2545f9e6
    name: ""
    type: namespace
    rule: mouser.com
    enable: true
  - id: 0cf06fa6
    name: ""
    type: namespace
    rule: mouser.fi
    enable: true
  - id: 96810c26
    name: ""
    type: namespace
    rule: mssg.me
    enable: true
  - id: e3ff0e2f
    name: ""
    type: namespace
    rule: multisim.com
    enable: true
  - id: b16a5277
    name: ""
    type: namespace
    rule: myheritage.com
    enable: true
  - id: 0e027d0e
    name: ""
    type: namespace
    rule: myjetbrains.com
    enable: true
  - id: 8bef78d8
    name: ""
    type: namespace
    rule: myparallels.com
    enable: true
  - id: 0ddd7f60
    name: ""
    type: namespace
    rule: myqrcode.com
    enable: true
  - id: 2d14ffe9
    name: ""
    type: namespace
    rule: nba.com
    enable: true
  - id: 9315b8fd
    name: ""
    type: namespace
    rule: neo4j.com
    enable: true
  - id: 01d36721
    name: ""
    type: namespace
    rule: netacad.com
    enable: true
  - id: 9903c32b
    name: ""
    type: namespace
    rule: netapp.com
    enable: true
  - id: 8da05e60
    name: ""
    type: namespace
    rule: netflix.ca
    enable: true
  - id: aca24fe9
    name: ""
    type: namespace
    rule: netflix.com
    enable: true
  - id: 6a063331
    name: ""
    type: namespace
    rule: netflix.net
    enable: true
  - id: 689f62e5
    name: ""
    type: namespace
    rule: netflixinvestor.com
    enable: true
  - id: df23ba8b
    name: ""
    type: namespace
    rule: netflixtechblog.com
    enable: true
  - id: fdd4186d
    name: ""
    type: namespace
    rule: netlify.com
    enable: true
  - id: a41c7650
    name: ""
    type: domain
    rule: new.abb.com
    enable: true
  - id: b2d2799c
    name: ""
    type: namespace
    rule: newark.com
    enable: true
  - id: edcaa55d
    name: ""
    type: domain
    rule: newsroom.porsche.com
    enable: true
  - id: 316c9805
    name: ""
    type: namespace
    rule: nfl.com
    enable: true
  - id: e6de8648
    name: ""
    type: namespace
    rule: nflxext.com
    enable: true
  - id: 6b38fd84
    name: ""
    type: namespace
    rule: nflximg.com
    enable: true
  - id: b46e484c
    name: ""
    type: namespace
    rule: nflximg.net
    enable: true
  - id: 188718d5
    name: ""
    type: namespace
    rule: nflxsearch.net
    enable: true
  - id: ec7986e6
    name: ""
    type: namespace
    rule: nflxso.net
    enable: true
  - id: 4213b4cf
    name: ""
    type: namespace
    rule: nflxvideo.net
    enable: true
  - id: 3da361fb
    name: ""
    type: namespace
    rule: ngrok.com
    enable: true
  - id: c545d186
    name: ""
    type: namespace
    rule: ni.com
    enable: true
  - id: 7dc7b2f8
    name: ""
    type: namespace
    rule: nike.com
    enable: true
  - id: 510b97ae
    name: ""
    type: namespace
    rule: nitropdf.com
    enable: true
  - id: 743c1e68
    name: ""
    type: namespace
    rule: nordaccount.com
    enable: true
  - id: 1121834e
    name: ""
    type: namespace
    rule: nordcdn.com
    enable: true
  - id: 4e8e9000
    name: ""
    type: namespace
    rule: nordvpn.com
    enable: true
  - id: f5225036
    name: ""
    type: domain
    rule: notion-emojis.s3-us-west-2.amazonaws.com
    enable: true
  - id: 9079c2d3
    name: ""
    type: namespace
    rule: notion-static.com
    enable: true
  - id: db4ec0da
    name: ""
    type: namespace
    rule: notion.com
    enable: true
  - id: 80aa9350
    name: ""
    type: namespace
    rule: notion.new
    enable: true
  - id: 8f99998e
    name: ""
    type: namespace
    rule: notion.site
    enable: true
  - id: 9c3e2eba
    name: ""
    type: namespace
    rule: notion.so
    enable: true
  - id: d9469fc0
    name: ""
    type: domain
    rule: ntp.msn.com
    enable: true
  - id: 8218b946
    name: ""
    type: namespace
    rule: nxp.com
    enable: true
  - id: 19e0d9d1
    name: ""
    type: namespace
    rule: ocstore.com
    enable: true
  - id: 98a142dc
    name: ""
    type: namespace
    rule: octopus.do
    enable: true
  - id: 204bb613
    name: ""
    type: namespace
    rule: omnissa.com
    enable: true
  - id: 9989fbbc
    name: ""
    type: namespace
    rule: onfastspring.com
    enable: true
  - id: f8727e2b
    name: ""
    type: namespace
    rule: onshape.com
    enable: true
  - id: a116b578
    name: ""
    type: namespace
    rule: openh264.org
    enable: true
  - id: 755b0852
    name: ""
    type: namespace
    rule: oracle.com
    enable: true
  - id: 85663fa2
    name: ""
    type: namespace
    rule: oraclecloud.com
    enable: true
  - id: d444ab1d
    name: ""
    type: namespace
    rule: paddle.com
    enable: true
  - id: 6d1b4570
    name: ""
    type: namespace
    rule: paddlestatus.com
    enable: true
  - id: fb32f269
    name: ""
    type: namespace
    rule: pandasecurity.com
    enable: true
  - id: 1bee5713
    name: ""
    type: namespace
    rule: parallels.cn
    enable: true
  - id: f8db75e0
    name: ""
    type: namespace
    rule: parallels.com
    enable: true
  - id: e73cbe55
    name: ""
    type: namespace
    rule: parallels.net
    enable: true
  - id: db95e6db
    name: ""
    type: namespace
    rule: parallelsaccess.com
    enable: true
  - id: 55dd21c0
    name: ""
    type: namespace
    rule: paritydeals.com
    enable: true
  - id: f2302355
    name: ""
    type: namespace
    rule: patreon.com
    enable: true
  - id: 9d932710
    name: ""
    type: namespace
    rule: patreonusercontent.com
    enable: true
  - id: f28336cb
    name: ""
    type: namespace
    rule: paywithmoon.com
    enable: true
  - id: eb5e4e82
    name: ""
    type: namespace
    rule: pcgamesn.com
    enable: true
  - id: d0f680f1
    name: ""
    type: namespace
    rule: pcmag.com
    enable: true
  - id: eab555f3
    name: ""
    type: namespace
    rule: penguin.com
    enable: true
  - id: 34d4eb17
    name: ""
    type: namespace
    rule: penguinrandomhouse.com
    enable: true
  - id: 783fbbc2
    name: ""
    type: namespace
    rule: pexels.com
    enable: true
  - id: 5a9e7f8e
    name: ""
    type: namespace
    rule: philiascans.org
    enable: true
  - id: "34104025"
    name: ""
    type: namespace
    rule: pingdom.com
    enable: true
  - id: 1f611e48
    name: ""
    type: domain
    rule: pkgs.tailscale.com
    enable: true
  - id: f85a8bad
    name: ""
    type: domain
    rule: platform.activestate.com
    enable: true
  - id: 8668abce
    name: ""
    type: namespace
    rule: plugshare.com
    enable: true
  - id: 816726ff
    name: ""
    type: namespace
    rule: posthog.com
    enable: true
  - id: 7f21838c
    name: ""
    type: namespace
    rule: premierleague.com
    enable: true
  - id: b3ab6ad9
    name: ""
    type: namespace
    rule: primark.com
    enable: true
  - id: 7ca3dbc5
    name: ""
    type: namespace
    rule: primevideo.com
    enable: true
  - id: e7a69ad5
    name: ""
    type: domain
    rule: production-openaicom-storage.azureedge.net
    enable: true
  - id: a7b3ec0e
    name: ""
    type: namespace
    rule: profitwell.com
    enable: true
  - id: ccbfd165
    name: ""
    type: namespace
    rule: prowlarr.com
    enable: true
  - id: a03db71b
    name: ""
    type: domain
    rule: public.parsec.app
    enable: true
  - id: 5b280d89
    name: ""
    type: namespace
    rule: qobuz.com
    enable: true
  - id: d52cb416
    name: ""
    type: namespace
    rule: qodana.cloud
    enable: true
  - id: 92a74faf
    name: ""
    type: namespace
    rule: qoder.com
    enable: true
  - id: 538d7122
    name: ""
    type: namespace
    rule: qt.io
    enable: true
  - id: e3447194
    name: ""
    type: namespace
    rule: qualcomm.com
    enable: true
  - id: 3bec799f
    name: ""
    type: namespace
    rule: quicknode.com
    enable: true
  - id: ddbb1798
    name: ""
    type: namespace
    rule: qwant.com
    enable: true
  - id: fbc201c6
    name: ""
    type: namespace
    rule: reactflow.dev
    enable: true
  - id: f9c4ec1c
    name: ""
    type: namespace
    rule: recraft.ai
    enable: true
  - id: 0df79700
    name: ""
    type: namespace
    rule: redis.io
    enable: true
  - id: 0b1f4857
    name: ""
    type: namespace
    rule: redislabs.com
    enable: true
  - id: 854257fb
    name: ""
    type: namespace
    rule: remna.st
    enable: true
  - id: 5048362d
    name: ""
    type: namespace
    rule: remove.bg
    enable: true
  - id: 27440b41
    name: ""
    type: namespace
    rule: research.net
    enable: true
  - id: 3b1ba77d
    name: ""
    type: namespace
    rule: salesforce-experience.com
    enable: true
  - id: d0ed3fd8
    name: ""
    type: namespace
    rule: salesforce-hub.com
    enable: true
  - id: ea3dcaaf
    name: ""
    type: namespace
    rule: salesforce-scrt.com
    enable: true
  - id: d69bdc63
    name: ""
    type: namespace
    rule: salesforce-setup.com
    enable: true
  - id: 6810b54c
    name: ""
    type: namespace
    rule: salesforce-sites.com
    enable: true
  - id: 64aa15eb
    name: ""
    type: namespace
    rule: salesforce.com
    enable: true
  - id: f7462f45
    name: ""
    type: namespace
    rule: salesforceiq.com
    enable: true
  - id: 05b77802
    name: ""
    type: namespace
    rule: salesforceliveagent.com
    enable: true
  - id: "61752125"
    name: ""
    type: namespace
    rule: schneider-electric.com
    enable: true
  - id: 8a8a7243
    name: ""
    type: namespace
    rule: sdxcentral.com
    enable: true
  - id: 4af89391
    name: ""
    type: namespace
    rule: se.com
    enable: true
  - id: 6ce619dc
    name: ""
    type: namespace
    rule: seconddinnertech.com
    enable: true
  - id: 4a79d12e
    name: ""
    type: namespace
    rule: semrush.com
    enable: true
  - id: e6561946
    name: ""
    type: namespace
    rule: sentry.dev
    enable: true
  - id: 189f6df6
    name: ""
    type: namespace
    rule: sentry.io
    enable: true
  - id: 4b7649b8
    name: ""
    type: namespace
    rule: sephora.com
    enable: true
  - id: 23bca140
    name: ""
    type: namespace
    rule: servarr.com
    enable: true
  - id: 4aacb589
    name: ""
    type: namespace
    rule: sfdcopens.com
    enable: true
  - id: d76b842f
    name: ""
    type: namespace
    rule: sharefile.com
    enable: true
  - id: 93fa2db5
    name: ""
    type: namespace
    rule: sharefile.io
    enable: true
  - id: 18aa564f
    name: ""
    type: domain
    rule: shinyhardware.co.uk
    enable: true
  - id: df534d09
    name: ""
    type: domain
    rule: shop.gameloft.com
    enable: true
  - id: ab30d222
    name: ""
    type: namespace
    rule: sigsauer.com
    enable: true
  - id: 442757a8
    name: ""
    type: namespace
    rule: singlekey-id.com
    enable: true
  - id: 2dc31449
    name: ""
    type: namespace
    rule: site.com
    enable: true
  - id: 40d95ad1
    name: ""
    type: namespace
    rule: siteground.com
    enable: true
  - id: cde109fd
    name: ""
    type: namespace
    rule: sketchup.com
    enable: true
  - id: af2987b9
    name: ""
    type: namespace
    rule: sky.com
    enable: true
  - id: 6cec86a2
    name: ""
    type: namespace
    rule: skycdp.com
    enable: true
  - id: dd81daed
    name: ""
    type: namespace
    rule: smartbear.co
    enable: true
  - id: 5385ccfb
    name: ""
    type: namespace
    rule: smartbear.com
    enable: true
  - id: 0c41b6bb
    name: ""
    type: namespace
    rule: smartdeploy.com
    enable: true
  - id: c6fc6cc8
    name: ""
    type: namespace
    rule: snapgametech.com
    enable: true
  - id: f31bc316
    name: ""
    type: namespace
    rule: snapgene.com
    enable: true
  - id: 8d3ccf04
    name: ""
    type: namespace
    rule: snort.org
    enable: true
  - id: f0776eec
    name: ""
    type: namespace
    rule: snyk.io
    enable: true
  - id: c4a7bdf3
    name: ""
    type: namespace
    rule: solarwinds.com
    enable: true
  - id: 59dfedab
    name: ""
    type: namespace
    rule: sonara.ai
    enable: true
  - id: 7f1609d8
    name: ""
    type: namespace
    rule: spacelift.io
    enable: true
  - id: 6709f706
    name: ""
    type: namespace
    rule: spiceworks.com
    enable: true
  - id: c94014a2
    name: ""
    type: namespace
    rule: spitfireaudio.com
    enable: true
  - id: 5b874c0d
    name: ""
    type: namespace
    rule: spotify.com
    enable: true
  - id: 9a619921
    name: ""
    type: namespace
    rule: squadbustersgame.com
    enable: true
  - id: 62038b52
    name: ""
    type: namespace
    rule: squareup.com
    enable: true
  - id: 7ec401e0
    name: ""
    type: namespace
    rule: streamable.com
    enable: true
  - id: e5a30119
    name: ""
    type: namespace
    rule: supercell.com
    enable: true
  - id: fe68edaa
    name: ""
    type: domain
    rule: support.anydesk.com
    enable: true
  - id: c9abe0ef
    name: ""
    type: domain
    rule: support.xerox.com
    enable: true
  - id: e24102cc
    name: ""
    type: namespace
    rule: surveymonkey.com
    enable: true
  - id: 96732c52
    name: ""
    type: namespace
    rule: swagger.io
    enable: true
  - id: b207f7c0
    name: ""
    type: namespace
    rule: swapd.co
    enable: true
  - id: 742242aa
    name: ""
    type: namespace
    rule: synoforum.com
    enable: true
  - id: 707bca0c
    name: ""
    type: namespace
    rule: syslog-ng.com
    enable: true
  - id: eef27e8a
    name: ""
    type: namespace
    rule: tableau.com
    enable: true
  - id: 784ec4d7
    name: ""
    type: namespace
    rule: talosintelligence.com
    enable: true
  - id: f615c3db
    name: ""
    type: namespace
    rule: techbargains.com
    enable: true
  - id: 2d52cb7d
    name: ""
    type: namespace
    rule: telemetr.io
    enable: true
  - id: 97c04aa5
    name: ""
    type: namespace
    rule: tempmail.plus
    enable: true
  - id: 36378b2f
    name: ""
    type: namespace
    rule: terraform.io
    enable: true
  - id: 505b6b16
    name: ""
    type: namespace
    rule: theaudiodb.com
    enable: true
  - id: 345ddba9
    name: ""
    type: namespace
    rule: themoviedb.org
    enable: true
  - id: f2006209
    name: ""
    type: namespace
    rule: ti.com
    enable: true
  - id: a56c179a
    name: ""
    type: namespace
    rule: tidal.com
    enable: true
  - id: f62612a7
    name: ""
    type: namespace
    rule: timberland.de
    enable: true
  - id: c61375e2
    name: ""
    type: domain
    rule: tmdb-image-prod.b-cdn.net
    enable: true
  - id: 1fa77bab
    name: ""
    type: namespace
    rule: tmdb.com
    enable: true
  - id: feac407d
    name: ""
    type: namespace
    rule: tmdb.org
    enable: true
  - id: 7894090f
    name: ""
    type: namespace
    rule: toolbox.app
    enable: true
  - id: ded87780
    name: ""
    type: namespace
    rule: torrenteditor.com
    enable: true
  - id: cdd20624
    name: ""
    type: namespace
    rule: trailblazer.me
    enable: true
  - id: 658f280e
    name: ""
    type: namespace
    rule: trailhead.com
    enable: true
  - id: 3c84a575
    name: ""
    type: namespace
    rule: transferwise.com
    enable: true
  - id: ddb4aae6
    name: ""
    type: namespace
    rule: truthsocial.com
    enable: true
  - id: 4f2d352e
    name: ""
    type: namespace
    rule: tsmc.com
    enable: true
  - id: 6f112e36
    name: ""
    type: namespace
    rule: tutanota.com
    enable: true
  - id: c032b13a
    name: ""
    type: namespace
    rule: typing.com
    enable: true
  - id: 1ee58464
    name: ""
    type: namespace
    rule: uaudio.com
    enable: true
  - id: e4992e93
    name: ""
    type: namespace
    rule: uizard.io
    enable: true
  - id: bcdbca4d
    name: ""
    type: namespace
    rule: unscreen.com
    enable: true
  - id: 43ed5b18
    name: ""
    type: namespace
    rule: upwork.com
    enable: true
  - id: 25ae593a
    name: ""
    type: domain
    rule: usher.ttvnw.net
    enable: true
  - id: edfb19ad
    name: ""
    type: domain
    rule: v.vrv.co
    enable: true
  - id: 7ff72ac8
    name: ""
    type: namespace
    rule: vagrantcloud.com
    enable: true
  - id: f648bd27
    name: ""
    type: namespace
    rule: veeam.com
    enable: true
  - id: 450f9a0a
    name: ""
    type: namespace
    rule: verificationacademy.com
    enable: true
  - id: bbe378b2
    name: ""
    type: namespace
    rule: vmware.com
    enable: true
  - id: 2df6d549
    name: ""
    type: domain
    rule: vod-fy.crunchyrollcdn.com
    enable: true
  - id: e2d96223
    name: ""
    type: namespace
    rule: volkswagen-classic-parts.com
    enable: true
  - id: 50bf189f
    name: ""
    type: namespace
    rule: vyos.io
    enable: true
  - id: 8b961e38
    name: ""
    type: domain
    rule: w.atwiki.jp
    enable: true
  - id: 9c903526
    name: ""
    type: namespace
    rule: walmart.com
    enable: true
  - id: 95d2a5fb
    name: ""
    type: namespace
    rule: watchguard.com
    enable: true
  - id: 75553dff
    name: ""
    type: namespace
    rule: watermarkremover.io
    enable: true
  - id: 1d0a442b
    name: ""
    type: namespace
    rule: wdfiles.com
    enable: true
  - id: 05b8c6f8
    name: ""
    type: namespace
    rule: weather.com
    enable: true
  - id: "96668223"
    name: ""
    type: namespace
    rule: webnames.ca
    enable: true
  - id: 8ca65f0a
    name: ""
    type: namespace
    rule: weebly.com
    enable: true
  - id: 9ff4033f
    name: ""
    type: namespace
    rule: wetransfer.com
    enable: true
  - id: 487f13fa
    name: ""
    type: namespace
    rule: widgetapp.stream
    enable: true
  - id: 9e7e86d7
    name: ""
    type: namespace
    rule: wikidot.com
    enable: true
  - id: b81e0415
    name: ""
    type: namespace
    rule: wise.com
    enable: true
  - id: 56b22f08
    name: ""
    type: namespace
    rule: wpengine.com
    enable: true
  - id: 532b8e54
    name: ""
    type: namespace
    rule: wunderground.com
    enable: true
  - id: e491f796
    name: ""
    type: domain
    rule: www3.corsair.com
    enable: true
  - id: 225c0853
    name: ""
    type: namespace
    rule: x-minus.pro
    enable: true
  - id: 2a9589e9
    name: ""
    type: namespace
    rule: xiaomi.eu
    enable: true
  - id: 40e7e3ed
    name: ""
    type: namespace
    rule: xrite.com
    enable: true
  - id: 08c988fb
    name: ""
    type: domain
    rule: xsts.auth.xboxlive.com
    enable: true
  - id: 1d672017
    name: ""
    type: namespace
    rule: xtracloud.net
    enable: true
  - id: 7bc78c3d
    name: ""
    type: namespace
    rule: yeggi.com
    enable: true
  - id: 9ff04cdd
    name: ""
    type: namespace
    rule: youtrack.cloud
    enable: true
  - id: 97ed4864
    name: ""
    type: namespace
    rule: zapier.com
    enable: true
  - id: f121f4c7
    name: ""
    type: namespace
    rule: zedge.net
    enable: true
  - id: b239749f
    name: ""
    type: namespace
    rule: zerossl.com
    enable: true
- id: 39ad29b8
  name: Hdrezka
  color: '#d1f254'
  interface: Mihomo
  enable: true
  rules:
  - id: 4b64e745
    name: ""
    type: namespace
    rule: hd-rezka.tv
    enable: true
  - id: f7f9751c
    name: ""
    type: namespace
    rule: hdrezka.ac
    enable: true
  - id: b410ad73
    name: ""
    type: namespace
    rule: hdrezka.ag
    enable: true
  - id: ed284223
    name: ""
    type: namespace
    rule: hdrezka.app
    enable: true
  - id: ab2d7b46
    name: ""
    type: namespace
    rule: hdrezka.me
    enable: true
  - id: 0e6fbb5d
    name: ""
    type: namespace
    rule: hdrezka.tech
    enable: true
  - id: b456dfbc
    name: ""
    type: namespace
    rule: hdrezka.tv
    enable: true
  - id: a1f5e539
    name: ""
    type: namespace
    rule: hdrzk.org
    enable: true
  - id: 0ab6aa40
    name: ""
    type: namespace
    rule: rezka-ua.in
    enable: true
  - id: b33f9e35
    name: ""
    type: namespace
    rule: rezka.ag
    enable: true
  - id: fa96e0d2
    name: ""
    type: namespace
    rule: rezka.cc
    enable: true
  - id: 4273f08a
    name: ""
    type: namespace
    rule: rezka.fi
    enable: true
  - id: 71c58893
    name: ""
    type: namespace
    rule: rezka.land
    enable: true
  - id: db8f4157
    name: ""
    type: namespace
    rule: rezka.my
    enable: true
  - id: 6caebfa3
    name: ""
    type: namespace
    rule: rezka.tv
    enable: true
  - id: 5fd1fdbd
    name: ""
    type: namespace
    rule: rezkify.com
    enable: true
  - id: cd4aba78
    name: ""
    type: namespace
    rule: voidboost.cc
    enable: true
- id: 1b61d661
  name: Hetzner
  color: '#54a3f2'
  interface: Mihomo
  enable: true
  rules:
  - id: ba9b3a30
    name: ""
    type: subnet
    rule: 116.202.0.0/15
    enable: true
  - id: 5a987a04
    name: ""
    type: subnet
    rule: 128.140.0.0/17
    enable: true
  - id: 305abe8c
    name: ""
    type: subnet
    rule: 135.181.0.0/16
    enable: true
  - id: 3058f5e6
    name: ""
    type: subnet
    rule: 136.243.0.0/16
    enable: true
  - id: 12ca3755
    name: ""
    type: subnet
    rule: 138.199.128.0/17
    enable: true
  - id: ddb0106d
    name: ""
    type: subnet
    rule: 138.201.0.0/16
    enable: true
  - id: e8db9120
    name: ""
    type: subnet
    rule: 142.132.128.0/17
    enable: true
  - id: 1e85f5c5
    name: ""
    type: subnet
    rule: 144.76.0.0/16
    enable: true
  - id: 3ebde26c
    name: ""
    type: subnet
    rule: 148.251.0.0/16
    enable: true
  - id: 77097b13
    name: ""
    type: subnet
    rule: 157.180.0.0/17
    enable: true
  - id: a5b0b1d7
    name: ""
    type: subnet
    rule: 157.90.0.0/16
    enable: true
  - id: 63d06e40
    name: ""
    type: subnet
    rule: 159.69.0.0/16
    enable: true
  - id: c7a753d1
    name: ""
    type: subnet
    rule: 162.55.0.0/16
    enable: true
  - id: 326be6d8
    name: ""
    type: subnet
    rule: 167.233.0.0/16
    enable: true
  - id: 1d0e4270
    name: ""
    type: subnet
    rule: 167.235.0.0/16
    enable: true
  - id: a9f2c22c
    name: ""
    type: subnet
    rule: 168.119.0.0/16
    enable: true
  - id: 2db2829e
    name: ""
    type: subnet
    rule: 171.25.225.0/24
    enable: true
  - id: 24bd11cf
    name: ""
    type: subnet
    rule: 176.9.0.0/16
    enable: true
  - id: 3829eafa
    name: ""
    type: subnet
    rule: 178.104.0.0/15
    enable: true
  - id: f7328873
    name: ""
    type: subnet
    rule: 178.212.75.0/24
    enable: true
  - id: 403b9064
    name: ""
    type: subnet
    rule: 178.63.0.0/16
    enable: true
  - id: "46490195"
    name: ""
    type: subnet
    rule: 185.107.52.0/22
    enable: true
  - id: da8a8049
    name: ""
    type: subnet
    rule: 185.12.65.0/24
    enable: true
  - id: "56330573"
    name: ""
    type: subnet
    rule: 185.126.28.0/22
    enable: true
  - id: d60f0abb
    name: ""
    type: subnet
    rule: 185.157.176.0/22
    enable: true
  - id: "413015e7"
    name: ""
    type: subnet
    rule: 185.157.83.0/24
    enable: true
  - id: 0b0eb748
    name: ""
    type: subnet
    rule: 185.171.224.0/22
    enable: true
  - id: 8e3cdfec
    name: ""
    type: subnet
    rule: 185.189.228.0/22
    enable: true
  - id: cf15efe5
    name: ""
    type: subnet
    rule: 185.213.45.0/24
    enable: true
  - id: cc768faf
    name: ""
    type: subnet
    rule: 185.216.237.0/24
    enable: true
  - id: d8ae2f49
    name: ""
    type: subnet
    rule: 185.226.99.0/24
    enable: true
  - id: efeab43f
    name: ""
    type: subnet
    rule: 185.228.8.0/23
    enable: true
  - id: f66ec915
    name: ""
    type: subnet
    rule: 185.50.120.0/23
    enable: true
  - id: 04017fae
    name: ""
    type: subnet
    rule: 188.245.0.0/16
    enable: true
  - id: 379b97dd
    name: ""
    type: subnet
    rule: 188.34.128.0/17
    enable: true
  - id: dc708da7
    name: ""
    type: subnet
    rule: 188.40.0.0/16
    enable: true
  - id: 701952a6
    name: ""
    type: subnet
    rule: 193.105.82.0/24
    enable: true
  - id: 69ebb617
    name: ""
    type: subnet
    rule: 193.110.6.0/23
    enable: true
  - id: c0450a39
    name: ""
    type: subnet
    rule: 193.163.198.0/24
    enable: true
  - id: 5ed44487
    name: ""
    type: subnet
    rule: 194.42.180.0/22
    enable: true
  - id: d2c9086e
    name: ""
    type: subnet
    rule: 194.42.184.0/22
    enable: true
  - id: 2f458d20
    name: ""
    type: subnet
    rule: 194.62.106.0/24
    enable: true
  - id: f9890181
    name: ""
    type: subnet
    rule: 195.201.0.0/16
    enable: true
  - id: 08fa9b10
    name: ""
    type: subnet
    rule: 195.248.224.0/24
    enable: true
  - id: 453b8892
    name: ""
    type: subnet
    rule: 195.60.226.0/24
    enable: true
  - id: e876652b
    name: ""
    type: subnet
    rule: 197.242.84.0/22
    enable: true
  - id: 7941bf83
    name: ""
    type: subnet
    rule: 2.28.0.0/15
    enable: true
  - id: 0fd6f414
    name: ""
    type: subnet
    rule: 201.131.3.0/24
    enable: true
  - id: b27b3ab1
    name: ""
    type: subnet
    rule: 204.168.128.0/17
    enable: true
  - id: cf06fc1d
    name: ""
    type: subnet
    rule: 204.29.146.0/24
    enable: true
  - id: 78e5232a
    name: ""
    type: subnet
    rule: 213.133.96.0/19
    enable: true
  - id: 26aacae6
    name: ""
    type: subnet
    rule: 213.239.192.0/18
    enable: true
  - id: 927414ce
    name: ""
    type: subnet
    rule: 216.55.108.0/22
    enable: true
  - id: 93cf4ad2
    name: ""
    type: subnet
    rule: 23.88.0.0/17
    enable: true
  - id: 259777a1
    name: ""
    type: subnet6
    rule: 2a01:4f8::/31
    enable: true
  - id: a21a8482
    name: ""
    type: subnet6
    rule: 2a01:4ff:ff01::/48
    enable: true
  - id: 222e8e1b
    name: ""
    type: subnet6
    rule: 2a06:be80::/29
    enable: true
  - id: fe096659
    name: ""
    type: subnet6
    rule: 2a12:2240::/29
    enable: true
  - id: 0837067c
    name: ""
    type: subnet
    rule: 31.58.88.0/24
    enable: true
  - id: 817f4dbb
    name: ""
    type: subnet
    rule: 37.27.0.0/16
    enable: true
  - id: 12e12dd1
    name: ""
    type: subnet
    rule: 45.145.227.0/24
    enable: true
  - id: 3ba22542
    name: ""
    type: subnet
    rule: 45.15.99.0/24
    enable: true
  - id: bf79defa
    name: ""
    type: subnet
    rule: 46.224.0.0/15
    enable: true
  - id: 13b58d68
    name: ""
    type: subnet
    rule: 46.4.0.0/16
    enable: true
  - id: b6f611d8
    name: ""
    type: subnet
    rule: 46.62.128.0/17
    enable: true
  - id: aef4ad0e
    name: ""
    type: subnet
    rule: 49.12.0.0/15
    enable: true
  - id: 483c4f6a
    name: ""
    type: subnet
    rule: 5.75.128.0/17
    enable: true
  - id: b3bfd81f
    name: ""
    type: subnet
    rule: 5.9.0.0/16
    enable: true
  - id: ebeec245
    name: ""
    type: subnet
    rule: 62.238.0.0/17
    enable: true
  - id: 6f511ec8
    name: ""
    type: subnet
    rule: 65.108.0.0/15
    enable: true
  - id: c7085085
    name: ""
    type: subnet
    rule: 65.21.0.0/16
    enable: true
  - id: d07cf8e1
    name: ""
    type: subnet
    rule: 77.42.0.0/17
    enable: true
  - id: a97d80e3
    name: ""
    type: subnet
    rule: 78.138.62.0/24
    enable: true
  - id: 9d530c62
    name: ""
    type: subnet
    rule: 78.46.0.0/15
    enable: true
  - id: ab1fe82f
    name: ""
    type: subnet
    rule: 85.10.192.0/18
    enable: true
  - id: d072be0d
    name: ""
    type: subnet
    rule: 85.93.20.0/24
    enable: true
  - id: 04c65033
    name: ""
    type: subnet
    rule: 88.198.0.0/16
    enable: true
  - id: 528b2fb6
    name: ""
    type: subnet
    rule: 88.99.0.0/16
    enable: true
  - id: 33c0aa94
    name: ""
    type: subnet
    rule: 89.167.0.0/17
    enable: true
  - id: a0203a96
    name: ""
    type: subnet
    rule: 91.107.128.0/17
    enable: true
  - id: 2b48e028
    name: ""
    type: subnet
    rule: 91.190.240.0/21
    enable: true
  - id: a4a8551c
    name: ""
    type: subnet
    rule: 91.98.0.0/15
    enable: true
  - id: e9c4073e
    name: ""
    type: subnet
    rule: 94.130.0.0/16
    enable: true
  - id: be26fbbb
    name: ""
    type: subnet
    rule: 95.216.0.0/15
    enable: true
  - id: 45ab51ba
    name: ""
    type: namespace
    rule: hetzner.com
    enable: true
- id: 551c9217
  name: Hodca
  color: '#f25475'
  interface: Mihomo
  enable: true
  rules:
  - id: "56337787"
    name: ""
    type: namespace
    rule: 3os.org
    enable: true
  - id: e7dd0da1
    name: ""
    type: namespace
    rule: acclaimedvideogames.com
    enable: true
  - id: d4db1f7b
    name: ""
    type: namespace
    rule: adbappcontrol.com
    enable: true
  - id: e7e45044
    name: ""
    type: namespace
    rule: ajay.app
    enable: true
  - id: "00358718"
    name: ""
    type: namespace
    rule: allawnos.com
    enable: true
  - id: 452d8c72
    name: ""
    type: namespace
    rule: alterportal.net
    enable: true
  - id: 6aaebe6f
    name: ""
    type: namespace
    rule: amazon.com
    enable: true
  - id: e6941f12
    name: ""
    type: namespace
    rule: amazonaws.com
    enable: true
  - id: 9cc5efac
    name: ""
    type: namespace
    rule: aniliberty.top
    enable: true
  - id: c12d6466
    name: ""
    type: namespace
    rule: archlinux.org
    enable: true
  - id: 34d7a308
    name: ""
    type: namespace
    rule: armbian.com
    enable: true
  - id: 637f74a0
    name: ""
    type: namespace
    rule: armbian.de
    enable: true
  - id: 127afb3b
    name: ""
    type: namespace
    rule: artixlinux.org
    enable: true
  - id: 6c16d517
    name: ""
    type: namespace
    rule: artstation.com
    enable: true
  - id: a1cb3631
    name: ""
    type: namespace
    rule: beamng.com
    enable: true
  - id: 2093d5ee
    name: ""
    type: namespace
    rule: beatmods.com
    enable: true
  - id: 47ff1c18
    name: ""
    type: namespace
    rule: beatsaver.com
    enable: true
  - id: a4f3eb29
    name: ""
    type: namespace
    rule: bitbucket.org
    enable: true
  - id: 24637b4c
    name: ""
    type: namespace
    rule: bitru.org
    enable: true
  - id: f37d12fb
    name: ""
    type: namespace
    rule: bitvise.com
    enable: true
  - id: c266da84
    name: ""
    type: namespace
    rule: blackhatworld.com
    enable: true
  - id: be482821
    name: ""
    type: namespace
    rule: britishcouncil.org
    enable: true
  - id: f7f21729
    name: ""
    type: namespace
    rule: bsmanager.io
    enable: true
  - id: d4e471a8
    name: ""
    type: namespace
    rule: callfilter.app
    enable: true
  - id: 96cf6048
    name: ""
    type: namespace
    rule: capcut.com
    enable: true
  - id: 701f4685
    name: ""
    type: namespace
    rule: capcutapi.com
    enable: true
  - id: 413d67ab
    name: ""
    type: namespace
    rule: capcutstatic.com
    enable: true
  - id: 048b7ea4
    name: ""
    type: namespace
    rule: capcutvod.com
    enable: true
  - id: 9e8dec7c
    name: ""
    type: domain
    rule: cdn-lfs-eu-1.hf.co
    enable: true
  - id: 0a9bf35b
    name: ""
    type: domain
    rule: cdn-lfs-us-1.hf.co
    enable: true
  - id: 749049b4
    name: ""
    type: domain
    rule: cdn-lfs.hf.co
    enable: true
  - id: ef691a3d
    name: ""
    type: domain
    rule: cdn-lfs.huggingface.co
    enable: true
  - id: a713a904
    name: ""
    type: namespace
    rule: cdn-service.space
    enable: true
  - id: 3a1dec64
    name: ""
    type: domain
    rule: cdn.embedly.com
    enable: true
  - id: a09cdf0f
    name: ""
    type: domain
    rule: cdn.polyhaven.com
    enable: true
  - id: 5bb69426
    name: ""
    type: domain
    rule: cdn.web-global.fds.api.mi-img.com
    enable: true
  - id: 748dccda
    name: ""
    type: namespace
    rule: check-host.net
    enable: true
  - id: dbb82134
    name: ""
    type: namespace
    rule: clashverge.dev
    enable: true
  - id: 50b7e01e
    name: ""
    type: namespace
    rule: clerk.com
    enable: true
  - id: f01d97c5
    name: ""
    type: namespace
    rule: clerk.dev
    enable: true
  - id: 53e43b44
    name: ""
    type: namespace
    rule: clickup-attachments.com
    enable: true
  - id: 103e9157
    name: ""
    type: namespace
    rule: cloudflarestorage.com
    enable: true
  - id: 51fbf34a
    name: ""
    type: namespace
    rule: cloudns.net
    enable: true
  - id: e8a6c7af
    name: ""
    type: namespace
    rule: clubtv.pro
    enable: true
  - id: e7345718
    name: ""
    type: namespace
    rule: cochrane.org
    enable: true
  - id: b318fc00
    name: ""
    type: namespace
    rule: coderabbit.ai
    enable: true
  - id: d7793246
    name: ""
    type: namespace
    rule: consensus.app
    enable: true
  - id: 105a3e3a
    name: ""
    type: namespace
    rule: convertunits.com
    enable: true
  - id: da45bc13
    name: ""
    type: namespace
    rule: crdroid.net
    enable: true
  - id: 7b0cc0b3
    name: ""
    type: namespace
    rule: curseforge.com
    enable: true
  - id: 6dde5b54
    name: ""
    type: namespace
    rule: customfw.xyz
    enable: true
  - id: d9fb8328
    name: ""
    type: domain
    rule: d4c.nintendo.net
    enable: true
  - id: d2718096
    name: ""
    type: namespace
    rule: desec.io
    enable: true
  - id: "53139235"
    name: ""
    type: namespace
    rule: dev.to
    enable: true
  - id: 8525ae14
    name: ""
    type: namespace
    rule: discogs.com
    enable: true
  - id: a74aea43
    name: ""
    type: namespace
    rule: discourse-cdn.com
    enable: true
  - id: f87950f1
    name: ""
    type: namespace
    rule: dockhand.pro
    enable: true
  - id: b2c09caf
    name: ""
    type: namespace
    rule: dodopayments.com
    enable: true
  - id: f35a00bf
    name: ""
    type: namespace
    rule: dosvid.tk
    enable: true
  - id: d6b028c0
    name: ""
    type: domain
    rule: dragons.nintendo.net
    enable: true
  - id: 32a8a3ac
    name: ""
    type: namespace
    rule: drpool.io
    enable: true
  - id: d5f75c42
    name: ""
    type: namespace
    rule: ds-servers.com
    enable: true
  - id: d199c783
    name: ""
    type: domain
    rule: dvprogram.state.gov
    enable: true
  - id: 77ce4b2e
    name: ""
    type: domain
    rule: eaaccounts.akamaized.net
    enable: true
  - id: 73b519c4
    name: ""
    type: namespace
    rule: easysimplesolution.net
    enable: true
  - id: 088c1548
    name: ""
    type: namespace
    rule: edx.org
    enable: true
  - id: 67ba9d3c
    name: ""
    type: namespace
    rule: elsevier.com
    enable: true
  - id: 04eed2d5
    name: ""
    type: domain
    rule: elsevier.com.cdn.cloudflare.net
    enable: true
  - id: 9a67b4f6
    name: ""
    type: domain
    rule: eshop.nintendo.net
    enable: true
  - id: 17a34d97
    name: ""
    type: namespace
    rule: ezgif.com
    enable: true
  - id: d6c9d30c
    name: ""
    type: namespace
    rule: fandom.com
    enable: true
  - id: 34bfcd14
    name: ""
    type: namespace
    rule: fastpic.org
    enable: true
  - id: fcfa05dc
    name: ""
    type: namespace
    rule: fedoraproject.org
    enable: true
  - id: d2f70a78
    name: ""
    type: domain
    rule: feeds.feedburner.com
    enable: true
  - id: 3befe947
    name: ""
    type: namespace
    rule: figshare.com
    enable: true
  - id: f1e627b1
    name: ""
    type: namespace
    rule: filmix.my
    enable: true
  - id: e165cbce
    name: ""
    type: namespace
    rule: flathub.org
    enable: true
  - id: 750f9dd9
    name: ""
    type: namespace
    rule: flclash.cc
    enable: true
  - id: 6fd54e5a
    name: ""
    type: domain
    rule: forum.syncthing.net
    enable: true
  - id: 2d11b745
    name: ""
    type: namespace
    rule: fosshub.com
    enable: true
  - id: 4030e8cf
    name: ""
    type: namespace
    rule: fossorial.io
    enable: true
  - id: e798bcef
    name: ""
    type: namespace
    rule: friendlyelec.com
    enable: true
  - id: "06127875"
    name: ""
    type: namespace
    rule: fwupd.org
    enable: true
  - id: f1beb8da
    name: ""
    type: domain
    rule: galaxy.ansible.com
    enable: true
  - id: 1bd019f3
    name: ""
    type: namespace
    rule: geekbench.com
    enable: true
  - id: 1fdaf8de
    name: ""
    type: namespace
    rule: gitlab.com
    enable: true
  - id: cd24a7a0
    name: ""
    type: namespace
    rule: gizmochina.com
    enable: true
  - id: 7cffc82e
    name: ""
    type: namespace
    rule: gnome.org
    enable: true
  - id: 71b068c4
    name: ""
    type: namespace
    rule: gopro.com
    enable: true
  - id: 0dac1170
    name: ""
    type: namespace
    rule: grafana.net
    enable: true
  - id: 73487a8a
    name: ""
    type: namespace
    rule: heavyfetish.com
    enable: true
  - id: 1ea31d58
    name: ""
    type: namespace
    rule: helpdesk-static.com
    enable: true
  - id: d62fe894
    name: ""
    type: namespace
    rule: helpdesk.com
    enable: true
  - id: 40c3165e
    name: ""
    type: namespace
    rule: heltec.org
    enable: true
  - id: d5149f86
    name: ""
    type: namespace
    rule: hetzner.cloud
    enable: true
  - id: 60075b24
    name: ""
    type: namespace
    rule: higgsfield.ai
    enable: true
  - id: 8b9f6900
    name: ""
    type: namespace
    rule: hostero.eu
    enable: true
  - id: b43bee6a
    name: ""
    type: namespace
    rule: howtogeek.com
    enable: true
  - id: b69ddbd5
    name: ""
    type: namespace
    rule: htx.com
    enable: true
  - id: f95a4fc8
    name: ""
    type: namespace
    rule: huggingface.co
    enable: true
  - id: 51558cf1
    name: ""
    type: namespace
    rule: ikea.com
    enable: true
  - id: bf48406a
    name: ""
    type: namespace
    rule: imagedelivery.net
    enable: true
  - id: d5def888
    name: ""
    type: namespace
    rule: imazing.com
    enable: true
  - id: bfd0b792
    name: ""
    type: namespace
    rule: imgbb.com
    enable: true
  - id: e6824e8d
    name: ""
    type: namespace
    rule: imigo.ai
    enable: true
  - id: 0c9b6ac4
    name: ""
    type: namespace
    rule: inoreader.com
    enable: true
  - id: 1ed3ced0
    name: ""
    type: namespace
    rule: iot334.com
    enable: true
  - id: 836c977c
    name: ""
    type: namespace
    rule: ipinfo.app
    enable: true
  - id: 05c47655
    name: ""
    type: domain
    rule: irc-ws.chat.twitch.tv
    enable: true
  - id: "08784980"
    name: ""
    type: namespace
    rule: ixxx.com
    enable: true
  - id: a82a2710
    name: ""
    type: namespace
    rule: izzysoft.de
    enable: true
  - id: beb089d5
    name: ""
    type: namespace
    rule: jellyfin.org
    enable: true
  - id: adbba1ea
    name: ""
    type: namespace
    rule: jinxxy.com
    enable: true
  - id: 2adb7ff5
    name: ""
    type: namespace
    rule: joeysretrohandhelds.com
    enable: true
  - id: 16c2d66d
    name: ""
    type: namespace
    rule: karing.app
    enable: true
  - id: b7c4b102
    name: ""
    type: namespace
    rule: kde.org
    enable: true
  - id: f2cc307d
    name: ""
    type: namespace
    rule: kyoceradocumentsolutions.com
    enable: true
  - id: fa263122
    name: ""
    type: namespace
    rule: lenso.ai
    enable: true
  - id: ce8f3744
    name: ""
    type: namespace
    rule: libria.fun
    enable: true
  - id: f9944817
    name: ""
    type: namespace
    rule: lifeforge.dev
    enable: true
  - id: b8694103
    name: ""
    type: namespace
    rule: linuxserver.io
    enable: true
  - id: b8bfa81c
    name: ""
    type: namespace
    rule: litellm.ai
    enable: true
  - id: "97356640"
    name: ""
    type: namespace
    rule: livechat.com
    enable: true
  - id: 13473f41
    name: ""
    type: namespace
    rule: livechatinc.com
    enable: true
  - id: 9716bab4
    name: ""
    type: namespace
    rule: llhost.eu
    enable: true
  - id: 9cbb7ae6
    name: ""
    type: namespace
    rule: localsend.org
    enable: true
  - id: 2f8d31ab
    name: ""
    type: namespace
    rule: lowendtalk.com
    enable: true
  - id: 0094319e
    name: ""
    type: namespace
    rule: luadns.com
    enable: true
  - id: c2f2b8d9
    name: ""
    type: namespace
    rule: magicalchemy.org
    enable: true
  - id: 1828b31e
    name: ""
    type: namespace
    rule: manjaro.org
    enable: true
  - id: 96a97a23
    name: ""
    type: namespace
    rule: maximoff.su
    enable: true
  - id: da319089
    name: ""
    type: namespace
    rule: mdpi.com
    enable: true
  - id: 76742afb
    name: ""
    type: domain
    rule: media5.cdnbase.com
    enable: true
  - id: f44aa3da
    name: ""
    type: domain
    rule: mediafilez.forgecdn.net
    enable: true
  - id: 367a47cd
    name: ""
    type: namespace
    rule: memepedia.ru
    enable: true
  - id: 58d81298
    name: ""
    type: namespace
    rule: meshtastic.org
    enable: true
  - id: cc6a2239
    name: ""
    type: domain
    rule: mirror.chaotic.cx
    enable: true
  - id: a56060f5
    name: ""
    type: namespace
    rule: mongodb.com
    enable: true
  - id: 2761e1aa
    name: ""
    type: namespace
    rule: monochrome.tf
    enable: true
  - id: 6477c515
    name: ""
    type: domain
    rule: music.apple.com
    enable: true
  - id: 680c2ee7
    name: ""
    type: namespace
    rule: netbird.io
    enable: true
  - id: b1a8454e
    name: ""
    type: namespace
    rule: nextcloud.com
    enable: true
  - id: 32e09fc6
    name: ""
    type: namespace
    rule: nextdirect.com
    enable: true
  - id: 84ece747
    name: ""
    type: namespace
    rule: nexusmods.com
    enable: true
  - id: e96af959
    name: ""
    type: namespace
    rule: nintendo.com
    enable: true
  - id: bfce4d32
    name: ""
    type: namespace
    rule: nixos.org
    enable: true
  - id: 3706de5c
    name: ""
    type: namespace
    rule: nuxt.com
    enable: true
  - id: ef26225c
    name: ""
    type: namespace
    rule: nvidia.com
    enable: true
  - id: d7996a76
    name: ""
    type: namespace
    rule: ocbase.com
    enable: true
  - id: 16263c56
    name: ""
    type: namespace
    rule: openrailwaymap.org
    enable: true
  - id: 491ab60d
    name: ""
    type: namespace
    rule: opensubtitles.org
    enable: true
  - id: 30feff46
    name: ""
    type: namespace
    rule: opentext.com
    enable: true
  - id: 6c5edad6
    name: ""
    type: namespace
    rule: openwrt.org
    enable: true
  - id: e5dcfdcc
    name: ""
    type: namespace
    rule: opintopolku.fi
    enable: true
  - id: 35a54a3c
    name: ""
    type: namespace
    rule: ovh.ie
    enable: true
  - id: 8961d7d3
    name: ""
    type: namespace
    rule: pantone.com
    enable: true
  - id: c4ba82e3
    name: ""
    type: namespace
    rule: pastebin.com
    enable: true
  - id: e7280704
    name: ""
    type: namespace
    rule: patterns.dev
    enable: true
  - id: 8318394c
    name: ""
    type: namespace
    rule: pdfcoffee.com
    enable: true
  - id: 0dcca4fa
    name: ""
    type: namespace
    rule: pinata.cloud
    enable: true
  - id: 79f31a64
    name: ""
    type: namespace
    rule: ping-admin.com
    enable: true
  - id: 593e09ee
    name: ""
    type: domain
    rule: pinia-colada.esm.dev
    enable: true
  - id: 13a66ad0
    name: ""
    type: namespace
    rule: plantuml.com
    enable: true
  - id: 4a770a69
    name: ""
    type: namespace
    rule: porkbun.com
    enable: true
  - id: a18fa591
    name: ""
    type: domain
    rule: pplx-res.cloudinary.com
    enable: true
  - id: fa967abc
    name: ""
    type: namespace
    rule: protondb.com
    enable: true
  - id: cb1b5fef
    name: ""
    type: namespace
    rule: protonvpn.com
    enable: true
  - id: 1062ca4f
    name: ""
    type: namespace
    rule: pstatic.net
    enable: true
  - id: "98212966"
    name: ""
    type: namespace
    rule: pstmn.io
    enable: true
  - id: 281ad9cd
    name: ""
    type: namespace
    rule: pusher.com
    enable: true
  - id: de9db687
    name: ""
    type: namespace
    rule: pypi.org
    enable: true
  - id: 5f2bd67e
    name: ""
    type: namespace
    rule: qualtrics.com
    enable: true
  - id: 9b312a1b
    name: ""
    type: namespace
    rule: reddit.com
    enable: true
  - id: 43b3cfd9
    name: ""
    type: domain
    rule: redux.js.org
    enable: true
  - id: 81b4c4f6
    name: ""
    type: domain
    rule: resizing.flixster.com
    enable: true
  - id: 1994247f
    name: ""
    type: namespace
    rule: rosepinetheme.com
    enable: true
  - id: 3194bb9c
    name: ""
    type: namespace
    rule: rottentomatoes.com
    enable: true
  - id: 3810cae5
    name: ""
    type: namespace
    rule: rulet.tv
    enable: true
  - id: 73be8b6c
    name: ""
    type: namespace
    rule: russianfood.com
    enable: true
  - id: 8beafce3
    name: ""
    type: namespace
    rule: rutracker.org
    enable: true
  - id: 01787a27
    name: ""
    type: namespace
    rule: sb-cd.com
    enable: true
  - id: 0630d466
    name: ""
    type: namespace
    rule: sbox.game
    enable: true
  - id: 0f6b2882
    name: ""
    type: namespace
    rule: scira.ai
    enable: true
  - id: 362d53ee
    name: ""
    type: namespace
    rule: scribd.com
    enable: true
  - id: 4e72435f
    name: ""
    type: namespace
    rule: seriesgraph.com
    enable: true
  - id: dc7f2b78
    name: ""
    type: namespace
    rule: shara-mail.com
    enable: true
  - id: ff5447b6
    name: ""
    type: namespace
    rule: silabs.com
    enable: true
  - id: 7902f09c
    name: ""
    type: domain
    rule: sing-box.sagernet.org
    enable: true
  - id: 555ad3ab
    name: ""
    type: namespace
    rule: skillsforall.com
    enable: true
  - id: cc21da44
    name: ""
    type: namespace
    rule: smods.ru
    enable: true
  - id: c39d084d
    name: ""
    type: namespace
    rule: snikket.org
    enable: true
  - id: 187dfed0
    name: ""
    type: namespace
    rule: spankbang.com
    enable: true
  - id: efd62d34
    name: ""
    type: domain
    rule: srv.nintendo.net
    enable: true
  - id: 25cafe57
    name: ""
    type: domain
    rule: static.wixstatic.com
    enable: true
  - id: 183fee1a
    name: ""
    type: namespace
    rule: steamos.cloud
    enable: true
  - id: 74c68ddb
    name: ""
    type: domain
    rule: storybook.js.org
    enable: true
  - id: 9c40aab2
    name: ""
    type: namespace
    rule: strapi.io
    enable: true
  - id: 7492fa39
    name: ""
    type: namespace
    rule: strava.com
    enable: true
  - id: 6d11cf97
    name: ""
    type: namespace
    rule: stripe.com
    enable: true
  - id: 94a1b552
    name: ""
    type: namespace
    rule: stripecdn.com
    enable: true
  - id: 326f3be1
    name: ""
    type: namespace
    rule: studyinfinland.fi
    enable: true
  - id: 111cc9df
    name: ""
    type: namespace
    rule: succurity.com
    enable: true
  - id: 450bb2a2
    name: ""
    type: namespace
    rule: sxyprn.com
    enable: true
  - id: 3d0d5c60
    name: ""
    type: namespace
    rule: sxyprn.net
    enable: true
  - id: 8f9751e5
    name: ""
    type: namespace
    rule: tailwind-variants.org
    enable: true
  - id: 0c711a09
    name: ""
    type: namespace
    rule: teamviewer.com
    enable: true
  - id: f0bf742b
    name: ""
    type: namespace
    rule: tefl.org
    enable: true
  - id: 748787ea
    name: ""
    type: namespace
    rule: text.com
    enable: true
  - id: 10b84fb9
    name: ""
    type: namespace
    rule: thelancet.com
    enable: true
  - id: 47f03117
    name: ""
    type: namespace
    rule: tiny.cloud
    enable: true
  - id: ca506c37
    name: ""
    type: namespace
    rule: transistor.fm
    enable: true
  - id: 5ccaf657
    name: ""
    type: namespace
    rule: tremendous.com
    enable: true
  - id: 7324a665
    name: ""
    type: namespace
    rule: trueachievements.com
    enable: true
  - id: fa5927e6
    name: ""
    type: namespace
    rule: tunemymusic.com
    enable: true
  - id: "51326805"
    name: ""
    type: namespace
    rule: tuya-inc.cn
    enable: true
  - id: 83f31ff2
    name: ""
    type: namespace
    rule: tuya.com
    enable: true
  - id: 9c3df7f7
    name: ""
    type: namespace
    rule: tuyaaf.com
    enable: true
  - id: e5fdfb3b
    name: ""
    type: namespace
    rule: tuyacn.com
    enable: true
  - id: 614905d2
    name: ""
    type: namespace
    rule: tuyaeu.com
    enable: true
  - id: afbe7f85
    name: ""
    type: namespace
    rule: tuyain.com
    enable: true
  - id: cc00f353
    name: ""
    type: namespace
    rule: tuyaus.com
    enable: true
  - id: 1883d9b1
    name: ""
    type: namespace
    rule: ubuntu-touch.io
    enable: true
  - id: e571c188
    name: ""
    type: domain
    rule: use.typekit.net
    enable: true
  - id: 1990fa1a
    name: ""
    type: namespace
    rule: userbenchmark.com
    enable: true
  - id: b8c9d96a
    name: ""
    type: domain
    rule: utils.docs.rw
    enable: true
  - id: a91974aa
    name: ""
    type: namespace
    rule: vecpea.com
    enable: true
  - id: ba5800a2
    name: ""
    type: domain
    rule: vivo.com.cn
    enable: true
  - id: c6e54935
    name: ""
    type: domain
    rule: vod.streamgum.com
    enable: true
  - id: 3cf3a251
    name: ""
    type: namespace
    rule: vpnjantit.com
    enable: true
  - id: 102e9746
    name: ""
    type: namespace
    rule: vrchat.cloud
    enable: true
  - id: 7e6e2a0e
    name: ""
    type: namespace
    rule: vrchat.com
    enable: true
  - id: 2c51d9b6
    name: ""
    type: namespace
    rule: walletbot.me
    enable: true
  - id: fd66e7fc
    name: ""
    type: namespace
    rule: wayground.com
    enable: true
  - id: 8e7b46df
    name: ""
    type: namespace
    rule: wbagora.com
    enable: true
  - id: 0bbcd71c
    name: ""
    type: namespace
    rule: wbgames.com
    enable: true
  - id: 4488dc72
    name: ""
    type: namespace
    rule: wbinsights.com
    enable: true
  - id: a9d0ee6f
    name: ""
    type: namespace
    rule: whoer.net
    enable: true
  - id: 0cc3b575
    name: ""
    type: namespace
    rule: windowsupdate.com
    enable: true
  - id: "385685e1"
    name: ""
    type: namespace
    rule: wwnd.space
    enable: true
  - id: cd8caa1c
    name: ""
    type: namespace
    rule: xda-developers.com
    enable: true
  - id: "84808170"
    name: ""
    type: namespace
    rule: xdaforums.com
    enable: true
  - id: 1157068d
    name: ""
    type: namespace
    rule: xraycore.org
    enable: true
  - id: cc169ece
    name: ""
    type: namespace
    rule: yarnpkg.com
    enable: true
  - id: fcaf1327
    name: ""
    type: namespace
    rule: youngliving.com
    enable: true
  - id: db21a747
    name: ""
    type: namespace
    rule: zerotier.com
    enable: true
- id: b24659e0
  name: Meta
  color: '#54f262'
  interface: Mihomo
  enable: true
  rules:
  - id: ec73fe2d
    name: ""
    type: subnet
    rule: 102.132.112.0/24
    enable: true
  - id: 4b38df75
    name: ""
    type: subnet
    rule: 102.132.115.0/24
    enable: true
  - id: cb713e8e
    name: ""
    type: subnet
    rule: 102.132.116.0/23
    enable: true
  - id: 13941f65
    name: ""
    type: subnet
    rule: 102.132.119.0/24
    enable: true
  - id: 741eb536
    name: ""
    type: subnet
    rule: 102.132.120.0/23
    enable: true
  - id: dca7b4e3
    name: ""
    type: subnet
    rule: 102.132.123.0/24
    enable: true
  - id: 2f14c102
    name: ""
    type: subnet
    rule: 102.132.125.0/24
    enable: true
  - id: 4f705f29
    name: ""
    type: subnet
    rule: 102.132.126.0/24
    enable: true
  - id: 870a3831
    name: ""
    type: subnet
    rule: 102.132.96.0/20
    enable: true
  - id: 981a6de4
    name: ""
    type: subnet
    rule: 102.221.188.0/22
    enable: true
  - id: 9541980c
    name: ""
    type: subnet
    rule: 103.4.96.0/22
    enable: true
  - id: fec8db56
    name: ""
    type: subnet
    rule: 129.134.0.0/17
    enable: true
  - id: f5e02ea0
    name: ""
    type: subnet
    rule: 129.134.130.0/24
    enable: true
  - id: b74acf6e
    name: ""
    type: subnet
    rule: 129.134.132.0/24
    enable: true
  - id: 0719b346
    name: ""
    type: subnet
    rule: 129.134.135.0/24
    enable: true
  - id: 43ac5592
    name: ""
    type: subnet
    rule: 129.134.136.0/22
    enable: true
  - id: 3cd9d9ba
    name: ""
    type: subnet
    rule: 129.134.140.0/24
    enable: true
  - id: 62fd9836
    name: ""
    type: subnet
    rule: 129.134.143.0/24
    enable: true
  - id: f49ca6c1
    name: ""
    type: subnet
    rule: 129.134.144.0/24
    enable: true
  - id: 5605f7a1
    name: ""
    type: subnet
    rule: 129.134.148.0/23
    enable: true
  - id: f034c178
    name: ""
    type: subnet
    rule: 129.134.150.0/24
    enable: true
  - id: cfd24952
    name: ""
    type: subnet
    rule: 129.134.154.0/23
    enable: true
  - id: 0673cff8
    name: ""
    type: subnet
    rule: 129.134.156.0/22
    enable: true
  - id: dce2de3b
    name: ""
    type: subnet
    rule: 129.134.160.0/22
    enable: true
  - id: acf450ff
    name: ""
    type: subnet
    rule: 129.134.164.0/23
    enable: true
  - id: "71475472"
    name: ""
    type: subnet
    rule: 129.134.168.0/21
    enable: true
  - id: a3213902
    name: ""
    type: subnet
    rule: 129.134.176.0/20
    enable: true
  - id: 5e698d79
    name: ""
    type: subnet
    rule: 129.134.194.0/23
    enable: true
  - id: 500a0986
    name: ""
    type: subnet
    rule: 129.134.196.0/23
    enable: true
  - id: 4112f885
    name: ""
    type: subnet
    rule: 157.240.0.0/17
    enable: true
  - id: c90a4833
    name: ""
    type: subnet
    rule: 157.240.128.0/23
    enable: true
  - id: 153edda4
    name: ""
    type: subnet
    rule: 157.240.131.0/24
    enable: true
  - id: 882448c2
    name: ""
    type: subnet
    rule: 157.240.132.0/24
    enable: true
  - id: "13480363"
    name: ""
    type: subnet
    rule: 157.240.134.0/24
    enable: true
  - id: ae1806d3
    name: ""
    type: subnet
    rule: 157.240.136.0/23
    enable: true
  - id: 25b5b33e
    name: ""
    type: subnet
    rule: 157.240.139.0/24
    enable: true
  - id: c039171b
    name: ""
    type: subnet
    rule: 157.240.140.0/24
    enable: true
  - id: 03ca59ec
    name: ""
    type: subnet
    rule: 157.240.156.0/22
    enable: true
  - id: 7e83f011
    name: ""
    type: subnet
    rule: 157.240.169.0/24
    enable: true
  - id: 7e037600
    name: ""
    type: subnet
    rule: 157.240.170.0/24
    enable: true
  - id: e99aeee9
    name: ""
    type: subnet
    rule: 157.240.175.0/24
    enable: true
  - id: a62caf8a
    name: ""
    type: subnet
    rule: 157.240.177.0/24
    enable: true
  - id: "179728e4"
    name: ""
    type: subnet
    rule: 157.240.179.0/24
    enable: true
  - id: e139974e
    name: ""
    type: subnet
    rule: 157.240.181.0/24
    enable: true
  - id: a5fa168d
    name: ""
    type: subnet
    rule: 157.240.182.0/23
    enable: true
  - id: 4168ef38
    name: ""
    type: subnet
    rule: 157.240.184.0/21
    enable: true
  - id: a3910aed
    name: ""
    type: subnet
    rule: 157.240.192.0/18
    enable: true
  - id: 8224e8b6
    name: ""
    type: subnet
    rule: 163.114.128.0/20
    enable: true
  - id: 598dc1fc
    name: ""
    type: subnet
    rule: 163.70.128.0/17
    enable: true
  - id: 0dc154b0
    name: ""
    type: subnet
    rule: 163.77.132.0/23
    enable: true
  - id: 690750d3
    name: ""
    type: subnet
    rule: 163.77.136.0/23
    enable: true
  - id: b9ecd02b
    name: ""
    type: subnet
    rule: 173.252.64.0/18
    enable: true
  - id: 2ef53d32
    name: ""
    type: subnet
    rule: 179.60.192.0/22
    enable: true
  - id: 9bedf194
    name: ""
    type: subnet
    rule: 185.60.216.0/22
    enable: true
  - id: 5e56ca16
    name: ""
    type: subnet
    rule: 185.89.216.0/22
    enable: true
  - id: 11efe984
    name: ""
    type: subnet
    rule: 199.201.64.0/22
    enable: true
  - id: 85bdb9c5
    name: ""
    type: subnet
    rule: 204.15.20.0/22
    enable: true
  - id: cbe08151
    name: ""
    type: subnet6
    rule: 2620:0:1c00::/40
    enable: true
  - id: 205cc4f4
    name: ""
    type: subnet6
    rule: 2620:10d:c090::/44
    enable: true
  - id: 0a3651b2
    name: ""
    type: subnet6
    rule: 2a03:2880::/32
    enable: true
  - id: 803deb99
    name: ""
    type: subnet6
    rule: 2a03:2887:ff00::/48
    enable: true
  - id: 0a9325a1
    name: ""
    type: subnet6
    rule: 2a03:2887:ff02::/47
    enable: true
  - id: 7d992bf8
    name: ""
    type: subnet6
    rule: 2a03:2887:ff04::/46
    enable: true
  - id: 6b211c43
    name: ""
    type: subnet6
    rule: 2a03:2887:ff09::/48
    enable: true
  - id: c62a9a8c
    name: ""
    type: subnet6
    rule: 2a03:2887:ff0a::/48
    enable: true
  - id: edd0aa03
    name: ""
    type: subnet6
    rule: 2a03:2887:ff1b::/48
    enable: true
  - id: 8fda9a69
    name: ""
    type: subnet6
    rule: 2a03:2887:ff1e::/48
    enable: true
  - id: f2a10d05
    name: ""
    type: subnet6
    rule: 2a03:2887:ff20::/48
    enable: true
  - id: b2a29737
    name: ""
    type: subnet6
    rule: 2a03:2887:ff22::/47
    enable: true
  - id: bf65f25a
    name: ""
    type: subnet6
    rule: 2a03:2887:ff27::/48
    enable: true
  - id: abb1b0f6
    name: ""
    type: subnet6
    rule: 2a03:2887:ff28::/46
    enable: true
  - id: 72b67f52
    name: ""
    type: subnet6
    rule: 2a03:2887:ff2e::/47
    enable: true
  - id: 548ff485
    name: ""
    type: subnet6
    rule: 2a03:2887:ff30::/48
    enable: true
  - id: a20874a1
    name: ""
    type: subnet6
    rule: 2a03:2887:ff33::/48
    enable: true
  - id: 4ba3d771
    name: ""
    type: subnet6
    rule: 2a03:2887:ff37::/48
    enable: true
  - id: f3409022
    name: ""
    type: subnet6
    rule: 2a03:2887:ff38::/46
    enable: true
  - id: 4426889b
    name: ""
    type: subnet6
    rule: 2a03:2887:ff3e::/47
    enable: true
  - id: 1bda1174
    name: ""
    type: subnet6
    rule: 2a03:2887:ff40::/46
    enable: true
  - id: a56a765b
    name: ""
    type: subnet6
    rule: 2a03:2887:ff44::/47
    enable: true
  - id: 6f1cbe04
    name: ""
    type: subnet6
    rule: 2a03:2887:ff48::/46
    enable: true
  - id: d16d1ca4
    name: ""
    type: subnet6
    rule: 2a03:2887:ff4d::/48
    enable: true
  - id: 9600f4d0
    name: ""
    type: subnet6
    rule: 2a03:2887:ff4e::/47
    enable: true
  - id: ee0ac3a6
    name: ""
    type: subnet6
    rule: 2a03:2887:ff50::/45
    enable: true
  - id: d5492cd3
    name: ""
    type: subnet6
    rule: 2a03:2887:ff58::/47
    enable: true
  - id: a6c0ab2a
    name: ""
    type: subnet6
    rule: 2a03:2887:ff5a::/48
    enable: true
  - id: c64ca9c8
    name: ""
    type: subnet6
    rule: 2a03:2887:ff5f::/48
    enable: true
  - id: 9558d7d8
    name: ""
    type: subnet6
    rule: 2a03:2887:ff60::/48
    enable: true
  - id: 13a06de5
    name: ""
    type: subnet6
    rule: 2a03:2887:ff62::/47
    enable: true
  - id: cde8e774
    name: ""
    type: subnet6
    rule: 2a03:2887:ff64::/46
    enable: true
  - id: 88d532a2
    name: ""
    type: subnet6
    rule: 2a03:2887:ff68::/46
    enable: true
  - id: da3d1736
    name: ""
    type: subnet6
    rule: 2a03:2887:ff6f::/48
    enable: true
  - id: f6360c83
    name: ""
    type: subnet6
    rule: 2a03:2887:ff70::/46
    enable: true
  - id: 59a3dda1
    name: ""
    type: subnet6
    rule: 2c0f:ef78:10::/47
    enable: true
  - id: b85ba184
    name: ""
    type: subnet6
    rule: 2c0f:ef78:3::/48
    enable: true
  - id: ed6744f9
    name: ""
    type: subnet6
    rule: 2c0f:ef78:5::/48
    enable: true
  - id: 6ec56340
    name: ""
    type: subnet6
    rule: 2c0f:ef78:9::/48
    enable: true
  - id: 672a4d97
    name: ""
    type: subnet6
    rule: 2c0f:ef78:c::/47
    enable: true
  - id: 1b5eb299
    name: ""
    type: subnet
    rule: 31.13.24.0/21
    enable: true
  - id: fed31c28
    name: ""
    type: subnet
    rule: 31.13.64.0/18
    enable: true
  - id: 47d58d44
    name: ""
    type: subnet
    rule: 45.64.40.0/22
    enable: true
  - id: 204ac342
    name: ""
    type: subnet
    rule: 57.141.0.0/24
    enable: true
  - id: 2acbf130
    name: ""
    type: subnet
    rule: 57.141.10.0/24
    enable: true
  - id: 6276df74
    name: ""
    type: subnet
    rule: 57.141.12.0/23
    enable: true
  - id: c302f976
    name: ""
    type: subnet
    rule: 57.141.14.0/24
    enable: true
  - id: e1a10c2b
    name: ""
    type: subnet
    rule: 57.141.16.0/22
    enable: true
  - id: ebc61781
    name: ""
    type: subnet
    rule: 57.141.2.0/23
    enable: true
  - id: 59904daa
    name: ""
    type: subnet
    rule: 57.141.20.0/24
    enable: true
  - id: 84d9e36a
    name: ""
    type: subnet
    rule: 57.141.22.0/24
    enable: true
  - id: 322512ff
    name: ""
    type: subnet
    rule: 57.141.24.0/24
    enable: true
  - id: 900bf2fc
    name: ""
    type: subnet
    rule: 57.141.4.0/23
    enable: true
  - id: 1711fc77
    name: ""
    type: subnet
    rule: 57.141.6.0/24
    enable: true
  - id: 6e42c6f5
    name: ""
    type: subnet
    rule: 57.141.8.0/24
    enable: true
  - id: 09dbf8e8
    name: ""
    type: subnet
    rule: 57.144.0.0/14
    enable: true
  - id: c12912a7
    name: ""
    type: subnet
    rule: 66.220.144.0/20
    enable: true
  - id: 6ad7e08f
    name: ""
    type: subnet
    rule: 69.171.224.0/19
    enable: true
  - id: d2dce883
    name: ""
    type: subnet
    rule: 69.63.176.0/20
    enable: true
  - id: 25913e6f
    name: ""
    type: subnet
    rule: 74.119.76.0/22
    enable: true
  - id: 5210a76e
    name: ""
    type: namespace
    rule: cdninstagram.com
    enable: true
  - id: 66de406c
    name: ""
    type: namespace
    rule: circlecrewpinkcrowd.com
    enable: true
  - id: cf5733c0
    name: ""
    type: namespace
    rule: facebook.com
    enable: true
  - id: 52b206e0
    name: ""
    type: namespace
    rule: facebook.net
    enable: true
  - id: af9fb1c0
    name: ""
    type: namespace
    rule: fb.com
    enable: true
  - id: 68fa2516
    name: ""
    type: namespace
    rule: fbcdn.net
    enable: true
  - id: 69a9e0ac
    name: ""
    type: namespace
    rule: fbsbx.com
    enable: true
  - id: "78700149"
    name: ""
    type: namespace
    rule: ig.me
    enable: true
  - id: c187c670
    name: ""
    type: namespace
    rule: instagram.com
    enable: true
  - id: 5866524f
    name: ""
    type: namespace
    rule: internalfb.com
    enable: true
  - id: ab93191b
    name: ""
    type: namespace
    rule: meta.com
    enable: true
  - id: 54ff290d
    name: ""
    type: namespace
    rule: oculus.com
    enable: true
  - id: 933ce835
    name: ""
    type: namespace
    rule: threads.com
    enable: true
  - id: c50ba3fc
    name: ""
    type: namespace
    rule: threads.net
    enable: true
  - id: 35f74d47
    name: ""
    type: namespace
    rule: wa.me
    enable: true
  - id: ac91bc9d
    name: ""
    type: namespace
    rule: whatsapp.biz
    enable: true
  - id: 03a4bce0
    name: ""
    type: namespace
    rule: whatsapp.com
    enable: true
  - id: 65108d0a
    name: ""
    type: namespace
    rule: whatsapp.net
    enable: true
- id: 3239dcbb
  name: News
  color: '#9054f2'
  interface: Mihomo
  enable: true
  rules:
  - id: 4a467155
    name: ""
    type: namespace
    rule: 24.kg
    enable: true
  - id: "44040037"
    name: ""
    type: domain
    rule: 7dniv.rv.ua
    enable: true
  - id: 38e803f7
    name: ""
    type: domain
    rule: 9tv.co.il
    enable: true
  - id: 89acb74b
    name: ""
    type: namespace
    rule: activatica.org
    enable: true
  - id: d77e6e67
    name: ""
    type: namespace
    rule: agents.media
    enable: true
  - id: 774f9018
    name: ""
    type: domain
    rule: api.theins.info
    enable: true
  - id: a9cf1d17
    name: ""
    type: namespace
    rule: arbat.media
    enable: true
  - id: 7822f261
    name: ""
    type: namespace
    rule: atn.ua
    enable: true
  - id: e4c6f5be
    name: ""
    type: namespace
    rule: azathabar.com
    enable: true
  - id: ae6b76d7
    name: ""
    type: namespace
    rule: azattyq.org
    enable: true
  - id: a1228d37
    name: ""
    type: namespace
    rule: baikal-journal.ru
    enable: true
  - id: 487f3137
    name: ""
    type: domain
    rule: bbc.co.uk
    enable: true
  - id: 722075d4
    name: ""
    type: namespace
    rule: bbc.com
    enable: true
  - id: 6e347086
    name: ""
    type: domain
    rule: bbci.co.uk
    enable: true
  - id: 15b47605
    name: ""
    type: namespace
    rule: bellingcat.com
    enable: true
  - id: 9af4ea01
    name: ""
    type: namespace
    rule: bihus.info
    enable: true
  - id: 55b91162
    name: ""
    type: namespace
    rule: blackseanews.net
    enable: true
  - id: f1ba1426
    name: ""
    type: namespace
    rule: censor.net
    enable: true
  - id: 6fb8e07c
    name: ""
    type: namespace
    rule: cherta.media
    enable: true
  - id: af5d03d8
    name: ""
    type: namespace
    rule: colta.ru
    enable: true
  - id: 0a54dc14
    name: ""
    type: domain
    rule: csskor.ill.in.ua
    enable: true
  - id: 5710a0e2
    name: ""
    type: namespace
    rule: currenttime.tv
    enable: true
  - id: 7f073413
    name: ""
    type: domain
    rule: cursorinfo.co.il
    enable: true
  - id: 5d347e4a
    name: ""
    type: namespace
    rule: cyxymu.info
    enable: true
  - id: 078eac84
    name: ""
    type: namespace
    rule: dailylviv.com
    enable: true
  - id: ba11bb6a
    name: ""
    type: namespace
    rule: delfi.lt
    enable: true
  - id: 12a444b5
    name: ""
    type: namespace
    rule: delfi.lv
    enable: true
  - id: 0aad8488
    name: ""
    type: namespace
    rule: discours.io
    enable: true
  - id: b7154220
    name: ""
    type: namespace
    rule: dovod.online
    enable: true
  - id: 0e4b0e77
    name: ""
    type: namespace
    rule: doxa.team
    enable: true
  - id: e91b2e23
    name: ""
    type: namespace
    rule: dumka.media
    enable: true
  - id: 13659c5c
    name: ""
    type: namespace
    rule: dw.com
    enable: true
  - id: 6765ce1f
    name: ""
    type: namespace
    rule: echofm.online
    enable: true
  - id: 1f7bfeb1
    name: ""
    type: namespace
    rule: ej.ru
    enable: true
  - id: 7c034eae
    name: ""
    type: namespace
    rule: ekhokavkaza.com
    enable: true
  - id: ccbbdce0
    name: ""
    type: namespace
    rule: espreso.tv
    enable: true
  - id: da899edf
    name: ""
    type: namespace
    rule: euronews.com
    enable: true
  - id: 57ea5d93
    name: ""
    type: namespace
    rule: europesays.com
    enable: true
  - id: 46e5b13f
    name: ""
    type: namespace
    rule: euroradio.fm
    enable: true
  - id: 039aeaa1
    name: ""
    type: namespace
    rule: eutrp.eu
    enable: true
  - id: 66809a85
    name: ""
    type: namespace
    rule: expres.online
    enable: true
  - id: 747b4c75
    name: ""
    type: namespace
    rule: fn-volga.ru
    enable: true
  - id: 7700a0d1
    name: ""
    type: namespace
    rule: fonge.org
    enable: true
  - id: e6cc3631
    name: ""
    type: namespace
    rule: fortanga.org
    enable: true
  - id: 6d1ca46b
    name: ""
    type: namespace
    rule: foxnews.com
    enable: true
  - id: 1271a180
    name: ""
    type: namespace
    rule: freemedia.io
    enable: true
  - id: 34ee2fb9
    name: ""
    type: namespace
    rule: germania.one
    enable: true
  - id: 352fcd57
    name: ""
    type: namespace
    rule: glavred.info
    enable: true
  - id: 11919bdf
    name: ""
    type: namespace
    rule: glavred.net
    enable: true
  - id: 15ea277e
    name: ""
    type: namespace
    rule: golosameriki.com
    enable: true
  - id: 22dba23a
    name: ""
    type: namespace
    rule: grani.ru
    enable: true
  - id: cd7e80b1
    name: ""
    type: namespace
    rule: graty.me
    enable: true
  - id: eb54e2f3
    name: ""
    type: namespace
    rule: gulagu.net
    enable: true
  - id: fba6d508
    name: ""
    type: namespace
    rule: holod.media
    enable: true
  - id: bf8ba29c
    name: ""
    type: namespace
    rule: hromadske.ua
    enable: true
  - id: db1b965c
    name: ""
    type: namespace
    rule: hs.fi
    enable: true
  - id: a0195477
    name: ""
    type: domain
    rule: i.sakh.com
    enable: true
  - id: b85647df
    name: ""
    type: namespace
    rule: idelreal.org
    enable: true
  - id: 0634e456
    name: ""
    type: namespace
    rule: important-stories.com
    enable: true
  - id: 949492b4
    name: ""
    type: domain
    rule: interfax.com.ua
    enable: true
  - id: a7ab11fe
    name: ""
    type: namespace
    rule: is.fi
    enable: true
  - id: d4117a8c
    name: ""
    type: namespace
    rule: istories.media
    enable: true
  - id: 3a0ef0f7
    name: ""
    type: namespace
    rule: itsmycity.ru
    enable: true
  - id: 270dd2a9
    name: ""
    type: domain
    rule: jskor.ill.in.ua
    enable: true
  - id: d61686ce
    name: ""
    type: namespace
    rule: kaktus.media
    enable: true
  - id: 06d14275
    name: ""
    type: namespace
    rule: kasparov.ru
    enable: true
  - id: c002d6fb
    name: ""
    type: namespace
    rule: kavkaz-uzel.eu
    enable: true
  - id: df991222
    name: ""
    type: namespace
    rule: kavkazr.com
    enable: true
  - id: 65eccb76
    name: ""
    type: namespace
    rule: kolsar.org
    enable: true
  - id: 03d6949a
    name: ""
    type: domain
    rule: kor.ill.in.ua
    enable: true
  - id: 3e69a611
    name: ""
    type: namespace
    rule: korrespondent.net
    enable: true
  - id: 7f381cfa
    name: ""
    type: namespace
    rule: kovcheg.live
    enable: true
  - id: bd5622e4
    name: ""
    type: namespace
    rule: krymr.com
    enable: true
  - id: a198d250
    name: ""
    type: namespace
    rule: lamcdn.net
    enable: true
  - id: da11344b
    name: ""
    type: namespace
    rule: liga.net
    enable: true
  - id: 7b16604b
    name: ""
    type: namespace
    rule: locals.md
    enable: true
  - id: afaaf2ee
    name: ""
    type: domain
    rule: mbk-news.appspot.com
    enable: true
  - id: e6b37ecb
    name: ""
    type: namespace
    rule: mediazona.ca
    enable: true
  - id: 72d0f7fe
    name: ""
    type: namespace
    rule: meduza.io
    enable: true
  - id: 3b0711b8
    name: ""
    type: namespace
    rule: merezha.co
    enable: true
  - id: acc70498
    name: ""
    type: namespace
    rule: metla.press
    enable: true
  - id: add5e30e
    name: ""
    type: namespace
    rule: mezha.net
    enable: true
  - id: adb184a0
    name: ""
    type: namespace
    rule: mignews.com
    enable: true
  - id: 0f7f4eec
    name: ""
    type: namespace
    rule: moscowtimes.ru
    enable: true
  - id: 4eed9d16
    name: ""
    type: domain
    rule: newsru.co.il
    enable: true
  - id: ead18c19
    name: ""
    type: namespace
    rule: newsru.com
    enable: true
  - id: "78168875"
    name: ""
    type: namespace
    rule: newtimes.ru
    enable: true
  - id: 74b19095
    name: ""
    type: namespace
    rule: novaya.no
    enable: true
  - id: 1c208f18
    name: ""
    type: namespace
    rule: novayagazeta.eu
    enable: true
  - id: cd501240
    name: ""
    type: namespace
    rule: novayagazeta.ru
    enable: true
  - id: 2d766296
    name: ""
    type: namespace
    rule: novyny.live
    enable: true
  - id: 3a2b0649
    name: ""
    type: namespace
    rule: obozrevatel.com
    enable: true
  - id: 75252de2
    name: ""
    type: namespace
    rule: oi.legal
    enable: true
  - id: 2d98c501
    name: ""
    type: namespace
    rule: openmedia.io
    enable: true
  - id: ca203c58
    name: ""
    type: namespace
    rule: opposition-news.com
    enable: true
  - id: ce7139eb
    name: ""
    type: namespace
    rule: ovd.info
    enable: true
  - id: 367d78c6
    name: ""
    type: namespace
    rule: ovd.legal
    enable: true
  - id: f978ad28
    name: ""
    type: namespace
    rule: ovd.news
    enable: true
  - id: f1199b9c
    name: ""
    type: namespace
    rule: ovdinfo.org
    enable: true
  - id: 7a554a8e
    name: ""
    type: namespace
    rule: ozodi.org
    enable: true
  - id: 35086fdc
    name: ""
    type: namespace
    rule: pap.pl
    enable: true
  - id: 5f83c0e7
    name: ""
    type: namespace
    rule: paperpaper.io
    enable: true
  - id: 9ae372e1
    name: ""
    type: namespace
    rule: paperpaper.ru
    enable: true
  - id: c728a44a
    name: ""
    type: domain
    rule: patriot.dp.ua
    enable: true
  - id: 636cb7dd
    name: ""
    type: namespace
    rule: polit.ru
    enable: true
  - id: fbe4b3f2
    name: ""
    type: namespace
    rule: politico.eu
    enable: true
  - id: 876e76a2
    name: ""
    type: namespace
    rule: politiken.dk
    enable: true
  - id: b363377e
    name: ""
    type: domain
    rule: portal.lviv.ua
    enable: true
  - id: 52b84e59
    name: ""
    type: namespace
    rule: posle.media
    enable: true
  - id: 500e4945
    name: ""
    type: namespace
    rule: postimees.ee
    enable: true
  - id: 323d3b59
    name: ""
    type: namespace
    rule: pravda.com
    enable: true
  - id: "79024179"
    name: ""
    type: domain
    rule: pravda.com.ua
    enable: true
  - id: 6a4ada14
    name: ""
    type: namespace
    rule: proekt.media
    enable: true
  - id: d7b0c7ba
    name: ""
    type: namespace
    rule: prosleduetmedia.com
    enable: true
  - id: 2da0df57
    name: ""
    type: namespace
    rule: provereno.media
    enable: true
  - id: 4667170b
    name: ""
    type: domain
    rule: r4.err.ee
    enable: true
  - id: 3c1e7fc2
    name: ""
    type: namespace
    rule: radiosakharov.org
    enable: true
  - id: 152cc37b
    name: ""
    type: namespace
    rule: radiosvoboda.org
    enable: true
  - id: 563c14da
    name: ""
    type: namespace
    rule: rbc.ua
    enable: true
  - id: 26984dd9
    name: ""
    type: namespace
    rule: realist.online
    enable: true
  - id: 1bdbb7a2
    name: ""
    type: namespace
    rule: republic.ru
    enable: true
  - id: fd04be46
    name: ""
    type: namespace
    rule: rezonans.media
    enable: true
  - id: c455d517
    name: ""
    type: namespace
    rule: rferl.org
    enable: true
  - id: "50140886"
    name: ""
    type: namespace
    rule: rima.media
    enable: true
  - id: 8e4ebd6f
    name: ""
    type: namespace
    rule: roar-review.com
    enable: true
  - id: 2381e8e6
    name: ""
    type: namespace
    rule: root-nation.com
    enable: true
  - id: b18befe2
    name: ""
    type: namespace
    rule: roskomsvoboda.org
    enable: true
  - id: dcafc1b8
    name: ""
    type: domain
    rule: rus.delfi.ee
    enable: true
  - id: ee0235fb
    name: ""
    type: domain
    rule: rus.jauns.lv
    enable: true
  - id: 09b72fb8
    name: ""
    type: namespace
    rule: sakhalin.info
    enable: true
  - id: ab6524f4
    name: ""
    type: namespace
    rule: sakharovfoundation.org
    enable: true
  - id: 9f7b1ede
    name: ""
    type: namespace
    rule: semnasem.org
    enable: true
  - id: fdc3ba87
    name: ""
    type: namespace
    rule: severreal.org
    enable: true
  - id: e73c3df1
    name: ""
    type: namespace
    rule: sibreal.org
    enable: true
  - id: 093ec2ab
    name: ""
    type: namespace
    rule: skat.media
    enable: true
  - id: ed2eba8a
    name: ""
    type: namespace
    rule: slavicsac.com
    enable: true
  - id: 890f71f7
    name: ""
    type: namespace
    rule: sobesednik.com
    enable: true
  - id: 1fac9ee3
    name: ""
    type: namespace
    rule: sotaproject.com
    enable: true
  - id: 5b3d3c6f
    name: ""
    type: namespace
    rule: spektr.press
    enable: true
  - id: e138d2c8
    name: ""
    type: namespace
    rule: spiegel.de
    enable: true
  - id: 256313f7
    name: ""
    type: namespace
    rule: sputnikipogrom.com
    enable: true
  - id: 82f6e58b
    name: ""
    type: namespace
    rule: strana.news
    enable: true
  - id: 839c02f0
    name: ""
    type: namespace
    rule: strana.today
    enable: true
  - id: 487e3892
    name: ""
    type: namespace
    rule: suspilne.media
    enable: true
  - id: 2c38fdbf
    name: ""
    type: domain
    rule: svidomi.in.ua
    enable: true
  - id: 2c1277d1
    name: ""
    type: namespace
    rule: svoboda.org
    enable: true
  - id: d1bd8b6a
    name: ""
    type: domain
    rule: svoi.kr.ua
    enable: true
  - id: c0b18e65
    name: ""
    type: namespace
    rule: svtv.org
    enable: true
  - id: afae0f5f
    name: ""
    type: namespace
    rule: t-invariant.org
    enable: true
  - id: ecd5de46
    name: ""
    type: namespace
    rule: tayga.info
    enable: true
  - id: "72258497"
    name: ""
    type: namespace
    rule: telegraf.by
    enable: true
  - id: 49a70eb8
    name: ""
    type: namespace
    rule: telegraf.news
    enable: true
  - id: 89e09ee6
    name: ""
    type: domain
    rule: telegraph.co.uk
    enable: true
  - id: 12116d58
    name: ""
    type: namespace
    rule: the-village.ru
    enable: true
  - id: b2619b3a
    name: ""
    type: namespace
    rule: thebarentsobserver.com
    enable: true
  - id: 18c02985
    name: ""
    type: namespace
    rule: thebell.io
    enable: true
  - id: 05c6d612
    name: ""
    type: namespace
    rule: theins.press
    enable: true
  - id: 3d2f2f89
    name: ""
    type: namespace
    rule: theins.ru
    enable: true
  - id: 8c0f604e
    name: ""
    type: namespace
    rule: themoscowtimes.com
    enable: true
  - id: bdd95560
    name: ""
    type: namespace
    rule: thetruestory.news
    enable: true
  - id: f806ccdc
    name: ""
    type: namespace
    rule: tvfreedom.io
    enable: true
  - id: 94f2a884
    name: ""
    type: namespace
    rule: tvrain.ru
    enable: true
  - id: b9f6759e
    name: ""
    type: namespace
    rule: tvrain.tv
    enable: true
  - id: 5283db08
    name: ""
    type: domain
    rule: ui.ill.in.ua
    enable: true
  - id: f52ba641
    name: ""
    type: namespace
    rule: ukr.radio
    enable: true
  - id: 67656ef8
    name: ""
    type: namespace
    rule: ukrainer.net
    enable: true
  - id: 1827ec0d
    name: ""
    type: namespace
    rule: ukrinform.net
    enable: true
  - id: 08ccc0e1
    name: ""
    type: namespace
    rule: unian.ua
    enable: true
  - id: 27732c9d
    name: ""
    type: namespace
    rule: usa.one
    enable: true
  - id: ff4ccd48
    name: ""
    type: namespace
    rule: usatoday.com
    enable: true
  - id: f9c35df1
    name: ""
    type: namespace
    rule: verstka.media
    enable: true
  - id: 6a95447e
    name: ""
    type: namespace
    rule: vesma.one
    enable: true
  - id: d927d297
    name: ""
    type: namespace
    rule: vesma.today
    enable: true
  - id: 3241e541
    name: ""
    type: domain
    rule: vesty.co.il
    enable: true
  - id: 489a8a0a
    name: ""
    type: namespace
    rule: voanews.com
    enable: true
  - id: b05d7622
    name: ""
    type: namespace
    rule: vot-tak.tv
    enable: true
  - id: 79f25ba3
    name: ""
    type: namespace
    rule: welt.de
    enable: true
  - id: 6c4e7e35
    name: ""
    type: namespace
    rule: wonderzine.com
    enable: true
  - id: 5ca960c9
    name: ""
    type: namespace
    rule: yle.fi
    enable: true
  - id: c0582281
    name: ""
    type: namespace
    rule: zahav.ru
    enable: true
  - id: 1b4a91bf
    name: ""
    type: namespace
    rule: zaxid.net
    enable: true
  - id: 0581b0af
    name: ""
    type: namespace
    rule: zerkalo.io
    enable: true
  - id: 32152a65
    name: ""
    type: namespace
    rule: zona.media
    enable: true
- id: 86bca26c
  name: Ovh
  color: '#f2be54'
  interface: Mihomo
  enable: true
  rules:
  - id: bb005b3b
    name: ""
    type: subnet
    rule: 103.166.228.0/24
    enable: true
  - id: 703a88bb
    name: ""
    type: subnet
    rule: 103.167.178.0/23
    enable: true
  - id: a228890f
    name: ""
    type: subnet
    rule: 103.168.196.0/23
    enable: true
  - id: 3999800d
    name: ""
    type: subnet
    rule: 103.170.116.0/23
    enable: true
  - id: f746e83d
    name: ""
    type: subnet
    rule: 103.189.191.0/24
    enable: true
  - id: 433d3506
    name: ""
    type: subnet
    rule: 103.199.80.0/24
    enable: true
  - id: 48a1ca43
    name: ""
    type: subnet
    rule: 103.206.156.0/23
    enable: true
  - id: 5c5c45ad
    name: ""
    type: subnet
    rule: 103.239.50.0/24
    enable: true
  - id: 8eb94201
    name: ""
    type: subnet
    rule: 103.244.227.0/24
    enable: true
  - id: 6a4707d7
    name: ""
    type: subnet
    rule: 103.5.12.0/22
    enable: true
  - id: "30096515"
    name: ""
    type: subnet
    rule: 104.164.137.0/24
    enable: true
  - id: 23be5faa
    name: ""
    type: subnet
    rule: 104.167.16.0/24
    enable: true
  - id: 63f5afad
    name: ""
    type: subnet
    rule: 104.222.182.0/24
    enable: true
  - id: 3a28526d
    name: ""
    type: subnet
    rule: 104.225.253.0/24
    enable: true
  - id: 1b8cfa15
    name: ""
    type: subnet
    rule: 104.234.135.0/24
    enable: true
  - id: 95c401bc
    name: ""
    type: subnet
    rule: 104.234.168.0/24
    enable: true
  - id: eae6f7d5
    name: ""
    type: subnet
    rule: 104.234.198.0/24
    enable: true
  - id: 0b1ed38b
    name: ""
    type: subnet
    rule: 104.234.50.0/24
    enable: true
  - id: 1d41f4d2
    name: ""
    type: subnet
    rule: 104.234.60.0/24
    enable: true
  - id: dd47e914
    name: ""
    type: subnet
    rule: 104.234.94.0/23
    enable: true
  - id: 9e2537bb
    name: ""
    type: subnet
    rule: 104.239.79.0/24
    enable: true
  - id: df7317a2
    name: ""
    type: subnet
    rule: 107.189.64.0/18
    enable: true
  - id: 1b040f6d
    name: ""
    type: subnet
    rule: 108.174.65.0/24
    enable: true
  - id: 019e5133
    name: ""
    type: subnet
    rule: 109.105.195.0/24
    enable: true
  - id: fe6a2a3c
    name: ""
    type: subnet
    rule: 109.110.184.0/24
    enable: true
  - id: 9ed9fc8c
    name: ""
    type: subnet
    rule: 109.122.15.0/24
    enable: true
  - id: f4a7a99c
    name: ""
    type: subnet
    rule: 109.122.20.0/24
    enable: true
  - id: b89e627d
    name: ""
    type: subnet
    rule: 109.122.58.0/24
    enable: true
  - id: 9a6bd521
    name: ""
    type: subnet
    rule: 109.176.153.0/24
    enable: true
  - id: 05e88d13
    name: ""
    type: subnet
    rule: 109.176.40.0/21
    enable: true
  - id: 898494c8
    name: ""
    type: subnet
    rule: 109.176.48.0/21
    enable: true
  - id: f5a460a4
    name: ""
    type: subnet
    rule: 109.232.89.0/24
    enable: true
  - id: 4fc7ea07
    name: ""
    type: subnet
    rule: 114.129.44.0/24
    enable: true
  - id: 9bc266e5
    name: ""
    type: subnet
    rule: 117.18.104.0/24
    enable: true
  - id: 7e038a38
    name: ""
    type: subnet
    rule: 123.100.227.0/24
    enable: true
  - id: bad8880a
    name: ""
    type: subnet
    rule: 128.0.118.0/24
    enable: true
  - id: 9a4473cc
    name: ""
    type: subnet
    rule: 132.243.197.0/24
    enable: true
  - id: c7cfa300
    name: ""
    type: subnet
    rule: 134.195.148.0/23
    enable: true
  - id: e27ab4a9
    name: ""
    type: subnet
    rule: 135.125.0.0/16
    enable: true
  - id: 5a1b51e3
    name: ""
    type: subnet
    rule: 135.148.0.0/16
    enable: true
  - id: 89ecaae5
    name: ""
    type: subnet
    rule: 136.0.95.0/24
    enable: true
  - id: 3446947c
    name: ""
    type: subnet
    rule: 136.143.200.0/24
    enable: true
  - id: 4e77f70c
    name: ""
    type: subnet
    rule: 137.74.0.0/16
    enable: true
  - id: b10c37a4
    name: ""
    type: subnet
    rule: 137.83.50.0/24
    enable: true
  - id: "42075561"
    name: ""
    type: subnet
    rule: 139.99.0.0/16
    enable: true
  - id: eba79a98
    name: ""
    type: subnet
    rule: 140.233.177.0/24
    enable: true
  - id: bf961c84
    name: ""
    type: subnet
    rule: 141.11.1.0/24
    enable: true
  - id: fa05c3b8
    name: ""
    type: subnet
    rule: 141.11.107.0/24
    enable: true
  - id: ba33f95f
    name: ""
    type: subnet
    rule: 141.11.18.0/24
    enable: true
  - id: 981be08c
    name: ""
    type: subnet
    rule: 141.11.187.0/24
    enable: true
  - id: e9f36a28
    name: ""
    type: subnet
    rule: 141.11.21.0/24
    enable: true
  - id: 66075ccc
    name: ""
    type: subnet
    rule: 141.11.250.0/24
    enable: true
  - id: a748f0ae
    name: ""
    type: subnet
    rule: 141.11.32.0/24
    enable: true
  - id: 3dc95508
    name: ""
    type: subnet
    rule: 141.11.39.0/24
    enable: true
  - id: f855afc0
    name: ""
    type: subnet
    rule: 141.11.40.0/24
    enable: true
  - id: 2167ed37
    name: ""
    type: subnet
    rule: 141.11.45.0/24
    enable: true
  - id: d01d4b67
    name: ""
    type: subnet
    rule: 141.11.49.0/24
    enable: true
  - id: 1bec328f
    name: ""
    type: subnet
    rule: 141.11.74.0/23
    enable: true
  - id: 30757cce
    name: ""
    type: subnet
    rule: 141.11.96.0/24
    enable: true
  - id: 9e9a37f9
    name: ""
    type: subnet
    rule: 141.227.128.0/21
    enable: true
  - id: 7f6627cc
    name: ""
    type: subnet
    rule: 141.227.136.0/22
    enable: true
  - id: c8bce6b7
    name: ""
    type: subnet
    rule: 141.227.140.0/24
    enable: true
  - id: 732f818a
    name: ""
    type: subnet
    rule: 141.227.142.0/24
    enable: true
  - id: b76f19b9
    name: ""
    type: subnet
    rule: 141.227.148.0/22
    enable: true
  - id: 9114d0c6
    name: ""
    type: subnet
    rule: 141.227.152.0/24
    enable: true
  - id: 4d3a9871
    name: ""
    type: subnet
    rule: 141.227.154.0/24
    enable: true
  - id: 0b9827bb
    name: ""
    type: subnet
    rule: 141.227.156.0/24
    enable: true
  - id: d9bc6488
    name: ""
    type: subnet
    rule: 141.227.158.0/24
    enable: true
  - id: 00a0fef5
    name: ""
    type: subnet
    rule: 141.227.160.0/24
    enable: true
  - id: 1be62d6b
    name: ""
    type: subnet
    rule: 141.227.162.0/24
    enable: true
  - id: bbd9ea56
    name: ""
    type: subnet
    rule: 141.227.164.0/23
    enable: true
  - id: 4f7ec626
    name: ""
    type: subnet
    rule: 141.227.166.0/24
    enable: true
  - id: b8a6b6e0
    name: ""
    type: subnet
    rule: 141.227.168.0/24
    enable: true
  - id: 24d16b5e
    name: ""
    type: subnet
    rule: 141.227.170.0/24
    enable: true
  - id: 0dcab3a3
    name: ""
    type: subnet
    rule: 141.227.172.0/24
    enable: true
  - id: ad8eb814
    name: ""
    type: subnet
    rule: 141.227.174.0/24
    enable: true
  - id: 3f1c8be1
    name: ""
    type: subnet
    rule: 141.227.176.0/24
    enable: true
  - id: a1d2f938
    name: ""
    type: subnet
    rule: 141.227.178.0/24
    enable: true
  - id: 93f31b88
    name: ""
    type: subnet
    rule: 141.227.180.0/24
    enable: true
  - id: "04243642"
    name: ""
    type: subnet
    rule: 141.227.186.0/24
    enable: true
  - id: 334a98b1
    name: ""
    type: subnet
    rule: 141.227.188.0/23
    enable: true
  - id: 341e5fdc
    name: ""
    type: subnet
    rule: 141.227.190.0/24
    enable: true
  - id: e28fd579
    name: ""
    type: subnet
    rule: 141.8.242.0/24
    enable: true
  - id: 1ed5f243
    name: ""
    type: subnet
    rule: 141.94.0.0/15
    enable: true
  - id: 1530450a
    name: ""
    type: subnet
    rule: 142.111.85.0/24
    enable: true
  - id: 85858d0c
    name: ""
    type: subnet
    rule: 142.249.92.0/24
    enable: true
  - id: 00a10620
    name: ""
    type: subnet
    rule: 142.252.115.0/24
    enable: true
  - id: 8c47aca1
    name: ""
    type: subnet
    rule: 142.252.127.0/24
    enable: true
  - id: 6c8dd884
    name: ""
    type: subnet
    rule: 142.252.51.0/24
    enable: true
  - id: a95c5fd2
    name: ""
    type: subnet
    rule: 142.4.192.0/19
    enable: true
  - id: 3cfd1015
    name: ""
    type: subnet
    rule: 142.44.128.0/17
    enable: true
  - id: 4421c286
    name: ""
    type: subnet
    rule: 143.109.54.0/24
    enable: true
  - id: 13390c03
    name: ""
    type: subnet
    rule: 143.14.231.0/24
    enable: true
  - id: c4196be7
    name: ""
    type: subnet
    rule: 143.14.59.0/24
    enable: true
  - id: 5b8cbd88
    name: ""
    type: subnet
    rule: 143.20.195.0/24
    enable: true
  - id: 759db66f
    name: ""
    type: subnet
    rule: 143.20.215.0/24
    enable: true
  - id: 1145e1b5
    name: ""
    type: subnet
    rule: 143.20.66.0/24
    enable: true
  - id: 2f9719b9
    name: ""
    type: subnet
    rule: 144.2.32.0/19
    enable: true
  - id: 480b0dce
    name: ""
    type: subnet
    rule: 144.217.0.0/16
    enable: true
  - id: 5fba40cc
    name: ""
    type: subnet
    rule: 144.225.123.0/24
    enable: true
  - id: 7df296fb
    name: ""
    type: subnet
    rule: 144.225.127.0/24
    enable: true
  - id: b1de0d84
    name: ""
    type: subnet
    rule: 144.225.162.0/24
    enable: true
  - id: 2f2fc3f3
    name: ""
    type: subnet
    rule: 144.225.178.0/24
    enable: true
  - id: 9bba40de
    name: ""
    type: subnet
    rule: 144.225.52.0/24
    enable: true
  - id: c4af65b8
    name: ""
    type: subnet
    rule: 144.31.149.0/24
    enable: true
  - id: 9853c983
    name: ""
    type: subnet
    rule: 145.239.0.0/16
    enable: true
  - id: 1ef79aaa
    name: ""
    type: subnet
    rule: 145.79.151.0/24
    enable: true
  - id: cf570aa0
    name: ""
    type: subnet
    rule: 146.103.10.0/24
    enable: true
  - id: 03be2216
    name: ""
    type: subnet
    rule: 146.59.0.0/16
    enable: true
  - id: 0ca4fe88
    name: ""
    type: subnet
    rule: 147.135.0.0/16
    enable: true
  - id: d3cc765f
    name: ""
    type: subnet
    rule: 148.113.0.0/18
    enable: true
  - id: "49327818"
    name: ""
    type: subnet
    rule: 148.113.128.0/17
    enable: true
  - id: 8291a4bc
    name: ""
    type: subnet
    rule: 148.113.70.0/24
    enable: true
  - id: a405557e
    name: ""
    type: subnet
    rule: 148.113.72.0/24
    enable: true
  - id: 1b6f5196
    name: ""
    type: subnet
    rule: 148.135.192.0/24
    enable: true
  - id: 7f215c6d
    name: ""
    type: subnet
    rule: 148.222.120.0/22
    enable: true
  - id: 00f29af6
    name: ""
    type: subnet
    rule: 148.222.40.0/22
    enable: true
  - id: ee77d368
    name: ""
    type: subnet
    rule: 149.18.101.0/24
    enable: true
  - id: 6dc264be
    name: ""
    type: subnet
    rule: 149.202.0.0/16
    enable: true
  - id: 978704db
    name: ""
    type: subnet
    rule: 149.5.230.0/24
    enable: true
  - id: f4e4442a
    name: ""
    type: subnet
    rule: 149.56.0.0/16
    enable: true
  - id: 7d926c7c
    name: ""
    type: subnet
    rule: 15.204.0.0/16
    enable: true
  - id: ab46ebcc
    name: ""
    type: subnet
    rule: 15.235.0.0/16
    enable: true
  - id: 5bb56fe3
    name: ""
    type: subnet
    rule: 151.240.1.0/24
    enable: true
  - id: 4216cfc7
    name: ""
    type: subnet
    rule: 151.241.68.0/24
    enable: true
  - id: 5c84715b
    name: ""
    type: subnet
    rule: 151.242.103.0/24
    enable: true
  - id: 54e9250b
    name: ""
    type: subnet
    rule: 151.242.139.0/24
    enable: true
  - id: a7292c67
    name: ""
    type: subnet
    rule: 151.242.76.0/24
    enable: true
  - id: 99d03825
    name: ""
    type: subnet
    rule: 151.243.160.0/22
    enable: true
  - id: 6cb229ee
    name: ""
    type: subnet
    rule: 151.243.236.0/24
    enable: true
  - id: 61cc373b
    name: ""
    type: subnet
    rule: 151.244.78.0/24
    enable: true
  - id: a0730861
    name: ""
    type: subnet
    rule: 151.245.111.0/24
    enable: true
  - id: c2ed6a54
    name: ""
    type: subnet
    rule: 151.245.238.0/24
    enable: true
  - id: 264ff65b
    name: ""
    type: subnet
    rule: 151.245.54.0/24
    enable: true
  - id: 04060c1f
    name: ""
    type: subnet
    rule: 151.246.177.0/24
    enable: true
  - id: f33323aa
    name: ""
    type: subnet
    rule: 151.246.190.0/24
    enable: true
  - id: 3ecabe11
    name: ""
    type: subnet
    rule: 151.247.145.0/24
    enable: true
  - id: 8e8de592
    name: ""
    type: subnet
    rule: 151.247.192.0/24
    enable: true
  - id: 27a7ad34
    name: ""
    type: subnet
    rule: 151.247.205.0/24
    enable: true
  - id: c9132bdb
    name: ""
    type: subnet
    rule: 151.247.217.0/24
    enable: true
  - id: d29629e7
    name: ""
    type: subnet
    rule: 151.247.37.0/24
    enable: true
  - id: b39ae8de
    name: ""
    type: subnet
    rule: 151.80.0.0/16
    enable: true
  - id: 68bb0fe8
    name: ""
    type: subnet
    rule: 152.228.128.0/17
    enable: true
  - id: 08f6af51
    name: ""
    type: subnet
    rule: 153.52.116.0/24
    enable: true
  - id: 90e073fe
    name: ""
    type: subnet
    rule: 155.117.11.0/24
    enable: true
  - id: 3640be4a
    name: ""
    type: subnet
    rule: 155.117.127.0/24
    enable: true
  - id: 96560d52
    name: ""
    type: subnet
    rule: 155.117.13.0/24
    enable: true
  - id: c06307db
    name: ""
    type: subnet
    rule: 155.117.197.0/24
    enable: true
  - id: 10fcc8c9
    name: ""
    type: subnet
    rule: 155.117.233.0/24
    enable: true
  - id: e311c973
    name: ""
    type: subnet
    rule: 155.117.234.0/24
    enable: true
  - id: a2d17f96
    name: ""
    type: subnet
    rule: 155.117.248.0/24
    enable: true
  - id: 25fc0372
    name: ""
    type: subnet
    rule: 155.117.5.0/24
    enable: true
  - id: ddfb7684
    name: ""
    type: subnet
    rule: 155.117.6.0/24
    enable: true
  - id: 2525e14f
    name: ""
    type: subnet
    rule: 157.254.30.0/24
    enable: true
  - id: 670a2b60
    name: ""
    type: subnet
    rule: 158.173.221.0/24
    enable: true
  - id: 779f7e4f
    name: ""
    type: subnet
    rule: 158.62.199.0/24
    enable: true
  - id: 2c0ac660
    name: ""
    type: subnet
    rule: 158.69.0.0/16
    enable: true
  - id: 38d259d6
    name: ""
    type: subnet
    rule: 158.94.170.0/24
    enable: true
  - id: 8597d994
    name: ""
    type: subnet
    rule: 16.216.27.0/24
    enable: true
  - id: 772f8b63
    name: ""
    type: subnet
    rule: 16.217.96.0/24
    enable: true
  - id: ea40ca2e
    name: ""
    type: subnet
    rule: 16.5.198.0/24
    enable: true
  - id: c7ab3d5a
    name: ""
    type: subnet
    rule: 160.20.158.0/23
    enable: true
  - id: ffa2a7ab
    name: ""
    type: subnet
    rule: 160.236.145.0/24
    enable: true
  - id: 728257af
    name: ""
    type: subnet
    rule: 162.141.71.0/24
    enable: true
  - id: f3733fbd
    name: ""
    type: subnet
    rule: 162.19.0.0/16
    enable: true
  - id: f2a8e49d
    name: ""
    type: subnet
    rule: 162.212.35.0/24
    enable: true
  - id: fd58d28b
    name: ""
    type: subnet
    rule: 162.223.195.0/24
    enable: true
  - id: d6fdd444
    name: ""
    type: subnet
    rule: 163.223.88.0/24
    enable: true
  - id: 25203f0e
    name: ""
    type: subnet
    rule: 163.5.132.0/24
    enable: true
  - id: fa2c9c32
    name: ""
    type: subnet
    rule: 163.5.149.0/24
    enable: true
  - id: 507a9479
    name: ""
    type: subnet
    rule: 163.5.187.0/24
    enable: true
  - id: d62e9e1d
    name: ""
    type: subnet
    rule: 163.5.62.0/24
    enable: true
  - id: 7fff6dee
    name: ""
    type: subnet
    rule: 164.132.0.0/16
    enable: true
  - id: b201d01f
    name: ""
    type: subnet
    rule: 164.37.39.0/24
    enable: true
  - id: 173332df
    name: ""
    type: subnet
    rule: 166.0.112.0/24
    enable: true
  - id: 048ab7f0
    name: ""
    type: subnet
    rule: 166.1.85.0/24
    enable: true
  - id: 3f9f0851
    name: ""
    type: subnet
    rule: 166.1.88.0/24
    enable: true
  - id: 5c33dfd8
    name: ""
    type: subnet
    rule: 166.1.90.0/24
    enable: true
  - id: 598d5d59
    name: ""
    type: subnet
    rule: 167.114.0.0/16
    enable: true
  - id: f052916b
    name: ""
    type: subnet
    rule: 167.148.125.0/24
    enable: true
  - id: 56c41c04
    name: ""
    type: subnet
    rule: 167.148.193.0/24
    enable: true
  - id: 7c364e25
    name: ""
    type: subnet
    rule: 167.234.38.0/24
    enable: true
  - id: 88a9e04b
    name: ""
    type: subnet
    rule: 167.253.62.0/24
    enable: true
  - id: 3493b158
    name: ""
    type: subnet
    rule: 168.222.183.0/24
    enable: true
  - id: 0f084b2f
    name: ""
    type: subnet
    rule: 168.222.243.0/24
    enable: true
  - id: dca6b6a0
    name: ""
    type: subnet
    rule: 168.222.43.0/24
    enable: true
  - id: a87e16e5
    name: ""
    type: subnet
    rule: 168.222.49.0/24
    enable: true
  - id: 244fa622
    name: ""
    type: subnet
    rule: 168.245.185.0/24
    enable: true
  - id: a8a70fed
    name: ""
    type: subnet
    rule: 169.40.32.0/24
    enable: true
  - id: cc299626
    name: ""
    type: subnet
    rule: 172.83.201.0/24
    enable: true
  - id: 6cf48dde
    name: ""
    type: subnet
    rule: 176.105.231.0/24
    enable: true
  - id: 9c70190c
    name: ""
    type: subnet
    rule: 176.31.0.0/16
    enable: true
  - id: a6c06a3b
    name: ""
    type: subnet
    rule: 177.111.0.0/19
    enable: true
  - id: e144bb51
    name: ""
    type: subnet
    rule: 177.111.111.0/24
    enable: true
  - id: d7c53728
    name: ""
    type: subnet
    rule: 178.32.0.0/15
    enable: true
  - id: c42f0483
    name: ""
    type: subnet
    rule: 178.83.45.0/24
    enable: true
  - id: accc827d
    name: ""
    type: subnet
    rule: 178.83.46.0/24
    enable: true
  - id: 031761cb
    name: ""
    type: subnet
    rule: 178.92.111.0/24
    enable: true
  - id: 20effe84
    name: ""
    type: subnet
    rule: 178.92.120.0/24
    enable: true
  - id: 2ccbcd3c
    name: ""
    type: subnet
    rule: 178.93.247.0/24
    enable: true
  - id: f92d3332
    name: ""
    type: subnet
    rule: 178.94.22.0/24
    enable: true
  - id: 0332689a
    name: ""
    type: subnet
    rule: 178.95.157.0/24
    enable: true
  - id: d6f97c19
    name: ""
    type: subnet
    rule: 180.131.145.0/24
    enable: true
  - id: 04fecbd4
    name: ""
    type: subnet
    rule: 181.41.194.0/24
    enable: true
  - id: "66736e02"
    name: ""
    type: subnet
    rule: 184.174.96.0/23
    enable: true
  - id: 03cc194a
    name: ""
    type: subnet
    rule: 185.10.200.0/22
    enable: true
  - id: 390a5c9f
    name: ""
    type: subnet
    rule: 185.101.104.0/24
    enable: true
  - id: b34b6412
    name: ""
    type: subnet
    rule: 185.113.138.0/24
    enable: true
  - id: e5faa971
    name: ""
    type: subnet
    rule: 185.113.249.0/24
    enable: true
  - id: 76784f3c
    name: ""
    type: subnet
    rule: 185.12.32.0/23
    enable: true
  - id: b9580835
    name: ""
    type: subnet
    rule: 185.127.28.0/24
    enable: true
  - id: 5f4f3736
    name: ""
    type: subnet
    rule: 185.129.220.0/24
    enable: true
  - id: 33e5137f
    name: ""
    type: subnet
    rule: 185.129.222.0/24
    enable: true
  - id: c1c57e42
    name: ""
    type: subnet
    rule: 185.133.74.0/24
    enable: true
  - id: 8c62c1aa
    name: ""
    type: subnet
    rule: 185.135.188.0/24
    enable: true
  - id: "46219223"
    name: ""
    type: subnet
    rule: 185.137.181.0/24
    enable: true
  - id: 2ebb16b9
    name: ""
    type: subnet
    rule: 185.146.195.0/24
    enable: true
  - id: 925b8ed7
    name: ""
    type: subnet
    rule: 185.15.68.0/22
    enable: true
  - id: a65da991
    name: ""
    type: subnet
    rule: 185.155.218.0/24
    enable: true
  - id: c64ff553
    name: ""
    type: subnet
    rule: 185.162.233.0/24
    enable: true
  - id: 9d8ec1c8
    name: ""
    type: subnet
    rule: 185.170.155.0/24
    enable: true
  - id: fa1c4e75
    name: ""
    type: subnet
    rule: 185.196.221.0/24
    enable: true
  - id: 7fe60fcf
    name: ""
    type: subnet
    rule: 185.207.132.0/24
    enable: true
  - id: 69da0ddb
    name: ""
    type: subnet
    rule: 185.207.134.0/24
    enable: true
  - id: 570f8c01
    name: ""
    type: subnet
    rule: 185.216.126.0/24
    enable: true
  - id: bd0c30e2
    name: ""
    type: subnet
    rule: 185.220.196.0/24
    enable: true
  - id: 011d3be5
    name: ""
    type: subnet
    rule: 185.225.74.0/23
    enable: true
  - id: 90ed2947
    name: ""
    type: subnet
    rule: 185.226.181.0/24
    enable: true
  - id: 36ac55cf
    name: ""
    type: subnet
    rule: 185.228.207.0/24
    enable: true
  - id: 46efad35
    name: ""
    type: subnet
    rule: 185.240.238.0/24
    enable: true
  - id: 3945f3f7
    name: ""
    type: subnet
    rule: 185.241.50.0/23
    enable: true
  - id: 5a2f0594
    name: ""
    type: subnet
    rule: 185.250.41.0/24
    enable: true
  - id: da784b4e
    name: ""
    type: subnet
    rule: 185.251.234.0/24
    enable: true
  - id: 50b327b3
    name: ""
    type: subnet
    rule: 185.255.28.0/24
    enable: true
  - id: e0aed541
    name: ""
    type: subnet
    rule: 185.3.73.0/24
    enable: true
  - id: 7e18b534
    name: ""
    type: subnet
    rule: 185.30.212.0/23
    enable: true
  - id: 8305dac0
    name: ""
    type: subnet
    rule: 185.45.160.0/22
    enable: true
  - id: 88acef25
    name: ""
    type: subnet
    rule: 185.5.39.0/24
    enable: true
  - id: 654280c2
    name: ""
    type: subnet
    rule: 185.6.28.0/24
    enable: true
  - id: 4a667ef0
    name: ""
    type: subnet
    rule: 185.68.137.0/24
    enable: true
  - id: 3fd35909
    name: ""
    type: subnet
    rule: 185.95.157.0/24
    enable: true
  - id: 22a538c7
    name: ""
    type: subnet
    rule: 188.165.0.0/16
    enable: true
  - id: "39464890"
    name: ""
    type: subnet
    rule: 188.220.150.0/24
    enable: true
  - id: 21f1fdc9
    name: ""
    type: subnet
    rule: 188.220.202.0/24
    enable: true
  - id: 73a7cf0c
    name: ""
    type: subnet
    rule: 188.220.22.0/24
    enable: true
  - id: 9c05e599
    name: ""
    type: subnet
    rule: 188.220.38.0/24
    enable: true
  - id: f4b59987
    name: ""
    type: subnet
    rule: 188.255.193.0/24
    enable: true
  - id: ff6ab59c
    name: ""
    type: subnet
    rule: 188.68.164.0/22
    enable: true
  - id: 2d370988
    name: ""
    type: subnet
    rule: 191.101.150.0/24
    enable: true
  - id: f047b1f2
    name: ""
    type: subnet
    rule: 191.101.210.0/24
    enable: true
  - id: b5dd333f
    name: ""
    type: subnet
    rule: 191.101.218.0/24
    enable: true
  - id: d3fa2e1b
    name: ""
    type: subnet
    rule: 191.44.99.0/24
    enable: true
  - id: 0789785c
    name: ""
    type: subnet
    rule: 191.96.140.0/23
    enable: true
  - id: f0f9152a
    name: ""
    type: subnet
    rule: 192.109.11.0/24
    enable: true
  - id: d6bf2384
    name: ""
    type: subnet
    rule: 192.124.170.0/24
    enable: true
  - id: 41fd2f48
    name: ""
    type: subnet
    rule: 192.152.126.0/24
    enable: true
  - id: 64f08ebb
    name: ""
    type: subnet
    rule: 192.177.90.0/24
    enable: true
  - id: 28f95152
    name: ""
    type: subnet
    rule: 192.207.105.0/24
    enable: true
  - id: c3fa247e
    name: ""
    type: subnet
    rule: 192.240.152.0/21
    enable: true
  - id: 70ae3b3f
    name: ""
    type: subnet
    rule: 192.30.124.0/24
    enable: true
  - id: 9bb8e321
    name: ""
    type: subnet
    rule: 192.65.20.0/22
    enable: true
  - id: d033b6d2
    name: ""
    type: subnet
    rule: 192.70.246.0/23
    enable: true
  - id: 4f240a94
    name: ""
    type: subnet
    rule: 192.95.0.0/18
    enable: true
  - id: 917853bf
    name: ""
    type: subnet
    rule: 192.99.0.0/16
    enable: true
  - id: 9f7c70e8
    name: ""
    type: subnet
    rule: 193.149.28.0/22
    enable: true
  - id: 6a35a56e
    name: ""
    type: subnet
    rule: 193.151.166.0/24
    enable: true
  - id: 69b292ce
    name: ""
    type: subnet
    rule: 193.17.223.0/24
    enable: true
  - id: 1cfdfcbb
    name: ""
    type: subnet
    rule: 193.19.76.0/23
    enable: true
  - id: 145bb5bf
    name: ""
    type: subnet
    rule: 193.219.99.0/24
    enable: true
  - id: 6c9d3efe
    name: ""
    type: subnet
    rule: 193.221.202.0/24
    enable: true
  - id: da510faa
    name: ""
    type: subnet
    rule: 193.243.147.0/24
    enable: true
  - id: 29e51311
    name: ""
    type: subnet
    rule: 193.33.176.0/23
    enable: true
  - id: 2a45545a
    name: ""
    type: subnet
    rule: 193.70.0.0/17
    enable: true
  - id: 98cb5ade
    name: ""
    type: subnet
    rule: 193.93.254.0/24
    enable: true
  - id: b2b28c64
    name: ""
    type: subnet
    rule: 194.104.138.0/24
    enable: true
  - id: adb7f476
    name: ""
    type: subnet
    rule: 194.110.171.0/24
    enable: true
  - id: 937e32aa
    name: ""
    type: subnet
    rule: 194.147.159.0/24
    enable: true
  - id: 2be9ea24
    name: ""
    type: subnet
    rule: 194.156.227.0/24
    enable: true
  - id: 51a5d1c5
    name: ""
    type: subnet
    rule: 194.164.230.0/24
    enable: true
  - id: f1451e61
    name: ""
    type: subnet
    rule: 194.61.44.0/23
    enable: true
  - id: 66ed70e1
    name: ""
    type: subnet
    rule: 194.76.173.0/24
    enable: true
  - id: 7e627847
    name: ""
    type: subnet
    rule: 194.76.36.0/23
    enable: true
  - id: 4c3a8220
    name: ""
    type: subnet
    rule: 194.77.220.0/24
    enable: true
  - id: 4120ec52
    name: ""
    type: subnet
    rule: 194.87.205.0/24
    enable: true
  - id: edd61519
    name: ""
    type: subnet
    rule: 194.88.232.0/24
    enable: true
  - id: 3d089dee
    name: ""
    type: subnet
    rule: 195.123.191.0/24
    enable: true
  - id: 914882df
    name: ""
    type: subnet
    rule: 195.144.5.0/24
    enable: true
  - id: c4aee10a
    name: ""
    type: subnet
    rule: 195.20.146.0/24
    enable: true
  - id: 9b7cfc52
    name: ""
    type: subnet
    rule: 195.38.19.0/24
    enable: true
  - id: b41b2f7c
    name: ""
    type: subnet
    rule: 195.62.72.0/23
    enable: true
  - id: d62fb191
    name: ""
    type: subnet
    rule: 195.66.30.0/23
    enable: true
  - id: e16a6c66
    name: ""
    type: subnet
    rule: 198.100.144.0/20
    enable: true
  - id: 7fcac8b9
    name: ""
    type: subnet
    rule: 198.101.27.0/24
    enable: true
  - id: "44729819"
    name: ""
    type: subnet
    rule: 198.17.79.0/24
    enable: true
  - id: 098bc0ce
    name: ""
    type: subnet
    rule: 198.244.128.0/17
    enable: true
  - id: d4bdaa3b
    name: ""
    type: subnet
    rule: 198.245.48.0/20
    enable: true
  - id: 32856ede
    name: ""
    type: subnet
    rule: 198.27.64.0/18
    enable: true
  - id: 32e21a36
    name: ""
    type: subnet
    rule: 198.49.103.0/24
    enable: true
  - id: 3cfb7993
    name: ""
    type: subnet
    rule: 198.50.128.0/17
    enable: true
  - id: f5a18073
    name: ""
    type: subnet
    rule: 199.168.192.0/22
    enable: true
  - id: 9b382285
    name: ""
    type: subnet
    rule: 199.193.138.0/24
    enable: true
  - id: ea964d6a
    name: ""
    type: subnet
    rule: 199.195.140.0/23
    enable: true
  - id: a752dafd
    name: ""
    type: subnet
    rule: 199.204.24.0/24
    enable: true
  - id: d7550d67
    name: ""
    type: subnet
    rule: 199.48.178.0/24
    enable: true
  - id: 47e11c80
    name: ""
    type: subnet
    rule: 199.7.141.0/24
    enable: true
  - id: 77eec87b
    name: ""
    type: subnet
    rule: 2.26.132.0/24
    enable: true
  - id: "003673e1"
    name: ""
    type: subnet
    rule: 2.26.153.0/24
    enable: true
  - id: cf43b9a1
    name: ""
    type: subnet
    rule: 2.27.164.0/24
    enable: true
  - id: feee91e0
    name: ""
    type: subnet
    rule: 2.27.97.0/24
    enable: true
  - id: b73af539
    name: ""
    type: subnet
    rule: 2.58.172.0/24
    enable: true
  - id: 828f544b
    name: ""
    type: subnet6
    rule: 2001:41d0::/32
    enable: true
  - id: 7504c1c3
    name: ""
    type: subnet
    rule: 201.4.67.0/24
    enable: true
  - id: 5e793a89
    name: ""
    type: subnet
    rule: 202.181.0.0/24
    enable: true
  - id: 01107b7f
    name: ""
    type: subnet
    rule: 202.2.60.0/22
    enable: true
  - id: 47537f13
    name: ""
    type: subnet
    rule: 202.92.214.0/23
    enable: true
  - id: 89b4be90
    name: ""
    type: subnet
    rule: 203.27.201.0/24
    enable: true
  - id: 399cff30
    name: ""
    type: subnet
    rule: 203.5.184.0/24
    enable: true
  - id: 73a4062e
    name: ""
    type: subnet
    rule: 205.234.176.0/24
    enable: true
  - id: 70eeaca5
    name: ""
    type: subnet
    rule: 206.168.174.0/23
    enable: true
  - id: 0dab0de2
    name: ""
    type: subnet
    rule: 206.168.95.0/24
    enable: true
  - id: 411240be
    name: ""
    type: subnet
    rule: 206.206.126.0/24
    enable: true
  - id: 596c155c
    name: ""
    type: subnet
    rule: 207.166.205.0/24
    enable: true
  - id: af9faabf
    name: ""
    type: subnet
    rule: 207.166.206.0/24
    enable: true
  - id: d0cf5a3f
    name: ""
    type: subnet
    rule: 207.180.13.0/24
    enable: true
  - id: 786df1ef
    name: ""
    type: subnet
    rule: 207.230.127.0/24
    enable: true
  - id: ce1230f2
    name: ""
    type: subnet
    rule: 207.244.209.0/24
    enable: true
  - id: 778d93a6
    name: ""
    type: subnet
    rule: 208.122.8.0/24
    enable: true
  - id: fa751109
    name: ""
    type: subnet
    rule: 208.64.136.0/21
    enable: true
  - id: d7644a87
    name: ""
    type: subnet
    rule: 209.112.80.0/22
    enable: true
  - id: edd26491
    name: ""
    type: subnet
    rule: 209.126.71.0/24
    enable: true
  - id: 69d0c3c5
    name: ""
    type: subnet
    rule: 209.151.124.0/24
    enable: true
  - id: ec44fef8
    name: ""
    type: subnet
    rule: 209.251.24.0/24
    enable: true
  - id: 79e71c95
    name: ""
    type: subnet
    rule: 209.71.36.0/24
    enable: true
  - id: cb7f515e
    name: ""
    type: subnet
    rule: 212.100.171.0/24
    enable: true
  - id: 7b6350cf
    name: ""
    type: subnet
    rule: 212.134.90.0/24
    enable: true
  - id: 9ef52036
    name: ""
    type: subnet
    rule: 212.192.253.0/24
    enable: true
  - id: ef34ce59
    name: ""
    type: subnet
    rule: 212.69.8.0/24
    enable: true
  - id: f3d2d831
    name: ""
    type: subnet
    rule: 212.74.39.0/24
    enable: true
  - id: 69b8d1cf
    name: ""
    type: subnet
    rule: 213.130.130.0/24
    enable: true
  - id: e2112947
    name: ""
    type: subnet
    rule: 213.130.149.0/24
    enable: true
  - id: 41985ac9
    name: ""
    type: subnet
    rule: 213.177.172.0/24
    enable: true
  - id: bc993c35
    name: ""
    type: subnet
    rule: 213.186.32.0/19
    enable: true
  - id: 3c4e4261
    name: ""
    type: subnet
    rule: 213.218.214.0/24
    enable: true
  - id: 35bd1f39
    name: ""
    type: subnet
    rule: 213.251.128.0/18
    enable: true
  - id: 81a9a5b1
    name: ""
    type: subnet
    rule: 213.32.0.0/17
    enable: true
  - id: 0f5fa0f7
    name: ""
    type: subnet
    rule: 216.122.123.0/24
    enable: true
  - id: ea69c5fa
    name: ""
    type: subnet
    rule: 216.183.120.0/24
    enable: true
  - id: 3a7606b0
    name: ""
    type: subnet
    rule: 216.203.15.0/24
    enable: true
  - id: ac975a9c
    name: ""
    type: subnet
    rule: 216.211.218.0/24
    enable: true
  - id: f9abc022
    name: ""
    type: subnet
    rule: 216.247.96.0/24
    enable: true
  - id: 5b608593
    name: ""
    type: subnet
    rule: 217.11.174.0/24
    enable: true
  - id: 61c7375e
    name: ""
    type: subnet
    rule: 217.182.0.0/16
    enable: true
  - id: e0cd3290
    name: ""
    type: subnet
    rule: 217.217.26.0/24
    enable: true
  - id: 9847b012
    name: ""
    type: subnet
    rule: 217.60.196.0/24
    enable: true
  - id: 6c8da0bb
    name: ""
    type: subnet
    rule: 217.65.73.0/24
    enable: true
  - id: 3ad0d94f
    name: ""
    type: subnet
    rule: 222.167.237.0/24
    enable: true
  - id: e30b3de5
    name: ""
    type: subnet
    rule: 23.136.172.0/24
    enable: true
  - id: f8cc1b7c
    name: ""
    type: subnet
    rule: 23.137.200.0/24
    enable: true
  - id: "05655e16"
    name: ""
    type: subnet
    rule: 23.151.184.0/24
    enable: true
  - id: 6b5151d7
    name: ""
    type: subnet
    rule: 23.156.24.0/23
    enable: true
  - id: b61c3875
    name: ""
    type: subnet
    rule: 23.230.14.0/24
    enable: true
  - id: e3d25c65
    name: ""
    type: subnet
    rule: 23.230.93.0/24
    enable: true
  - id: 9409d6c3
    name: ""
    type: subnet
    rule: 23.92.224.0/19
    enable: true
  - id: 2e570043
    name: ""
    type: subnet6
    rule: 2402:1f00::/32
    enable: true
  - id: fbd219eb
    name: ""
    type: subnet6
    rule: 2604:2dc0::/32
    enable: true
  - id: d42b6550
    name: ""
    type: subnet6
    rule: 2607:5300::/32
    enable: true
  - id: 64143bf1
    name: ""
    type: subnet
    rule: 31.24.81.0/24
    enable: true
  - id: 9ebc3614
    name: ""
    type: subnet
    rule: 31.41.37.0/24
    enable: true
  - id: 68b7e967
    name: ""
    type: subnet
    rule: 31.56.219.0/24
    enable: true
  - id: 708dfbc5
    name: ""
    type: subnet
    rule: 31.57.161.0/24
    enable: true
  - id: "37385e40"
    name: ""
    type: subnet
    rule: 31.57.199.0/24
    enable: true
  - id: 039959ce
    name: ""
    type: subnet
    rule: 31.59.68.0/24
    enable: true
  - id: a7434267
    name: ""
    type: subnet
    rule: 31.6.62.0/24
    enable: true
  - id: 833c1dba
    name: ""
    type: subnet
    rule: 31.77.120.0/24
    enable: true
  - id: 5470faaa
    name: ""
    type: subnet
    rule: 31.99.205.0/24
    enable: true
  - id: dc4191ca
    name: ""
    type: subnet
    rule: 37.187.0.0/16
    enable: true
  - id: 19d28124
    name: ""
    type: subnet
    rule: 37.59.0.0/16
    enable: true
  - id: 647c2b33
    name: ""
    type: subnet
    rule: 37.60.48.0/20
    enable: true
  - id: 269b0364
    name: ""
    type: subnet
    rule: 37.98.145.0/24
    enable: true
  - id: "225825e1"
    name: ""
    type: subnet
    rule: 40.160.0.0/17
    enable: true
  - id: e0ed5af0
    name: ""
    type: subnet
    rule: 40.160.128.0/19
    enable: true
  - id: 405452fd
    name: ""
    type: subnet
    rule: 40.160.224.0/22
    enable: true
  - id: 6a860ba4
    name: ""
    type: subnet
    rule: 40.160.228.0/24
    enable: true
  - id: 292e1b57
    name: ""
    type: subnet
    rule: 40.160.230.0/23
    enable: true
  - id: 343e1f27
    name: ""
    type: subnet
    rule: 40.160.232.0/21
    enable: true
  - id: 5bcea3ec
    name: ""
    type: subnet
    rule: 40.160.240.0/23
    enable: true
  - id: 32165c32
    name: ""
    type: subnet
    rule: 40.160.242.0/24
    enable: true
  - id: f698e519
    name: ""
    type: subnet
    rule: 40.160.244.0/24
    enable: true
  - id: 4886ebd2
    name: ""
    type: subnet
    rule: 40.160.246.0/24
    enable: true
  - id: "731525e4"
    name: ""
    type: subnet
    rule: 40.160.248.0/24
    enable: true
  - id: d4c2af92
    name: ""
    type: subnet
    rule: 40.160.250.0/24
    enable: true
  - id: 3733c5ca
    name: ""
    type: subnet
    rule: 40.160.252.0/24
    enable: true
  - id: "86686201"
    name: ""
    type: subnet
    rule: 40.160.254.0/24
    enable: true
  - id: c4f3fbc8
    name: ""
    type: subnet
    rule: 40.27.29.0/24
    enable: true
  - id: fcff96d7
    name: ""
    type: subnet
    rule: 43.226.0.0/23
    enable: true
  - id: f3d2b71e
    name: ""
    type: subnet
    rule: 45.112.195.0/24
    enable: true
  - id: 2ee90d1f
    name: ""
    type: subnet
    rule: 45.149.185.0/24
    enable: true
  - id: 70fc70b3
    name: ""
    type: subnet
    rule: 45.149.243.0/24
    enable: true
  - id: 9eff191f
    name: ""
    type: subnet
    rule: 45.149.63.0/24
    enable: true
  - id: 5db1e296
    name: ""
    type: subnet
    rule: 45.152.164.0/24
    enable: true
  - id: 158bf30d
    name: ""
    type: subnet
    rule: 45.154.157.0/24
    enable: true
  - id: 17f9d754
    name: ""
    type: subnet
    rule: 45.158.9.0/24
    enable: true
  - id: 2b405cf1
    name: ""
    type: subnet
    rule: 45.177.236.0/22
    enable: true
  - id: 85150c11
    name: ""
    type: subnet
    rule: 45.39.79.0/24
    enable: true
  - id: df0ed541
    name: ""
    type: subnet
    rule: 45.43.142.0/24
    enable: true
  - id: 4072513c
    name: ""
    type: subnet
    rule: 45.66.82.0/23
    enable: true
  - id: 61797f94
    name: ""
    type: subnet
    rule: 45.92.60.0/22
    enable: true
  - id: 101d1b6d
    name: ""
    type: subnet
    rule: 45.94.49.0/24
    enable: true
  - id: 944639cb
    name: ""
    type: subnet
    rule: 46.105.0.0/16
    enable: true
  - id: a3c0c195
    name: ""
    type: subnet
    rule: 46.17.217.0/24
    enable: true
  - id: 09ac0e4e
    name: ""
    type: subnet
    rule: 46.202.232.0/22
    enable: true
  - id: 98e2d08c
    name: ""
    type: subnet
    rule: 46.202.240.0/22
    enable: true
  - id: 1efbacd0
    name: ""
    type: subnet
    rule: 46.203.108.0/22
    enable: true
  - id: 59b24256
    name: ""
    type: subnet
    rule: 46.203.116.0/22
    enable: true
  - id: 94afa2eb
    name: ""
    type: subnet
    rule: 46.203.128.0/22
    enable: true
  - id: 5eb20006
    name: ""
    type: subnet
    rule: 46.203.140.0/22
    enable: true
  - id: 1a7c21d3
    name: ""
    type: subnet
    rule: 46.236.211.0/24
    enable: true
  - id: 8908d2bd
    name: ""
    type: subnet
    rule: 46.244.32.0/20
    enable: true
  - id: 88bb38b2
    name: ""
    type: subnet
    rule: 46.28.236.0/24
    enable: true
  - id: b4af2226
    name: ""
    type: subnet
    rule: 5.135.0.0/16
    enable: true
  - id: 2eedc708
    name: ""
    type: subnet
    rule: 5.172.36.0/24
    enable: true
  - id: b45639a8
    name: ""
    type: subnet
    rule: 5.175.162.0/24
    enable: true
  - id: a9557c79
    name: ""
    type: subnet
    rule: 5.175.168.0/24
    enable: true
  - id: 36eacc5f
    name: ""
    type: subnet
    rule: 5.175.195.0/24
    enable: true
  - id: 0e7c43a7
    name: ""
    type: subnet
    rule: 5.178.106.0/24
    enable: true
  - id: 12239e7c
    name: ""
    type: subnet
    rule: 5.178.110.0/24
    enable: true
  - id: a54b8947
    name: ""
    type: subnet
    rule: 5.182.19.0/24
    enable: true
  - id: adc1006c
    name: ""
    type: subnet
    rule: 5.196.0.0/16
    enable: true
  - id: 5d50dba8
    name: ""
    type: subnet
    rule: 5.231.207.0/24
    enable: true
  - id: 88de3473
    name: ""
    type: subnet
    rule: 5.231.255.0/24
    enable: true
  - id: 3adf3501
    name: ""
    type: subnet
    rule: 5.39.0.0/17
    enable: true
  - id: "16048421"
    name: ""
    type: subnet
    rule: 50.114.91.0/24
    enable: true
  - id: 905a61a6
    name: ""
    type: subnet
    rule: 50.3.38.0/24
    enable: true
  - id: 8d91d8b6
    name: ""
    type: subnet
    rule: 51.161.0.0/16
    enable: true
  - id: a84a334a
    name: ""
    type: subnet
    rule: 51.178.0.0/16
    enable: true
  - id: 1dd957ff
    name: ""
    type: subnet
    rule: 51.195.0.0/16
    enable: true
  - id: 57b54c95
    name: ""
    type: subnet
    rule: 51.210.0.0/16
    enable: true
  - id: 2ba00b3b
    name: ""
    type: subnet
    rule: 51.222.0.0/16
    enable: true
  - id: 467d525a
    name: ""
    type: subnet
    rule: 51.241.1.0/24
    enable: true
  - id: cb0c60c1
    name: ""
    type: subnet
    rule: 51.254.0.0/15
    enable: true
  - id: e73f4b16
    name: ""
    type: subnet
    rule: 51.38.0.0/16
    enable: true
  - id: 25c78343
    name: ""
    type: subnet
    rule: 51.68.0.0/16
    enable: true
  - id: b67ac126
    name: ""
    type: subnet
    rule: 51.75.0.0/16
    enable: true
  - id: d38d23f7
    name: ""
    type: subnet
    rule: 51.77.0.0/16
    enable: true
  - id: 559f9bb0
    name: ""
    type: subnet
    rule: 51.79.0.0/16
    enable: true
  - id: 7443ffaf
    name: ""
    type: subnet
    rule: 51.81.0.0/16
    enable: true
  - id: c8eb68a8
    name: ""
    type: subnet
    rule: 51.83.0.0/16
    enable: true
  - id: f85451af
    name: ""
    type: subnet
    rule: 51.89.0.0/16
    enable: true
  - id: 51fb1445
    name: ""
    type: subnet
    rule: 51.91.0.0/16
    enable: true
  - id: 35e7ed06
    name: ""
    type: subnet
    rule: 54.36.0.0/14
    enable: true
  - id: 1db137dd
    name: ""
    type: subnet
    rule: 57.128.0.0/15
    enable: true
  - id: 526d8253
    name: ""
    type: subnet
    rule: 57.130.0.0/16
    enable: true
  - id: 09ba181a
    name: ""
    type: subnet
    rule: 57.131.0.0/17
    enable: true
  - id: ef78cb08
    name: ""
    type: subnet
    rule: 57.131.128.0/18
    enable: true
  - id: 634c734d
    name: ""
    type: subnet
    rule: 62.122.126.0/24
    enable: true
  - id: 3ee6396c
    name: ""
    type: subnet
    rule: 63.251.117.0/24
    enable: true
  - id: 7867256c
    name: ""
    type: subnet
    rule: 64.112.98.0/24
    enable: true
  - id: 91ca856e
    name: ""
    type: subnet
    rule: 64.225.244.0/23
    enable: true
  - id: 1d43556f
    name: ""
    type: subnet
    rule: 64.94.92.0/23
    enable: true
  - id: a30cf9e7
    name: ""
    type: subnet
    rule: 64.95.150.0/23
    enable: true
  - id: b151c231
    name: ""
    type: subnet
    rule: 66.179.218.0/23
    enable: true
  - id: 11b76602
    name: ""
    type: subnet
    rule: 66.70.128.0/17
    enable: true
  - id: 7bc51628
    name: ""
    type: subnet
    rule: 66.92.11.0/24
    enable: true
  - id: ab9c564a
    name: ""
    type: subnet
    rule: 66.92.161.0/24
    enable: true
  - id: 582f5889
    name: ""
    type: subnet
    rule: 66.92.168.0/24
    enable: true
  - id: 2c9744c3
    name: ""
    type: subnet
    rule: 66.92.25.0/24
    enable: true
  - id: c751759b
    name: ""
    type: subnet
    rule: 68.232.108.0/24
    enable: true
  - id: 30df2ab2
    name: ""
    type: subnet
    rule: 68.65.214.0/24
    enable: true
  - id: e74718ba
    name: ""
    type: subnet
    rule: 69.72.31.0/24
    enable: true
  - id: 3bf6202a
    name: ""
    type: subnet
    rule: 72.11.139.0/24
    enable: true
  - id: beb670cb
    name: ""
    type: subnet
    rule: 72.244.230.0/24
    enable: true
  - id: 40672ade
    name: ""
    type: subnet
    rule: 72.251.0.0/17
    enable: true
  - id: 3dd87bfb
    name: ""
    type: subnet
    rule: 74.0.7.0/24
    enable: true
  - id: be9add6f
    name: ""
    type: subnet
    rule: 76.9.104.0/23
    enable: true
  - id: 630521a4
    name: ""
    type: subnet
    rule: 77.107.88.0/24
    enable: true
  - id: ebcf1060
    name: ""
    type: subnet
    rule: 77.67.28.0/24
    enable: true
  - id: 19ca7802
    name: ""
    type: subnet
    rule: 77.73.34.0/24
    enable: true
  - id: 3d68eab2
    name: ""
    type: subnet
    rule: 77.74.120.0/23
    enable: true
  - id: 5b2cdec9
    name: ""
    type: subnet
    rule: 77.74.122.0/24
    enable: true
  - id: 7d5ba95f
    name: ""
    type: subnet
    rule: 77.74.230.0/24
    enable: true
  - id: af504ede
    name: ""
    type: subnet
    rule: 77.81.138.0/24
    enable: true
  - id: 4f3e8a10
    name: ""
    type: subnet
    rule: 77.83.244.0/24
    enable: true
  - id: f8919970
    name: ""
    type: subnet
    rule: 77.87.123.0/24
    enable: true
  - id: 6de5760a
    name: ""
    type: subnet
    rule: 78.105.156.0/24
    enable: true
  - id: bb1087e2
    name: ""
    type: subnet
    rule: 78.111.138.0/24
    enable: true
  - id: 50d85afc
    name: ""
    type: subnet
    rule: 79.110.61.0/24
    enable: true
  - id: 00ae94a4
    name: ""
    type: subnet
    rule: 79.137.0.0/17
    enable: true
  - id: cc98292e
    name: ""
    type: subnet
    rule: 79.172.216.0/24
    enable: true
  - id: bd9bf04b
    name: ""
    type: subnet
    rule: 79.99.146.0/24
    enable: true
  - id: 64d7f96a
    name: ""
    type: subnet
    rule: 8.18.128.0/24
    enable: true
  - id: 401fc23a
    name: ""
    type: subnet
    rule: 8.18.172.0/24
    enable: true
  - id: 7c19e14d
    name: ""
    type: subnet
    rule: 8.20.110.0/24
    enable: true
  - id: 35806bf9
    name: ""
    type: subnet
    rule: 8.21.41.0/24
    enable: true
  - id: d70f8474
    name: ""
    type: subnet
    rule: 8.24.8.0/21
    enable: true
  - id: 90f5900f
    name: ""
    type: subnet
    rule: 8.26.94.0/24
    enable: true
  - id: ada531b8
    name: ""
    type: subnet
    rule: 8.29.224.0/24
    enable: true
  - id: 297c81eb
    name: ""
    type: subnet
    rule: 8.30.208.0/21
    enable: true
  - id: f37d4516
    name: ""
    type: subnet
    rule: 8.33.128.0/21
    enable: true
  - id: f9e81c05
    name: ""
    type: subnet
    rule: 8.33.136.0/23
    enable: true
  - id: 1874c20d
    name: ""
    type: subnet
    rule: 8.33.96.0/21
    enable: true
  - id: 3024af83
    name: ""
    type: subnet
    rule: 8.7.244.0/24
    enable: true
  - id: c360b941
    name: ""
    type: subnet
    rule: 80.240.94.0/24
    enable: true
  - id: 3866b388
    name: ""
    type: subnet
    rule: 80.86.211.0/24
    enable: true
  - id: "51504061"
    name: ""
    type: subnet
    rule: 80.87.206.0/24
    enable: true
  - id: 3312f4ff
    name: ""
    type: subnet
    rule: 81.168.32.0/24
    enable: true
  - id: e39f4c42
    name: ""
    type: subnet
    rule: 81.168.80.0/24
    enable: true
  - id: d4207f07
    name: ""
    type: subnet
    rule: 82.117.230.0/23
    enable: true
  - id: 337f473f
    name: ""
    type: subnet
    rule: 82.117.245.0/24
    enable: true
  - id: 973994ae
    name: ""
    type: subnet
    rule: 82.129.0.0/22
    enable: true
  - id: 0ddf9dfa
    name: ""
    type: subnet
    rule: 82.152.109.0/24
    enable: true
  - id: 84d86499
    name: ""
    type: subnet
    rule: 82.152.197.0/24
    enable: true
  - id: c5bebd3b
    name: ""
    type: subnet
    rule: 82.152.200.0/24
    enable: true
  - id: a1bf0487
    name: ""
    type: subnet
    rule: 82.152.211.0/24
    enable: true
  - id: 12b3fd70
    name: ""
    type: subnet
    rule: 82.152.226.0/24
    enable: true
  - id: 989cb0a6
    name: ""
    type: subnet
    rule: 82.152.240.0/24
    enable: true
  - id: 97c45ab3
    name: ""
    type: subnet
    rule: 82.152.243.0/24
    enable: true
  - id: d03b828d
    name: ""
    type: subnet
    rule: 82.152.57.0/24
    enable: true
  - id: d1185abe
    name: ""
    type: subnet
    rule: 82.152.58.0/24
    enable: true
  - id: 2fdd9b86
    name: ""
    type: subnet
    rule: 82.152.73.0/24
    enable: true
  - id: d0ccd241
    name: ""
    type: subnet
    rule: 82.152.75.0/24
    enable: true
  - id: 0899f2d3
    name: ""
    type: subnet
    rule: 82.152.8.0/24
    enable: true
  - id: 29f7661b
    name: ""
    type: subnet
    rule: 82.152.98.0/24
    enable: true
  - id: 9e0ac8c8
    name: ""
    type: subnet
    rule: 82.153.205.0/24
    enable: true
  - id: 0d2a4239
    name: ""
    type: subnet
    rule: 82.153.66.0/24
    enable: true
  - id: 11e1213d
    name: ""
    type: subnet
    rule: 82.21.139.0/24
    enable: true
  - id: 542ac12c
    name: ""
    type: subnet
    rule: 82.22.118.0/24
    enable: true
  - id: c0be0e20
    name: ""
    type: subnet
    rule: 82.22.15.0/24
    enable: true
  - id: ea16526d
    name: ""
    type: subnet
    rule: 82.22.25.0/24
    enable: true
  - id: 02aff114
    name: ""
    type: subnet
    rule: 82.24.190.0/24
    enable: true
  - id: "50347494"
    name: ""
    type: subnet
    rule: 82.24.96.0/22
    enable: true
  - id: 5cf00160
    name: ""
    type: subnet
    rule: 82.25.14.0/24
    enable: true
  - id: c7fd0ea2
    name: ""
    type: subnet
    rule: 82.25.146.0/23
    enable: true
  - id: 91b0656d
    name: ""
    type: subnet
    rule: 82.25.44.0/24
    enable: true
  - id: a9a59c85
    name: ""
    type: subnet
    rule: 82.26.176.0/20
    enable: true
  - id: f1b194bb
    name: ""
    type: subnet
    rule: 82.26.81.0/24
    enable: true
  - id: 94b47bdb
    name: ""
    type: subnet
    rule: 82.29.126.0/24
    enable: true
  - id: 1e449565
    name: ""
    type: subnet
    rule: 82.29.93.0/24
    enable: true
  - id: 927170cc
    name: ""
    type: subnet
    rule: 82.38.124.0/22
    enable: true
  - id: f33fbfad
    name: ""
    type: subnet
    rule: 82.38.140.0/22
    enable: true
  - id: a266c66c
    name: ""
    type: subnet
    rule: 82.38.152.0/21
    enable: true
  - id: 6255e05d
    name: ""
    type: subnet
    rule: 82.38.160.0/21
    enable: true
  - id: c6046dbe
    name: ""
    type: subnet
    rule: 82.38.219.0/24
    enable: true
  - id: b3acea1b
    name: ""
    type: subnet
    rule: 82.38.224.0/19
    enable: true
  - id: "85571052"
    name: ""
    type: subnet
    rule: 82.38.82.0/24
    enable: true
  - id: 768bf6ab
    name: ""
    type: subnet
    rule: 82.39.108.0/24
    enable: true
  - id: d504fd5b
    name: ""
    type: subnet
    rule: 82.39.119.0/24
    enable: true
  - id: c9678fce
    name: ""
    type: subnet
    rule: 82.39.156.0/22
    enable: true
  - id: 369626ab
    name: ""
    type: subnet
    rule: 82.39.176.0/21
    enable: true
  - id: "27188256"
    name: ""
    type: subnet
    rule: 82.39.216.0/22
    enable: true
  - id: b1dec265
    name: ""
    type: subnet
    rule: 82.39.224.0/22
    enable: true
  - id: c44598f6
    name: ""
    type: subnet
    rule: 82.40.0.0/20
    enable: true
  - id: 8fb2f5fd
    name: ""
    type: subnet
    rule: 82.40.16.0/22
    enable: true
  - id: 116faf2b
    name: ""
    type: subnet
    rule: 82.41.100.0/22
    enable: true
  - id: 26a255a8
    name: ""
    type: subnet
    rule: 82.41.104.0/22
    enable: true
  - id: dea104e3
    name: ""
    type: subnet
    rule: 82.41.124.0/22
    enable: true
  - id: ffad60ae
    name: ""
    type: subnet
    rule: 82.41.134.0/24
    enable: true
  - id: cc86f6c2
    name: ""
    type: subnet
    rule: 82.41.148.0/22
    enable: true
  - id: 217063b1
    name: ""
    type: subnet
    rule: 82.41.152.0/22
    enable: true
  - id: 8264909e
    name: ""
    type: subnet
    rule: 82.41.160.0/21
    enable: true
  - id: c44d013c
    name: ""
    type: subnet
    rule: 82.41.172.0/22
    enable: true
  - id: 1e0adc11
    name: ""
    type: subnet
    rule: 82.41.176.0/22
    enable: true
  - id: 7794c14f
    name: ""
    type: subnet
    rule: 82.41.184.0/21
    enable: true
  - id: b08054b2
    name: ""
    type: subnet
    rule: 82.41.204.0/22
    enable: true
  - id: 91c7efbc
    name: ""
    type: subnet
    rule: 82.41.212.0/22
    enable: true
  - id: 7ec5cb48
    name: ""
    type: subnet
    rule: 82.41.224.0/21
    enable: true
  - id: 9945a88f
    name: ""
    type: subnet
    rule: 82.41.44.0/22
    enable: true
  - id: bffb2dab
    name: ""
    type: subnet
    rule: 82.41.52.0/22
    enable: true
  - id: 1df46a7c
    name: ""
    type: subnet
    rule: 82.41.68.0/22
    enable: true
  - id: fdc84ca9
    name: ""
    type: subnet
    rule: 82.41.80.0/22
    enable: true
  - id: a821903b
    name: ""
    type: subnet
    rule: 82.41.88.0/22
    enable: true
  - id: 51a97df3
    name: ""
    type: subnet
    rule: 82.47.180.0/24
    enable: true
  - id: cb9b89cf
    name: ""
    type: subnet
    rule: 82.47.63.0/24
    enable: true
  - id: af35ad6d
    name: ""
    type: subnet
    rule: 82.47.98.0/24
    enable: true
  - id: fc5a9113
    name: ""
    type: subnet
    rule: 83.136.214.0/23
    enable: true
  - id: f66c04f6
    name: ""
    type: subnet
    rule: 83.143.16.0/21
    enable: true
  - id: 10f546c8
    name: ""
    type: subnet
    rule: 83.175.167.0/24
    enable: true
  - id: fc1d7fcb
    name: ""
    type: subnet
    rule: 83.175.173.0/24
    enable: true
  - id: ce49dbc6
    name: ""
    type: subnet
    rule: 84.19.167.0/24
    enable: true
  - id: c7fff364
    name: ""
    type: subnet
    rule: 84.32.10.0/24
    enable: true
  - id: 551da927
    name: ""
    type: subnet
    rule: 84.75.33.0/24
    enable: true
  - id: 474c110c
    name: ""
    type: subnet
    rule: 85.118.164.0/24
    enable: true
  - id: 65fca9e7
    name: ""
    type: subnet
    rule: 85.217.144.0/23
    enable: true
  - id: 1b14bcf6
    name: ""
    type: subnet
    rule: 86.54.26.0/24
    enable: true
  - id: 8e8ecdce
    name: ""
    type: subnet
    rule: 87.229.40.0/24
    enable: true
  - id: f2057f92
    name: ""
    type: subnet
    rule: 87.229.51.0/24
    enable: true
  - id: de6744b2
    name: ""
    type: subnet
    rule: 87.76.137.0/24
    enable: true
  - id: e151e49e
    name: ""
    type: subnet
    rule: 87.76.140.0/24
    enable: true
  - id: bad9ebe1
    name: ""
    type: subnet
    rule: 87.76.170.0/24
    enable: true
  - id: 644b3ea5
    name: ""
    type: subnet
    rule: 87.86.181.0/24
    enable: true
  - id: a7b2fc2f
    name: ""
    type: subnet
    rule: 87.86.252.0/24
    enable: true
  - id: b78c440b
    name: ""
    type: subnet
    rule: 87.98.128.0/17
    enable: true
  - id: 41fb9e2c
    name: ""
    type: subnet
    rule: 88.216.221.0/24
    enable: true
  - id: 518a510f
    name: ""
    type: subnet
    rule: 88.218.34.0/24
    enable: true
  - id: fea20246
    name: ""
    type: subnet
    rule: 89.125.172.0/24
    enable: true
  - id: e1698525
    name: ""
    type: subnet
    rule: 89.126.233.0/24
    enable: true
  - id: 73c39972
    name: ""
    type: subnet
    rule: 89.19.44.0/24
    enable: true
  - id: 6d3fc39a
    name: ""
    type: subnet
    rule: 89.213.119.0/24
    enable: true
  - id: 99d9424d
    name: ""
    type: subnet
    rule: 89.213.67.0/24
    enable: true
  - id: bbaad887
    name: ""
    type: subnet
    rule: 89.40.83.0/24
    enable: true
  - id: a516212f
    name: ""
    type: subnet
    rule: 91.121.0.0/16
    enable: true
  - id: 6067692b
    name: ""
    type: subnet
    rule: 91.134.0.0/16
    enable: true
  - id: 49c09291
    name: ""
    type: subnet
    rule: 91.198.19.0/24
    enable: true
  - id: 77b01c9a
    name: ""
    type: subnet
    rule: 91.199.32.0/24
    enable: true
  - id: d6fcaef8
    name: ""
    type: subnet
    rule: 91.199.83.0/24
    enable: true
  - id: a8d5bb7c
    name: ""
    type: subnet
    rule: 91.213.192.0/24
    enable: true
  - id: f93e3e91
    name: ""
    type: subnet
    rule: 91.224.117.0/24
    enable: true
  - id: c82be3d4
    name: ""
    type: subnet
    rule: 91.246.38.0/24
    enable: true
  - id: da47d008
    name: ""
    type: subnet
    rule: 91.90.88.0/21
    enable: true
  - id: 9297590a
    name: ""
    type: subnet
    rule: 92.113.13.0/24
    enable: true
  - id: 19381c27
    name: ""
    type: subnet
    rule: 92.118.168.0/24
    enable: true
  - id: 561a7db1
    name: ""
    type: subnet
    rule: 92.222.0.0/16
    enable: true
  - id: 7965e310
    name: ""
    type: subnet
    rule: 92.246.224.0/19
    enable: true
  - id: a7f8341f
    name: ""
    type: subnet
    rule: 92.62.117.0/24
    enable: true
  - id: 095a2de3
    name: ""
    type: subnet
    rule: 92.62.241.0/24
    enable: true
  - id: 3600b66b
    name: ""
    type: subnet
    rule: 93.114.69.0/24
    enable: true
  - id: 60d19407
    name: ""
    type: subnet
    rule: 93.174.111.0/24
    enable: true
  - id: a8ebaf38
    name: ""
    type: subnet
    rule: 94.158.184.0/24
    enable: true
  - id: a04b4fd3
    name: ""
    type: subnet
    rule: 94.183.158.0/24
    enable: true
  - id: 15e876d3
    name: ""
    type: subnet
    rule: 94.23.0.0/16
    enable: true
  - id: "15526276"
    name: ""
    type: subnet
    rule: 95.135.166.0/23
    enable: true
  - id: 01ecb86c
    name: ""
    type: subnet
    rule: 95.81.72.0/22
    enable: true
  - id: 2869fdd5
    name: ""
    type: subnet
    rule: 96.62.105.0/24
    enable: true
  - id: d8a71161
    name: ""
    type: namespace
    rule: ovhcloud.com
    enable: true
- id: 4ef6948d
  name: Porn
  color: '#54f2ec'
  interface: Mihomo
  enable: true
  rules:
  - id: b78b8f2b
    name: ""
    type: namespace
    rule: xvideos.net
    enable: true
  - id: 7b620669
    name: ""
    type: namespace
    rule: xxxrip.net
    enable: true
  - id: 70c5902b
    name: ""
    type: namespace
    rule: sextor.org
    enable: true
  - id: 1b5af7bc
    name: ""
    type: domain
    rule: attachments.f95zone.to
    enable: true
  - id: 320904ad
    name: ""
    type: namespace
    rule: babepedia.com
    enable: true
  - id: 6b01a9fb
    name: ""
    type: namespace
    rule: chaturbate.com
    enable: true
  - id: f6cc1de8
    name: ""
    type: namespace
    rule: coomer.su
    enable: true
  - id: 4898ead1
    name: ""
    type: namespace
    rule: e-hentai.org
    enable: true
  - id: 806566d4
    name: ""
    type: namespace
    rule: eporner.com
    enable: true
  - id: 8210fb31
    name: ""
    type: namespace
    rule: etahub.com
    enable: true
  - id: 9802e740
    name: ""
    type: namespace
    rule: fansly.com
    enable: true
  - id: c559cf34
    name: ""
    type: namespace
    rule: fapello.com
    enable: true
  - id: d9cbaf86
    name: ""
    type: namespace
    rule: freeones.com
    enable: true
  - id: 1da636de
    name: ""
    type: namespace
    rule: hentai-foundry.com
    enable: true
  - id: f6b8df6a
    name: ""
    type: namespace
    rule: hitomi.la
    enable: true
  - id: a2b2c66d
    name: ""
    type: namespace
    rule: hqporner.com
    enable: true
  - id: 4beed1aa
    name: ""
    type: namespace
    rule: idolcomplex.com
    enable: true
  - id: 4cba83aa
    name: ""
    type: namespace
    rule: manyvids.com
    enable: true
  - id: eb3db3e6
    name: ""
    type: namespace
    rule: mmcdn.com
    enable: true
  - id: cd33b678
    name: ""
    type: namespace
    rule: multporn.net
    enable: true
  - id: a97e82d8
    name: ""
    type: namespace
    rule: nhentai.com
    enable: true
  - id: afe90409
    name: ""
    type: namespace
    rule: nhentai.net
    enable: true
  - id: "37779959"
    name: ""
    type: namespace
    rule: nude-moon.org
    enable: true
  - id: 30110a71
    name: ""
    type: namespace
    rule: phncdn.com
    enable: true
  - id: ebc9fc2f
    name: ""
    type: domain
    rule: phncdn.com.sds.rncdn7.com
    enable: true
  - id: e4e889e7
    name: ""
    type: namespace
    rule: playboy.com
    enable: true
  - id: bfc95610
    name: ""
    type: namespace
    rule: pornhub.com
    enable: true
  - id: 3f03ea39
    name: ""
    type: namespace
    rule: pornhub.org
    enable: true
  - id: b7f2909f
    name: ""
    type: namespace
    rule: pornolab.net
    enable: true
  - id: b31299a2
    name: ""
    type: namespace
    rule: realbooru.com
    enable: true
  - id: 96d3b053
    name: ""
    type: namespace
    rule: reddxxx.com
    enable: true
  - id: 6883f5d6
    name: ""
    type: namespace
    rule: redgifs.com
    enable: true
  - id: 4a6f708c
    name: ""
    type: namespace
    rule: rentry.org
    enable: true
  - id: f7a3c706
    name: ""
    type: namespace
    rule: rule34.art
    enable: true
  - id: 8b0e5f4a
    name: ""
    type: namespace
    rule: rule34.us
    enable: true
  - id: 93ed40bd
    name: ""
    type: namespace
    rule: rule34.xxx
    enable: true
  - id: 51bc00be
    name: ""
    type: namespace
    rule: sankakuapi.com
    enable: true
  - id: 7a5670bb
    name: ""
    type: namespace
    rule: sankakucomplex.com
    enable: true
  - id: 296b11aa
    name: ""
    type: namespace
    rule: sankakustatic.com
    enable: true
  - id: 937051cf
    name: ""
    type: namespace
    rule: theporndude.com
    enable: true
  - id: a241e270
    name: ""
    type: namespace
    rule: ukdevilz.com
    enable: true
  - id: 541ebf1b
    name: ""
    type: namespace
    rule: vipergirls.to
    enable: true
  - id: 3e1af696
    name: ""
    type: namespace
    rule: xhamster.com
    enable: true
  - id: bb29603f
    name: ""
    type: namespace
    rule: xhamsterlive.com
    enable: true
  - id: 0c9ee09c
    name: ""
    type: namespace
    rule: xhcdn.com
    enable: true
  - id: 6eace8ad
    name: ""
    type: namespace
    rule: xnxx-cdn.com
    enable: true
  - id: eacb1d22
    name: ""
    type: namespace
    rule: xnxx-ru.com
    enable: true
  - id: 0eab1038
    name: ""
    type: namespace
    rule: xnxx.com
    enable: true
  - id: 333a39aa
    name: ""
    type: namespace
    rule: xnxx.net
    enable: true
  - id: "57118909"
    name: ""
    type: namespace
    rule: xnxx.tv
    enable: true
  - id: 372097cb
    name: ""
    type: namespace
    rule: xnxx3.com
    enable: true
  - id: dcdae32b
    name: ""
    type: namespace
    rule: xv-ru.com
    enable: true
  - id: 7ce07219
    name: ""
    type: namespace
    rule: xvideos-cdn.com
    enable: true
  - id: 7ed3761c
    name: ""
    type: namespace
    rule: xvideos.com
    enable: true
- id: ee05dd1d
  name: Roblox
  color: '#f254ca'
  interface: Mihomo
  enable: true
  rules:
  - id: 19e12b88
    name: ""
    type: subnet
    rule: 128.116.0.0/17
    enable: true
  - id: 39df4c38
    name: ""
    type: subnet
    rule: 209.206.40.0/21
    enable: true
  - id: 3edb84b9
    name: ""
    type: namespace
    rule: rbxcdn.com
    enable: true
  - id: d8cc918f
    name: ""
    type: namespace
    rule: rbxinfra.net
    enable: true
  - id: 1421b824
    name: ""
    type: namespace
    rule: roblox.com
    enable: true
  - id: b4fd532a
    name: ""
    type: namespace
    rule: robloxdev.com
    enable: true
- id: 2f9be9d6
  name: Telegram
  color: '#9cf254'
  interface: Mihomo
  enable: true
  rules:
  - id: 915a7f0e
    name: ""
    type: subnet
    rule: 149.154.160.0/20
    enable: true
  - id: 099597bc
    name: ""
    type: subnet
    rule: 185.76.151.0/24
    enable: true
  - id: 6d0fc1da
    name: ""
    type: subnet
    rule: 194.221.0.0/16
    enable: true
  - id: 901fe61e
    name: ""
    type: subnet6
    rule: 2001:67c:4e8::/48
    enable: true
  - id: 6915ca74
    name: ""
    type: subnet6
    rule: 2001:b28:f23c::/47
    enable: true
  - id: 887569b6
    name: ""
    type: subnet6
    rule: 2001:b28:f23f::/48
    enable: true
  - id: b89359fe
    name: ""
    type: subnet6
    rule: 2a0a:f280::/32
    enable: true
  - id: 84bea4f4
    name: ""
    type: subnet
    rule: 5.28.192.0/18
    enable: true
  - id: 25a99e39
    name: ""
    type: subnet
    rule: 91.105.192.0/23
    enable: true
  - id: 1061c795
    name: ""
    type: subnet
    rule: 91.108.16.0/21
    enable: true
  - id: aba170bb
    name: ""
    type: subnet
    rule: 91.108.4.0/22
    enable: true
  - id: e2eff2a3
    name: ""
    type: subnet
    rule: 91.108.56.0/22
    enable: true
  - id: f53f7070
    name: ""
    type: subnet
    rule: 91.108.8.0/21
    enable: true
  - id: 141534c3
    name: ""
    type: subnet
    rule: 95.161.64.0/20
    enable: true
  - id: d130953c
    name: ""
    type: namespace
    rule: cdn-telegram.org
    enable: true
  - id: "84678199"
    name: ""
    type: namespace
    rule: comments.app
    enable: true
  - id: 7b114146
    name: ""
    type: namespace
    rule: contest.com
    enable: true
  - id: d7d42414
    name: ""
    type: namespace
    rule: fragment.com
    enable: true
  - id: e2a882d5
    name: ""
    type: namespace
    rule: graph.org
    enable: true
  - id: 26b510ce
    name: ""
    type: namespace
    rule: quiz.directory
    enable: true
  - id: b598b7a4
    name: ""
    type: namespace
    rule: t.me
    enable: true
  - id: 7a9b46e2
    name: ""
    type: namespace
    rule: tdesktop.com
    enable: true
  - id: 6cbed19e
    name: ""
    type: namespace
    rule: telega.one
    enable: true
  - id: 10fcd9ca
    name: ""
    type: namespace
    rule: telegra.ph
    enable: true
  - id: 4ab066b8
    name: ""
    type: namespace
    rule: telegram-cdn.org
    enable: true
  - id: 1899306f
    name: ""
    type: namespace
    rule: telegram.dog
    enable: true
  - id: 6e28a0ea
    name: ""
    type: namespace
    rule: telegram.me
    enable: true
  - id: 746b90f1
    name: ""
    type: namespace
    rule: telegram.org
    enable: true
  - id: 5c647de8
    name: ""
    type: namespace
    rule: telegram.space
    enable: true
  - id: 4ddba02b
    name: ""
    type: namespace
    rule: telesco.pe
    enable: true
  - id: fa44984e
    name: ""
    type: namespace
    rule: tg.dev
    enable: true
  - id: ed9fbb07
    name: ""
    type: namespace
    rule: ton.org
    enable: true
  - id: 5416ea8f
    name: ""
    type: namespace
    rule: tx.me
    enable: true
  - id: f6964947
    name: ""
    type: namespace
    rule: usercontent.dev
    enable: true
- id: 5497508d
  name: Tiktok
  color: '#546ef2'
  interface: Mihomo
  enable: true
  rules:
  - id: 6abfd2d6
    name: ""
    type: namespace
    rule: byteoversea.com
    enable: true
  - id: 7e4180e0
    name: ""
    type: namespace
    rule: ibytedtos.com
    enable: true
  - id: 5baa566d
    name: ""
    type: namespace
    rule: muscdn.com
    enable: true
  - id: 250442ca
    name: ""
    type: namespace
    rule: musical.ly
    enable: true
  - id: 991bcc08
    name: ""
    type: namespace
    rule: tik-tokapi.com
    enable: true
  - id: 05d0be0e
    name: ""
    type: namespace
    rule: tiktok.com
    enable: true
  - id: 5f3dd7af
    name: ""
    type: namespace
    rule: tiktokcdn-eu.com
    enable: true
  - id: f4d91ce3
    name: ""
    type: namespace
    rule: tiktokcdn-us.com
    enable: true
  - id: aebad881
    name: ""
    type: namespace
    rule: tiktokcdn.com
    enable: true
  - id: 7a02a4f4
    name: ""
    type: namespace
    rule: tiktokd.net
    enable: true
  - id: bda6d2d9
    name: ""
    type: namespace
    rule: tiktokd.org
    enable: true
  - id: 2b805590
    name: ""
    type: namespace
    rule: tiktokv.com
    enable: true
  - id: b44c0feb
    name: ""
    type: namespace
    rule: tiktokv.eu
    enable: true
  - id: 70ce316f
    name: ""
    type: namespace
    rule: tiktokv.us
    enable: true
  - id: a4566036
    name: ""
    type: namespace
    rule: tiktokw.us
    enable: true
  - id: 450548bd
    name: ""
    type: namespace
    rule: ttwstatic.com
    enable: true
- id: e0e9ad8c
  name: Twitter
  color: '#f26854'
  interface: Mihomo
  enable: true
  rules:
  - id: 8c8a0334
    name: ""
    type: subnet
    rule: 103.252.112.0/22
    enable: true
  - id: 4ed94141
    name: ""
    type: subnet
    rule: 104.244.41.0/24
    enable: true
  - id: c8820828
    name: ""
    type: subnet
    rule: 104.244.42.0/24
    enable: true
  - id: 81c27313
    name: ""
    type: subnet
    rule: 104.244.44.0/22
    enable: true
  - id: ab0c2bbb
    name: ""
    type: subnet
    rule: 188.64.224.0/21
    enable: true
  - id: e6b1501f
    name: ""
    type: subnet
    rule: 192.133.76.0/22
    enable: true
  - id: 19cc6eae
    name: ""
    type: subnet
    rule: 199.16.156.0/22
    enable: true
  - id: 24f7ddb9
    name: ""
    type: subnet
    rule: 199.59.148.0/22
    enable: true
  - id: "05079853"
    name: ""
    type: subnet
    rule: 199.96.56.0/23
    enable: true
  - id: 44968fc3
    name: ""
    type: subnet
    rule: 202.160.128.0/22
    enable: true
  - id: 9c45bf66
    name: ""
    type: subnet6
    rule: 2400:6680:f000::/36
    enable: true
  - id: fc83cc64
    name: ""
    type: subnet6
    rule: 2606:1f80:f000::/36
    enable: true
  - id: 79e88dd7
    name: ""
    type: subnet6
    rule: 2a04:9d40:f000::/36
    enable: true
  - id: 4d86e64b
    name: ""
    type: subnet
    rule: 64.63.0.0/18
    enable: true
  - id: e28e74fd
    name: ""
    type: namespace
    rule: ads-twitter.com
    enable: true
  - id: 6c206cb9
    name: ""
    type: namespace
    rule: cms-twdigitalassets.com
    enable: true
  - id: 4861c2cd
    name: ""
    type: namespace
    rule: periscope.tv
    enable: true
  - id: 53faae6e
    name: ""
    type: namespace
    rule: pscp.tv
    enable: true
  - id: 503714c5
    name: ""
    type: namespace
    rule: t.co
    enable: true
  - id: 3b3fae47
    name: ""
    type: namespace
    rule: tellapart.com
    enable: true
  - id: "28655325"
    name: ""
    type: namespace
    rule: tweetdeck.com
    enable: true
  - id: 53c4ed50
    name: ""
    type: namespace
    rule: twimg.com
    enable: true
  - id: 23aa5b75
    name: ""
    type: namespace
    rule: twitpic.com
    enable: true
  - id: fbda0014
    name: ""
    type: namespace
    rule: twitter.biz
    enable: true
  - id: 485ad0e9
    name: ""
    type: namespace
    rule: twitter.com
    enable: true
  - id: ccb91f69
    name: ""
    type: namespace
    rule: twitter.jp
    enable: true
  - id: eb2bc409
    name: ""
    type: namespace
    rule: twittercommunity.com
    enable: true
  - id: 5dc9cc76
    name: ""
    type: namespace
    rule: twitterflightschool.com
    enable: true
  - id: fc809d0b
    name: ""
    type: namespace
    rule: twitterinc.com
    enable: true
  - id: 1d8c636c
    name: ""
    type: namespace
    rule: twitteroauth.com
    enable: true
  - id: 5bf156bb
    name: ""
    type: namespace
    rule: twitterstat.us
    enable: true
  - id: 259cc09b
    name: ""
    type: namespace
    rule: twtrdns.net
    enable: true
  - id: 69ac8b44
    name: ""
    type: namespace
    rule: twttr.com
    enable: true
  - id: 8f1b2786
    name: ""
    type: namespace
    rule: twttr.net
    enable: true
  - id: 3311c858
    name: ""
    type: namespace
    rule: twvid.com
    enable: true
  - id: 98e16eee
    name: ""
    type: namespace
    rule: vine.co
    enable: true
  - id: bedb3f48
    name: ""
    type: namespace
    rule: x.com
    enable: true
- id: 4e8ce948
  name: GoogleVideo VPN
  color: '#0e7490'
  interface: Mihomo
  enable: true
  rules: []
- id: 145328f2
  name: Youtube
  color: '#54f296'
  interface: pppoe-wan
  enable: false
  rules:
  - id: a877f736
    name: ""
    type: namespace
    rule: cdn.youtube.com
    enable: true
  - id: dc01379a
    name: ""
    type: namespace
    rule: i.ytimg.com
    enable: true
  - id: 532170eb
    name: ""
    type: namespace
    rule: i9.ytimg.com
    enable: true
  - id: c3f02a14
    name: ""
    type: namespace
    rule: kids.youtube.com
    enable: true
  - id: 7b612697
    name: ""
    type: namespace
    rule: m.youtube.com
    enable: true
  - id: 40ab07d5
    name: ""
    type: namespace
    rule: music.youtube.com
    enable: true
  - id: 023d97a8
    name: ""
    type: namespace
    rule: nhacmp3youtube.com
    enable: true
  - id: 1058c8ec
    name: ""
    type: namespace
    rule: returnyoutubedislikeapi.com
    enable: true
  - id: 36ac9bce
    name: ""
    type: namespace
    rule: s.ytimg.com
    enable: true
  - id: c8fae658
    name: ""
    type: namespace
    rule: signaler-pa.youtube.com
    enable: true
  - id: 8ed5ccd6
    name: ""
    type: namespace
    rule: studio.youtube.com
    enable: true
  - id: 875e1128
    name: ""
    type: namespace
    rule: tv.youtube.com
    enable: true
  - id: 689d1b20
    name: ""
    type: namespace
    rule: wide-youtube.l.google.com
    enable: true
  - id: 940c0ff0
    name: ""
    type: namespace
    rule: withyoutube.com
    enable: true
  - id: 071c41a9
    name: ""
    type: namespace
    rule: youtu.be
    enable: true
  - id: 4730911a
    name: ""
    type: namespace
    rule: youtube-nocookie.com
    enable: true
  - id: d1403501
    name: ""
    type: namespace
    rule: youtube-ui.l.google.com
    enable: true
  - id: 75392b25
    name: ""
    type: namespace
    rule: youtube.ae
    enable: true
  - id: ef97f998
    name: ""
    type: namespace
    rule: youtube.al
    enable: true
  - id: 1cbaa8bf
    name: ""
    type: namespace
    rule: youtube.am
    enable: true
  - id: b8d4de84
    name: ""
    type: namespace
    rule: youtube.at
    enable: true
  - id: d8cf4d5f
    name: ""
    type: namespace
    rule: youtube.az
    enable: true
  - id: 53c9a507
    name: ""
    type: namespace
    rule: youtube.ba
    enable: true
  - id: db32899b
    name: ""
    type: namespace
    rule: youtube.be
    enable: true
  - id: bfbd1725
    name: ""
    type: namespace
    rule: youtube.bg
    enable: true
  - id: e68b9cc0
    name: ""
    type: namespace
    rule: youtube.bh
    enable: true
  - id: 41fb2689
    name: ""
    type: namespace
    rule: youtube.bo
    enable: true
  - id: 01b1815c
    name: ""
    type: namespace
    rule: youtube.by
    enable: true
  - id: 99a8554e
    name: ""
    type: namespace
    rule: youtube.ca
    enable: true
  - id: 046ab898
    name: ""
    type: namespace
    rule: youtube.cat
    enable: true
  - id: "0e506089"
    name: ""
    type: namespace
    rule: youtube.ch
    enable: true
  - id: 1eb3f427
    name: ""
    type: namespace
    rule: youtube.cl
    enable: true
  - id: e10716b8
    name: ""
    type: namespace
    rule: youtube.co
    enable: true
  - id: 78bc7e02
    name: ""
    type: namespace
    rule: youtube.co.ae
    enable: true
  - id: ab02bda4
    name: ""
    type: namespace
    rule: youtube.co.at
    enable: true
  - id: 0f8fe787
    name: ""
    type: namespace
    rule: youtube.co.cr
    enable: true
  - id: 87b310bb
    name: ""
    type: namespace
    rule: youtube.co.hu
    enable: true
  - id: e2d538cd
    name: ""
    type: namespace
    rule: youtube.co.id
    enable: true
  - id: 6db337ff
    name: ""
    type: namespace
    rule: youtube.co.il
    enable: true
  - id: 7446a621
    name: ""
    type: namespace
    rule: youtube.co.in
    enable: true
  - id: 6f8c1a34
    name: ""
    type: namespace
    rule: youtube.co.jp
    enable: true
  - id: d15fa170
    name: ""
    type: namespace
    rule: youtube.co.ke
    enable: true
  - id: b4831c49
    name: ""
    type: namespace
    rule: youtube.co.kr
    enable: true
  - id: e234df4c
    name: ""
    type: namespace
    rule: youtube.co.ma
    enable: true
  - id: 6c7ec1cd
    name: ""
    type: namespace
    rule: youtube.co.nz
    enable: true
  - id: f0677266
    name: ""
    type: namespace
    rule: youtube.co.th
    enable: true
  - id: b106704c
    name: ""
    type: namespace
    rule: youtube.co.tz
    enable: true
  - id: 4746947d
    name: ""
    type: namespace
    rule: youtube.co.ug
    enable: true
  - id: 666c1cab
    name: ""
    type: namespace
    rule: youtube.co.uk
    enable: true
  - id: 2e67e784
    name: ""
    type: namespace
    rule: youtube.co.ve
    enable: true
  - id: e889a658
    name: ""
    type: namespace
    rule: youtube.co.za
    enable: true
  - id: 42386ab1
    name: ""
    type: namespace
    rule: youtube.co.zw
    enable: true
  - id: 7573ca0f
    name: ""
    type: namespace
    rule: youtube.com
    enable: true
  - id: c6c3f95f
    name: ""
    type: namespace
    rule: youtube.com.ar
    enable: true
  - id: 19b70412
    name: ""
    type: namespace
    rule: youtube.com.au
    enable: true
  - id: 6e2b185b
    name: ""
    type: namespace
    rule: youtube.com.az
    enable: true
  - id: e3b9526d
    name: ""
    type: namespace
    rule: youtube.com.bd
    enable: true
  - id: 78e128b7
    name: ""
    type: namespace
    rule: youtube.com.bh
    enable: true
  - id: 964b7a37
    name: ""
    type: namespace
    rule: youtube.com.bo
    enable: true
  - id: 31c87cf7
    name: ""
    type: namespace
    rule: youtube.com.br
    enable: true
  - id: a2152874
    name: ""
    type: namespace
    rule: youtube.com.by
    enable: true
  - id: 95dc03bc
    name: ""
    type: namespace
    rule: youtube.com.co
    enable: true
  - id: 0632d689
    name: ""
    type: namespace
    rule: youtube.com.do
    enable: true
  - id: 46ebf289
    name: ""
    type: namespace
    rule: youtube.com.ec
    enable: true
  - id: 9a961ff8
    name: ""
    type: namespace
    rule: youtube.com.ee
    enable: true
  - id: 687cc050
    name: ""
    type: namespace
    rule: youtube.com.eg
    enable: true
  - id: 69827d7b
    name: ""
    type: namespace
    rule: youtube.com.es
    enable: true
  - id: fdbfba0d
    name: ""
    type: namespace
    rule: youtube.com.gh
    enable: true
  - id: badd8d19
    name: ""
    type: namespace
    rule: youtube.com.gr
    enable: true
  - id: 9f292be9
    name: ""
    type: namespace
    rule: youtube.com.gt
    enable: true
  - id: 3eddeb0b
    name: ""
    type: namespace
    rule: youtube.com.hk
    enable: true
  - id: 9055b38e
    name: ""
    type: namespace
    rule: youtube.com.hn
    enable: true
  - id: d8af5385
    name: ""
    type: namespace
    rule: youtube.com.hr
    enable: true
  - id: fa838efc
    name: ""
    type: namespace
    rule: youtube.com.jm
    enable: true
  - id: d0496bd0
    name: ""
    type: namespace
    rule: youtube.com.jo
    enable: true
  - id: c302f17b
    name: ""
    type: namespace
    rule: youtube.com.kw
    enable: true
  - id: 6139aa1b
    name: ""
    type: namespace
    rule: youtube.com.lb
    enable: true
  - id: aa996f68
    name: ""
    type: namespace
    rule: youtube.com.lv
    enable: true
  - id: 50f0bb80
    name: ""
    type: namespace
    rule: youtube.com.ly
    enable: true
  - id: 5689e51f
    name: ""
    type: namespace
    rule: youtube.com.mk
    enable: true
  - id: 9bf34183
    name: ""
    type: namespace
    rule: youtube.com.mt
    enable: true
  - id: 6fb1e3f0
    name: ""
    type: namespace
    rule: youtube.com.mx
    enable: true
  - id: 6e7ce530
    name: ""
    type: namespace
    rule: youtube.com.my
    enable: true
  - id: d502a9a0
    name: ""
    type: namespace
    rule: youtube.com.ng
    enable: true
  - id: 33b95dce
    name: ""
    type: namespace
    rule: youtube.com.ni
    enable: true
  - id: 0bee8878
    name: ""
    type: namespace
    rule: youtube.com.om
    enable: true
  - id: d34172f7
    name: ""
    type: namespace
    rule: youtube.com.pa
    enable: true
  - id: ee18fe37
    name: ""
    type: namespace
    rule: youtube.com.pe
    enable: true
  - id: 0a5f97dd
    name: ""
    type: namespace
    rule: youtube.com.ph
    enable: true
  - id: a04b184e
    name: ""
    type: namespace
    rule: youtube.com.pk
    enable: true
  - id: 140ff9c1
    name: ""
    type: namespace
    rule: youtube.com.pt
    enable: true
  - id: 9c2dd584
    name: ""
    type: namespace
    rule: youtube.com.py
    enable: true
  - id: b655f592
    name: ""
    type: namespace
    rule: youtube.com.qa
    enable: true
  - id: 7ba0c5aa
    name: ""
    type: namespace
    rule: youtube.com.ro
    enable: true
  - id: dabea0ed
    name: ""
    type: namespace
    rule: youtube.com.sa
    enable: true
  - id: 9effe1f4
    name: ""
    type: namespace
    rule: youtube.com.sg
    enable: true
  - id: 5ac7b30a
    name: ""
    type: namespace
    rule: youtube.com.sv
    enable: true
  - id: d700a141
    name: ""
    type: namespace
    rule: youtube.com.tn
    enable: true
  - id: 8ca520cc
    name: ""
    type: namespace
    rule: youtube.com.tr
    enable: true
  - id: d1d80d0e
    name: ""
    type: namespace
    rule: youtube.com.tw
    enable: true
  - id: 0c651ec1
    name: ""
    type: namespace
    rule: youtube.com.ua
    enable: true
  - id: 10c61881
    name: ""
    type: namespace
    rule: youtube.com.uy
    enable: true
  - id: fb1879ca
    name: ""
    type: namespace
    rule: youtube.com.ve
    enable: true
  - id: c2ce153b
    name: ""
    type: namespace
    rule: youtube.cr
    enable: true
  - id: 07e6e1c0
    name: ""
    type: namespace
    rule: youtube.cz
    enable: true
  - id: dca8684e
    name: ""
    type: namespace
    rule: youtube.de
    enable: true
  - id: 60a44328
    name: ""
    type: namespace
    rule: youtube.dk
    enable: true
  - id: 5fd3e1e5
    name: ""
    type: namespace
    rule: youtube.ee
    enable: true
  - id: 68f4b600
    name: ""
    type: namespace
    rule: youtube.es
    enable: true
  - id: e9c8cce3
    name: ""
    type: namespace
    rule: youtube.fi
    enable: true
  - id: aa3e1fd3
    name: ""
    type: namespace
    rule: youtube.fr
    enable: true
  - id: f2b9c86e
    name: ""
    type: namespace
    rule: youtube.ge
    enable: true
  - id: b78758f3
    name: ""
    type: namespace
    rule: youtube.googleapis.com
    enable: true
  - id: fe7b57dd
    name: ""
    type: namespace
    rule: youtube.gr
    enable: true
  - id: f253f56a
    name: ""
    type: namespace
    rule: youtube.gt
    enable: true
  - id: 74798f58
    name: ""
    type: namespace
    rule: youtube.hk
    enable: true
  - id: acdff9bb
    name: ""
    type: namespace
    rule: youtube.hr
    enable: true
  - id: 731d9077
    name: ""
    type: namespace
    rule: youtube.hu
    enable: true
  - id: 02a06246
    name: ""
    type: namespace
    rule: youtube.ie
    enable: true
  - id: 4e0b2cbe
    name: ""
    type: namespace
    rule: youtube.in
    enable: true
  - id: cee91343
    name: ""
    type: namespace
    rule: youtube.iq
    enable: true
  - id: 0d86ac71
    name: ""
    type: namespace
    rule: youtube.is
    enable: true
  - id: 783c9dde
    name: ""
    type: namespace
    rule: youtube.it
    enable: true
  - id: 49d77657
    name: ""
    type: namespace
    rule: youtube.jo
    enable: true
  - id: 39ec23d0
    name: ""
    type: namespace
    rule: youtube.jp
    enable: true
  - id: 191b91dc
    name: ""
    type: namespace
    rule: youtube.kr
    enable: true
  - id: b70e1bd8
    name: ""
    type: namespace
    rule: youtube.kz
    enable: true
  - id: c09df3d5
    name: ""
    type: namespace
    rule: youtube.la
    enable: true
  - id: db4ba276
    name: ""
    type: namespace
    rule: youtube.lk
    enable: true
  - id: 371dabc4
    name: ""
    type: namespace
    rule: youtube.lt
    enable: true
  - id: eb0d473d
    name: ""
    type: namespace
    rule: youtube.lu
    enable: true
  - id: effd4fa4
    name: ""
    type: namespace
    rule: youtube.lv
    enable: true
  - id: 142a5a50
    name: ""
    type: namespace
    rule: youtube.ly
    enable: true
  - id: 5fa68121
    name: ""
    type: namespace
    rule: youtube.ma
    enable: true
  - id: dac3bab8
    name: ""
    type: namespace
    rule: youtube.md
    enable: true
  - id: 2f3b065e
    name: ""
    type: namespace
    rule: youtube.me
    enable: true
  - id: facf2bb4
    name: ""
    type: namespace
    rule: youtube.mk
    enable: true
  - id: b6e088f9
    name: ""
    type: namespace
    rule: youtube.mn
    enable: true
  - id: "35792059"
    name: ""
    type: namespace
    rule: youtube.mx
    enable: true
  - id: d49eea6f
    name: ""
    type: namespace
    rule: youtube.my
    enable: true
  - id: 642ed5ee
    name: ""
    type: namespace
    rule: youtube.ng
    enable: true
  - id: eb2a4774
    name: ""
    type: namespace
    rule: youtube.ni
    enable: true
  - id: ab46db94
    name: ""
    type: namespace
    rule: youtube.nl
    enable: true
  - id: 24681cce
    name: ""
    type: namespace
    rule: youtube.no
    enable: true
  - id: 1535a369
    name: ""
    type: namespace
    rule: youtube.pa
    enable: true
  - id: 2c0d34fa
    name: ""
    type: namespace
    rule: youtube.pe
    enable: true
  - id: a68d7633
    name: ""
    type: namespace
    rule: youtube.ph
    enable: true
  - id: 07468bef
    name: ""
    type: namespace
    rule: youtube.pk
    enable: true
  - id: 9338c745
    name: ""
    type: namespace
    rule: youtube.pl
    enable: true
  - id: dc932c25
    name: ""
    type: namespace
    rule: youtube.pr
    enable: true
  - id: a80f27c1
    name: ""
    type: namespace
    rule: youtube.pt
    enable: true
  - id: 42f3ef1c
    name: ""
    type: namespace
    rule: youtube.qa
    enable: true
  - id: 7f87f7ab
    name: ""
    type: namespace
    rule: youtube.ro
    enable: true
  - id: ade0c639
    name: ""
    type: namespace
    rule: youtube.rs
    enable: true
  - id: 59ec08ee
    name: ""
    type: namespace
    rule: youtube.ru
    enable: true
  - id: 5c1510f0
    name: ""
    type: namespace
    rule: youtube.sa
    enable: true
  - id: 8c885c5b
    name: ""
    type: namespace
    rule: youtube.se
    enable: true
  - id: 7e40339b
    name: ""
    type: namespace
    rule: youtube.sg
    enable: true
  - id: aed709ae
    name: ""
    type: namespace
    rule: youtube.si
    enable: true
  - id: 3c9e42a6
    name: ""
    type: namespace
    rule: youtube.sk
    enable: true
  - id: e13e91c2
    name: ""
    type: namespace
    rule: youtube.sn
    enable: true
  - id: 69bb7730
    name: ""
    type: namespace
    rule: youtube.soy
    enable: true
  - id: 098c92ed
    name: ""
    type: namespace
    rule: youtube.sv
    enable: true
  - id: 102f926f
    name: ""
    type: namespace
    rule: youtube.tn
    enable: true
  - id: cc6251e2
    name: ""
    type: namespace
    rule: youtube.tv
    enable: true
  - id: 078866b7
    name: ""
    type: namespace
    rule: youtube.ua
    enable: true
  - id: 5a2dcd19
    name: ""
    type: namespace
    rule: youtube.ug
    enable: true
  - id: 05a21db7
    name: ""
    type: namespace
    rule: youtube.uy
    enable: true
  - id: f19ade37
    name: ""
    type: namespace
    rule: youtube.vn
    enable: true
  - id: b03fbb5d
    name: ""
    type: namespace
    rule: youtubeeducation.com
    enable: true
  - id: "02099030"
    name: ""
    type: namespace
    rule: youtubeembeddedplayer.googleapis.com
    enable: true
  - id: a543c937
    name: ""
    type: namespace
    rule: youtubefanfest.com
    enable: true
  - id: df28cda5
    name: ""
    type: namespace
    rule: youtubegaming.com
    enable: true
  - id: ced49605
    name: ""
    type: namespace
    rule: youtubego.co.id
    enable: true
  - id: a4549c85
    name: ""
    type: namespace
    rule: youtubego.co.in
    enable: true
  - id: 5c9963c2
    name: ""
    type: namespace
    rule: youtubego.com
    enable: true
  - id: "70168310"
    name: ""
    type: namespace
    rule: youtubego.com.br
    enable: true
  - id: e87bec02
    name: ""
    type: namespace
    rule: youtubego.id
    enable: true
  - id: 8e77e72f
    name: ""
    type: namespace
    rule: youtubego.in
    enable: true
  - id: 6bf618bd
    name: ""
    type: namespace
    rule: youtubei.googleapis.com
    enable: true
  - id: 7af8241e
    name: ""
    type: namespace
    rule: youtubei.youtube.com
    enable: true
  - id: c9511f1e
    name: ""
    type: namespace
    rule: youtubekids.com
    enable: true
  - id: 2bab8bf6
    name: ""
    type: namespace
    rule: youtubemobilesupport.com
    enable: true
  - id: 895b193d
    name: ""
    type: namespace
    rule: yt.be
    enable: true
  - id: 37ba8f10
    name: ""
    type: namespace
    rule: yt3.ggpht.com
    enable: true
  - id: 3b06696e
    name: ""
    type: namespace
    rule: yt3.googleusercontent.com
    enable: true
  - id: 7823a5b7
    name: ""
    type: namespace
    rule: yt4.ggpht.com
    enable: true
  - id: e393273f
    name: ""
    type: namespace
    rule: ytimg.com
    enable: true
  - id: 1a944a06
    name: ""
    type: namespace
    rule: ytimg.l.google.com
    enable: true
  - id: 1199ade5
    name: ""
    type: namespace
    rule: yt-video-upload.l.google.com
    enable: true
- id: a1b2c3d4
  name: PS5
  color: '#003791'
  interface: Mihomo
  enable: true
  rules:
  - id: b2c3d4e5
    name: ""
    type: namespace
    rule: playstation.com
    enable: true
  - id: c3d4e5f6
    name: ""
    type: namespace
    rule: playstation.net
    enable: true
  - id: d4e5f6a7
    name: ""
    type: namespace
    rule: playstationnetwork.com
    enable: true
  - id: e5f6a7b8
    name: ""
    type: namespace
    rule: sonyentertainmentnetwork.com
    enable: true
  - id: f6a7b8c9
    name: ""
    type: namespace
    rule: playstation.org
    enable: true
  - id: a7b8c9d0
    name: ""
    type: namespace
    rule: np.playstation.net
    enable: true
  - id: b8c9d0e1
    name: ""
    type: namespace
    rule: np.communication.playstation.net
    enable: true
  - id: c9d0e1f2
    name: ""
    type: namespace
    rule: np.ac.playstation.net
    enable: true
  - id: d0e1f2a3
    name: ""
    type: namespace
    rule: np.community.playstation.net
    enable: true
  - id: e1f2a3b4
    name: ""
    type: namespace
    rule: np.dl.playstation.net
    enable: true
  - id: f2a3b4c5
    name: ""
    type: namespace
    rule: dl.playstation.net
    enable: true
  - id: a3b4c5d6
    name: ""
    type: namespace
    rule: stun.playstation.net
    enable: true
  - id: b4c5d6e7
    name: ""
    type: namespace
    rule: update.playstation.net
    enable: true
  - id: c5d6e7f8
    name: ""
    type: namespace
    rule: ndmdhs.com
    enable: true
  - id: "55000000"
    name: ""
    type: namespace
    rule: psn.com
    enable: true
  - id: "55000001"
    name: ""
    type: namespace
    rule: sony.com
    enable: true
  - id: "55000002"
    name: ""
    type: namespace
    rule: sonyinteractive.com
    enable: true
  - id: "55000003"
    name: ""
    type: namespace
    rule: gtix.net
    enable: true

ASSET_EOF
  save_stream /usr/bin/geomask-seed-lists.py 755 <<'ASSET_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# geomask-seed-lists.py - restore MagiTrickle domain lists from the geomask template.
#
# The template ships the full `groups:` block (25 groups / ~3300 rules, no secrets).
# This tool splices that block into the live MagiTrickle config, preserving the host's
# `app:` settings and trailing keys. magitrickled must be STOPPED while it writes
# (the daemon owns the file); the geomask shell wrapper handles stop/start + sync.
#
# Modes:
#   --check-empty   exit 0 if the live config has 0 groups (safe to auto-seed), else 1. No writes.
#   (default)       write template groups into config (backup first), print CHANGED summary.
#   --force         same as default; used by the shell to express intent (this tool always overwrites).
#   --template P    template path (default /etc/geomask/lists/magitrickle-groups.yaml)
#   --config P      config path  (default /etc/magitrickle/state/config.yaml)
import sys, os, re, time

TEMPLATE = '/etc/geomask/lists/magitrickle-groups.yaml'
CONFIG = '/etc/magitrickle/state/config.yaml'

def parse_args():
    mode = 'write'
    tpl, cfg = TEMPLATE, CONFIG
    for a in sys.argv[1:]:
        if a == '--check-empty': mode = 'check'
        elif a == '--force': mode = 'write'
        elif a.startswith('--template='): tpl = a.split('=', 1)[1]
        elif a.startswith('--config='): cfg = a.split('=', 1)[1]
    return mode, tpl, cfg

def read_lines(p):
    with open(p, encoding='utf-8') as f:
        return f.read().split('\n')

def groups_region(lines):
    """Return (gi, si): indices of the `groups:` line and the next top-level key (or len)."""
    gi = None
    for i, l in enumerate(lines):
        if l == 'groups:' and gi is None:
            gi = i
            break
    if gi is None:
        return None, None
    si = len(lines)
    for i in range(gi + 1, len(lines)):
        if re.match(r'^[A-Za-z]', lines[i]):  # next top-level key (subscriptions:, etc.)
            si = i
            break
    return gi, si

def count_groups(lines):
    gi, si = groups_region(lines)
    if gi is None:
        return 0
    return sum(1 for l in lines[gi + 1:si] if l.startswith('- id:'))

def main():
    mode, tpl, cfg = parse_args()
    if not os.path.exists(tpl):
        print('ERR template missing: %s' % tpl); return 2
    tlines = read_lines(tpl)
    ti, _ = groups_region(tlines)
    if ti is None:
        print('ERR template has no `groups:` section'); return 2
    groups_lines = tlines[ti:]
    while groups_lines and groups_lines[-1].strip() == '':
        groups_lines.pop()
    if not any(l.startswith('- id:') for l in groups_lines):
        print('ERR template groups block is empty'); return 2

    cur = read_lines(cfg) if os.path.exists(cfg) else None
    ng = count_groups(cur) if cur else 0

    if mode == 'check':
        # exit 0 if empty (auto-seed is safe), 1 if it already has groups
        sys.exit(0 if ng == 0 else 1)

    if cur is None:
        print('ERR live config missing (%s); start magitrickle first' % cfg); return 2

    gi, si = groups_region(cur)
    if gi is None:
        new = cur + groups_lines
    else:
        new = cur[:gi] + groups_lines + cur[si:]

    ts = time.strftime('%Y%m%d%H%M%S')
    bak = cfg + '.bak_geomask_' + ts
    with open(bak, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(cur).rstrip('\n') + '\n')

    tmp = cfg + '.gm.tmp'
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(new).rstrip('\n') + '\n')
    os.replace(tmp, cfg)

    ng2 = count_groups(new)
    nrules = sum(1 for l in groups_lines if l.startswith('  - id:'))
    print('CHANGED before=%d after=%d rules=%d backup=%s' % (ng, ng2, nrules, os.path.basename(bak)))
    return 0

if __name__ == '__main__':
    sys.exit(main())

ASSET_EOF
}

# v1.13.0: restore MagiTrickle domain lists from the bundled template.
#   seed_lists ""    -> auto: seed only if MagiTrickle has no groups (fresh install)
#   seed_lists force -> overwrite current groups with the template (backup first)
# magitrickled owns config.yaml, so it is stopped around the write, then restarted + synced.
seed_lists() {
  _force="${1:-}"
  _tpl="$(P /etc/geomask/lists/magitrickle-groups.yaml)"
  _cfg="$(P /etc/magitrickle/state/config.yaml)"
  _py="$(P /usr/bin/geomask-seed-lists.py)"
  [ -s "$_tpl" ] || { warn "lists template missing ($_tpl) - skip seed"; return 0; }
  [ -f "$_py" ]  || { warn "seed script missing ($_py) - skip seed"; return 0; }
  if [ "$_force" != force ]; then
    [ -f "$_cfg" ] || { info "lists: MagiTrickle config not created yet - auto-seed deferred (it seeds once magitrickle initializes)"; return 0; }
    python3 "$_py" --check-empty --config="$_cfg" --template="$_tpl" || { info "lists: MagiTrickle already configured - auto-seed skipped (use --seed-lists to restore)"; return 0; }
  fi
  info "lists: seeding MagiTrickle groups from template (mode=${_force:-ifempty})..."
  initd magitrickle stop >/dev/null 2>&1 || true
  _out=$(python3 "$_py" --config="$_cfg" --template="$_tpl" 2>&1); _rc=$?
  initd magitrickle start >/dev/null 2>&1 || true
  sleep 2
  svc_alive magitrickled || warn "magitrickle did not come back after seed"
  # regenerate mihomo rulesets + hot-reload mihomo (no mihomo restart)
  sh "$(P /root/sync_mtrickle_mihomo.sh)" >/dev/null 2>&1 || true
  controller_curl -s -X PUT "http://127.0.0.1:9090/configs" -H 'Content-Type: application/json' \
    -d '{"path":"/etc/mihomo/config.yaml"}' >/dev/null 2>&1 || true
  printf '%s\n' "$_out" | sed 's/^/  | /'
  if [ "$_rc" -eq 0 ]; then info "lists: seed applied"; else bad "lists: seed failed rc=$_rc"; fi
  return "$_rc"
}

step5_check() {
  _need=0
  _s="$(P /root/sync_mtrickle_mihomo.sh)"
  if [ -s "$_s" ]; then
    info "sync script: present"
    [ -x "$_s" ] || warn "sync script not executable (chmod +x on router)"
  else
    bad "sync script missing: /root/sync_mtrickle_mihomo.sh"; _need=1
  fi
  if crontab -l 2>/dev/null | grep -q 'sync_mtrickle_mihomo'; then info "cron */5: present"; else bad "cron entry missing"; _need=1; fi
  # v1.10.0: event sync watchdog (service enabled + running; graceful if script absent on old installs)
  if [ -x "$(P /etc/init.d/geomask-syncd)" ]; then
    if pgrep -f geomask-syncd.sh >/dev/null 2>&1; then info "syncd: running"
    else warn "syncd: installed but not running"; _need=1; fi
    ls "$(P /etc/rc.d)" 2>/dev/null | grep -q 'geomask-syncd' && info "syncd: enabled" || { warn "syncd: not enabled"; _need=1; }
  else
    bad "syncd: /etc/init.d/geomask-syncd missing"; _need=1
  fi
  if [ -x "$(P /usr/bin/geomask-guard.sh)" ]; then info "guard: present"; else bad "guard missing: /usr/bin/geomask-guard.sh"; _need=1; fi
  if [ -x "$(P /etc/hotplug.d/iface/99-geomask-guard)" ]; then info "guard hotplug: present"; else bad "guard hotplug missing"; _need=1; fi
  if crontab -l 2>/dev/null | grep -q 'geomask-guard'; then info "guard cron */5: present"; else bad "guard cron missing"; _need=1; fi
  # v1.11.0: node audit plumbing
  if [ -x "$(P /usr/bin/geomask-node-scan.sh)" ] && [ -s "$(P /etc/geomask-nodes.conf)" ]; then info "node-scan: installed"
  else bad "node-scan missing (script/conf)"; _need=1; fi
  if crontab -l 2>/dev/null | grep -q 'geomask-node-scan'; then info "nodescan cron 03:30: present"; else bad "nodescan cron missing"; _need=1; fi
  # v1.14.0: youtube edge watchdog
  # v1.21.5: the VPN lane must contain ONLY subscription nodes. DIRECT as a group member was a
  # workaround for a misdiagnosis (the real cause was provider health-check hiding every node);
  # left in place it silently moves VPN-lane traffic onto the plain, DPI-visible path instead of
  # failing loudly. A hard 502 is the correct behaviour when the subscription is down.
  if grep -qE '^  - name: VPN$' "$_c" 2>/dev/null; then
    _vb=$(awk '/^  - name: VPN$/{f=1;next} f&&/^  - name:/{exit} f' "$_c")
    if printf '%s' "$_vb" | grep -qE '^\s*-\s+DIRECT\s*$'; then
      bad "the VPN group contains DIRECT - VPN-lane traffic leaks to the plain path silently when nodes fail"; _need=1
    else
      _vt=$(printf '%s' "$_vb" | awk '/^    type:/{sub(/^[^:]*:[[:space:]]*/,"");print;exit}')
      info "VPN lane: ${_vt:-unknown}, subscription nodes only"
    fi
  fi
  if [ -x "$(P /usr/bin/geomask-ytwatch.sh)" ] && [ -s "$(P /etc/geomask-ytwatch.conf)" ]; then info "ytwatch: installed"
  else bad "ytwatch missing (script/conf)"; _need=1; fi
  if crontab -l 2>/dev/null | grep -qE '# geomask-ytwatch$'; then info "ytwatch cron */5: present"; else bad "ytwatch cron missing"; _need=1; fi
  if crontab -l 2>/dev/null | grep -qE '# geomask-ytwatch-reset$'; then info "ytwatch reset cron: present"; else bad "ytwatch reset cron missing"; _need=1; fi
  # v1.15.0: torrent admin
  if [ -x "$(P /usr/bin/geomask-torrent.sh)" ] && [ -d "$(P /etc/geomask/torrent)" ]; then info "torrent admin: installed"
  else bad "torrent admin missing (script/dir)"; _need=1; fi
  # v1.18.0: VPN lane audit
  if [ -x "$(P /usr/bin/geomask-vpnwatch.sh)" ] && [ -s "$(P /etc/geomask/vpnwatch.conf)" ]; then info "vpnwatch: installed"
  else bad "vpnwatch missing (script/conf)"; _need=1; fi
  if crontab -l 2>/dev/null | grep -qE '# geomask-vpnwatch$'; then info "vpnwatch cron */1: present"
  else warn "vpnwatch cron missing - the lane audit will not run"; fi
  if [ -x "$(P /usr/bin/geomask-morning-check.sh)" ]; then info "morning check: installed"
  else bad "morning check script missing"; _need=1; fi
  # the extra lane is optional; report it, never fail because of it
  if [ -e "$(P /sys/class/net/VPN-noP2P)" ]; then
    info "lane VPN-noP2P: netdev present (MagiTrickle can select it)"
  else
    info "lane VPN-noP2P: not installed (run: geomask-lane.sh install)"
  fi
  svc_alive magitrickled && info "magitrickle: running" || { bad "magitrickle not running"; _need=1; }
  return $_need
}
step5_apply() {
  save_stream /root/sync_mtrickle_mihomo.sh 755 <<'ASSET_EOF'
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

ASSET_EOF
  save_stream /etc/mihomo/ruleset/ytdirect.yaml 644 <<'ASSET_EOF'
# YouTube DIRECT ruleset (non-video assets) - DO NOT EDIT manually.
# v1.13.3: googlevideo.com / manifest.googlevideo.com REMOVED here -> routed to VPN via the
# "GoogleVideo VPN" MagiTrickle group (sync writes ytvpn.yaml; rule precedes this one).
payload:
  - DOMAIN-SUFFIX,cdn.youtube.com
  - DOMAIN-SUFFIX,i.ytimg.com
  - DOMAIN-SUFFIX,i9.ytimg.com
  - DOMAIN-SUFFIX,kids.youtube.com
  - DOMAIN-SUFFIX,m.youtube.com
  - DOMAIN-SUFFIX,music.youtube.com
  - DOMAIN-SUFFIX,nhacmp3youtube.com
  - DOMAIN-SUFFIX,returnyoutubedislikeapi.com
  - DOMAIN-SUFFIX,s.ytimg.com
  - DOMAIN-SUFFIX,signaler-pa.youtube.com
  - DOMAIN-SUFFIX,studio.youtube.com
  - DOMAIN-SUFFIX,tv.youtube.com
  - DOMAIN-SUFFIX,wide-youtube.l.google.com
  - DOMAIN-SUFFIX,withyoutube.com
  - DOMAIN-SUFFIX,youtu.be
  - DOMAIN-SUFFIX,youtube-nocookie.com
  - DOMAIN-SUFFIX,youtube-ui.l.google.com
  - DOMAIN-SUFFIX,youtube.ae
  - DOMAIN-SUFFIX,youtube.al
  - DOMAIN-SUFFIX,youtube.am
  - DOMAIN-SUFFIX,youtube.at
  - DOMAIN-SUFFIX,youtube.az
  - DOMAIN-SUFFIX,youtube.ba
  - DOMAIN-SUFFIX,youtube.be
  - DOMAIN-SUFFIX,youtube.bg
  - DOMAIN-SUFFIX,youtube.bh
  - DOMAIN-SUFFIX,youtube.bo
  - DOMAIN-SUFFIX,youtube.by
  - DOMAIN-SUFFIX,youtube.ca
  - DOMAIN-SUFFIX,youtube.cat
  - DOMAIN-SUFFIX,youtube.ch
  - DOMAIN-SUFFIX,youtube.cl
  - DOMAIN-SUFFIX,youtube.co
  - DOMAIN-SUFFIX,youtube.co.ae
  - DOMAIN-SUFFIX,youtube.co.at
  - DOMAIN-SUFFIX,youtube.co.cr
  - DOMAIN-SUFFIX,youtube.co.hu
  - DOMAIN-SUFFIX,youtube.co.id
  - DOMAIN-SUFFIX,youtube.co.il
  - DOMAIN-SUFFIX,youtube.co.in
  - DOMAIN-SUFFIX,youtube.co.jp
  - DOMAIN-SUFFIX,youtube.co.ke
  - DOMAIN-SUFFIX,youtube.co.kr
  - DOMAIN-SUFFIX,youtube.co.ma
  - DOMAIN-SUFFIX,youtube.co.nz
  - DOMAIN-SUFFIX,youtube.co.th
  - DOMAIN-SUFFIX,youtube.co.tz
  - DOMAIN-SUFFIX,youtube.co.ug
  - DOMAIN-SUFFIX,youtube.co.uk
  - DOMAIN-SUFFIX,youtube.co.ve
  - DOMAIN-SUFFIX,youtube.co.za
  - DOMAIN-SUFFIX,youtube.co.zw
  - DOMAIN-SUFFIX,youtube.com
  - DOMAIN-SUFFIX,youtube.com.ar
  - DOMAIN-SUFFIX,youtube.com.au
  - DOMAIN-SUFFIX,youtube.com.az
  - DOMAIN-SUFFIX,youtube.com.bd
  - DOMAIN-SUFFIX,youtube.com.bh
  - DOMAIN-SUFFIX,youtube.com.bo
  - DOMAIN-SUFFIX,youtube.com.br
  - DOMAIN-SUFFIX,youtube.com.by
  - DOMAIN-SUFFIX,youtube.com.co
  - DOMAIN-SUFFIX,youtube.com.do
  - DOMAIN-SUFFIX,youtube.com.ec
  - DOMAIN-SUFFIX,youtube.com.ee
  - DOMAIN-SUFFIX,youtube.com.eg
  - DOMAIN-SUFFIX,youtube.com.es
  - DOMAIN-SUFFIX,youtube.com.gh
  - DOMAIN-SUFFIX,youtube.com.gr
  - DOMAIN-SUFFIX,youtube.com.gt
  - DOMAIN-SUFFIX,youtube.com.hk
  - DOMAIN-SUFFIX,youtube.com.hn
  - DOMAIN-SUFFIX,youtube.com.hr
  - DOMAIN-SUFFIX,youtube.com.jm
  - DOMAIN-SUFFIX,youtube.com.jo
  - DOMAIN-SUFFIX,youtube.com.kw
  - DOMAIN-SUFFIX,youtube.com.lb
  - DOMAIN-SUFFIX,youtube.com.lv
  - DOMAIN-SUFFIX,youtube.com.ly
  - DOMAIN-SUFFIX,youtube.com.mk
  - DOMAIN-SUFFIX,youtube.com.mt
  - DOMAIN-SUFFIX,youtube.com.mx
  - DOMAIN-SUFFIX,youtube.com.my
  - DOMAIN-SUFFIX,youtube.com.ng
  - DOMAIN-SUFFIX,youtube.com.ni
  - DOMAIN-SUFFIX,youtube.com.om
  - DOMAIN-SUFFIX,youtube.com.pa
  - DOMAIN-SUFFIX,youtube.com.pe
  - DOMAIN-SUFFIX,youtube.com.ph
  - DOMAIN-SUFFIX,youtube.com.pk
  - DOMAIN-SUFFIX,youtube.com.pt
  - DOMAIN-SUFFIX,youtube.com.py
  - DOMAIN-SUFFIX,youtube.com.qa
  - DOMAIN-SUFFIX,youtube.com.ro
  - DOMAIN-SUFFIX,youtube.com.sa
  - DOMAIN-SUFFIX,youtube.com.sg
  - DOMAIN-SUFFIX,youtube.com.sv
  - DOMAIN-SUFFIX,youtube.com.tn
  - DOMAIN-SUFFIX,youtube.com.tr
  - DOMAIN-SUFFIX,youtube.com.tw
  - DOMAIN-SUFFIX,youtube.com.ua
  - DOMAIN-SUFFIX,youtube.com.uy
  - DOMAIN-SUFFIX,youtube.com.ve
  - DOMAIN-SUFFIX,youtube.cr
  - DOMAIN-SUFFIX,youtube.cz
  - DOMAIN-SUFFIX,youtube.de
  - DOMAIN-SUFFIX,youtube.dk
  - DOMAIN-SUFFIX,youtube.ee
  - DOMAIN-SUFFIX,youtube.es
  - DOMAIN-SUFFIX,youtube.fi
  - DOMAIN-SUFFIX,youtube.fr
  - DOMAIN-SUFFIX,youtube.ge
  - DOMAIN-SUFFIX,youtube.googleapis.com
  - DOMAIN-SUFFIX,youtube.gr
  - DOMAIN-SUFFIX,youtube.gt
  - DOMAIN-SUFFIX,youtube.hk
  - DOMAIN-SUFFIX,youtube.hr
  - DOMAIN-SUFFIX,youtube.hu
  - DOMAIN-SUFFIX,youtube.ie
  - DOMAIN-SUFFIX,youtube.in
  - DOMAIN-SUFFIX,youtube.iq
  - DOMAIN-SUFFIX,youtube.is
  - DOMAIN-SUFFIX,youtube.it
  - DOMAIN-SUFFIX,youtube.jo
  - DOMAIN-SUFFIX,youtube.jp
  - DOMAIN-SUFFIX,youtube.kr
  - DOMAIN-SUFFIX,youtube.kz
  - DOMAIN-SUFFIX,youtube.la
  - DOMAIN-SUFFIX,youtube.lk
  - DOMAIN-SUFFIX,youtube.lt
  - DOMAIN-SUFFIX,youtube.lu
  - DOMAIN-SUFFIX,youtube.lv
  - DOMAIN-SUFFIX,youtube.ly
  - DOMAIN-SUFFIX,youtube.ma
  - DOMAIN-SUFFIX,youtube.md
  - DOMAIN-SUFFIX,youtube.me
  - DOMAIN-SUFFIX,youtube.mk
  - DOMAIN-SUFFIX,youtube.mn
  - DOMAIN-SUFFIX,youtube.mx
  - DOMAIN-SUFFIX,youtube.my
  - DOMAIN-SUFFIX,youtube.ng
  - DOMAIN-SUFFIX,youtube.ni
  - DOMAIN-SUFFIX,youtube.nl
  - DOMAIN-SUFFIX,youtube.no
  - DOMAIN-SUFFIX,youtube.pa
  - DOMAIN-SUFFIX,youtube.pe
  - DOMAIN-SUFFIX,youtube.ph
  - DOMAIN-SUFFIX,youtube.pk
  - DOMAIN-SUFFIX,youtube.pl
  - DOMAIN-SUFFIX,youtube.pr
  - DOMAIN-SUFFIX,youtube.pt
  - DOMAIN-SUFFIX,youtube.qa
  - DOMAIN-SUFFIX,youtube.ro
  - DOMAIN-SUFFIX,youtube.rs
  - DOMAIN-SUFFIX,youtube.ru
  - DOMAIN-SUFFIX,youtube.sa
  - DOMAIN-SUFFIX,youtube.se
  - DOMAIN-SUFFIX,youtube.sg
  - DOMAIN-SUFFIX,youtube.si
  - DOMAIN-SUFFIX,youtube.sk
  - DOMAIN-SUFFIX,youtube.sn
  - DOMAIN-SUFFIX,youtube.soy
  - DOMAIN-SUFFIX,youtube.sv
  - DOMAIN-SUFFIX,youtube.tn
  - DOMAIN-SUFFIX,youtube.tv
  - DOMAIN-SUFFIX,youtube.ua
  - DOMAIN-SUFFIX,youtube.ug
  - DOMAIN-SUFFIX,youtube.uy
  - DOMAIN-SUFFIX,youtube.vn
  - DOMAIN-SUFFIX,youtubeeducation.com
  - DOMAIN-SUFFIX,youtubeembeddedplayer.googleapis.com
  - DOMAIN-SUFFIX,youtubefanfest.com
  - DOMAIN-SUFFIX,youtubegaming.com
  - DOMAIN-SUFFIX,youtubego.co.id
  - DOMAIN-SUFFIX,youtubego.co.in
  - DOMAIN-SUFFIX,youtubego.com
  - DOMAIN-SUFFIX,youtubego.com.br
  - DOMAIN-SUFFIX,youtubego.id
  - DOMAIN-SUFFIX,youtubego.in
  - DOMAIN-SUFFIX,youtubei.googleapis.com
  - DOMAIN-SUFFIX,youtubei.youtube.com
  - DOMAIN-SUFFIX,youtubekids.com
  - DOMAIN-SUFFIX,youtubemobilesupport.com
  - DOMAIN-SUFFIX,yt.be
  - DOMAIN-SUFFIX,yt3.ggpht.com
  - DOMAIN-SUFFIX,yt3.googleusercontent.com
  - DOMAIN-SUFFIX,yt4.ggpht.com
  - DOMAIN-SUFFIX,ytimg.com
  - DOMAIN-SUFFIX,ytimg.l.google.com

ASSET_EOF
  # v1.13.3: googlevideo -> VPN. Source of truth is the MagiTrickle group "GoogleVideo VPN";
  # sync regenerates ytvpn.yaml from it. Seed the file only if missing so mihomo -t passes before
  # first sync; never clobber an existing one here.
  if [ ! -s "$(P /etc/mihomo/ruleset/ytvpn.yaml)" ]; then
    save_stream /etc/mihomo/ruleset/ytvpn.yaml 644 <<'ASSET_EOF'
# Bootstrap for googlevideo -> VPN. SOURCE OF TRUTH is the MagiTrickle group "GoogleVideo VPN"
# (:8080); /root/sync_mtrickle_mihomo.sh regenerates this file from that group on every sync.
# This seed only matters before the first sync so mihomo -t has a valid ruleset. Edit in MagiTrickle.
payload:
  - DOMAIN-SUFFIX,googlevideo.com

ASSET_EOF
  else
    info "ytvpn list: keeping existing /etc/mihomo/ruleset/ytvpn.yaml (sync-managed)"
  fi
  # v1.17.0: lane split - IP rules must never reach the restricted VPN subscription.
  # mtrickle_bulk.yaml is sync-generated; seed it empty so mihomo -t passes before the first sync.
  if [ ! -s "$(P /etc/mihomo/ruleset/mtrickle_bulk.yaml)" ]; then
    printf '%s\n%s\n' '# AUTO-GENERATED by /root/sync_mtrickle_mihomo.sh from magitrickle config - DO NOT EDIT' 'payload: []' > "$(P /etc/mihomo/ruleset/mtrickle_bulk.yaml)"
    info "mtrickle_bulk list: created empty (sync will fill it)"
  else
    info "mtrickle_bulk list: keeping existing /etc/mihomo/ruleset/mtrickle_bulk.yaml"
  fi
  # v1.15.0: torrent tracker allow-list -> DIRECT (static asset, generated by geomask-torrent.sh)
  if [ ! -s "$(P /etc/mihomo/ruleset/torrentdirect.yaml)" ]; then
    save_stream /etc/mihomo/ruleset/torrentdirect.yaml 644 <<'ASSET_EOF'
# AUTO-GENERATED from public tracker lists (ngosang/trackerslist, XIU2/TrackersListCollection)
# Policy: trackers must never be swallowed by the VPN lists. Do not edit by hand.
payload:
  - DOMAIN-SUFFIX,004430.xyz
  - DOMAIN-SUFFIX,1.tracker.eu.org
  - DOMAIN-SUFFIX,1337.abcvg.info
  - DOMAIN-SUFFIX,admin.52ywp.com
  - DOMAIN-SUFFIX,anime-tracker.aruku.kro.kr
  - DOMAIN-SUFFIX,bittorrent-tracker.e-n-c-r-y-p-t.net
  - DOMAIN-SUFFIX,bt-tracker.de
  - DOMAIN-SUFFIX,bt1.archive.org
  - DOMAIN-SUFFIX,bt2.archive.org
  - DOMAIN-SUFFIX,edgev.duckdns.org
  - DOMAIN-SUFFIX,evan.im
  - DOMAIN-SUFFIX,exodus.desync.com
  - DOMAIN-SUFFIX,explodie.org
  - DOMAIN-SUFFIX,gargoyleperch.de
  - DOMAIN-SUFFIX,ht.therarbg.to
  - DOMAIN-SUFFIX,ipv4announce.sktorrent.eu
  - DOMAIN-SUFFIX,ipv6.govt.hu
  - DOMAIN-SUFFIX,kolankoalastree.newtrackon.co.nz
  - DOMAIN-SUFFIX,mail.segso.net
  - DOMAIN-SUFFIX,martin-gebhardt.eu
  - DOMAIN-SUFFIX,ns575949.ip-51-222-82.net
  - DOMAIN-SUFFIX,nyaa.tracker.wf
  - DOMAIN-SUFFIX,open.demonii.com
  - DOMAIN-SUFFIX,open.ftorrent.com
  - DOMAIN-SUFFIX,open.stealth.si
  - DOMAIN-SUFFIX,open.tracker.cl
  - DOMAIN-SUFFIX,open.tracker.ink
  - DOMAIN-SUFFIX,opentor.org
  - DOMAIN-SUFFIX,opentracker.lain.moscow
  - DOMAIN-SUFFIX,opentracker2.lain.moscow
  - DOMAIN-SUFFIX,p4p.arenabg.com
  - DOMAIN-SUFFIX,retracker.hotplug.ru
  - DOMAIN-SUFFIX,retracker01-msk-virt.corbina.net
  - DOMAIN-SUFFIX,seedpeer.net
  - DOMAIN-SUFFIX,t.213891.xyz
  - DOMAIN-SUFFIX,t.overflow.biz
  - DOMAIN-SUFFIX,torrent.tracker.durukanbal.com
  - DOMAIN-SUFFIX,torrentsmd.com
  - DOMAIN-SUFFIX,tr.abiir.top
  - DOMAIN-SUFFIX,tr.burnabyhighstar.com
  - DOMAIN-SUFFIX,tr.highstar.shop
  - DOMAIN-SUFFIX,tr.nyacat.pw
  - DOMAIN-SUFFIX,tr3.ysagin.top
  - DOMAIN-SUFFIX,tr4ck3r.duckdns.org
  - DOMAIN-SUFFIX,tracker-udp.gbitt.info
  - DOMAIN-SUFFIX,tracker.7471.top
  - DOMAIN-SUFFIX,tracker.aruku.ovh
  - DOMAIN-SUFFIX,tracker.breizh.pm
  - DOMAIN-SUFFIX,tracker.cn.nyaa.net
  - DOMAIN-SUFFIX,tracker.corpscorp.online
  - DOMAIN-SUFFIX,tracker.ddunlimited.net
  - DOMAIN-SUFFIX,tracker.dhitechnical.com
  - DOMAIN-SUFFIX,tracker.dler.com
  - DOMAIN-SUFFIX,tracker.dler.org
  - DOMAIN-SUFFIX,tracker.ducks.party
  - DOMAIN-SUFFIX,tracker.evergarden.uk
  - DOMAIN-SUFFIX,tracker.farted.net
  - DOMAIN-SUFFIX,tracker.filemail.com
  - DOMAIN-SUFFIX,tracker.fnix.net
  - DOMAIN-SUFFIX,tracker.foreverpirates.co
  - DOMAIN-SUFFIX,tracker.gmi.gd
  - DOMAIN-SUFFIX,tracker.ilibr.org
  - DOMAIN-SUFFIX,tracker.internetwarriors.net
  - DOMAIN-SUFFIX,tracker.k.vu
  - DOMAIN-SUFFIX,tracker.kuroy.me
  - DOMAIN-SUFFIX,tracker.midnightprogrammer.net
  - DOMAIN-SUFFIX,tracker.mywaifu.best
  - DOMAIN-SUFFIX,tracker.nekomi.cn
  - DOMAIN-SUFFIX,tracker.nyaa.net
  - DOMAIN-SUFFIX,tracker.nyaa.vc
  - DOMAIN-SUFFIX,tracker.okade.pro
  - DOMAIN-SUFFIX,tracker.opentrackr.com
  - DOMAIN-SUFFIX,tracker.opentrackr.org
  - DOMAIN-SUFFIX,tracker.peerfect.org
  - DOMAIN-SUFFIX,tracker.playground.ru
  - DOMAIN-SUFFIX,tracker.pmman.tech
  - DOMAIN-SUFFIX,tracker.qingwapt.org
  - DOMAIN-SUFFIX,tracker.qu.ax
  - DOMAIN-SUFFIX,tracker.renfei.net
  - DOMAIN-SUFFIX,tracker.sela.st
  - DOMAIN-SUFFIX,tracker.skynetcloud.site
  - DOMAIN-SUFFIX,tracker.skyts.net
  - DOMAIN-SUFFIX,tracker.theoks.net
  - DOMAIN-SUFFIX,tracker.torrent.eu.org
  - DOMAIN-SUFFIX,tracker.torrents.observer
  - DOMAIN-SUFFIX,tracker.tryhackx.org
  - DOMAIN-SUFFIX,tracker.waaa.moe
  - DOMAIN-SUFFIX,tracker.wildkat.net
  - DOMAIN-SUFFIX,tracker.willy.pro
  - DOMAIN-SUFFIX,tracker.xn--djrq4gl4hvoi.top
  - DOMAIN-SUFFIX,tracker.yume-hatsuyuki.moe
  - DOMAIN-SUFFIX,tracker.zhuqiy.com
  - DOMAIN-SUFFIX,tracker.zhuqiy.dgj055.icu
  - DOMAIN-SUFFIX,tracker1.520.jp
  - DOMAIN-SUFFIX,tracker1.itzmx.com
  - DOMAIN-SUFFIX,tracker2.dler.org
  - DOMAIN-SUFFIX,tracker2.itzmx.com
  - DOMAIN-SUFFIX,tracker3.itzmx.com
  - DOMAIN-SUFFIX,tracker4.itzmx.com
  - DOMAIN-SUFFIX,v2.iperson.xyz
  - DOMAIN-SUFFIX,whybother.torrentonline.cc
  - DOMAIN-SUFFIX,www.wareztorrent.com
  - DOMAIN-SUFFIX,yuptracker-eu.gaijinent.com
  - IP-CIDR,52.58.128.163/32,no-resolve
  - IP-CIDR,93.158.213.92/32,no-resolve
  - IP-CIDR,107.189.2.131/32,no-resolve
  - IP-CIDR,207.241.226.111/32,no-resolve
  - IP-CIDR,207.241.231.226/32,no-resolve

ASSET_EOF
  else
    info "torrentdirect list: keeping existing /etc/mihomo/ruleset/torrentdirect.yaml"
  fi
  # v1.20.4: zapret force-list exceptions (direction B). Owner-edited; never overwritten.
  if [ -s "$(P /etc/geomask/zapret-force-keep.txt)" ]; then
    info "zapret force-keep: keeping existing /etc/geomask/zapret-force-keep.txt"
  else
    mkdir -p "$(P /etc/geomask)" 2>/dev/null
    save_stream /etc/geomask/zapret-force-keep.txt 644 <<'ASSET_EOF'
# zapret force-list exceptions - geomask never removes these from DPI processing,
# even when the same domain also appears in a tunneled MagiTrickle/AI list.
#
# Gaming services (owner, 01.11): these must keep being processed by zapret.
# One domain per line. Editing this file is enough - the sync re-reads it every run,
# and a domain that reappears here is automatically restored into the force list.
api.epicgames.dev
firstlook.gg
live.wardogs.bulkhead.pragmaengine.com

ASSET_EOF
  fi
  # v1.17.0: torrent admin - rebuild the tracker ruleset / toggle the DIRECT listener from the panel
  mkdir -p "$(P /etc/geomask/torrent)" 2>/dev/null
  save_stream /usr/bin/geomask-torrent.sh 755 <<'ASSET_EOF'
#!/bin/sh
# geomask-torrent.sh - manage the torrent/tracker DIRECT bypass (geomask v1.15.0+).
#
#   geomask-torrent.sh --status                 JSON for the panel
#   geomask-torrent.sh --refresh                rebuild the ruleset from the public lists + extras
#   geomask-torrent.sh --listener enable|off    toggle the SOCKS5/HTTP listener that pins torrents to DIRECT
#   geomask-torrent.sh --extra "a.org b.org"    replace the user-added tracker hosts (then rebuild)
#
# Everything it writes is validated with `mihomo -t` and rolled back on failure; reload goes
# through the local controller API with the bearer token, never via argv.
exec python3 - "$@" <<'PYEOF'
import json, os, re, subprocess, sys, time, urllib.request

CFG='/etc/mihomo/config.yaml'
RS='/etc/mihomo/ruleset/torrentdirect.yaml'
DIR='/etc/geomask/torrent'
SOURCES=DIR+'/sources.conf'
EXTRA=DIR+'/extra.txt'
JOURNAL='/root/geo-sync.log'
LISTENER_PORT='7894'

def log(msg):
    try:
        with open(JOURNAL,'a',encoding='utf-8') as f:
            f.write('%s TORRENT %s\n' % (time.strftime('%F %T'), msg))
    except Exception:
        pass

def read(p, default=''):
    try:
        return open(p, encoding='utf-8').read()
    except Exception:
        return default

def sources():
    s=[l.strip() for l in read(SOURCES).splitlines() if l.strip() and not l.strip().startswith('#')]
    return s or ['https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt',
                 'https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/all.txt']

def extras():
    out=set()
    for l in read(EXTRA).splitlines():
        l=l.strip().lower().strip('.').rstrip('/')
        if l and not l.startswith('#'): out.add(l)
    return out

# ---------- controller ----------
def secret():
    for ln in read(CFG).splitlines():
        m=re.match(r'^secret:\s*["\']?([^"\'\s]+)', ln)
        if m: return m.group(1)
    return ''

def api(method, path, body=None):
    req=urllib.request.Request('http://127.0.0.1:9090'+path, method=method,
                               data=(json.dumps(body).encode() if body is not None else None))
    s=secret()
    if s: req.add_header('Authorization','Bearer '+s)
    if body is not None: req.add_header('Content-Type','application/json')
    try:
        return urllib.request.urlopen(req, timeout=10).getcode()
    except Exception as e:
        log('controller %s %s failed: %s' % (method, path, e)); return 0

def validate():
    return subprocess.run(['/usr/bin/mihomo','-t','-d','/etc/mihomo'],
                          capture_output=True, timeout=60).returncode == 0

# ---------- ruleset build ----------
def fetch(url):
    try:
        r=urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent':'geomask'}), timeout=25)
        return r.read().decode('utf-8','replace')
    except Exception as e:
        log('source fetch failed %s: %s' % (url, e)); return ''

def build_ruleset():
    import ipaddress
    hosts=set(); ips=set(); bad=0
    for u in sources():
        for ln in fetch(u).splitlines():
            ln=ln.strip()
            if not ln: continue
            m=re.match(r'^(?:udp|https?)://([^/]+)', ln, re.I)
            if not m: bad+=1; continue
            h=re.sub(r':\d+$','',m.group(1)).strip('.').lower()
            if not h: continue
            try:
                ipaddress.ip_address(h); ips.add(h); continue
            except ValueError:
                pass
            if re.fullmatch(r'[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+', h):
                hosts.add(h)
            else:
                bad+=1
    hosts |= extras()
    hosts = {h for h in hosts if not any(h != a and h.endswith('.'+a) for a in hosts)}
    body=('# AUTO-GENERATED by geomask-torrent.sh from the public tracker lists + user extras - DO NOT EDIT\n'
          '# regenerate: geomask-torrent.sh --refresh ; user hosts: %s\n' % EXTRA)
    body+='payload:\n'
    for h in sorted(hosts): body+='  - DOMAIN-SUFFIX,%s\n' % h
    for i in sorted(ips, key=lambda x: tuple(int(o) for o in x.split('.'))): body+='  - IP-CIDR,%s/32,no-resolve\n' % i
    os.makedirs('/etc/mihomo/ruleset', exist_ok=True)
    tmp=RS+'.tmp'
    open(tmp,'w',encoding='utf-8',newline='').write(body)
    old=read(RS)
    if old == body:
        os.remove(tmp)
        return len(hosts), len(ips), False
    open(RS+'.bak','w',encoding='utf-8',newline='').write(old) if old else None
    os.replace(tmp, RS)
    if not validate():
        if old: open(RS,'w',encoding='utf-8',newline='').write(old)
        log('ruleset rejected by mihomo -t, restored previous'); return len(hosts), len(ips), False
    return len(hosts), len(ips), True

# ---------- listener toggle ----------
# The listener is the torrent client's egress. Policy rules (v1.17.0):
#   RESERVE lane configured -> no fixed policy: the rule chain decides, so AI domains sent here
#     still match RULE-SET,ai and go to AI, while every IP rule (peers on hosting providers)
#     goes to RESERVE, never to the P2P-restricted VPN sub.
#   no RESERVE lane         -> fixed "proxy: DIRECT", because otherwise peers whose IP sits in
#     the hosting lists end up on the VPN sub - exactly what got the subscription blocked (31.10).
LISTENER_BLOCK=['  - name: torrent-direct','    type: mixed','    port: %s' % LISTENER_PORT,
                '    listen: 192.168.0.1']

def has_reserve_lane():
    """A RESERVE group means every IP rule is routed away from the P2P-restricted VPN sub,
    so the listener can be left to the rule chain. Without it a fixed policy is mandatory."""
    return re.search(r'(?m)^  - name: RESERVE\s*$', read(CFG)) is not None

def listener_block():
    blk = list(LISTENER_BLOCK)
    if not has_reserve_lane():
        blk.append('    proxy: DIRECT')   # keeps P2P off the VPN subscription by force
    return blk

def listener_policy():
    t=read(CFG)
    m=re.search(r'(?m)^  - name: torrent-direct\n(?:[ ]{4}.*\n)*?[ ]{4}proxy:\s*(\S+)', t)
    return m.group(1) if m else ''

def listener_present():
    return 'torrent-direct' in read(CFG)

def set_listener(on):
    t=read(CFG); lines=t.splitlines(True)
    if on:
        if listener_present(): return False
        idx=next((i for i,l in enumerate(lines) if re.match(r'^\s+proxy: AI\s*$', l)), None)
        if idx is None: log('no ai-devices listener to anchor to'); return False
        lines.insert(idx+1, ''.join(x+'\n' for x in listener_block()))
    else:
        if not listener_present(): return False
        out=[]; i=0
        while i < len(lines):
            if re.match(r'^\s*-\s*name:\s*torrent-direct\s*$', lines[i]):
                i+=1
                while i < len(lines) and (lines[i].startswith('    ') or lines[i].strip()==''):
                    if i+1 < len(lines) and re.match(r'^\s*-\s*name:', lines[i+1]): break
                    if lines[i].strip()=='' and i+1 < len(lines) and not lines[i+1].startswith(' '): break
                    i+=1
                continue
            out.append(lines[i]); i+=1
        lines=out
    new=''.join(lines)
    bak=CFG+'.bak_torrent'; open(bak,'w',encoding='utf-8',newline='').write(t)
    open(CFG,'w',encoding='utf-8',newline='').write(new)
    if not validate():
        open(CFG,'w',encoding='utf-8',newline='').write(t)
        log('listener change rejected by mihomo -t, config restored'); return False
    api('PUT','/configs?force=true', {'path': CFG})
    log('listener %s' % ('enabled' if on else 'disabled'))
    return True

# ---------- commands ----------
def status():
    prov=0
    try:
        req=urllib.request.Request('http://127.0.0.1:9090/providers/rules')
        s=secret()
        if s: req.add_header('Authorization','Bearer '+s)
        d=json.load(urllib.request.urlopen(req, timeout=8))
        prov=(d.get('providers') or d).get('torrentdirect',{}).get('ruleCount',0)
    except Exception:
        pass
    rs=read(RS)
    return {
        'ok': True,
        'listener_present': listener_present(),
        'listener_policy': listener_policy(),
        'listener_port': int(LISTENER_PORT),
        'ruleset_present': bool(rs.strip()),
        'domains': len(re.findall(r'DOMAIN-SUFFIX,', rs)),
        'raw_ips': len(re.findall(r'IP-CIDR,', rs)),
        'provider_loaded': prov,
        'extras': sorted(extras()),
        'sources': sources(),
        'proxy_hint': 'socks5h://192.168.0.1:%s' % LISTENER_PORT,
    }

args=sys.argv[1:]
if '--status' in args:
    print(json.dumps(status(), ensure_ascii=False)); sys.exit(0)
if '--listener' in args:
    i=args.index('--listener'); want=args[i+1] if i+1 < len(args) else 'enable'
    ok=set_listener(want in ('enable','on','true','1'))
    print(json.dumps({'ok': ok, 'listener_present': listener_present()})); sys.exit(0 if ok else 1)
if '--extra' in args:
    i=args.index('--extra'); val=args[i+1] if i+1 < len(args) else ''
    os.makedirs(DIR, exist_ok=True)
    hosts=[h.strip().lower().strip('.') for h in re.split(r'[\s,;]+', val) if h.strip()]
    bad=[h for h in hosts if not re.fullmatch(r'[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+', h)]
    if bad:
        print(json.dumps({'ok': False, 'rejected': bad})); sys.exit(1)
    open(EXTRA,'w',encoding='utf-8',newline='').write('\n'.join(sorted(set(hosts)))+'\n' if hosts else '')
    d,i2,changed=build_ruleset()
    if changed: api('PUT','/configs?force=true', {'path': CFG})
    log('extras set: %d host(s)' % len(hosts))
    print(json.dumps({'ok': True, 'domains': d, 'raw_ips': i2, 'changed': changed})); sys.exit(0)
# default: --refresh
os.makedirs(DIR, exist_ok=True)
if not os.path.exists(SOURCES):
    open(SOURCES,'w',encoding='utf-8',newline='').write(
        '# tracker announce lists used to build the DIRECT ruleset\n'
        + '\n'.join(sources()) + '\n')
d,i2,changed=build_ruleset()
if changed:
    time.sleep(1)
    api('PUT','/configs?force=true', {'path': CFG})
    log('ruleset refreshed: %d domains, %d raw ips' % (d, i2))
else:
    log('ruleset refresh: nothing changed (%d domains)' % d)
print(json.dumps({'ok': True, 'domains': d, 'raw_ips': i2, 'changed': changed}))
PYEOF

ASSET_EOF
  # v1.21.4: keep an existing lane across reinstalls - it carries an interface the owner may have
  # assigned MagiTrickle lists to, and losing it silently reroutes those lists.
  if [ -e "$(P /sys/class/net/VPN-noP2P)" ] && [ -x "$(P /usr/bin/geomask-lane.sh)" ]; then
    info "lane VPN-noP2P: already present, left untouched"
  elif [ -x "$(P /usr/bin/geomask-lane.sh)" ] && [ -n "$GM_AUTO_LANE" ]; then
    "$(P /usr/bin/geomask-lane.sh)" install >/dev/null 2>&1 || warn "lane install failed"
  fi
  # v1.21.0: extra tunnel lane - gives MagiTrickle's interface dropdown a real netdev that
  # always exits through the restricted subscription, so a list can be pointed at it directly.
  save_stream /usr/bin/geomask-lane.sh 755 <<'ASSET_EOF'
#!/bin/sh
# geomask-lane.sh - manage an extra tunnel lane so MagiTrickle's interface dropdown gains a
# real netdev for one mihomo group.
#
#   geomask-lane.sh install    create the lane (idempotent)
#   geomask-lane.sh status     what exists right now
#   geomask-lane.sh remove     stop, disable and delete everything geomask added
#
# Why a netdev at all: the MagiTrickle dropdown lists /sys/class/net entries, not mihomo
# groups. The existing "AI" option is not special - it is a second hev-socks5-tunnel instance
# (ai.yml -> tun "AI" 198.19.0.1 -> socks 7891 -> mihomo listener with "proxy: AI"). A new
# option therefore needs a new tunnel device, built the same way. MagiTrickle itself creates
# the per-group fwmark table with "default dev <iface>" once a group picks it.
LANE_NAME="${LANE_NAME:-VPN-noP2P}"      # <=15 chars: Linux ifname limit
LANE_IP="${LANE_IP:-198.20.0.1}"
LANE_PORT="${LANE_PORT:-7892}"
LANE_GROUP="${LANE_GROUP:-VPN-noP2P}"    # the mihomo group this lane always uses
YML=/etc/hev-socks5-tunnel/nop2p.yml
INITD=/etc/init.d/hev-nop2p
CFG=/etc/mihomo/config.yaml
LNAME=nop2p-lane

die() { echo "lane: $*" >&2; exit 1; }

status() {
  echo "lane $LANE_NAME (group $LANE_GROUP, socks $LANE_PORT)"
  [ -e "/sys/class/net/$LANE_NAME" ] && echo "  netdev:   present" || echo "  netdev:   absent"
  [ -f "$YML" ] && echo "  config:   $YML" || echo "  config:   missing"
  [ -x "$INITD" ] && { echo -n "  service:  "; "$INITD" enabled >/dev/null 2>&1 && echo -n "enabled " || echo -n "disabled "; "$INITD" running >/dev/null 2>&1 && echo "running" || echo "not running"; } || echo "  service:  missing"
  grep -q "name: $LNAME" "$CFG" 2>/dev/null && echo "  listener: present" || echo "  listener: absent"
}

install() {
  command -v hev-socks5-tunnel >/dev/null 2>&1 || die "hev-socks5-tunnel is not installed"
  [ -d /etc/hev-socks5-tunnel ] || die "/etc/hev-socks5-tunnel does not exist"
  grep -qE "^  - name: $LANE_GROUP\b" "$CFG" || die "mihomo group $LANE_GROUP not found - refusing"

  echo "=== 1) tunnel config ==="
  if [ -s "$YML" ]; then
    echo "  keeping existing $YML"
  else
    cat > "$YML" <<YMLend
tunnel:
  name: $LANE_NAME
  mtu: 8500
  multi-queue: false
  ipv4: $LANE_IP
socks5:
  port: $LANE_PORT
  address: 127.0.0.1
  udp: 'udp'
YMLend
    echo "  wrote $YML"
  fi

  echo "=== 2) service ==="
  if [ ! -x "$INITD" ]; then
    cat > "$INITD" <<'INITend'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/hev-socks5-tunnel /etc/hev-socks5-tunnel/nop2p.yml
  procd_set_param file /etc/hev-socks5-tunnel/nop2p.yml
  procd_set_param limits core="unlimited"
  procd_set_param limits nofile="1000000 1000000"
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param respawn
  procd_close_instance
}
INITend
    chmod 755 "$INITD"
    echo "  wrote $INITD"
  else
    echo "  keeping existing $INITD"
  fi
  "$INITD" enable >/dev/null 2>&1
  "$INITD" running >/dev/null 2>&1 || "$INITD" start
  sleep 2
  [ -e "/sys/class/net/$LANE_NAME" ] || die "tun $LANE_NAME did not appear"
  echo "  netdev $LANE_NAME is up"

  echo "=== 3) listener (validated before it is written) ==="
  if grep -q "name: $LNAME" "$CFG"; then
    echo "  listener already present"
  else
    cp -p "$CFG" "$CFG.bak_lane"
    python3 - "$CFG" "$LNAME" "$LANE_PORT" "$LANE_GROUP" <<'PY'
import re, sys
p, name, port, grp = sys.argv[1:5]
t = open(p, encoding='utf-8').read()
blk = ('  - name: %s\n    type: mixed\n    port: %s\n    listen: 127.0.0.1\n'
       '    proxy: %s\n' % (name, port, grp))
m = re.search(r'(?m)^listeners:\s*$(.*?)(?=^(?=[a-z]))', t, re.M | re.S)
if m:
    body = m.group(1)
    # append at the end of the listeners block, keeping the trailing blank line outside it
    tail = len(body) - len(body.rstrip())
    new = t[:m.start(1)] + body.rstrip('\n') + '\n' + blk + '\n' * (1 if tail else 0) + t[m.end(1):]
else:
    new = t + '\nlisteners:\n' + blk
open(p, 'w', encoding='utf-8', newline='').write(new)
print('  listener %s:%s -> proxy %s added' % (name, port, grp))
PY
    if ! /usr/bin/mihomo -t -d /etc/mihomo >/dev/null 2>&1; then
      cp -p "$CFG.bak_lane" "$CFG"; die "mihomo -t failed after adding the listener - config restored"
    fi
    SECRET=$(grep -m1 -oE '^secret:[[:space:]]*["'\'']?[^"'\''[:space:]]+' "$CFG" | sed -E 's/^secret:[[:space:]]*["'\'']?//')
    curl -s -o /dev/null -X PUT "http://127.0.0.1:9090/configs?force=true" \
      -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' \
      -d "{\"path\":\"$CFG\"}"
    sleep 6
  fi
  echo "=== done ==="
  status
}

remove() {
  "$INITD" stop >/dev/null 2>&1; "$INITD" disable >/dev/null 2>&1
  rm -f "$INITD" "$YML"
  if grep -q "name: $LNAME" "$CFG" 2>/dev/null; then
    cp -p "$CFG" "$CFG.bak_lane"
    python3 - "$CFG" "$LNAME" <<'PY'
import re, sys
p, name = sys.argv[1:3]
t = open(p, encoding='utf-8').read()
new = re.sub(r'(?m)^  - name: %s\n(?:[ ]{4}.*\n)+' % re.escape(name), '', t)
open(p, 'w', encoding='utf-8', newline='').write(new)
print('  listener removed' if new != t else '  nothing to remove')
PY
    /usr/bin/mihomo -t -d /etc/mihomo >/dev/null 2>&1 || { cp -p "$CFG.bak_lane" "$CFG"; die "config invalid after removing the listener - restored"; }
    SECRET=$(grep -m1 -oE '^secret:[[:space:]]*["'\'']?[^"'\''[:space:]]+' "$CFG" | sed -E 's/^secret:[[:space:]]*["'\'']?//')
    curl -s -o /dev/null -X PUT "http://127.0.0.1:9090/configs?force=true" \
      -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' -d "{\"path\":\"$CFG\"}"
  fi
  echo "  note: groups that had chosen $LANE_NAME in MagiTrickle must be re-pointed manually"
  status
}

case "${1:-status}" in
  install) install ;;
  remove)  remove ;;
  status)  status ;;
  *) die "usage: geomask-lane.sh {install|status|remove}" ;;
esac

ASSET_EOF
  # v1.20.6: morning check - read-only audit the owner runs after the restricted
  # subscription comes back, before enabling the torrent client again.
  save_stream /usr/bin/geomask-morning-check.sh 755 <<'ASSET_EOF'
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
if [ $FAIL -eq 0 ]; then
  echo "=== RESULT: safe to enable the torrent client ==="
else
  echo "=== RESULT: $FAIL problem(s) - read the FAIL lines above before torrenting ==="
fi
exit $FAIL

ASSET_EOF
  # v1.18.0: VPN lane audit - record what tries to use the P2P-restricted subscription while it
  # is offline, so the operator can see the future load before switching it back on.
  if [ ! -s "$(P /etc/geomask/vpnwatch.conf)" ]; then
    save_stream /etc/geomask/vpnwatch.conf 644 <<'ASSET_EOF'
# geomask vpnwatch configuration
# Records everything that tries to use a subscription that must not carry P2P, so the operator
# can see what would flow through it before it is switched on.
#
#   geomask-vpnwatch.sh --tick     called from cron (every minute), appends new events
#   geomask-vpnwatch.sh --report   prints a summary of what was captured
#   geomask-vpnwatch.sh --clear    empties the log

# Proxy group whose traffic is being watched (the P2P-restricted tunnel)
group=VPN-noP2P

# Where to write. Kept outside /tmp so a reboot does not lose the night's evidence.
logfile=/root/geomask-vpn-audit.log

# Keep at most this many lines (oldest are dropped)
max_lines=20000

ASSET_EOF
  else
    info "vpnwatch conf: keeping existing /etc/geomask/vpnwatch.conf"
  fi
  save_stream /usr/bin/geomask-vpnwatch.sh 755 <<'ASSET_EOF'
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

ASSET_EOF
  if crontab -l 2>/dev/null | grep -qE '# geomask-vpnwatch$'; then
    info "vpnwatch cron already present"
  else
    ( crontab -l 2>/dev/null; echo '* * * * * /usr/bin/geomask-vpnwatch.sh --tick >/dev/null 2>&1 # geomask-vpnwatch' ) | crontab - 2>/dev/null && info "cron added: */1 vpnwatch" || warn "cannot set crontab"
  fi
  save_stream /etc/hotplug.d/iface/99-default-vpn-route 755 <<'ASSET_EOF'
#!/bin/sh
# Route unmarked LAN traffic to Mihomo TUN; magitrickle marks take precedence.
# Devices from /etc/geo-devices.list with mode=bypass go DIRECT (real IP), never via VPN.
# Devices with mode=realtz follow normal mihomo routing (masked IP), only tz is real (PC-side).
# NOTE: runs inside netifd's ifup path -> MUST NOT block here (would stall PPPoE auth / WAN).
[ "$ACTION" = "ifup" ] || exit 0

apply_routes() {
  if ! ip route show table 100 | grep -q '^default'; then
    ip route show table main | grep -v '^default' | while IFS= read -r r; do
      ip route replace table 100 $r 2>/dev/null
    done
    ip route replace table 100 default dev Mihomo 2>/dev/null
  fi
  ip rule show | grep -q '32760:' || ip rule add priority 32760 iif br-lan lookup 100
  # --- ICMP bypass: must stay ABOVE the magitrickle fwmark rule base. That base
  #     is dynamic (drifts down as groups grow): observed 32558..32609 over time.
  #     A low pref (19901) is always above it, so ping to a marked IP never dies
  #     inside the TUN. Direct via pppoe-wan. Guard reseats the rule to
  #     (base - 100) when the base drifts, so presence is checked by SEMANTICS,
  #     never by the 19901 prefix (v1.6.2: ifup never adds a duplicate). ---
  ip rule show | grep -q 'iif br-lan ipproto icmp lookup main' || ip rule add priority 19901 iif br-lan ipproto icmp lookup main
  # --- AI-DNS: DNS of AI-mode devices exits through the AI tunnel (no DNS leak).
  #     The DoH worker runs as user dnsai; its sockets are marked 0x64 by the
  #     nft table geomask_ai_dns, and this rule sends the marked traffic to
  #     table 101 -> dev AI. pref 19902 stays ABOVE the magitrickle fwmark base
  #     (dynamic, observed 32558..32609) so magitrickle marks never preempt it.
  #     Opt-out: touch /etc/geomask-aidns.off ---
  if [ ! -f /etc/geomask-aidns.off ] && [ -f /etc/geomask-aidns.uid ]; then
    ip rule show | grep -q 'fwmark 0x64' || ip rule add pref 19902 fwmark 0x64 table 101
  fi
  # --- per-device rules: a low pref (19900) keeps a device rule ABOVE the
  #     magitrickle fwmark base (dynamic, observed 32558..32609), so marking can
  #     never preempt it; LAN stays local ---
  # --- bypass-mode devices ---
  if [ -f /etc/geo-devices.list ]; then
    while read -r dip dmode dname; do
      case "$dip" in ''|'#'*) continue ;; esac
      [ "$dmode" = "bypass" ] || continue
      ip rule show | grep -q "from $dip" || ip rule add priority 19900 from "$dip" lookup main
    done < /etc/geo-devices.list
    # --- ai-mode devices (the whole device goes through the AI tunnel; LAN stays local in table 101) ---
    if grep -qE '^[0-9.]+[[:space:]]+ai[[:space:]]' /etc/geo-devices.list; then
      if ip link show AI >/dev/null 2>&1; then
        if ! ip route show table 101 | grep -q '^default'; then
          ip route show table main | grep -v '^default' | while IFS= read -r r; do
            ip route replace table 101 $r 2>/dev/null
          done
          ip route replace table 101 default dev AI 2>/dev/null
        fi
        while read -r dip dmode dname; do
          case "$dip" in ''|'#'*) continue ;; esac
          [ "$dmode" = "ai" ] || continue
           ip rule show | grep -q "from $dip" || ip rule add priority 19900 from "$dip" lookup 101
        done < /etc/geo-devices.list
      fi
    fi
  fi
}

if ip link show Mihomo >/dev/null 2>&1; then
  apply_routes
else
  # Mihomo TUN not up yet: retry in BACKGROUND so netifd is never stalled (fixes PPPoE hangs).
  ( i=0; while [ $i -lt 20 ]; do
      ip link show Mihomo >/dev/null 2>&1 && { sleep 1; apply_routes; exit 0; }
      i=$((i+1)); sleep 1
    done ) >/dev/null 2>&1 &
fi
exit 0

ASSET_EOF
  save_stream /usr/bin/geomask-guard.sh 755 <<'ASSET_EOF'
#!/bin/sh
# geomask-guard.sh - durable fix for the B-001 class bug (TD-01).
# (A) Source-IP exclusion for ai/bypass devices at the HEAD of ip mangle
#     PREROUTING (before magitrickle MT_* jumps) so their packets never get
#     a magitrickle fwmark.
# (A2) Mark-clear: own nft table (prerouting, priority -149) wipes ONLY
#     magitrickle-space marks (0x4d61xxxx) for those devices. Position-
#     independent: survives any magitrickle/fw4 PREROUTING rebuild, so fwmark
#     rules can NEVER hijack our devices even during the watchdog window.
# (B) ip-rule watchdog: our per-device/icmp/aidns rules must exist and sit
#     ABOVE (numerically below) the magitrickle fwmark base; re-seat them at
#     MT_MIN-100 and flush conntrack when violated.
# (C) Safety: table 101 must keep "default dev AI".
# Logs actions only via logger -t geomask-guard (silent when healthy, cron
# runs every 5 min - no syslog spam). Read: logread | grep geomask-guard
GUARD_VERSION="1.21.7"

log() { logger -t geomask-guard "$*"; }

DEVS=/etc/geo-devices.list
CHAIN="ip mangle PREROUTING"
[ -f "$DEVS" ] || { log "SKIP: $DEVS missing"; exit 0; }

IPS=$(awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ($2=="ai" || $2=="bypass") {print $1}' "$DEVS" | tr '\n' ' ')
NEED_FLUSH=""

# ---------- (A) nft exclusion ----------
OUT=$(nft -a list chain $CHAIN 2>/dev/null)
if [ -z "$OUT" ]; then
  log "FAIL: cannot list $CHAIN"
else
  FIRST_MT=$(printf '%s\n' "$OUT" | grep -n 'jump MT_' | head -1 | cut -d: -f1)
  for ip in $IPS; do
    OURS=$(printf '%s\n' "$OUT" | grep -n "ip saddr $ip return" | head -1)
    if [ -z "$OURS" ]; then
      if nft insert rule $CHAIN ip saddr "$ip" return comment "geomask-excl" 2>/dev/null; then
        log "excl ADD $ip"
        NEED_FLUSH="1"
      else
        log "FAIL excl add $ip"
      fi
    else
      OUR_LINE=${OURS%%:*}
      if [ -n "$FIRST_MT" ] && [ "$OUR_LINE" -gt "$FIRST_MT" ]; then
        # our rule slid below the MT_ jumps (magitrickle re-seated) - rebuild at head
        printf '%s\n' "$OUT" | grep "ip saddr $ip return" | sed -n 's/.*handle \([0-9][0-9]*\).*/\1/p' | while read -r H; do
          nft delete rule $CHAIN handle "$H" 2>/dev/null
        done
        if nft insert rule $CHAIN ip saddr "$ip" return comment "geomask-excl" 2>/dev/null; then
          log "excl RESEAT $ip (was below MT_ jumps)"
          NEED_FLUSH="1"
        else
          log "FAIL excl reseat $ip"
        fi
      fi
    fi
  done
  # drop exclusions for devices no longer in the list (mode changed / removed)
  STALE=$(printf '%s\n' "$OUT" | grep 'geomask-excl')
  if [ -n "$STALE" ]; then
    OLDIFS2=$IFS
    IFS='
'
    for line in $STALE; do
      rip=$(printf '%s' "$line" | awk '{print $3}')
      case " $IPS " in
        *" $rip "*) ;;
        *)
          h=$(printf '%s' "$line" | sed -n 's/.*handle \([0-9][0-9]*\).*/\1/p')
          if [ -n "$h" ] && nft delete rule $CHAIN handle "$h" 2>/dev/null; then
            log "excl DEL stale $rip"
            NEED_FLUSH="1"
          fi
          ;;
      esac
    done
    IFS=$OLDIFS2
  fi
fi

# ---------- (A2) mark-clear table (survives PREROUTING rebuilds) ----------
# Own table is invisible to magitrickle (ip mangle) and fw4 (inet fw4).
# Hook at -149 = right after magitrickle's mangle (-150), before geomask
# AI-DNS mark 0x64 (-110). Clears ONLY 0x4d61xxxx marks - zapret/aidns marks
# are untouched.
MC_T=geomask_excl
nft list table ip "$MC_T" >/dev/null 2>&1 || nft add table ip "$MC_T" 2>/dev/null
if ! nft list chain ip "$MC_T" prerouting >/dev/null 2>&1; then
  nft add chain ip "$MC_T" prerouting '{ type filter hook prerouting priority -149; policy accept; }' 2>/dev/null \
    || log "FAIL mclear chain add"
fi
if ! nft list set ip "$MC_T" excl_ips >/dev/null 2>&1; then
  nft add set ip "$MC_T" excl_ips '{ type ipv4_addr; }' 2>/dev/null || log "FAIL mclear set add"
fi
if ! nft list chain ip "$MC_T" prerouting 2>/dev/null | grep -q '@excl_ips'; then
  nft add rule ip "$MC_T" prerouting ip saddr @excl_ips \
      meta mark and 0xffff0000 eq 0x4d610000 counter meta mark set 0 \
      comment "geomask-mclear" 2>/dev/null || log "FAIL mclear rule add"
  log "mclear rule installed"
fi
MC_CUR=$(nft list set ip "$MC_T" excl_ips 2>/dev/null | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | tr '\n' ' ')
for ip in $IPS; do
  case " $MC_CUR " in
    *" $ip "*) ;;
    *) nft add element ip "$MC_T" excl_ips "{ $ip }" 2>/dev/null && log "mclear ADD $ip" ;;
  esac
done
for rip in $MC_CUR; do
  case " $IPS " in
    *" $rip "*) ;;
    *) nft delete element ip "$MC_T" excl_ips "{ $rip }" 2>/dev/null && log "mclear DEL $rip" ;;
  esac
done

# ---------- (B) ip-rule watchdog ----------
MT_MIN=$(ip rule show 2>/dev/null | grep 'fwmark 0x4d61' | awk -F: '{print $1}' | sort -n | head -1)

CHECKLIST="iif br-lan ipproto icmp lookup main
fwmark 0x64 lookup 101"
for ip in $IPS; do
  mode=$(awk -v i="$ip" '$1==i {print $2}' "$DEVS")
  case "$mode" in
    ai) CHECKLIST="$CHECKLIST
from $ip lookup 101" ;;
    bypass) CHECKLIST="$CHECKLIST
from $ip lookup main" ;;
  esac
done

RULES_OK=1
OLDIFS=$IFS
IFS='
'
for pat in $CHECKLIST; do
  [ -z "$pat" ] && continue
  LINE=$(ip rule show | grep -F "$pat" | head -1)
  if [ -z "$LINE" ]; then RULES_OK=0; break; fi
  PREF=${LINE%%:*}
  case "$PREF" in
    ''|*[!0-9]*) RULES_OK=0; break ;;
  esac
  if [ -n "$MT_MIN" ] && [ "$PREF" -ge "$MT_MIN" ]; then RULES_OK=0; break; fi
done
IFS=$OLDIFS

if [ "$RULES_OK" = "0" ]; then
  if [ -n "$MT_MIN" ] && [ "$MT_MIN" -gt 100 ]; then
    BASE=$((MT_MIN - 100))
  else
    BASE=19900
  fi
  for ip in $IPS; do
    mode=$(awk -v i="$ip" '$1==i {print $2}' "$DEVS")
    case "$mode" in
      ai)
        while ip rule del from "$ip" lookup 101 2>/dev/null; do :; done
        while ip rule del from "$ip" lookup main 2>/dev/null; do :; done
        ip rule add priority "$BASE" from "$ip" lookup 101
        ;;
      bypass)
        while ip rule del from "$ip" lookup main 2>/dev/null; do :; done
        while ip rule del from "$ip" lookup 101 2>/dev/null; do :; done
        ip rule add priority "$BASE" from "$ip" lookup main
        ;;
    esac
  done
  while ip rule del iif br-lan ipproto icmp lookup main 2>/dev/null; do :; done
  ip rule add priority $((BASE + 1)) iif br-lan ipproto icmp lookup main
  while ip rule del fwmark 0x64 table 101 2>/dev/null; do :; done
  ip rule add priority $((BASE + 2)) fwmark 0x64 table 101
  NEED_FLUSH="1"
  log "ip rules re-seated at $BASE (magitrickle base: ${MT_MIN:-none})"
fi

# ---------- (C) table 101 safety ----------
if ! ip route show table 101 2>/dev/null | grep -q '^default'; then
  if ip route replace default dev AI table 101 2>/dev/null; then
    log "table 101 default restored (dev AI)"
  else
    log "WARN: table 101 has no default route (AI tun down?)"
  fi
fi

# ---------- conntrack flush when something changed ----------
if [ -n "$NEED_FLUSH" ]; then
  for ip in $IPS; do
    conntrack -D -s "$ip" >/dev/null 2>&1
    conntrack -D -d "$ip" >/dev/null 2>&1
  done
  log "conntrack flushed for: $IPS"
fi

exit 0

ASSET_EOF
  save_stream /etc/hotplug.d/iface/99-geomask-guard 755 <<'ASSET_EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
( /usr/bin/geomask-guard.sh >/dev/null 2>&1 & )
ASSET_EOF
  if crontab -l 2>/dev/null | grep -q 'geomask-guard'; then
    info "guard cron already present"
  else
    ( crontab -l 2>/dev/null; echo '*/5 * * * * /usr/bin/geomask-guard.sh >/dev/null 2>&1 # geomask-guard' ) | crontab - 2>/dev/null && info "cron added: */5 guard" || warn "cannot set crontab"
  fi
  if crontab -l 2>/dev/null | grep -q 'sync_mtrickle_mihomo'; then
    info "cron already present"
  else
    ( crontab -l 2>/dev/null; echo '*/5 * * * * /root/sync_mtrickle_mihomo.sh' ) | crontab - 2>/dev/null && info "cron added: */5 sync" || warn "cannot set crontab"
  fi
  # v1.11.0: nightly node audit (registry check of every subscription server)
  save_stream /usr/bin/geomask-node-scan.sh 755 <<'ASSET_EOF'
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
    _ok=[]; _bad=[]
    for _p in _provs:
        r=subprocess.run(['/bin/sh', '/usr/bin/geomask-node-scan.sh', '--provider', _p])
        (_ok if r.returncode==0 else _bad).append(_p)
    log('all-provider pass done: ok=[%s] failed=[%s]' % (','.join(_ok), ','.join(_bad)))
    if not _ok:
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

ASSET_EOF
  if [ ! -s "$(P /etc/geomask-nodes.conf)" ]; then
    save_stream /etc/geomask-nodes.conf 644 <<'ASSET_EOF'
# geomask node-scan configuration (v1.11.0+)
# Nightly subscription scan: a node is blocked by NAME in the VPN group
# exclude-filter when its SERVER matches these criteria. Edit freely; the scan
# re-reads this file every run; re-installing geomask keeps the file (keep-as-is).

# ISO country codes of the node SERVER considered leaking (comma separated)
# TR added 30.10: Turkish nodes returned to the pool after a format change went unnoticed
bad_countries=RU,BY,KZ,IR,TR

# ASN numbers of known fake-geo / RF-affiliated networks (comma separated, "AS" prefix optional)
# AS207847 CloudBlast (AE) - nodes labelled "United Kingdom" that actually exit in the UAE
bad_asns=AS210976,AS215540,AS207847

# Base name filter always kept in exclude-filter (static part).
# NOTE: emoji flags are NOT matched by country words - a node named only "🇷🇺 <something>"
# needs the flag itself in this list (added 30.10 after an RU node slipped through).
base_filter=Россия|Мобильный|РФ|Авто|Russia|Mobile|Auto|Албания|Хорватия|Литва|Латвия|Дания|Финляндия|Albania|Croatia|Lithuania|Latvia|Denmark|Finland|Turkey|Турция|United Kingdom|🇷🇺|без рекламы

# provider name in mihomo config to scan. "all" = every proxy-provider, one pass each (v1.20.4)
sub_provider=all

# User-Agent for fetching the subscription. The panel (Remnawave) answers a 1-node
# stub "Приложение не поддерживается" to unknown clients, so this MUST be a known app.
# clash-meta -> YAML config; v2rayNG/NekoBox/kitsunebi -> base64 share links.
sub_user_agent=clash-meta

# Groups allowed to carry a NAME filter (v1.20.3). Deliberately excludes the AI slot: that
# subscription is USA-only, and a name list tuned to another provider's naming emptied the group
# to a single pseudo-node when it was applied there by mistake. Geo/ASN rules still apply to
# every subscription - only the name filter is scoped here.
name_filter_groups='VPN,VPN-noP2P'

ASSET_EOF
  else
    info "nodes conf: keeping existing /etc/geomask-nodes.conf"
  fi
  if crontab -l 2>/dev/null | grep -q 'geomask-node-scan'; then
    info "nodescan cron already present"
  else
    ( crontab -l 2>/dev/null; echo '30 3 * * * /usr/bin/geomask-node-scan.sh >/dev/null 2>&1 # geomask-nodescan' ) | crontab - 2>/dev/null && info "cron added: 03:30 nodescan" || warn "cannot set crontab"
  fi
  # v1.14.0: YouTube edge watchdog - failing *.googlevideo.com edges get pinned to VPN,
  # released back to zapret nightly. Source of truth stays in MagiTrickle (group feeds ytvpn.yaml).
  save_stream /usr/bin/geomask-ytwatch.sh 755 <<'ASSET_EOF'
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

ASSET_EOF
  if [ ! -s "$(P /etc/geomask-ytwatch.conf)" ]; then
    save_stream /etc/geomask-ytwatch.conf 644 <<'ASSET_EOF'
# geomask youtube-edge watcher configuration (v1.14.0+)
# Decides how googlevideo.com (YouTube video edges) is routed. The edges are IP-blocked
# per-host by RKN, and Google rotates the hostnames, so a static list always lags behind.

# Routing mode:
#   auto    - edges go DIRECT (zapret/DPI); only hosts that actually fail get pinned to VPN
#   blanket - every *.googlevideo.com goes to VPN (the v1.13.x behaviour)
mode=auto

# Pin a host after this many failed dials inside the window (avoid pinning on one blip)
fail_threshold=2

# Consider failures from the last N minutes when scanning the log
window_min=30

# --- stalled-edge detection (v1.15.2) ---
# DPI can kill a stream AFTER the TCP handshake; mihomo then logs no error at all, so the
# log scan above sees nothing. Such a connection still shows up in the controller API as
# "alive a long time, almost nothing downloaded". That is what these thresholds define:
# a *.googlevideo.com connection routed DIRECT, older than stall_min_age seconds, with less
# than stall_max_bytes downloaded (a bare TLS handshake is only a few KB).
# A connection must be quiet for this long (SECONDS) before it counts at all.
stall_min_age=30
stall_max_bytes=10000
# how many quiet connections the SAME host must show in one sample. This is the real
# discriminator: a DPI-killed edge produces a swarm (dozens), a healthy player produces a
# couple of idle prefetch/keep-alive connections. 5s + 1 connection pinned healthy edges and
# made the TV stall every minute (owner, 01.11).
stall_min_conns=3
# consecutive samples a stalled host must appear in before pinning (cron runs every 1 min,
# so this is ~4 minutes of sustained evidence)
stall_threshold=4
# The player gives up on an edge after 10-15s and reconnects on ANOTHER one, so a per-edge pin
# is almost always applied to an edge the player already left. Therefore: when this many distinct
# edges look quiet in the same sample, the whole googlevideo class goes to VPN as ONE rule
# (blanket), because that is the only thing the player cannot rotate away from. It comes back
# down automatically after blanket_off_after clean samples (~20 minutes).
blanket_when=4
blanket_off_after=20

# Hard cap on automatically pinned hosts; when reached the watcher stops pinning and logs
max_pins=40

# MagiTrickle group that feeds ytvpn.yaml (created by geomask, editable at :8080)
group_name=GoogleVideo VPN

ASSET_EOF
  else
    info "ytwatch conf: keeping existing /etc/geomask-ytwatch.conf"
  fi
  # v1.20.4: the scan runs every minute (was */5). An old entry is rewritten in place.
  if crontab -l 2>/dev/null | grep -qE '# geomask-ytwatch$'; then
    if crontab -l 2>/dev/null | grep -qE '^\*/5 \* \* \* \* /usr/bin/geomask-ytwatch\.sh.*# geomask-ytwatch$'; then
      ( crontab -l 2>/dev/null | sed 's|^\*/5 \* \* \* \* /usr/bin/geomask-ytwatch.sh|*/1 * * * * /usr/bin/geomask-ytwatch.sh|' ) | crontab - 2>/dev/null \
        && info "ytwatch cron migrated */5 -> */1" || warn "cannot migrate the ytwatch cron"
    else
      info "ytwatch cron already present"
    fi
  else
    ( crontab -l 2>/dev/null; echo '*/1 * * * * /usr/bin/geomask-ytwatch.sh >/dev/null 2>&1 # geomask-ytwatch' ) | crontab - 2>/dev/null && info "cron added: */1 ytwatch" || warn "cannot set crontab"
  fi
  if crontab -l 2>/dev/null | grep -qE '# geomask-ytwatch-reset$'; then
    info "ytwatch reset cron already present"
  else
    ( crontab -l 2>/dev/null; echo '20 4 * * * /usr/bin/geomask-ytwatch.sh --reset >/dev/null 2>&1 # geomask-ytwatch-reset' ) | crontab - 2>/dev/null && info "cron added: 04:20 ytwatch reset" || warn "cannot set crontab"
  fi
  # v1.10.0: event sync watchdog - magitrickle save -> sync within ~seconds (cron stays as backup)
  if have apk; then apk add inotifywait >/dev/null 2>&1 || true; fi
  save_stream /usr/bin/geomask-syncd.sh 755 <<'ASSET_EOF'
#!/bin/sh
# geomask-syncd.sh - event watchdog for magitrickle -> mihomo list sync (v1.10.0).
# Runs the idempotent sync (which reloads mihomo only on real change) a few seconds
# after magitrickle touches /etc/magitrickle/state, so the panel button and the */5
# cron become a backup, not the primary path.
# Prefers inotifywait (package inotifywait); falls back to a 10s mtime poll.
DIR=/etc/magitrickle/state
SYNC=/root/sync_mtrickle_mihomo.sh
DEB=4
log() { logger -t geomask-syncd "$1" 2>/dev/null; }
run() {
  [ -x "$SYNC" ] || return 0
  _o=$("$SYNC" 2>&1); _r=$?
  [ $_r -ne 0 ] && log "sync rc=$_r: $(printf '%s' "$_o" | tail -1)"
}
log "watchdog started (dir=$DIR, inotify=$(command -v inotifywait >/dev/null 2>&1 && echo yes || echo no))"
while true; do
  if ! [ -d "$DIR" ]; then sleep 15; continue; fi
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -qq -e close_write,moved_to,create,delete "$DIR" 2>/dev/null
    sleep "$DEB"
    run
  else
    sleep 10
    _c=$(ls -l "$DIR" 2>/dev/null | md5sum)
    if [ -n "$_prev" ] && [ "$_c" != "$_prev" ]; then run; fi
    _prev=$_c
  fi
done

ASSET_EOF
  save_stream /etc/init.d/geomask-syncd 755 <<'ASSET_EOF'
#!/bin/sh /etc/rc.common
# geomask-syncd - procd service for the event sync watchdog (geomask v1.10.0+).
START=98
STOP=10
USE_PROCD=1

start_service() {
	[ -x /usr/bin/geomask-syncd.sh ] || return 0
	procd_open_instance
	procd_set_param command /bin/sh /usr/bin/geomask-syncd.sh
	procd_set_param respawn 3600 5 0
	procd_set_param term_timeout 5
	procd_set_param pidfile /var/run/geomask-syncd.pid
	procd_close_instance
}

ASSET_EOF
  initd geomask-syncd enable >/dev/null 2>&1 || true
  if pgrep -f geomask-syncd.sh >/dev/null 2>&1; then
    info "syncd: already running"
  else
    initd geomask-syncd restart >/dev/null 2>&1 || true
    sleep 1
    pgrep -f geomask-syncd.sh >/dev/null 2>&1 && info "syncd: started" || warn "syncd: cannot start (check logread)"
  fi
  if ! svc_alive magitrickled; then
    info "starting magitrickle..."
    initd magitrickle start >/dev/null 2>&1 || true
  fi
  if [ "$GM_RESTART" = 1 ]; then
    info "running sync once (--restart)..."
    sh "$(P /root/sync_mtrickle_mihomo.sh)" 2>&1 | sed 's/^/  | /' || true
  else
    warn "sync not run (it may restart mihomo). Run later: sh /root/sync_mtrickle_mihomo.sh  or use --restart"
  fi
  # v1.13.0: ship the lists template + seeder, and auto-seed MagiTrickle if it is empty (fresh install).
  write_lists_assets
  seed_lists ""
  return 0
}
step5_verify() { step5_check; }

# ============================================================ STEP 6: services (start missing only)
SVC_LIST="dnsmasq magitrickled mihomo hev-socks5-tunnel rpcd ai-doh dnsmasq-ai"
# ai-doh/dnsmasq-ai run as generic binaries (https-dns-proxy/dnsmasq), so pidof
# by service name never matches - check their listening ports instead.
aidns_svc_ok() {
  case "$1" in
    ai-doh)     netstat -ltnu 2>/dev/null | grep -q '127.0.0.1:5055 ' ;;
    dnsmasq-ai) netstat -ltnu 2>/dev/null | grep -q '192.168.0.53:5353 ' ;;
  esac
}
step6_check() {
  _need=0
  for s in $SVC_LIST; do
    case "$s" in
      magitrickled) _p=magitrickled ;;
      *) _p=$s ;;
    esac
    if [ -f "$(P /etc/geomask-aidns.off)" ] && { [ "$s" = ai-doh ] || [ "$s" = dnsmasq-ai ]; }; then
      info "$s: AI-DNS disabled - skipped"; continue
    fi
    case "$s" in
      ai-doh|dnsmasq-ai)
        if aidns_svc_ok "$s"; then info "$s: listening"
        else warn "$s: NOT listening"; _need=1; fi
        ;;
      *) svc_alive "$_p" && info "$s: running" || { warn "$s: NOT running"; _need=1; } ;;
    esac
  done
  return $_need
}
step6_apply() {
  for s in $SVC_LIST; do
    _p=$s; [ "$s" = magitrickled ] && _p=magitrickle
    if [ -f "$(P /etc/geomask-aidns.off)" ] && { [ "$s" = ai-doh ] || [ "$s" = dnsmasq-ai ]; }; then
      info "$s: AI-DNS disabled - skipped"; continue
    fi
    case "$s" in
      ai-doh|dnsmasq-ai)
        if aidns_svc_ok "$s"; then info "$s: already listening - untouched"; continue; fi
        info "starting $s (not listening)..."
        initd "$s" start >/dev/null 2>&1 || warn "cannot start $s"
        ;;
      *)
        if svc_alive "$s"; then info "$s: already running - untouched"; continue; fi
        info "starting $s (it was down)..."
        initd "$_p" start >/dev/null 2>&1 || warn "cannot start $s"
        ;;
    esac
  done
  return 0
}
step6_verify() { step6_check; }

# ============================================================ STEP 7: end-to-end verify (read-only)
step7_check() {
  _need=0
  _r=$(nslookup ya.ru 127.0.0.1 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)
  if [ -n "$_r" ] && [ "$_r" != "127.0.0.1" ]; then info "DNS normal (ya.ru -> $_r)"; else bad "DNS broken for normal domains"; _need=1; fi
  _b=$(nslookup doubleclick.net 127.0.0.1 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)
  case "$_b" in
    ""|0.0.0.0|::) info "DNS adblock (doubleclick.net -> ${_b:-NXDOMAIN})" ;;
    *) warn "adblock: doubleclick.net resolves to $_b (adblock-fast may be off)" ;;
  esac
  _code=$(curl -m 5 -s -o /dev/null -w '%{http_code}' http://www.gstatic.com/generate_204 2>/dev/null)
  [ "$_code" = "204" ] && info "connectivity: 204 OK" || { bad "connectivity: HTTP ${_code:-none}"; _need=1; }
  if _px=$(controller_curl -f -m 5 -s http://127.0.0.1:9090/proxies 2>/dev/null); then
    printf '%s' "$_px" | grep -q '"VPN"' && info "mihomo group VPN: in API" || { bad "mihomo group VPN missing"; _need=1; }
    printf '%s' "$_px" | grep -q '"AI"' && info "mihomo group AI: in API" || { bad "mihomo group AI missing"; _need=1; }
  else
    bad "mihomo controller request failed (check authentication/connectivity)"; _need=1
  fi
  if have ubus; then
    ubus list 2>/dev/null | grep -qx 'geo-sync' && info "geo ubus: OK" || { bad "geo ubus: missing"; _need=1; }
  fi
  if ip rule show 2>/dev/null | grep -q 'iif br-lan ipproto icmp'; then info "ICMP bypass rule: present"; else warn "ICMP bypass rule absent - LAN ping may die in TUN"; fi
  # AI-DNS: DNS of AI devices must exit through the AI tunnel (mark -> table 101)
  if [ -f "$(P /etc/geomask-aidns.off)" ] || [ ! -f "$(P /etc/geomask-aidns.uid)" ]; then
    info "AI-DNS: not installed (DNS of AI devices resolves via router - run the aidns step)"
  else
    _rt=$(ip route get 1.1.1.1 mark 0x64 2>/dev/null)
    if [ -z "$_rt" ]; then
      warn "AI-DNS: routing check returned nothing (ip route unavailable?)"
    elif printf '%s' "$_rt" | grep -q 'dev AI'; then
      info "AI-DNS: marked DNS exits via AI tunnel (no leak)"
    else
      bad "AI-DNS: marked DNS does NOT route via AI tunnel (leak!)"; _need=1
    fi
  fi
  return $_need
}
step7_apply() { warn "verify-only step - nothing to apply"; return 0; }
step7_verify() { step7_check; }

# ============================================================ runner
STEP_NAMES="env geo subs aidns sync services verify"

step_desc() {
  case "$1" in
    env)      printf 'проверка окружения: версия OpenWrt, место на диске, зависимости (только чтение)' ;;
    geo)      printf 'гео-оверлей: панель "Гео-маскировка и AI" в LuCI + бэкенд geo-sync' ;;
    subs)     printf 'подписки: ссылки VPN/AI и группы VPN/AI в mihomo (проверка доступности)' ;;
    aidns)    printf 'AI-DNS: DNS AI-устройств через их же туннель — нет утечки DNS (ставится по умолчанию)' ;;
    sync)     printf 'sync: синк magitrickle→mihomo: watchdog (секунды) + cron-страховка' ;;
    services) printf 'сервисы: mihomo, magitrickle, hev-туннели, dnsmasq, веб-интерфейс' ;;
    verify)   printf 'сквозная проверка: выходы VPN/AI, DNS, группа AI, интернет (ничего не меняет)' ;;
    *)        printf '' ;;
  esac
}

step_fn() { # step_fn N action -> call stepN_action
  _n=$1; _a=$2
  case "$_n-$_a" in
    1-check) step1_check ;; 1-apply) step1_apply ;; 1-verify) step1_verify ;;
    2-check) step2_check ;; 2-apply) step2_apply ;; 2-verify) step2_verify ;;
    3-check) step3_check ;; 3-apply) step3_apply ;; 3-verify) step3_verify ;;
    4-check) step4_check ;; 4-apply) step4_apply ;; 4-verify) step4_verify ;;
    5-check) step5_check ;; 5-apply) step5_apply ;; 5-verify) step5_verify ;;
    6-check) step6_check ;; 6-apply) step6_apply ;; 6-verify) step6_verify ;;
    7-check) step7_check ;; 7-apply) step7_apply ;; 7-verify) step7_verify ;;
    *) bad "unknown step $_n"; return 1 ;;
  esac
}

run_step() { # run_step N  (interactive/auto common logic)
  _n=$1
  _name=$(echo "$STEP_NAMES" | cut -d' ' -f"$_n")
  hdr "$_n/7" "$_name"
  _fc_before=$FAILCNT
  if step_fn "$_n" check; then
    info "check: ALL GOOD"
    PASS=$((PASS+1))
    SKIP=$((SKIP+1))
    return 0
  fi
  info "check: issues found - apply needed"
  if [ "$GM_CHECK_ONLY" = 1 ]; then
    info "(check-only mode: not applying)"
    return 1
  fi
  if [ "$GM_AUTO" = 1 ] || [ "$GM_YES" = 1 ] || ask "Apply step $_n ($_name)?"; then
    if step_fn "$_n" apply; then
      info "--- verify ---"
      if step_fn "$_n" verify; then
        info "verify: PASS"
        # check-phase failures were fixed by apply - drop them from the global count
        FAILCNT=$_fc_before
        return 0
      else
        bad "verify: FAILED after apply"
        return 1
      fi
    else
      bad "apply failed or was skipped"
      return 1
    fi
  else
    info "skipped by user"
    SKIP=$((SKIP+1))
    return 2
  fi
}

# ============================================================ terminal UI
if [ -t 1 ]; then
  C_R="$(printf '\033[1;31m')"; C_G="$(printf '\033[1;32m')"; C_Y="$(printf '\033[1;33m')"
  C_B="$(printf '\033[1;36m')"; C_M="$(printf '\033[1;35m')"; C_DIM="$(printf '\033[38;5;244m')"
  NC="$(printf '\033[0m')"
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_M=""; C_DIM=""; NC=""
fi

clr()   { [ -t 1 ] && command -v clear >/dev/null 2>&1 && clear; return 0; }
PAUSE() { [ "$GM_YES" = 1 ] && return 0; [ -t 0 ] || return 0; printf '%sНажмите Enter...%s' "$C_DIM" "$NC"; read -r _p || true; echo; }

_maskurl()  { printf '%s' "${1:-}" | sed 's|/[^/]*$|/...|'; }
_row()      { printf '%s%-20s%s %s\n' "$C_Y" "$1:" "$NC" "$2"; }
_api_node() { controller_curl -s -m2 "http://127.0.0.1:9090/proxies/$1" 2>/dev/null | grep -oE '"now":"[^"]*"' | head -1 | sed 's/"now":"//;s/"$//'; }

_svc_row() { # _svc_row <label> <initd> <pidof-name>
  if [ ! -f "$(P /etc/init.d/$2)" ]; then _row "$1" "${C_DIM}не установлен${NC}"; return; fi
  if pidof "${3:-$2}" >/dev/null 2>&1; then _row "$1" "${C_G}запущен${NC}"; else _row "$1" "${C_R}остановлен${NC}"; fi
}

dashboard() {
  _model=$(cat "$(P /tmp/sysinfo/model)" 2>/dev/null)
  _rel=$(grep '^DISTRIB_RELEASE=' "$(P /etc/openwrt_release)" 2>/dev/null | cut -d"'" -f2)
  _row "Роутер" "${_model:-OpenWrt}${_rel:+ ${C_DIM}/ OpenWrt $_rel${NC}}"
  _svc_row "Zapret" zapret nfqws
  _svc_row "Mihomo" mihomo
  _svc_row "MagiTrickle" magitrickle magitrickled
  _svc_row "HevSocks5" hev-socks5-tunnel
  _svc_row "Dnsmasq" dnsmasq
  if [ -x "$(P /etc/init.d/adblock-fast)" ]; then
    _ab=$(grep -c 'server=/' "$(P /var/run/adblock-fast/dnsmasq.servers)" 2>/dev/null)
    _row "Adblock" "${C_G}${_ab:-0} доменов${NC}"
  fi
  _vpn=$(_api_node VPN); _ai=$(_api_node AI)
  _row "VPN узел" "${_vpn:-${C_DIM}нет ответа API${NC}}"
  _row "AI узел"  "${_ai:-${C_DIM}нет ответа API${NC}}"
  if [ -s "$(P /usr/bin/geo-backend.sh)" ] && ubus list 2>/dev/null | grep -qx 'geo-sync'; then
    _row "Geo LuCI" "${C_G}установлена${NC}"
  else
    _row "Geo LuCI" "${C_R}не установлена${NC}"
  fi
  if ip link show AI >/dev/null 2>&1; then _ait="${C_G}поднят${NC}"; else _ait="${C_DIM}нет${NC}"; fi
  _naic=$(grep -c ' ai ' "$(P /etc/geo-devices.list)" 2>/dev/null)
  _row "AI-туннель" "$_ait${_naic:+ · устройств: ${_naic:-0}}"
  _mt=$(grep -c 'DOMAIN-SUFFIX' "$(P /etc/mihomo/ruleset/mtrickle.yaml)" 2>/dev/null)
  _row "Sync правил" "${_mt:-0} в mtrickle.yaml"
  if [ -f "$(P /root/.geomask-norestart)" ]; then
    _row "VPN-рестарты" "${C_G}запрещены (pin)${NC}"
  else
    _row "VPN-рестарты" "${C_Y}разрешены${NC}"
  fi
}

print_banner() {
  printf '%s+========================================+%s\n' "$C_M" "$NC"
  printf '%s|%s      %sGEOMASK%s  -  geo-masking stack   %s|%s\n' "$C_M" "$NC" "$C_B" "$NC" "$C_M" "$NC"
  printf '%s+========================================+%s %sv%s%s\n' "$C_M" "$NC" "$C_DIM" "$GM_VERSION" "$NC"
}

show_menu() {
  echo
  printf '%s1)%s %sБыстрая диагностика%s %s(только чтение)%s\n'    "$C_B" "$NC" "$C_G" "$NC" "$C_DIM" "$NC"
  printf '%s2)%s %sПошаговый мастер%s %s(статус шагов, запуск любого отдельно)%s\n' "$C_B" "$NC" "$C_G" "$NC" "$C_DIM" "$NC"
  printf '%s3)%s %sПанель Гео%s %s(переустановить / обновить)%s\n'  "$C_B" "$NC" "$C_G" "$NC" "$C_DIM" "$NC"
  printf '%sf)%s %sУдалить -> установить -> настроить geomask%s\n'  "$C_B" "$NC" "$C_Y" "$NC"
  printf '%s0)%s Выход\n'                                          "$C_B" "$NC"
}

diag_quick() {
  PASS=0; FAILCNT=0; SKIP=0
  GM_CHECK_ONLY=1
  for n in 1 2 3 4 5 6 7; do run_step "$n" || true; done
  GM_CHECK_ONLY=0
  echo
  log "${C_DIM}== ДИАГНОСТИКА: pass=$PASS fail=$FAILCNT ==$NC"
}

# human-readable description of each step (bypasses ANY memory of "what is what")
step_desc() {
  case "$1" in
    env)      printf 'проверка окружения: версия OpenWrt, место на диске, зависимости (только чтение)' ;;
    geo)      printf 'гео-оверлей: панель "Гео-маскировка и AI" в LuCI + бэкенд geo-sync' ;;
    subs)     printf 'подписки: ссылки VPN/AI и группы VPN/AI в mihomo (проверка доступности)' ;;
    sync)     printf 'sync: синк magitrickle→mihomo: watchdog (секунды) + cron-страховка' ;;
    services) printf 'сервисы: mihomo, magitrickle, hev-туннели, dnsmasq, веб-интерфейс' ;;
    verify)   printf 'сквозная проверка: выходы VPN/AI, DNS, группа AI, интернет (ничего не меняет)' ;;
    *)        printf '' ;;
  esac
}

# step-by-step master: show status of every step, let the user run any single step
menu_master() {
  while :; do
    _n=1
    for _nm in $STEP_NAMES; do
      _d=$(step_desc "$_nm")
      if step_fn "$_n" check >/dev/null 2>&1; then
        printf '  %s%d)%s %s%-9s%s %s — %s %sвыполнено%s\n' "$C_B" "$_n" "$NC" "$C_Y" "$_nm" "$NC" "$_d" "$C_G" "$NC"
      else
        printf '  %s%d)%s %s%-9s%s %s — %s %sтребует внимания%s\n' "$C_B" "$_n" "$NC" "$C_Y" "$_nm" "$NC" "$_d" "$C_R" "$NC"
      fi
      _n=$((_n+1))
    done
    echo
    printf 'Номер шага для запуска (Enter - назад): '
    read -r _sel || return
    case "$_sel" in
      ''|q|Q) return ;;
      [1-7]) run_step "$_sel" || true; PAUSE ;;
      *) printf '%sнет такого шага%s\n' "$C_R" "$NC"; sleep 1 ;;
    esac
  done
}

# prompt for a subscription URL; keeps current value on Enter; honors flags/--yes
prompt_url() { # prompt_url <label> <current> <flag-value>  -> prints url, rc=1 if none
  _lbl="$1"; _cur="$2"; _flag="$3"
  if [ -n "$_flag" ]; then printf '%s' "$_flag"; return 0; fi
  if [ -n "$_cur" ]; then
    if [ "$GM_YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$_cur"; return 0; fi
    printf '%s [Enter = оставить %s]: ' "$_lbl" "$(_maskurl "$_cur")"
    read -r _v || _v=""
    printf '%s' "${_v:-$_cur}"
    return 0
  fi
  if [ "$GM_YES" = 1 ] || [ ! -t 0 ]; then return 1; fi
  while :; do
    printf '%s: ' "$_lbl"
    read -r _v || return 1
    case "$_v" in
      http://*|https://*) printf '%s' "$_v"; return 0 ;;
      '') return 1 ;;
      *) printf '  URL должен начинаться с http:// или https://\n' ;;
    esac
  done
}

# remove geomask parts (geo overlay, sync script, cron); keeps mihomo config
# $1 = noreload: skip the rpcd reload (caller re-registers right after install)
geomask_uninstall() {
  for f in /usr/bin/geo-backend.sh /usr/libexec/rpcd/geo-sync \
           /usr/share/rpcd/acl.d/luci-app-geo-sync.json \
           /usr/share/luci/menu.d/luci-app-geo-sync.json; do
    if [ -f "$(P "$f")" ]; then rm -f "$(P "$f")"; info "removed: $f"; fi
  done
  rm -f "$(P /www/luci-static/resources/view/geo-sync/main.js)" 2>/dev/null || true
  rmdir "$(P /www/luci-static/resources/view/geo-sync)" 2>/dev/null || true
  if [ -f "$(P /root/sync_mtrickle_mihomo.sh)" ]; then rm -f "$(P /root/sync_mtrickle_mihomo.sh)"; info "removed: sync script"; fi
  # v1.10.0: stop+remove the event sync watchdog
  if [ -x "$(P /etc/init.d/geomask-syncd)" ]; then
    initd geomask-syncd stop >/dev/null 2>&1 || true
    initd geomask-syncd disable >/dev/null 2>&1 || true
    pkill -f geomask-syncd.sh 2>/dev/null || true
    rm -f "$(P /etc/init.d/geomask-syncd)" "$(P /usr/bin/geomask-syncd.sh)"
    info "removed: syncd watchdog"
  fi
  # v1.11.0: node audit removal
  if crontab -l 2>/dev/null | grep -q 'geomask-node-scan'; then
    crontab -l 2>/dev/null | grep -v 'geomask-node-scan' | crontab - 2>/dev/null || true
  fi
  rm -f "$(P /usr/bin/geomask-node-scan.sh)"
  info "removed: node-scan (conf /etc/geomask-nodes.conf left for reference)"
  # v1.14.0: youtube edge watchdog removal. Release the auto-pins ONLY on a real uninstall:
  # --reinstall calls this too, and resetting there wiped every accumulated edge pin
  # (observed 31.10 18:21 - a self-update dropped 10 working pins).
  if [ -z "$1" ] && [ -x "$(P /usr/bin/geomask-ytwatch.sh)" ]; then
    "$(P /usr/bin/geomask-ytwatch.sh)" --reset >/dev/null 2>&1
  fi
  if crontab -l 2>/dev/null | grep -q 'geomask-ytwatch'; then
    crontab -l 2>/dev/null | grep -v 'geomask-ytwatch' | crontab - 2>/dev/null || true
  fi
  rm -f "$(P /usr/bin/geomask-ytwatch.sh)"
  info "removed: ytwatch (conf /etc/geomask-ytwatch.conf and /etc/geomask/ytwatch.state kept for reference)"
  # v1.15.0: torrent admin removal (ruleset + listener left in place: they belong to mihomo config)
  rm -f "$(P /usr/bin/geomask-torrent.sh)"
  info "removed: torrent admin (lists in /etc/geomask/torrent and the ruleset kept for reference)"
  # v1.18.0: vpnwatch removal (the audit log is kept - it is the evidence the operator collected)
  if crontab -l 2>/dev/null | grep -q 'geomask-vpnwatch'; then
    crontab -l 2>/dev/null | grep -v 'geomask-vpnwatch' | crontab - 2>/dev/null || true
  fi
  rm -f "$(P /usr/bin/geomask-vpnwatch.sh)"
  rm -f "$(P /usr/bin/geomask-morning-check.sh)"
  # The lane owns a service and a listener. Remove it ONLY on a real uninstall: --reinstall goes
  # through this function too, and wiping the lane there silently deletes an interface the owner
  # has assigned MagiTrickle lists to (same class of bug as the YouTube pins, fixed in v1.20.x).
  if [ -z "$1" ] && [ -x "$(P /usr/bin/geomask-lane.sh)" ]; then
    "$(P /usr/bin/geomask-lane.sh)" remove >/dev/null 2>&1 || warn "lane removal reported a problem"
  fi
  rm -f "$(P /usr/bin/geomask-lane.sh)"
  info "removed: vpnwatch (conf /etc/geomask/vpnwatch.conf and the audit log kept)"
  if crontab -l 2>/dev/null | grep -q 'sync_mtrickle_mihomo'; then
    crontab -l 2>/dev/null | grep -v 'sync_mtrickle_mihomo' | crontab - 2>/dev/null && info "cron entry removed"
  fi
  [ "$1" = "noreload" ] || initd rpcd reload 2>/dev/null || true
  return 0
}

# full flow: uninstall -> install geo -> rewrite mihomo 2-subs -> sync+cron -> services -> verify
menu_reinstall() {
  hdr "REINSTALL" "Удалить -> установить -> настроить geomask"
  warn "Удалены и переустановлены: гео-оверлей LuCI, sync-скрипт, cron."
  warn "Mihomo конфиг: существующий 2-подписочный сохраняется (патчатся только ссылки подписок);"
  warn "без конфига/маркеров подписок — запись шаблоном (старый — в бэкапе)."
  warn "Mihomo НЕ перезапускается: подписки применяются через API без обрыва VPN."
  _c="$(P $MIHOMO_CONF)"
  _curv=""; _cura=""
  if [ -s "$_c" ]; then
    _curv=$(_prov_url "$_c" sub)
    _cura=$(_prov_url "$_c" de5)
  fi
  ask "Продолжить пересстановку?" || { warn "отменено"; return 1; }
  _vpn=$(prompt_url "Ссылка на ОБЩУЮ VPN-подписку" "$_curv" "$GM_VPN_URL") || { bad "URL подписки не задан"; return 1; }
  _ai=$(prompt_url "Ссылка на AI-подписку (Германия)" "$_cura" "$GM_AI_URL") || { bad "URL AI-подписки не задан"; return 1; }
  hdr "1/6" "удаление geomask"; geomask_uninstall noreload || true
  hdr "2/6" "гео-оверлей LuCI"; step2_apply || true
  hdr "3/6" "mihomo: 2 подписки"
  if write_mihomo_config "$_vpn" "$_ai"; then
    api_refresh_provider sub "$_vpn" && info "provider sub refreshed (no restart)" || warn "provider sub: refresh failed, применится при старте mihomo"
    api_refresh_provider de5 "$_ai" && info "provider de5 refreshed (no restart)" || warn "provider de5: refresh failed, применится при старте mihomo"
  else
    bad "конфиг mihomo не записан"; return 1
  fi
  hdr "4/6" "AI-DNS (нет утечки DNS)"; step4_apply || true
  hdr "5/6" "синхронизация + роутинг"; step5_apply || true
  hdr "6/6" "сервисы"; step6_apply || true
  hdr "VERIFY" "итоговая проверка"
  if step7_check; then info "verify: PASS"; else bad "verify: FAIL"; return 1; fi
  log "Пересстановка geomask завершена."
  return 0
}

menu_loop() {
  while :; do
    clr
    print_banner
    echo
    dashboard
    show_menu
    printf '\n%sВыберите пункт:%s ' "$C_Y" "$NC"
    read -r _c || exit 0
    case "$_c" in
      1) diag_quick; PAUSE ;;
      2) menu_master || true; PAUSE ;;
      3) hdr "PANEL" "Панель Гео: переустановка/обновление"
         warn "Обновляет файлы панели (backend/rpcd/acl/страница); mihomo не трогается."
         run_step 2 || true; PAUSE ;;
      f|F) menu_reinstall || true; PAUSE ;;
      0|q|Q|"") exit 0 ;;
      *) printf '%sнеизвестный пункт%s\n' "$C_R" "$NC"; sleep 1 ;;
    esac
  done
}

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) GM_AUTO=1 ;;
    --check) GM_CHECK_ONLY=1 ;;
    --yes|-y) GM_YES=1 ;;
    --restart) GM_RESTART=1 ;;
    --backup) GM_BACKUP=1 ;;
    --reinstall) GM_REINSTALL=1 ;;
    --step) shift; GM_STEP="${1:-}" ;;
    --vpn-url) shift; GM_VPN_URL="${1:-}" ;;
    --ai-url) shift; GM_AI_URL="${1:-}" ;;
    --seed-lists) GM_SEED_LISTS=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1"; exit 2 ;;
  esac
  shift
done

# hard pin: router owner may forbid restarts permanently via flag file
if [ "$GM_RESTART" = 1 ] && [ -f "$(P /root/.geomask-norestart)" ]; then
  log "NOTE: /root/.geomask-norestart present - ignoring --restart (owner forbids VPN interruption)."
  GM_RESTART=0
fi

RC=0
if [ "$GM_BACKUP" = 1 ]; then
  _b=$(ensure_backup) && { info "full backup created: $_b"; info "SMB (freshest one): \\\\$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)\\geomask-backups ; history on PC: geomask\\fetch_backup.ps1"; RC=0; } || RC=1
elif [ "$GM_REINSTALL" = 1 ]; then
  menu_reinstall || RC=1
elif [ "$GM_SEED_LISTS" = 1 ]; then
  write_lists_assets && seed_lists force || RC=1
elif [ -n "$GM_STEP" ]; then
  run_step "$GM_STEP" || RC=1
elif [ "$GM_AUTO" = 1 ] || [ "$GM_CHECK_ONLY" = 1 ]; then
  log "geomask v$GM_VERSION  mode: $([ "$GM_CHECK_ONLY" = 1 ] && echo check || echo auto)"
  for n in 1 2 3 4 5 6 7; do
    if [ "$GM_CHECK_ONLY" = 1 ]; then
      run_step "$n" || true
    else
      run_step "$n" || { [ $? -eq 1 ] && { RC=1; bad "aborting on step $n failure"; break; }; }
    fi
  done
else
  menu_loop
fi

log ""
log "${C_DIM}== SUMMARY: pass=$PASS fail=$FAILCNT skipped_steps=$SKIP ==$NC"
[ "$FAILCNT" -eq 0 ] || RC=1
exit $RC
