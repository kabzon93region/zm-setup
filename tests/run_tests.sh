#!/bin/sh
# Sandbox test runner for geomask.sh (runs under Git-bash on Windows, no router access).
# Layout:
#   sandbox/bin/*     - stub commands (pidof, ubus, mihomo, curl, crontab, nslookup, ip, wget, apk)
#   sandbox/state/*   - state files consumed by stubs
#   sandbox/root/*    - fake filesystem (GM_PREFIX)
# Scenarios: S1 empty (all FAIL), S2 healthy (all OK), S3 apply (auto repairs subs).

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../geomask.sh"
STUB="$HERE/bin"
export PATH="$STUB:$PATH"

pass=0; failn=0
t() { # t <name> <expected_rc> <cmd...>
  _name="$1"; _want="$2"; shift 2
  "$@" >"$HERE/last_out.txt" 2>&1
  _rc=$?
  if [ "$_rc" = "$_want" ]; then
    echo "PASS: $_name (rc=$_rc)"
    pass=$((pass+1))
  else
    echo "FAIL: $_name (rc=$_rc, want $_want)"
    sed 's/^/    | /' "$HERE/last_out.txt" | tail -25
    failn=$((failn+1))
  fi
}

contains() { # contains <file> <pattern> <name>
  if grep -q "$2" "$1" 2>/dev/null; then echo "PASS: $3"; pass=$((pass+1));
  else echo "FAIL: $3 (pattern '$2' not found)"; tail -15 "$1" | sed 's/^/    | /'; failn=$((failn+1)); fi
}

rm -rf "$HERE/root_empty" "$HERE/root_healthy" "$HERE/root_apply" "$HERE/state"
mkdir -p "$HERE/state" "$HERE/root_empty/tmp" "$HERE/root_healthy/tmp" "$HERE/root_apply/tmp"

# ---------- scenario 1: empty root -> everything FAILs, script still exits cleanly ----------
echo "=== S1: empty root, --check ==="
: > "$HERE/state/services"; : > "$HERE/state/ubus_objects"; : > "$HERE/state/crontab"; : > "$HERE/state/ip_rules"
export GM_STATE="$HERE/state"
export GM_PREFIX="$HERE/root_empty"
t "S1 check exits nonzero" 1 sh "$SCRIPT" --check
contains "$HERE/last_out.txt" "SUMMARY" "S1 prints summary"
contains "$HERE/last_out.txt" "\[FAIL\]" "S1 reports failures"

# ---------- scenario 2: healthy root -> all OK ----------
echo "=== S2: healthy root, --check ==="
R="$HERE/root_healthy"
mkdir -p "$R/etc/openwrt" "$R/opt/zapret-manager-luci" "$R/usr/libexec/rpcd" \
         "$R/usr/share/rpcd/acl.d" "$R/www/luci-static/resources/zapret-manager" \
         "$R/usr/bin" "$R/etc/mihomo/ruleset" "$R/root" "$R/etc/hotplug.d/iface"
printf "DISTRIB_RELEASE='24.10'\n" > "$R/etc/openwrt_release"
echo x > "$R/opt/zapret-manager-luci/backend.sh"
echo x > "$R/usr/libexec/rpcd/zapret-manager"
echo x > "$R/usr/share/rpcd/acl.d/luci-app-zapret-manager.json"
echo x > "$R/www/luci-static/resources/zapret-manager/common.js"
mkdir -p "$R/etc/init.d"
for s in magitrickle mihomo zapret hev-socks5-tunnel dnsmasq; do
  printf '#!/bin/sh\nexit 0\n' > "$R/etc/init.d/$s"
done
# AI-DNS step deps (v1.5.7): DoH binary + rc.common for the services it installs
mkdir -p "$R/usr/sbin"
printf '#!/bin/sh\nexit 0\n' > "$R/usr/sbin/https-dns-proxy"; chmod +x "$R/usr/sbin/https-dns-proxy"
printf '#!/bin/sh\nexit 0\n' > "$R/etc/rc.common"; chmod +x "$R/etc/rc.common"
echo x > "$R/usr/bin/geo-backend.sh"
echo x > "$R/usr/libexec/rpcd/geo-sync"
echo x > "$R/usr/share/rpcd/acl.d/luci-app-geo-sync.json"
mkdir -p "$R/usr/share/luci/menu.d"
echo x > "$R/usr/share/luci/menu.d/luci-app-geo-sync.json"
mkdir -p "$R/www/luci-static/resources/view/geo-sync"; echo x > "$R/www/luci-static/resources/view/geo-sync/main.js"
echo x > "$R/root/sync_mtrickle_mihomo.sh"; chmod +x "$R/root/sync_mtrickle_mihomo.sh"
# routing guard (v1.6.0): script + hotplug fixtures for step5 checks
# (shebang required: Git-bash derives +x from shebang for non-exe files)
printf '#!/bin/sh\nexit 0\n' > "$R/usr/bin/geomask-guard.sh"; chmod +x "$R/usr/bin/geomask-guard.sh"
printf '#!/bin/sh\nexit 0\n' > "$R/etc/hotplug.d/iface/99-geomask-guard"; chmod +x "$R/etc/hotplug.d/iface/99-geomask-guard"
# event sync watchdog (v1.10.0): healthy fixture has init script + rc.d link + binary
mkdir -p "$R/etc/rc.d"
printf '#!/bin/sh\nexit 0\n' > "$R/usr/bin/geomask-syncd.sh"; chmod +x "$R/usr/bin/geomask-syncd.sh"
printf '#!/bin/sh\nexit 0\n' > "$R/etc/init.d/geomask-syncd"; chmod +x "$R/etc/init.d/geomask-syncd"
: > "$R/etc/rc.d/S98geomask-syncd"
# node audit (v1.11.0): script + conf fixtures
printf '#!/bin/sh\nexit 0\n' > "$R/usr/bin/geomask-node-scan.sh"; chmod +x "$R/usr/bin/geomask-node-scan.sh"
echo 'bad_asns=AS210976' > "$R/etc/geomask-nodes.conf"
# youtube edge watchdog (v1.14.0): script + conf fixtures
printf '#!/bin/sh\nexit 0\n' > "$R/usr/bin/geomask-ytwatch.sh"; chmod +x "$R/usr/bin/geomask-ytwatch.sh"
echo 'mode=auto' > "$R/etc/geomask-ytwatch.conf"
# torrent admin (v1.15.0): script + state dir fixtures
printf '#!/bin/sh\nexit 0\n' > "$R/usr/bin/geomask-torrent.sh"; chmod +x "$R/usr/bin/geomask-torrent.sh"
# v1.18.0: VPN lane audit (step5_check requires script + conf)
mkdir -p "$R/etc/geomask"
printf '#!/bin/sh\nexit 0\n' > "$R/usr/bin/geomask-vpnwatch.sh"; chmod +x "$R/usr/bin/geomask-vpnwatch.sh"
printf 'group=VPN-noP2P\nlogfile=/root/geomask-vpn-audit.log\n' > "$R/etc/geomask/vpnwatch.conf"
mkdir -p "$R/etc/geomask/torrent"
printf 'payload: []\n' > "$R/etc/mihomo/ruleset/ytvpn.yaml"
printf 'payload:\n  - DOMAIN-SUFFIX,tracker.example.org\n' > "$R/etc/mihomo/ruleset/torrentdirect.yaml"
# v1.17.0: the IP half of the mtrickle ruleset - must contain NO domain rules and vice versa
printf 'payload:\n  - IP-CIDR,203.0.113.0/24,no-resolve\n' > "$R/etc/mihomo/ruleset/mtrickle_bulk.yaml"
printf 'payload: []\n' > "$R/etc/mihomo/ruleset/mtrickle.yaml"
printf 'payload: []\n' > "$R/etc/mihomo/ruleset/ai.yaml"
printf 'payload: []\n' > "$R/etc/mihomo/ruleset/ytdirect.yaml"
cat > "$R/etc/mihomo/config.yaml" <<'YAMLEOF'
ipv6: false
proxy-providers:
  sub:
    type: http
    url: "https://example.com/a"
  de5:
    type: http
    url: "https://example.com/b"
proxy-groups:
  - name: VPN-noP2P
  - name: VPN
  - name: AI
