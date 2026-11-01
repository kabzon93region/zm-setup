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