rule-providers:
  ai:
    type: file
  mtrickle:
    type: file
  mtrickle_bulk:
    type: file
  ytdirect:
    type: file
  torrentdirect:
    type: file
rules:
  - AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,googlevideo.com)),REJECT
  - AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,youtube.com)),REJECT
  - AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,youtu.be)),REJECT
  - RULE-SET,ytvpn,VPN
  - RULE-SET,ytdirect,DIRECT
  - RULE-SET,ai,AI
  - RULE-SET,torrentdirect,DIRECT
  - SRC-PORT,41552,VPN
  - RULE-SET,mtrickle_bulk,VPN
  - RULE-SET,mtrickle,VPN-noP2P
  - MATCH,GLOBAL
listeners:
  - name: ai-devices
    type: mixed
    port: 7891
    listen: 127.0.0.1
    proxy: AI
  - name: torrent-direct
    type: mixed
    port: 7894
    listen: 192.168.0.1
sniffer:
  enable: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
    TLS:
      ports: [443, 8443, 5228]
    QUIC:
      ports: [443, 8443]
YAMLEOF
# healthy state
printf 'dnsmasq\nmagitrickled\nmihomo\nhev-socks5-tunnel\nrpcd\n' > "$HERE/state/services"
printf 'zapret-manager\ngeo-sync\n' > "$HERE/state/ubus_objects"
echo '*/5 * * * * /root/sync_mtrickle_mihomo.sh' > "$HERE/state/crontab"
echo '*/5 * * * * /usr/bin/geomask-guard.sh >/dev/null 2>&1 # geomask-guard' >> "$HERE/state/crontab"
echo '30 3 * * * /usr/bin/geomask-node-scan.sh >/dev/null 2>&1 # geomask-nodescan' >> "$HERE/state/crontab"
echo '*/5 * * * * /usr/bin/geomask-ytwatch.sh >/dev/null 2>&1 # geomask-ytwatch' >> "$HERE/state/crontab"
echo '20 4 * * * /usr/bin/geomask-ytwatch.sh --reset >/dev/null 2>&1 # geomask-ytwatch-reset' >> "$HERE/state/crontab"
echo '* * * * * /usr/bin/geomask-vpnwatch.sh --tick >/dev/null 2>&1 # geomask-vpnwatch' >> "$HERE/state/crontab"
echo '32666: from all iif br-lan ipproto icmp lookup main' > "$HERE/state/ip_rules"
# pgrep stub state: syncd watchdog considered running in healthy/apply scenarios
printf 'geomask-syncd.sh\n' > "$HERE/state/pgrep"
: > "$HERE/state/mihomo_t_ok"
export GM_PREFIX="$HERE/root_healthy"
t "S2 check exits zero" 0 sh "$SCRIPT" --check
contains "$HERE/last_out.txt" "fail=0" "S2 zero failures"

# ---------- scenario 3: broken subs config -> --auto repairs with URLs ----------
echo "=== S3: broken subs, --auto --restart with urls ==="
R="$HERE/root_apply"
cp -a "$HERE/root_healthy/." "$R/"
rm -f "$R/etc/mihomo/config.yaml"   # break it
: > "$HERE/state/mihomo_t_ok"        # stub mihomo -t will pass
export GM_PREFIX="$HERE/root_apply"
t "S3 auto exits zero" 0 sh "$SCRIPT" --auto --yes --restart --vpn-url "https://vpn.example/sub1" --ai-url "https://ai.example/sub2"
contains "$R/etc/mihomo/config.yaml" 'url: "https://vpn.example/sub1"' "S3 vpn url written"
contains "$R/etc/mihomo/config.yaml" 'url: "https://ai.example/sub2"' "S3 ai url written"
contains "$R/etc/mihomo/config.yaml" "name: VPN" "S3 VPN group written"
contains "$R/etc/mihomo/config.yaml" "RULE-SET,mtrickle,VPN" "S3 mtrickle rule written"
contains "$R/etc/mihomo/config.yaml" "port: 7891" "S3 AI-devices listener written"
contains "$HERE/last_out.txt" "verify: PASS" "S3 verify passed"

# ---------- scenario 4: help + bad flag ----------
echo "=== S4: CLI edges ==="
t "S4 help exits 0" 0 sh "$SCRIPT" --help
t "S4 bad flag exits 2" 2 sh "$SCRIPT" --wat

# ---------- scenario 5: /root/.geomask-norestart pin blocks --restart ----------
echo "=== S5: restart pin ==="
R="$HERE/root_apply"
rm -f "$R/root/.geomask-norestart"
rm -f "$R/etc/mihomo/config.yaml"
echo "restarts forbidden" > "$R/root/.geomask-norestart"
export GM_PREFIX="$R"
sh "$SCRIPT" --step 3 --restart --yes --vpn-url "https://vpn.example/p1" --ai-url "https://ai.example/p2" >"$HERE/last_out.txt" 2>&1 || true
contains "$HERE/last_out.txt" "ignoring --restart" "S5 pin ignores --restart"
if grep -q "restarting mihomo" "$HERE/last_out.txt"; then
  echo "FAIL: S5 restart happened despite pin"; failn=$((failn+1))
else
  echo "PASS: S5 no restart with pin"; pass=$((pass+1))
fi
rm -f "$R/root/.geomask-norestart"

# ---------- scenario 6: menu + step-by-step master ----------
echo "=== S6: interactive menu + master ==="
export GM_PREFIX="$HERE/root_healthy"
printf '2\nq\nq\n' | sh "$SCRIPT" >"$HERE/last_out.txt" 2>&1
_rc=$?
if [ "$_rc" = 0 ]; then echo "PASS: S6 menu exits 0"; pass=$((pass+1)); else echo "FAIL: S6 menu rc=$_rc"; failn=$((failn+1)); fi
contains "$HERE/last_out.txt" "GEOMASK" "S6 banner shown"
contains "$HERE/last_out.txt" "Выберите пункт" "S6 prompt shown"
contains "$HERE/last_out.txt" "Роутер:" "S6 dashboard shown"
contains "$HERE/last_out.txt" "Пошаговый мастер" "S6 master menu item shown"
_st_n=$(grep -cE 'выполнено|требует внимания' "$HERE/last_out.txt")
if [ "$_st_n" = 7 ]; then echo "PASS: S6 master shows 7 step statuses once"; pass=$((pass+1)); else echo "FAIL: S6 master status lines=$_st_n (want 7)"; failn=$((failn+1)); fi
if grep 'MagiTrickle:' "$HERE/last_out.txt" | grep -q 'запущен'; then echo "PASS: S6 MagiTrickle shows running"; pass=$((pass+1)); else echo "FAIL: S6 MagiTrickle status wrong"; grep 'MagiTrickle' "$HERE/last_out.txt" | sed 's/^/    | /'; failn=$((failn+1)); fi

# ---------- scenario 7: reinstall keeps current URLs, no mihomo restart ----------
echo "=== S7: --reinstall --yes (keep current subscription URLs) ==="
R="$HERE/root_apply"
export GM_PREFIX="$R"
sh "$SCRIPT" --reinstall --yes >"$HERE/last_out.txt" 2>&1
_rc=$?
if [ "$_rc" = 0 ]; then echo "PASS: S7 reinstall rc=0"; pass=$((pass+1)); else echo "FAIL: S7 reinstall rc=$_rc"; sed 's/^/    | /' "$HERE/last_out.txt" | tail -25; failn=$((failn+1)); fi
contains "$R/etc/mihomo/config.yaml" 'url: "https://vpn.example/p1"' "S7 kept VPN url"
contains "$R/etc/mihomo/config.yaml" 'url: "https://ai.example/p2"' "S7 kept AI url"
contains "$HERE/last_out.txt" "verify: PASS" "S7 verify passed"
if grep -q "restarting mihomo" "$HERE/last_out.txt"; then
  echo "FAIL: S7 restarted mihomo despite no-restart policy"; failn=$((failn+1))
else
  echo "PASS: S7 no mihomo restart"; pass=$((pass+1))
fi
[ -s "$R/usr/bin/geo-backend.sh" ] && { echo "PASS: S7 geo reinstalled"; pass=$((pass+1)); } || { echo "FAIL: S7 geo missing"; failn=$((failn+1)); }

# ---------- scenario 8: --check has no duplicate lines, real counters ----------
echo "=== S8: check-only output sanity ==="
export GM_PREFIX="$HERE/root_healthy"
sh "$SCRIPT" --check >"$HERE/last_out.txt" 2>&1
_rc=$?
if [ "$_rc" = 0 ]; then echo "PASS: S8 check rc=0"; pass=$((pass+1)); else echo "FAIL: S8 check rc=$_rc"; failn=$((failn+1)); fi
_n=$(grep -c 'proxy-providers: 2' "$HERE/last_out.txt")
if [ "$_n" = 1 ]; then echo "PASS: S8 no duplicate detail lines"; pass=$((pass+1)); else echo "FAIL: S8 detail lines printed $_n times"; failn=$((failn+1)); fi
contains "$HERE/last_out.txt" "OpenWrt: 24.10" "S8 OpenWrt version shown"
contains "$HERE/last_out.txt" "aidns" "S8 AI-DNS step present in report"
if grep -q 'pass=6' "$HERE/last_out.txt"; then echo "PASS: S8 summary counts passing steps"; pass=$((pass+1)); else echo "FAIL: S8 summary pass count: $(grep -o 'pass=[0-9]*' "$HERE/last_out.txt")"; failn=$((failn+1)); fi

# ---------- scenario 9: no third-party panel references in the installer ----------
echo "=== S9: no Zapret-Manager references ==="
_n=$(grep -cE 'Zapret-Manager|zapret-manager|StressOzz' "$SCRIPT")
if [ "$_n" = 0 ]; then echo "PASS: S9 installer has no panel references"; pass=$((pass+1)); else echo "FAIL: S9 found $_n panel references"; grep -nE 'Zapret-Manager|zapret-manager|StressOzz' "$SCRIPT" | head -5; failn=$((failn+1)); fi

# ---------- scenario 10: safe restart path (backup -> trial -> verified restart) ----------
echo "=== S10: safe mihomo restart path ==="
R="$HERE/root_apply"
rm -f "$R/root/.geomask-norestart"
rm -f "$R/etc/mihomo/config.yaml"
export GM_PREFIX="$R"
sh "$SCRIPT" --step 3 --restart --yes --vpn-url "https://vpn.example/p1" --ai-url "https://ai.example/p2" >"$HERE/last_out.txt" 2>&1 || true
cp -f "$HERE/last_out.txt" "$HERE/s10_out.txt" 2>/dev/null || true
contains "$HERE/last_out.txt" "trial run: OK" "S10 trial run before restart"
contains "$HERE/last_out.txt" "restarted and verified" "S10 verified restart"
contains "$HERE/last_out.txt" "router-backup" "S10 full backup created"

# ---------- scenario 11: ICMP rule presence check is semantic (v1.6.2) ----------
# Guard reseats our rules to pref (base - 100) when the magitrickle base drifts;
# the hotplug must NOT add a duplicate when the ICMP rule lives at another pref.
echo "=== S11: ICMP check semantic (no dup after reseat) ==="
if grep -q "grep -q '19901:'" "$SCRIPT"; then
  echo "FAIL: S11 installer still checks ICMP by pref 19901"; failn=$((failn+1))
else
  echo "PASS: S11 no pref-based ICMP check in installer"; pass=$((pass+1))
fi
echo '20100: from all iif br-lan ipproto icmp lookup main' > "$HERE/state/ip_rules"
ACTION=ifup sh "$HERE/../assets/99-default-vpn-route" >"$HERE/last_out.txt" 2>&1
_icmp_n=$(grep -c 'ipproto icmp' "$HERE/state/ip_rules")
if [ "$_icmp_n" = 1 ]; then
  echo "PASS: S11 reseated ICMP rule not duplicated"; pass=$((pass+1))
else
  echo "FAIL: S11 icmp rules now: $_icmp_n (want 1)"; sed 's/^/    | /' "$HERE/state/ip_rules"; failn=$((failn+1))
fi
contains "$HERE/state/ip_rules" "priority 32760" "S11 hotplug actually ran"

# ---------- scenario 12: self-update feature wiring (v1.7.0) ----------
echo "=== S12: self-update markers/methods ==="
# 1) every @@...@@ marker stamped by build.py (no leftovers)
if grep -q '@@' "$SCRIPT"; then
  echo "FAIL: S12 unreplaced markers:"; grep -o '@@[A-Za-z0-9_]*@@' "$SCRIPT" | head -3 | sed 's/^/    /'
  failn=$((failn+1))
else
  echo "PASS: S12 no unreplaced markers"; pass=$((pass+1))
fi
# 2) component versions == GM_VERSION
_gv=$(sed -n 's/^GM_VERSION="\([^"]*\)".*/\1/p' "$SCRIPT" | head -1)
for _m in "PANEL_VERSION = '$_gv'" "BACKEND_VERSION=\"$_gv\"" "GUARD_VERSION=\"$_gv\""; do
  if grep -qF "$_m" "$SCRIPT"; then echo "PASS: S12 stamped: $_m"; pass=$((pass+1))
  else echo "FAIL: S12 stamp missing: $_m"; failn=$((failn+1)); fi
done
# 3) upd_* methods wired through backend + rpcd + acl + js (>=3 refs each)
for _m in upd_check upd_apply upd_status; do
  _c=$(grep -c "$_m" "$SCRIPT")
  if [ "$_c" -ge 3 ]; then echo "PASS: S12 $_m wired ($_c refs)"; pass=$((pass+1))
  else echo "FAIL: S12 $_m refs=$_c (want >=3)"; failn=$((failn+1)); fi
done
# 4) update runner sanity: backup first, digest check, no-restart install
for _p in 'sysupgrade -b' 'sha256 mismatch' 'reinstall --yes' 'rpcd reload' 'wc -c < "$BK"' 'rm -f /tmp/router-backup-'; do
  if grep -qF "$_p" "$SCRIPT"; then echo "PASS: S12 runner has: $_p"; pass=$((pass+1))
  else echo "FAIL: S12 runner missing: $_p"; failn=$((failn+1)); fi
done
# 5) backups: persistent shared folder, but archive MUST be assembled in /tmp and moved -
#    a pre-existing copy under /root would nest into the next sysupgrade backup (v1.6-1.8 bug)
if grep -qF 'geomask-bk-' "$SCRIPT" && ! grep -qE 'sysupgrade -b "[^"]*geomask-backups/' "$SCRIPT"; then
  echo "PASS: S12 ensure_backup: /tmp assembly + move, no direct writes into share"; pass=$((pass+1))
else
  echo "FAIL: S12 ensure_backup writes backup directly into share dir"; failn=$((failn+1))
fi
# 6) busybox find has no -delete on OpenWrt - purge must use rm -f globs
if grep -q -- '-delete' "$SCRIPT"; then
  echo "FAIL: S12 uses unsupported 'find -delete'"; failn=$((failn+1))
else
  echo "PASS: S12 no find -delete (busybox-safe)"; pass=$((pass+1))
fi

# ---------- scenario 13: backup folder over SMB + panel links (v1.9.0) ----------
echo "=== S13: backups SMB share ==="
for _p in 'SMB_SHARE_NAME=geomask-backups' 'ensure_smb_share' 'cmd_backups' 'BACKUP_DIR=/root/geomask-backups'; do
  if grep -qF "$_p" "$SCRIPT"; then echo "PASS: S13 has: $_p"; pass=$((pass+1))
  else echo "FAIL: S13 missing: $_p"; failn=$((failn+1)); fi
done
# panel wires the backups method: rpcd list + acl read + js call + block render
_c=$(grep -c 'backups' "$SCRIPT")
if [ "$_c" -ge 8 ]; then echo "PASS: S13 backups wired across layers ($_c refs)"; pass=$((pass+1))
else echo "FAIL: S13 backups refs=$_c (want >=8)"; failn=$((failn+1)); fi
if grep -qF '"backups"' "$SCRIPT"; then echo "PASS: S13 acl/rpcd method present"; pass=$((pass+1))
else echo "FAIL: S13 no \"backups\" method"; failn=$((failn+1)); fi
# v1.9.1: uci section must be captured from 'uci add' output (no @share[last] syntax support)
if grep -qF '_sec=$(uci add ksmbd share' "$SCRIPT" && ! grep -qF '@share[last]' "$SCRIPT"; then
  echo "PASS: S13 uci section id captured correctly"; pass=$((pass+1))
else
  echo "FAIL: S13 bad uci section handling"; failn=$((failn+1))
fi
# v1.9.2: plain yes/no values (quoted '1' leaked into ksmbd.conf) + purge strictly BEFORE create
if grep -qF 'read_only=yes' "$SCRIPT" && ! grep -qE "read_only='1'" "$SCRIPT"; then
  echo "PASS: S13 uci yes/no values"; pass=$((pass+1))
else
  echo "FAIL: S13 quoted uci values present"; failn=$((failn+1))
fi
if grep -qF 'rm -f "$_dir"/router-backup-*.tar.gz 2>/dev/null' "$SCRIPT" && grep -qF 'rm -f /tmp/router-backup-*.tar.gz "$BKD"/router-backup-*.tar.gz' "$SCRIPT"; then
  echo "PASS: S13 old copies purged before sysupgrade (no embedding)"; pass=$((pass+1))
else
  echo "FAIL: S13 purge order wrong"; failn=$((failn+1))
fi
# v1.9.3: section enumeration must accept 'ksmbd.@share[N]' (uci show format) + dedupe
if grep -qF 's/^\(ksmbd\.[^=]*\)=share$/\1/p' "$SCRIPT" && grep -qF 'duplicate sections removed' "$SCRIPT"; then
  echo "PASS: S13 section enumeration handles @share[N] + dedupe"; pass=$((pass+1))
else
  echo "FAIL: S13 section enumeration broken"; failn=$((failn+1))
fi

# v1.12.0: tabbed panel + full node-audit automation control
for _p in 'gs-tabs' 'callNodesGet' 'cmd_nodes_set' 'cmd_sync_set' 'cmd_syncd_set' 'cmd_pin_set' 'geomask-nodescan.state'; do
  if grep -qF "$_p" "$SCRIPT"; then echo "PASS: S16 v1.12: $_p"; pass=$((pass+1))
  else echo "FAIL: S16 v1.12 missing: $_p"; failn=$((failn+1)); fi
done
# v1.12.2: generic LuCI footer must be suppressed (own save buttons only)
if grep -qF 'handleSaveApply: null' "$SCRIPT"; then
  echo "PASS: S16 v1.12.2 footer suppressed"; pass=$((pass+1))
else
  echo "FAIL: S16 v1.12.2 footer not suppressed"; failn=$((failn+1))
fi

echo "=== S14: syncd watchdog + stack card ==="
for _p in 'geomask-syncd.sh' '/etc/init.d/geomask-syncd' 'geomask-sync.state' 'cmd_stack' 'callStack' 'inotifywait'; do
  if grep -qF "$_p" "$SCRIPT"; then echo "PASS: S14 has: $_p"; pass=$((pass+1))
  else echo "FAIL: S14 missing: $_p"; failn=$((failn+1)); fi
done
# syncd must be removed on uninstall too (no orphans)
if grep -qF 'removed: syncd watchdog' "$SCRIPT"; then
  echo "PASS: S14 uninstall cleans syncd"; pass=$((pass+1))
else
  echo "FAIL: S14 uninstall leaves syncd"; failn=$((failn+1))
fi
# v1.9.4: backslashes must be JSON-escaped (rpcd rejects invalid \g escapes -> Invalid argument)
if grep -qF '_unc=$(json_esc' "$SCRIPT" && grep -qF '_j=$(printf' "$SCRIPT"; then
  echo "PASS: S13 UNC/say JSON escaping present"; pass=$((pass+1))
else
  echo "FAIL: S13 missing json escaping of backslash paths"; failn=$((failn+1))
fi
# v1.10.2: subscription exclude-filter must carry RF-marked node blocklist
if grep -qF 'Нидерланды-(5|13|16|18)' "$SCRIPT" && grep -qF 'Германия-[234]' "$SCRIPT"; then
  echo "PASS: S13 RF node filter in exclude-filter"; pass=$((pass+1))
else
  echo "FAIL: S13 RF node filter missing"; failn=$((failn+1))
fi

# v1.11.0: nightly node audit (registry scan + panel + cron)
for _p in 'geomask-node-scan.sh' 'geomask-nodes.conf' 'geomask-nodescan.state' 'nodescan cron' 'callNodescan' 'bad_asns'; do
  if grep -qF "$_p" "$SCRIPT"; then echo "PASS: S15 nodescan has: $_p"; pass=$((pass+1))
  else echo "FAIL: S15 nodescan missing: $_p"; failn=$((failn+1)); fi
done
# v1.9.6: simple SMB credentials (backup/backup, guest ok) + force_root for /root paths
if grep -qF 'force_root=1' "$SCRIPT" && grep -qF 'ksmbd.adduser backup -p backup' "$SCRIPT"; then
  echo "PASS: S13 force_root + backup auth user"; pass=$((pass+1))
else
  echo "FAIL: S13 SMB auth setup missing"; failn=$((failn+1))
fi
# backup must be built in /tmp then moved (never let an older /root copy nest into sysupgrade -b)
if grep -qF 'geomask-bk-$' "$SCRIPT" && grep -qF 'mv -f "$_out" "$_dest"' "$SCRIPT"; then
  echo "PASS: S13 ensure_backup: build in tmp + move (no nesting)"; pass=$((pass+1))
else
  echo "FAIL: S13 ensure_backup does not build-then-move"; failn=$((failn+1))
fi

# ---------- scenario 17: MagiTrickle lists template + seeder (v1.13.0) ----------
echo "=== S17: lists template (v1.13.0) ==="
for _p in '--seed-lists' 'write_lists_assets' 'seed_lists' 'geomask-seed-lists.py' 'magitrickle-groups.yaml' 'cmd_lists_get' 'cmd_lists_seed' 'callListsGet' 'callListsSeed' 'lists_get' 'lists_seed'; do
  if grep -qF -- "$_p" "$SCRIPT"; then echo "PASS: S17 has: $_p"; pass=$((pass+1))
  else echo "FAIL: S17 missing: $_p"; failn=$((failn+1)); fi
done
# template + meta shipped in repo
if [ -s "$HERE/../assets/magitrickle-groups.yaml" ] && [ -s "$HERE/../templates/lists.meta.json" ]; then
  echo "PASS: S17 template + meta present"; pass=$((pass+1))
else echo "FAIL: S17 template/meta missing"; failn=$((failn+1)); fi
# template must carry the real groups (To VPN + Google+AI + Youtube)
if grep -qF 'name: To VPN' "$HERE/../assets/magitrickle-groups.yaml" \
   && grep -qF 'name: Google+AI to DE' "$HERE/../assets/magitrickle-groups.yaml" \
   && grep -qF 'name: To Not VPN' "$HERE/../assets/magitrickle-groups.yaml"; then
  echo "PASS: S17 template has routing groups"; pass=$((pass+1))
else echo "FAIL: S17 template missing expected groups"; failn=$((failn+1)); fi
# SECRET SCAN: lists template must not contain URLs or hwid (domain lists only)
if grep -qiE 'http://|https://|x-hwid|hwid:' "$HERE/../assets/magitrickle-groups.yaml"; then
  echo "FAIL: S17 lists template contains URL/hwid"; grep -inE 'http|hwid' "$HERE/../assets/magitrickle-groups.yaml" | head -3 | sed 's/^/    | /'; failn=$((failn+1))
else echo "PASS: S17 lists template has no URLs/hwid"; pass=$((pass+1)); fi
# SECRET SCAN: no 32-hex credential literal in installer source or template
if grep -qE '\b[0-9a-f]{32}\b' "$HERE/../geomask.sh.in" "$HERE/../assets/magitrickle-groups.yaml"; then
  echo "FAIL: S17 possible 32-hex secret literal committed"; failn=$((failn+1))
else echo "PASS: S17 no 32-hex secret literal"; pass=$((pass+1)); fi
# seeder is prefix-aware (takes --config/--template) and idempotent-safe (check-empty)
if grep -qF -- '--check-empty' "$HERE/../assets/geomask-seed-lists.py" \
   && grep -qF -- '--config=' "$HERE/../assets/geomask-seed-lists.py" \
   && grep -qF 'bak_geomask_' "$HERE/../assets/geomask-seed-lists.py"; then
  echo "PASS: S17 seeder: check-empty + prefix paths + backup"; pass=$((pass+1))
else echo "FAIL: S17 seeder contract broken"; failn=$((failn+1)); fi
# backend runs OUTSIDE geomask.sh: svc_alive is undefined there -> must use pgrep (v1.13.0 bug guard)
if grep -qF 'svc_alive' "$HERE/../assets/geo-backend.sh"; then
  echo "FAIL: S17 geo-backend.sh calls svc_alive (undefined in backend context)"; failn=$((failn+1))
else echo "PASS: S17 geo-backend.sh uses pgrep, not svc_alive"; pass=$((pass+1)); fi

# ---------- scenario 18: ytvpn (googlevideo edges -> VPN via MagiTrickle group) (v1.13.2/3) ----------
echo "=== S18: ytvpn -> VPN (v1.13.3) ==="
# seed asset present and points googlevideo at the suffix (source of truth is the MT group)
if [ -s "$HERE/../assets/ytvpn.yaml" ] && grep -q 'DOMAIN-SUFFIX,googlevideo.com' "$HERE/../assets/ytvpn.yaml"; then
  echo "PASS: S18 ytvpn seed has googlevideo suffix"; pass=$((pass+1))
else echo "FAIL: S18 ytvpn seed missing/incomplete"; failn=$((failn+1)); fi
# sync must generate ytvpn.yaml from the GoogleVideo VPN group
for _p in 'GOOGLEVIDEO_GROUP' 'ytvpn_payload' 'write_if_changed(YTVPN'; do
  if grep -qF -- "$_p" "$HERE/../assets/sync_mtrickle_mihomo.sh"; then echo "PASS: S18 sync has: $_p"; pass=$((pass+1))
  else echo "FAIL: S18 sync missing: $_p"; failn=$((failn+1)); fi
done
# ytdirect must NOT carry googlevideo (would win over VPN by ordering)
if grep -qE 'googlevideo\.com$' "$HERE/../assets/ytdirect.yaml"; then
  echo "FAIL: S18 ytdirect still contains googlevideo suffix"; failn=$((failn+1))
else echo "PASS: S18 ytdirect free of googlevideo"; pass=$((pass+1)); fi
# built script wires provider + rule + check
for _p in 'path: /etc/mihomo/ruleset/ytvpn.yaml' 'RULE-SET,ytvpn,VPN' 'ytvpn rule: present'; do
  if grep -qF -- "$_p" "$SCRIPT"; then echo "PASS: S18 has: $_p"; pass=$((pass+1))
  else echo "FAIL: S18 missing: $_p"; failn=$((failn+1)); fi
done
# ORDERING: ytvpn rule must precede ytdirect DIRECT rule (else ytdirect suffix wins -> still DIRECT)
_yt=$(grep -nF 'RULE-SET,ytvpn,VPN' "$HERE/../geomask.sh.in" | head -1 | cut -d: -f1)
_yd=$(grep -nF 'RULE-SET,ytdirect,DIRECT' "$HERE/../geomask.sh.in" | head -1 | cut -d: -f1)
if [ -n "$_yt" ] && [ -n "$_yd" ] && [ "$_yt" -lt "$_yd" ]; then
  echo "PASS: S18 ytvpn rule precedes ytdirect (line $_yt < $_yd)"; pass=$((pass+1))
else echo "FAIL: S18 ytvpn/ytdirect order wrong (ytvpn=$_yt ytdirect=$_yd)"; failn=$((failn+1)); fi

# ---------- scenario 19: every backend dispatch method is present in rpcd ACL (v1.13.3) ----------
echo "=== S19: geo-sync methods must be ACL-granted AND registered in the rpcd wrapper ==="
# collect methods from the backend case-block (lines like:   foo)  cmd_foo ...) and check each
# appears in acl-geo-sync.json read[] or write[]. Missing -> rpcd -32002 Access denied at runtime.
_miss=0; _nowrap=0
for _m in $(grep -oE '^  [a-z_]+\) ' "$HERE/../assets/geo-backend.sh" | tr -d ' )' | sort -u); do
  if ! grep -qF "\"$_m\"" "$HERE/../assets/acl-geo-sync.json"; then
    echo "  MISSING in ACL: $_m"; _miss=$((_miss+1))
  fi
  # v1.13.3 lesson: the ubus method must ALSO be registered in the rpcd plugin wrapper
  if ! grep -qE "(json_add_object \"$_m\"|^\t\t$_m\))" "$HERE/../assets/geo-sync"; then
    echo "  MISSING in rpcd wrapper: $_m"; _nowrap=$((_nowrap+1))
  fi
done
if [ "$_miss" = 0 ]; then echo "PASS: S19 all backend methods granted in ACL"; pass=$((pass+1))
else echo "FAIL: S19 $_miss backend method(s) missing from ACL"; failn=$((failn+1)); fi
if [ "$_nowrap" = 0 ]; then echo "PASS: S19 all backend methods registered in rpcd wrapper"; pass=$((pass+1))
else echo "FAIL: S19 $_nowrap backend method(s) missing from rpcd wrapper"; failn=$((failn+1)); fi
# explicit: lists_get/lists_seed must be present (the v1.13.0 regression)
if grep -qF '"lists_get"' "$HERE/../assets/acl-geo-sync.json" && grep -qF '"lists_seed"' "$HERE/../assets/acl-geo-sync.json" \
   && grep -qF '"lists_get"' "$HERE/../assets/geo-sync" && grep -qF '"lists_seed"' "$HERE/../assets/geo-sync"; then
  echo "PASS: S19 lists_get/lists_seed in ACL + wrapper"; pass=$((pass+1))
else echo "FAIL: S19 lists_* not in ACL/wrapper"; failn=$((failn+1)); fi

# ---------- scenario 20: youtube edges watchdog (v1.14.0) ----------
echo "=== S20: ytwatch (googlevideo auto-pin) ==="
if [ -s "$HERE/../assets/geomask-ytwatch.sh" ] && [ -s "$HERE/../assets/geomask-ytwatch.conf" ]; then
  echo "PASS: S20 ytwatch script + conf present"; pass=$((pass+1))
else echo "FAIL: S20 ytwatch assets missing"; failn=$((failn+1)); fi
for _p in '/usr/bin/geomask-ytwatch.sh' '/etc/geomask-ytwatch.conf' '# geomask-ytwatch' '# geomask-ytwatch-reset'; do
  if grep -qF -- "$_p" "$SCRIPT"; then echo "PASS: S20 installer has: $_p"; pass=$((pass+1))
  else echo "FAIL: S20 installer missing: $_p"; failn=$((failn+1)); fi
done
grep -qF 'ytwatch: installed' "$SCRIPT" && { echo "PASS: S20 step5_check verifies ytwatch"; pass=$((pass+1)); } || { echo "FAIL: S20 no ytwatch check"; failn=$((failn+1)); }
grep -qF 'removed: ytwatch' "$SCRIPT" && { echo "PASS: S20 uninstall cleans ytwatch"; pass=$((pass+1)); } || { echo "FAIL: S20 uninstall leaves ytwatch"; failn=$((failn+1)); }
# watchdog semantics: reads mihomo dial errors, pins into the MT group, nightly release, cap, modes
for _p in 'googlevideo' '--reset' '--mode' 'max_pins' 'fail_threshold'; do
  if grep -qF -- "$_p" "$HERE/../assets/geomask-ytwatch.sh"; then echo "PASS: S20 ytwatch has: $_p"; pass=$((pass+1))
  else echo "FAIL: S20 ytwatch missing: $_p"; failn=$((failn+1)); fi
done
for _p in 'callYtGet' 'callYtMode' 'callYtReset' 'yt_get' 'yt_mode' 'yt_reset'; do
  if grep -qF -- "$_p" "$SCRIPT"; then echo "PASS: S20 panel/backend has: $_p"; pass=$((pass+1))
  else echo "FAIL: S20 panel/backend missing: $_p"; failn=$((failn+1)); fi
done
# v1.15.2: stalled-edge detection (DPI kills the stream AFTER the handshake -> no dial error at all)
for _p in 'stall_min_age' 'stall_max_bytes' 'stall_threshold' 'stall_seen' '/connections' "Bearer "; do
  if grep -qF -- "$_p" "$HERE/../assets/geomask-ytwatch.sh"; then echo "PASS: S20 ytwatch has: $_p"; pass=$((pass+1))
  else echo "FAIL: S20 ytwatch missing: $_p"; failn=$((failn+1)); fi
done
if grep -qF 'stall_min_age=' "$HERE/../assets/geomask-ytwatch.conf"; then
  echo "PASS: S20 stall thresholds shipped in the conf"; pass=$((pass+1))
else echo "FAIL: S20 stall thresholds missing from the conf"; failn=$((failn+1)); fi
grep -qF 'Зависшие рёбра' "$HERE/../assets/geo-sync-page.js" \
  && { echo "PASS: S20 panel shows stalled edges"; pass=$((pass+1)); } \
  || { echo "FAIL: S20 panel does not show stalled edges"; failn=$((failn+1)); }
# v1.16.1: state must survive a reboot/reinstall, and the MagiTrickle tag is the source of truth
if grep -qF "STATE='/etc/geomask/ytwatch.state'" "$HERE/../assets/geomask-ytwatch.sh"; then
  echo "PASS: S20 ytwatch state is persistent (not /tmp)"; pass=$((pass+1))
else echo "FAIL: S20 ytwatch state still lives in /tmp"; failn=$((failn+1)); fi
grep -qF 'def auto_rule_ids' "$HERE/../assets/geomask-ytwatch.sh" \
  && { echo "PASS: S20 reset uses the ytwatch rule tag"; pass=$((pass+1)); } \
  || { echo "FAIL: S20 reset has no tag-based fallback"; failn=$((failn+1)); }
grep -qF "rm -f \"\$(P /usr/bin/geomask-ytwatch.sh)\"" "$HERE/../geomask.sh.in" \
  && ! grep -qF 'tmp/geomask-ytwatch.state' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S20 uninstall does not delete the state"; pass=$((pass+1)); } \
  || { echo "FAIL: S20 uninstall still deletes the state"; failn=$((failn+1)); }

# ---------- scenario 21: update card must not show stale installed versions (v1.14.2) ----------
echo "=== S21: live installed-version block in update check ==="
if grep -qF '_upd_local_block' "$HERE/../assets/geo-backend.sh" \
   && grep -qF 'cached GitHub answer, but installed versions are always recomputed live' "$HERE/../assets/geo-backend.sh"; then
  echo "PASS: S21 cached check recomputes installed versions"; pass=$((pass+1))
else echo "FAIL: S21 update card still serves cached installed versions"; failn=$((failn+1)); fi
# the helper must be used by BOTH branches (cache hit and fresh fetch) - no duplicated logic left
if [ "$(grep -c '_upd_local_block' "$HERE/../assets/geo-backend.sh")" -ge 3 ]; then
  echo "PASS: S21 helper defined and used in both paths"; pass=$((pass+1))
else echo "FAIL: S21 helper not used in both paths"; failn=$((failn+1)); fi

# ---------- scenario 22: reboot must not make the update card lie (v1.14.3) ----------
echo "=== S22: release identity from flash components, not /tmp ==="
if grep -qF 'The "core" marker is an installer copy under /tmp' "$HERE/../assets/geo-backend.sh" \
   && grep -qF 'nothing deployed at all' "$HERE/../assets/geo-backend.sh"; then
  echo "PASS: S22 need-flag falls back to deployed components"; pass=$((pass+1))
else echo "FAIL: S22 need-flag still driven by the volatile /tmp core marker"; failn=$((failn+1)); fi
# the old unconditional rule must be gone
if grep -qE 'if \[ "\$_core" = "none" \]; then _LNEED=true$' "$HERE/../assets/geo-backend.sh"; then
  echo "FAIL: S22 bare core=none -> need=true rule still present"; failn=$((failn+1))
else echo "PASS: S22 no bare core=none -> need=true rule"; pass=$((pass+1)); fi

# ---------- scenario 23: torrent trackers must never reach the VPN lists (v1.14.4) ----------
echo "=== S23: torrentdirect (trackers -> DIRECT) ==="
if [ -s "$HERE/../assets/torrentdirect.yaml" ] && grep -q '^payload:' "$HERE/../assets/torrentdirect.yaml" \
   && grep -q 'DOMAIN-SUFFIX,' "$HERE/../assets/torrentdirect.yaml"; then
  echo "PASS: S23 tracker ruleset asset present with entries"; pass=$((pass+1))
else echo "FAIL: S23 tracker ruleset asset missing/empty"; failn=$((failn+1)); fi
if grep -qE 'x-hwid|token|password|secret|/sub' "$HERE/../assets/torrentdirect.yaml"; then
  echo "FAIL: S23 ruleset asset contains a secret-looking string"; failn=$((failn+1))
else echo "PASS: S23 ruleset asset has no secrets"; pass=$((pass+1)); fi
grep -qF '"torrentdirect.yaml"' "$HERE/../build.py" && { echo "PASS: S23 wired into build MAP"; pass=$((pass+1)); } || { echo "FAIL: S23 not in build MAP"; failn=$((failn+1)); }
for _p in '/etc/mihomo/ruleset/torrentdirect.yaml' 'RULE-SET,torrentdirect,DIRECT' 'torrentdirect->DIRECT rule' 'no blanket P2P port rules'; do
  if grep -qF -- "$_p" "$SCRIPT"; then echo "PASS: S23 installer has: $_p"; pass=$((pass+1))
  else echo "FAIL: S23 installer missing: $_p"; failn=$((failn+1)); fi
done
# the legacy rule that sent tracker ports to VPN must be gone FROM THE TEMPLATE.
# Scope to the generated rules block: the same strings appear in step3_check as detectors.
_tmpl=$(awk "/^ *printf .*'rules:'/{f=1} f{print} /'  - MATCH,GLOBAL'/{if(f)exit}" "$HERE/../geomask.sh.in")
if printf '%s' "$_tmpl" | grep -qE "DST-PORT,(6969|1337|2710|8081),VPN"; then
  echo "FAIL: S23 template still redirects P2P ports to VPN"; failn=$((failn+1))
else echo "PASS: S23 no P2P port -> VPN in the template"; pass=$((pass+1)); fi
if ! printf '%s' "$_tmpl" | grep -qF 'RULE-SET,torrentdirect,DIRECT'; then
  echo "FAIL: S23 template lacks the torrentdirect rule"; failn=$((failn+1))
else echo "PASS: S23 template emits the torrentdirect rule"; pass=$((pass+1)); fi
# ordering INSIDE the template: ai first, then torrentdirect, then mtrickle
_la=$(printf '%s\n' "$_tmpl" | grep -nF "RULE-SET,ai,AI" | head -1 | cut -d: -f1)
_lt=$(printf '%s\n' "$_tmpl" | grep -nF "RULE-SET,torrentdirect,DIRECT" | head -1 | cut -d: -f1)
_lm=$(printf '%s\n' "$_tmpl" | grep -nF "RULE-SET,mtrickle,VPN" | head -1 | cut -d: -f1)
if [ -n "$_la" ] && [ -n "$_lt" ] && [ -n "$_lm" ] && [ "$_la" -lt "$_lt" ] && [ "$_lt" -lt "$_lm" ]; then
  echo "PASS: S23 template rule order ai < torrentdirect < mtrickle"; pass=$((pass+1))
else echo "FAIL: S23 template rule order wrong (ai=$_la td=$_lt mt=$_lm)"; failn=$((failn+1)); fi
# the DIRECT listener for torrent clients is documented in the template too
grep -qF 'torrent-direct' "$HERE/../geomask.sh.in" || grep -qF 'torrent-direct' "$HERE/../docs/YOUTUBE.md" || grep -qF 'torrent-direct' "$HERE/../docs/ARCHITECTURE.md" \
  && { echo "PASS: S23 DIRECT listener documented"; pass=$((pass+1)); } || { echo "FAIL: S23 torrent-direct listener not documented"; failn=$((failn+1)); }

# ---------- scenario 24: torrent admin in the panel (v1.15.0) ----------
echo "=== S24: torrent admin (geomask-torrent.sh + panel) ==="
if [ -s "$HERE/../assets/geomask-torrent.sh" ]; then
  echo "PASS: S24 admin script present"; pass=$((pass+1))
else echo "FAIL: S24 admin script missing"; failn=$((failn+1)); fi
for _p in '--status' '--refresh' '--listener' '--extra' 'mihomo -t' 'Authorization'; do
  if grep -qF -- "$_p" "$HERE/../assets/geomask-torrent.sh"; then echo "PASS: S24 script has: $_p"; pass=$((pass+1))
  else echo "FAIL: S24 script missing: $_p"; failn=$((failn+1)); fi
done
grep -qF '"geomask-torrent.sh"' "$HERE/../build.py" && { echo "PASS: S24 in build MAP"; pass=$((pass+1)); } || { echo "FAIL: S24 not in build MAP"; failn=$((failn+1)); }
for _p in '/usr/bin/geomask-torrent.sh' '/etc/geomask/torrent' 'torrent admin: installed' 'removed: torrent admin'; do
  if grep -qF -- "$_p" "$SCRIPT"; then echo "PASS: S24 installer has: $_p"; pass=$((pass+1))
  else echo "FAIL: S24 installer missing: $_p"; failn=$((failn+1)); fi
done
# every admin method must exist in backend, rpcd wrapper AND acl (same trap as v1.13.0)
for _m in torrent_get torrent_refresh torrent_listener torrent_extra; do
  _ok=1
  grep -qF "cmd_$_m" "$HERE/../assets/geo-backend.sh" || { echo "  MISSING backend: $_m"; _ok=0; }
  grep -qF "\"$_m\"" "$HERE/../assets/geo-sync" || { echo "  MISSING rpcd wrapper: $_m"; _ok=0; }
  grep -qF "\"$_m\"" "$HERE/../assets/acl-geo-sync.json" || { echo "  MISSING acl: $_m"; _ok=0; }
  if [ "$_ok" = 1 ]; then echo "PASS: S24 $_m wired in backend+wrapper+acl"; pass=$((pass+1))
  else echo "FAIL: S24 $_m not wired everywhere"; failn=$((failn+1)); fi
done
for _p in 'callTorGet' 'callTorRefresh' 'callTorListener' 'callTorExtra' 'Торренты и трекеры'; do
  grep -qF -- "$_p" "$SCRIPT" && { echo "PASS: S24 panel has: $_p"; pass=$((pass+1)); } || { echo "FAIL: S24 panel missing: $_p"; failn=$((failn+1)); }
done
# the panel must read the 13th promise slot
grep -qF 'all[12]' "$HERE/../assets/geo-sync-page.js" && { echo "PASS: S24 panel consumes the new RPC slot"; pass=$((pass+1)); } || { echo "FAIL: S24 new RPC result not consumed"; failn=$((failn+1)); }
# v1.17.0: lanes. IP rules must never reach the P2P-restricted VPN subscription, because a
# torrent peer is always a bare address. The sync splits them out; --check enforces the invariant.
grep -qF 'MTBULK' "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && { echo "PASS: S24 sync emits a separate IP ruleset"; pass=$((pass+1)); } \
  || { echo "FAIL: S24 sync does not split IP rules"; failn=$((failn+1)); }
grep -qF "mt_dom = [p for p in mt_payload if not p.startswith('IP-CIDR')]" "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && { echo "PASS: S24 split is by rule TYPE (not by group name)"; pass=$((pass+1)); } \
  || { echo "FAIL: S24 split is not type-based"; failn=$((failn+1)); }
grep -qF 'lane invariant: mtrickle.yaml has no IP rules' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S24 --check verifies the lane invariant"; pass=$((pass+1)); } \
  || { echo "FAIL: S24 --check does not verify the invariant"; failn=$((failn+1)); }
grep -qF 'lane: mtrickle_bulk -> VPN rule missing' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S24 --check requires the lane routing rule"; pass=$((pass+1)); } \
  || { echo "FAIL: S24 --check does not require the lane rule"; failn=$((failn+1)); }
# the listener is rule-based only BECAUSE the lane exists; without a lane a fixed
# policy is still demanded - the check must keep both branches
grep -qF 'no fixed policy and no VPN lane' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S24 policy-less listener is still rejected without a lane"; pass=$((pass+1)); } \
  || { echo "FAIL: S24 lost the no-lanes safety branch"; failn=$((failn+1)); }
grep -qE 'SRC-PORT,41552,\(VPN\|AI\|DIRECT\)' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S24 peer-reply guard accepts the lane targets"; pass=$((pass+1)); } \
  || { echo "FAIL: S24 peer-reply guard check is wrong"; failn=$((failn+1)); }
if grep -qF 'def listener_block' "$HERE/../assets/geomask-torrent.sh" \
   && grep -qF "'    proxy: DIRECT'" "$HERE/../assets/geomask-torrent.sh"; then
  echo "PASS: S24 admin script: rule-based with lanes, DIRECT fallback without"; pass=$((pass+1))
else echo "FAIL: S24 admin script has no lane-aware policy logic"; failn=$((failn+1)); fi
grep -qF "'    proxy: DIRECT'" "$HERE/../geomask.sh.in" \
  && { echo "PASS: S24 fresh-install template pins a safe policy"; pass=$((pass+1)); } \
  || { echo "FAIL: S24 template ships a policy-less listener without lanes"; failn=$((failn+1)); }
# a self-update must not wipe accumulated YouTube pins (observed 31.10: --reinstall reset 10 pins)
grep -qF 'if [ -z "$1" ] && [ -x "$(P /usr/bin/geomask-ytwatch.sh)" ]' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S24 pins are released only on a real uninstall"; pass=$((pass+1)); } \
  || { echo "FAIL: S24 reinstall still releases YouTube pins"; failn=$((failn+1)); }

# v1.16.2: the panel must be able to bypass its own 1-hour cache for the GitHub poll
grep -qF "callUpdCheck({ force: 'force' })" "$HERE/../assets/geo-sync-page.js" \
  && { echo "PASS: S21 panel can force a live update check"; pass=$((pass+1)); } \
  || { echo "FAIL: S21 panel cannot force a live update check"; failn=$((failn+1)); }
grep -qF 'Проверить сейчас' "$HERE/../assets/geo-sync-page.js" \
  && { echo "PASS: S21 force-check control is labelled"; pass=$((pass+1)); } \
  || { echo "FAIL: S21 force-check control missing"; failn=$((failn+1)); }

# ==================== S25: route slots + VPN lane audit (v1.18.0) ====================
echo ""
echo "=== S25: slots VPN-noP2P / VPN / AI + lane audit ==="
# the restricted slot must be the one geomask ships and checks
grep -qF "'  - name: VPN-noP2P'" "$HERE/../geomask.sh.in" \
  && { echo "PASS: S25 template creates the VPN-noP2P slot"; pass=$((pass+1)); } \
  || { echo "FAIL: S25 template has no VPN-noP2P slot"; failn=$((failn+1)); }
grep -qF 'name: VPN$' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S25 --check distinguishes the optional VPN lane"; pass=$((pass+1)); } \
  || { echo "FAIL: S25 --check cannot tell a lane apart from no lane"; failn=$((failn+1)); }
# the new ubus method must exist in backend, wrapper AND acl (v1.13.0 trap)
for _m in vpnnp_sub_use; do
  grep -qF "$_m)" "$HERE/../assets/geo-backend.sh" \
    && grep -qF "\"$_m\"" "$HERE/../assets/geo-sync" \
    && grep -qF "\"$_m\"" "$HERE/../assets/acl-geo-sync.json" \
    && { echo "PASS: S25 $_m wired in backend+wrapper+acl"; pass=$((pass+1)); } \
    || { echo "FAIL: S25 $_m missing in one of backend/wrapper/acl"; failn=$((failn+1)); }
done
grep -qF 'callVpnnpSubUse' "$HERE/../assets/geo-sync-page.js" \
  && { echo "PASS: S25 panel exposes the third slot"; pass=$((pass+1)); } \
  || { echo "FAIL: S25 panel has no VPN-noP2P button"; failn=$((failn+1)); }
# status must report both tunnels, or the panel cards would lie
grep -qF '"vpn_nop2p_node"' "$HERE/../assets/geo-backend.sh" \
  && grep -qF '"vpn_nop2p_sub"' "$HERE/../assets/geo-backend.sh" \
  && { echo "PASS: S25 status reports both VPN slots"; pass=$((pass+1)); } \
  || { echo "FAIL: S25 status misses a slot"; failn=$((failn+1)); }
# lane creation must be reversible: backup + validate + rollback
grep -qF 'bak_slot' "$HERE/../assets/geo-backend.sh" \
  && grep -qF 'mihomo config test failed - old config kept' "$HERE/../assets/geo-backend.sh" \
  && { echo "PASS: S25 slot edit validates and rolls back"; pass=$((pass+1)); } \
  || { echo "FAIL: S25 slot edit has no rollback"; failn=$((failn+1)); }
for _p in 'geomask-vpnwatch.sh' 'geomask-vpnwatch.conf'; do
  grep -qF "\"$_p\"" "$HERE/../build.py" \
    && { echo "PASS: S25 asset in build MAP: $_p"; pass=$((pass+1)); } \
    || { echo "FAIL: S25 asset not in build MAP: $_p"; failn=$((failn+1)); }
done
grep -qF 'geomask-vpnwatch.sh 755' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S25 installer installs the audit script"; pass=$((pass+1)); } \
  || { echo "FAIL: S25 installer does not ship the audit script"; failn=$((failn+1)); }
grep -qF '# geomask-vpnwatch' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S25 audit cron tagged for clean removal"; pass=$((pass+1)); } \
  || { echo "FAIL: S25 cron is not tagged"; failn=$((failn+1)); }
grep -qF 'geomask-vpnwatch.sh)' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S25 uninstall removes the audit script"; pass=$((pass+1)); } \
  || { echo "FAIL: S25 uninstall leaves the audit script"; failn=$((failn+1)); }
# the audit must never touch routing - it only reads
if grep -nE 'PUT .*proxies|/proxies/.{0,20}DELETE|url-test' "$HERE/../assets/geomask-vpnwatch.sh" | grep -q .; then
  echo "FAIL: S25 audit script tries to change routing"; failn=$((failn+1))
else echo "PASS: S25 audit script is read-only"; pass=$((pass+1)); fi
grep -qF 'group=VPN-noP2P' "$HERE/../assets/geomask-vpnwatch.conf" \
  && { echo "PASS: S25 audit watches the restricted slot by default"; pass=$((pass+1)); } \
  || { echo "FAIL: S25 audit default group is wrong"; failn=$((failn+1)); }

# ==================== S26: zapret sync + port-rule invariant (v1.19.0) ====================
echo ""
echo "=== S26: zapret exclude sync and the restricted-slot invariant ==="
grep -qF 'ZEXCL' "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && grep -qF 'geomask sync: tunneled domains' "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && { echo "PASS: S26 sync writes a managed zapret exclude block"; pass=$((pass+1)); } \
  || { echo "FAIL: S26 sync has no zapret exclude block"; failn=$((failn+1)); }
grep -qF 'pinned_direct' "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && { echo "PASS: S26 DIRECT-pinned domains stay under DPI"; pass=$((pass+1)); } \
  || { echo "FAIL: S26 would exclude domains that go DIRECT"; failn=$((failn+1)); }
# the exclude file keeps its own content: the block is replaced by markers, not by rewriting
grep -qF 'drop our previous block by marker positions' "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && { echo "PASS: S26 exclude file keeps its own content around the block"; pass=$((pass+1)); } \
  || { echo "FAIL: S26 may clobber the exclude file"; failn=$((failn+1)); }
# v1.20.2: zapret wants BARE domains - writing "DOMAIN-SUFFIX,foo" would never match
grep -qF 'zapret' "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && grep -qF 'def bare(p)' "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && { echo "PASS: S26 exclude entries are stripped to bare domains"; pass=$((pass+1)); } \
  || { echo "FAIL: S26 would write mihomo rule syntax into zapret"; failn=$((failn+1)); }
grep -qF 'send ports/IPs/protocols to VPN-noP2P' "$HERE/../geomask.sh.in" \
  && { echo "PASS: S26 --check rejects port/IP rules on the restricted slot"; pass=$((pass+1)); } \
  || { echo "FAIL: S26 --check has no port-rule invariant"; failn=$((failn+1)); }
# v1.19.1: the actions column holds four buttons - nowrap pushed them out of the card
if grep -qF 'gs-subs td:last-child{width:200px;white-space:nowrap}' "$HERE/../assets/geo-sync-page.js"; then
  echo "FAIL: S26 subscription actions still force a single nowrap line"; failn=$((failn+1))
else echo "PASS: S26 subscription actions may wrap inside the card"; pass=$((pass+1)); fi
grep -qF '.gs-subs td:nth-child(3) .gs-badge{white-space:nowrap}' "$HERE/../assets/geo-sync-page.js" \
  && { echo "PASS: S26 the slot badge stays on one line"; pass=$((pass+1)); } \
  || { echo "FAIL: S26 the slot badge can break across lines"; failn=$((failn+1)); }

# v1.20.0: hand-written DIRECT pins outrank whatever group the owner picks - they must be gone
if grep -qE "DOMAIN-SUFFIX,(thepiratebay|rutracker)[a-z.]*,DIRECT" "$HERE/../geomask.sh.in"; then
  echo "FAIL: S26 template still emits hardcoded torrent DIRECT pins"; failn=$((failn+1))
else echo "PASS: S26 no hardcoded torrent pins in the template"; pass=$((pass+1)); fi
# node flags must reach the UI: cleanName strips them, so the badge has to carry them
grep -qF 'function flagOf' "$HERE/../assets/geo-sync-page.js" \
  && grep -qF 'ccBadge(cc, name)' "$HERE/../assets/geo-sync-page.js" \
  && { echo "PASS: S26 the badge renders the flag from the node name"; pass=$((pass+1)); } \
  || { echo "FAIL: S26 flags are still stripped everywhere"; failn=$((failn+1)); }
if grep -qE 'ccBadge\((aiCc|vpnCc|laneCc)\)' "$HERE/../assets/geo-sync-page.js"; then
  echo "FAIL: S26 some node badge still gets no name (flag lost)"; failn=$((failn+1))
else echo "PASS: S26 all three slot badges receive the node name"; pass=$((pass+1)); fi

# v1.20.1: the first implementation used a None sentinel for the pre-block list and crashed on
# the SECOND run (when the block already existed) - a crash here also skips the mihomo reload.
grep -qF 'pre, post = old[:bi], old[ei+1:]' "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && { echo "PASS: S26 exclude block is replaced by marker positions"; pass=$((pass+1)); } \
  || { echo "FAIL: S26 exclude block rewrite looks fragile again"; failn=$((failn+1)); }
grep -qF 'a zapret problem must never block the mihomo ruleset sync' "$HERE/../assets/sync_mtrickle_mihomo.sh" \
  && { echo "PASS: S26 zapret errors cannot break the ruleset sync"; pass=$((pass+1)); } \
  || { echo "FAIL: S26 a zapret error would abort the sync"; failn=$((failn+1)); }

# v1.20.3: the node filter must reach every VPN slot, must not be appended with duplicates,
# and must never be applied to the AI slot (its subscription is USA-only - a name list tuned
# to another provider emptied it to one pseudo-node when that was done by mistake).
grep -qF 'def apply_filter_all' "$HERE/../assets/geomask-node-scan.sh" \
  && grep -qF 'def group_blocks' "$HERE/../assets/geomask-node-scan.sh" \
  && { echo "PASS: S27 scan writes the filter per group, not per line"; pass=$((pass+1)); } \
  || { echo "FAIL: S27 scan still rewrites the first exclude-filter it finds"; failn=$((failn+1)); }
grep -qF 'if p and p not in seen' "$HERE/../assets/geomask-node-scan.sh" \
  && { echo "PASS: S27 filter alternations are de-duplicated"; pass=$((pass+1)); } \
  || { echo "FAIL: S27 the filter grows duplicated terms each run"; failn=$((failn+1)); }
grep -qF "name_filter_groups='VPN,VPN-noP2P'" "$HERE/../assets/geomask-nodes.conf" \
  && { echo "PASS: S27 AI is excluded from name filtering by default"; pass=$((pass+1)); } \
  || { echo "FAIL: S27 AI could be emptied by the name filter"; failn=$((failn+1)); }

echo ""
echo "== SANDBOX RESULT: pass=$pass fail=$failn =="
[ "$failn" -eq 0 ]
