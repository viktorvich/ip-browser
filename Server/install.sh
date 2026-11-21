#!/usr/bin/env bash
# IP Browser server installer. The app copies it to the server and runs it as root (directly
# or through sudo):
#   bash install.sh install --device <name> --pubkey '<ssh-ed25519 ...>' [--endpoint <address>]
# and keeps a root-owned copy for later management through ONE command, which is all the
# app's own SSH key may run (a forced command; a sudo user gets a sudoers rule for it alone):
#   /usr/local/sbin/ip-browser-manage add-device --device <name> | list-devices | revoke-device --device <name> | status | uninstall
# A reinstall from the same phone names the device it replaces: --retire-device <its old name>.
# By hand from a console: curl -fsSL <url>/install.sh | sudo bash -s -- install
# Debian 11+ / Ubuntu 20.04+, x86_64 or aarch64, systemd. Idempotent: running install
# again keeps the server's keys and only adds the device.
#
# What it builds (one server = one exit IPv4):
#   HOP   = Hysteria 2 (apernet, MIT) + Salamander obfuscation on UDP 443, UDP 20000-29999
#           hop to it; self-signed certificate, pinned by the client.
#   XHTTP = VLESS Encryption (ML-KEM-768) over XHTTP (Xray-core, MPL-2.0) behind a real
#           website on TCP 443 (Caddy, Apache-2.0, Let's Encrypt IP certificate). Optional:
#           if the certificate cannot be issued, the server offers HOP only.
# Both exit through IPv4 only; private, reserved and local destinations and SMTP are refused.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

VERB=${1:-install}; [ $# -gt 0 ] && shift
DEVICE=""; PUBKEY=""; ENDPOINT=""; RETIRE_DEVICES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE=${2:-}; shift 2 ;;
    --pubkey) PUBKEY=${2:-}; shift 2 ;;
    --endpoint) ENDPOINT=${2:-}; shift 2 ;;
    --retire-device) RETIRE_DEVICES+=("${2:-}"); shift 2 ;;
    --retire-key) shift 2 ;;   # the replaced key goes with its device (reconcile_keys)
    *) shift ;;
  esac
done

ETC=/etc/ip-browser; LIB=/usr/local/lib/ip-browser; SITE=/var/lib/ip-browser/site
MANAGE=/usr/local/sbin/ip-browser-manage; SUDOERS=/etc/sudoers.d/ip-browser
HY_VER=v2.14.0; XRAY_VER=v26.11.9; CADDY_VER=2.11.9
HOP_RANGE=20000-29999
TOTAL=9
step()   { echo "@@step $1 $TOTAL $2"; [ -t 1 ] || true; }
# fail <code> <detail>: the app shows its own words for <code>; a person at a console reads the detail.
fail()   { local code=$1; shift; echo "@@error $code $*"; echo "ERROR [$code]: $*" >&2; exit 1; }
warn()   { echo "@@warn $*"; }
result() { echo "@@result $1"; }
rand()   { head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-"$1"; }
jstr()   { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
valid_name() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,31}$'; }

[ "$(id -u)" = 0 ] || fail not_root "run as root or through sudo"

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) fail cpu "unsupported CPU $(uname -m) (x86_64 or aarch64 needed)" ;;
  esac
}

fetch() { # url sha256 destination
  local tmp; tmp=$(mktemp)
  curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$1" || { rm -f "$tmp"; fail download "$1"; }
  echo "$2  $tmp" | sha256sum -c --quiet - || { rm -f "$tmp"; fail checksum "$1"; }
  mv "$tmp" "$3"
}

public_ip() {
  local ip
  for u in https://checkip.amazonaws.com https://api.ipify.org https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d ' \r\n') || true
    if printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then echo "$ip"; return 0; fi
  done
  fail no_ipv4 "no public IPv4 address answered (checkip.amazonaws.com, api.ipify.org, icanhazip.com)"
}

# A hard reset during the image's own first updates leaves dpkg «interrupted», sometimes with
# truncated journal files in /var/lib/dpkg/updates that dpkg cannot parse. Both are repaired
# the standard way, so a person with a fresh server never has to type dpkg commands.
repair_dpkg() {
  local out
  out=$(dpkg --configure -a 2>&1) && return 0
  if printf '%s' "$out" | grep -q "/var/lib/dpkg/updates/"; then
    echo "@@warn dpkg_repaired truncated dpkg journal removed"
    rm -f /var/lib/dpkg/updates/*
    dpkg --configure -a >/dev/null 2>&1 || true
  fi
}

install_packages() {
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    debian:*|ubuntu:*|*:*debian*) ;;
    *) fail os "${PRETTY_NAME:-unknown}" ;;
  esac
  command -v systemctl >/dev/null || fail os "no systemd"
  [ "$(df -Pm / | awk 'NR==2{print $4}')" -ge 300 ] || fail disk "$(df -Ph / | awk 'NR==2{print $4}') free on /"
  # A fresh VPS often runs unattended-upgrades for the first minutes: wait for dpkg instead of failing.
  local waited=0
  dpkg_locked() {
    if command -v fuser >/dev/null; then fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1
    else pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null || pgrep -f unattended-upgr >/dev/null; fi
  }
  while dpkg_locked; do
    [ $waited -eq 0 ] && echo "@@step 1 $TOTAL Waiting for the system's own updates to finish"
    [ $waited -ge 600 ] && fail apt_busy "dpkg is locked for 10 minutes by another installer"
    sleep 5; waited=$((waited + 5))
  done
  # An interrupted dpkg run (a reboot during the image's own first updates) is repaired,
  # and apt is retried once, instead of stopping a person who has a perfectly good server.
  repair_dpkg
  local out
  for _ in 1 2; do
    if out=$(apt-get update -qq 2>&1) && out=$(apt-get install -y -qq curl ca-certificates openssl nftables unzip psmisc iproute2 qrencode 2>&1); then
      out=""; break
    fi
    repair_dpkg
    apt-get -f install -y -qq >/dev/null 2>&1 || true
    sleep 5
  done
  [ -z "$out" ] || fail apt "$(printf '%s' "$out" | grep -E '^(E|W):' | tail -2 | tr '\n' ' ')"
  curl -fsS --max-time 15 -o /dev/null https://github.com 2>/dev/null || fail no_internet "the server cannot open https://github.com"
  # UDP 443 must be ours; TCP 443/80 only matter for the XHTTP website front.
  local udp; udp=$(ss -Hulnp 'sport = :443' 2>/dev/null | grep -v '"hysteria"' | head -1 || true)
  [ -z "$udp" ] || fail port_busy "UDP 443 is used by: $(printf '%s' "$udp" | grep -o 'users:(("[^"]*' | cut -d'"' -f2)"
  local tcp; tcp=$(ss -Htlnp '( sport = :443 or sport = :80 )' 2>/dev/null | grep -v '"caddy"' | head -1 || true)
  if [ -n "$tcp" ]; then
    warn web_ports_busy "TCP 80/443 used by: $(printf '%s' "$tcp" | grep -o 'users:(("[^"]*' | cut -d'"' -f2) - XHTTP is skipped"
    touch /tmp/ip-browser-no-web
  else rm -f /tmp/ip-browser-no-web; fi
}

install_binaries() {
  local a; a=$(arch)
  mkdir -p "$LIB"
  if [ "$a" = amd64 ]; then
    HY_SHA=fc25edff9948708cb00a4ff01f3bccde677660aca050133bb1ad46c6860362d2
    XR_ZIP=Xray-linux-64.zip; XR_SHA=b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82
    CA_SHA=5b8cb7faf8726a2028ad96a66e54e6e81e8f361bc6175e5d22bbd997cc5177fb
  else
    HY_SHA=e7c52241299fe85aba11e9d36e85d8d88ddbb5799ac0e33d272219d20e313bab
    XR_ZIP=Xray-linux-arm64-v8a.zip; XR_SHA=64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be
    CA_SHA=5e377cff994fc9362a6fcf695c53f226cfca3a3ef85bd3a3687cf252d6310165
  fi
  if [ "$(cat "$LIB/versions" 2>/dev/null)" != "$HY_VER $XRAY_VER $CADDY_VER" ]; then
    fetch "https://github.com/apernet/hysteria/releases/download/app/$HY_VER/hysteria-linux-$a" "$HY_SHA" "$LIB/hysteria"
    fetch "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VER/$XR_ZIP" "$XR_SHA" "$LIB/xray.zip"
    unzip -o -q "$LIB/xray.zip" xray -d "$LIB" && rm -f "$LIB/xray.zip"
    fetch "https://github.com/caddyserver/caddy/releases/download/v$CADDY_VER/caddy_${CADDY_VER}_linux_$a.tar.gz" "$CA_SHA" "$LIB/caddy.tgz"
    tar -xzf "$LIB/caddy.tgz" -C "$LIB" caddy && rm -f "$LIB/caddy.tgz"
    chmod 755 "$LIB/hysteria" "$LIB/xray" "$LIB/caddy"
    echo "$HY_VER $XRAY_VER $CADDY_VER" > "$LIB/versions"
  fi
}

ensure_secrets() {
  mkdir -p "$ETC/devices" "$SITE" /var/lib/ip-browser/caddy
  getent passwd ipbrowser >/dev/null || useradd --system --home /var/lib/ip-browser --shell /usr/sbin/nologin ipbrowser
  [ -s "$ETC/ip" ] || public_ip > "$ETC/ip"
  # The address clients dial (what the app reached over SSH) can differ from the exit
  # address websites see (NAT, a provider's floating IP). Default: the exit address.
  if [ -n "$ENDPOINT" ]; then
    printf '%s' "$ENDPOINT" | grep -Eq '^[A-Za-z0-9.-]{1,253}$' || fail endpoint "$ENDPOINT"
    echo "$ENDPOINT" > "$ETC/endpoint"
  fi
  [ -s "$ETC/endpoint" ] || cp "$ETC/ip" "$ETC/endpoint"
  [ -s "$ETC/obfs" ] || rand 32 > "$ETC/obfs"
  [ -s "$ETC/path" ] || echo "/$(rand 16)" > "$ETC/path"
  [ -s "$ETC/sni" ] || echo "edge-$(rand 8).net" > "$ETC/sni"
  if [ ! -s "$ETC/hy.crt" ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=$(cat "$ETC/sni")" -addext "subjectAltName=DNS:$(cat "$ETC/sni")" \
      -keyout "$ETC/hy.key" -out "$ETC/hy.crt" >/dev/null 2>&1
  fi
  if [ ! -s "$ETC/vlessenc" ]; then
    # ML-KEM-768 pair (post-quantum authentication); the server keeps "decryption".
    "$LIB/xray" vlessenc | awk '/ML-KEM-768/{pq=1} pq && /"decryption"/{gsub(/"/,"",$2); d=$2} pq && /"encryption"/{gsub(/"/,"",$2); e=$2} END{print d; print e}' > "$ETC/vlessenc"
    [ "$(wc -l < "$ETC/vlessenc")" = 2 ] || fail core "xray vlessenc gave no keys"
  fi
  fix_permissions
}

# Everything root reads or runs (the nftables rules, the device secrets, this script) belongs to
# root; the services' user only READS its own configuration and writes only Caddy's storage.
fix_permissions() {
  chown root:ipbrowser "$ETC"; chmod 750 "$ETC"
  chown -R root:root "$ETC/devices"; chmod 700 "$ETC/devices"
  find "$ETC" -maxdepth 1 -type f -exec chown root:root {} + -exec chmod 600 {} +
  for f in hysteria.yaml hy.crt hy.key xray.json Caddyfile; do
    [ -e "$ETC/$f" ] && { chown root:ipbrowser "$ETC/$f"; chmod 640 "$ETC/$f"; }
  done
  [ -e "$ETC/hop.nft" ] && chmod 644 "$ETC/hop.nft"
  chown root:root /var/lib/ip-browser "$SITE"; chmod 755 /var/lib/ip-browser "$SITE"
  find "$SITE" -type f -exec chown root:root {} + -exec chmod 644 {} +
  chown -R ipbrowser:ipbrowser /var/lib/ip-browser/caddy; chmod 700 /var/lib/ip-browser/caddy
}

pin() { openssl x509 -in "$ETC/hy.crt" -outform der | sha256sum | cut -c1-64; }

add_device_files() { # name
  local d=$1
  valid_name "$d" || fail device "$DEVICE"
  [ -s "$ETC/devices/$d.hy" ] || rand 32 > "$ETC/devices/$d.hy"
  [ -s "$ETC/devices/$d.id" ] || cat /proc/sys/kernel/random/uuid > "$ETC/devices/$d.id"
  chown root:root "$ETC/devices/$d".*; chmod 600 "$ETC/devices/$d".*
}

PRIVATE='"0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.0.2.0/24","192.168.0.0/16","198.18.0.0/15","198.51.100.0/24","203.0.113.0/24","224.0.0.0/4","240.0.0.0/4"'

write_configs() {
  local users="" clients="" d
  for f in "$ETC"/devices/*.hy; do
    [ -e "$f" ] || continue
    d=$(basename "$f" .hy)
    users="$users    $d: $(cat "$f")"$'\n'
    clients="$clients{\"id\":\"$(cat "$ETC/devices/$d.id")\",\"email\":\"$d\"},"
  done
  clients=${clients%,}
  cat > "$ETC/hysteria.yaml" <<EOF
listen: :443
tls:
  cert: $ETC/hy.crt
  key: $ETC/hy.key
auth:
  type: userpass
  userpass:
$users
obfs:
  type: salamander
  salamander:
    password: $(cat "$ETC/obfs")
resolver:
  type: https
  https:
    addr: 1.1.1.1:443
    sni: cloudflare-dns.com
    timeout: 6s
outbounds:
  - name: v4
    type: direct
    direct:
      mode: 4
acl:
  inline:
$(printf '%s' "$PRIVATE" | tr -d '"' | tr ',' '\n' | sed 's/^/    - reject(/; s/$/)/')
    - reject(all, tcp/25)
    - v4(all)
EOF
  local dec; dec=$(sed -n 1p "$ETC/vlessenc")
  cat > "$ETC/xray.json" <<EOF
{
  "log": {"loglevel": "warning", "access": "none"},
  "inbounds": [{
    "listen": "127.0.0.1", "port": 10443, "protocol": "vless",
    "settings": {"clients": [$clients], "decryption": "$dec"},
    "streamSettings": {"network": "xhttp", "xhttpSettings": {"path": "$(cat "$ETC/path")", "mode": "auto"}}
  }],
  "outbounds": [{"tag": "v4", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
                {"tag": "block", "protocol": "blackhole"}],
  "dns": {"servers": ["https+local://1.1.1.1/dns-query"], "queryStrategy": "UseIPv4"},
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
    {"type": "field", "ip": [$PRIVATE], "outboundTag": "block"},
    {"type": "field", "port": "25", "outboundTag": "block"}]}
}
EOF
  # The cover site answers on every address the phones dial (the endpoint typed in the app) and on the exit
  # address, each with its own certificate: a request is routed by its Host, and a server reached through a
  # second address (or a name) must serve that address too (21.11.2026: XHTTP to .88 was dropped by a site for .87).
  local ip ep sites plain
  ip=$(cat "$ETC/ip"); ep=$(cat "$ETC/endpoint" 2>/dev/null || echo "$ip")
  if [ "$ep" = "$ip" ]; then sites="https://$ip"; plain="http://$ip"
  else sites="https://$ep, https://$ip"; plain="http://$ep, http://$ip"; fi
  cat > "$ETC/Caddyfile" <<EOF
{
	admin off
	default_sni $ep
	storage file_system /var/lib/ip-browser/caddy
	servers {
		protocols h1 h2
	}
}
$sites {
	tls {
		issuer acme {
			profile shortlived
		}
	}
	handle $(cat "$ETC/path")* {
		reverse_proxy 127.0.0.1:10443 {
			flush_interval -1
			transport http {
				versions h2c
			}
		}
	}
	handle {
		root * $SITE
		file_server
	}
}
$plain {
	redir https://{host}{uri} 308
}
EOF
  [ -s "$SITE/index.html" ] || cat > "$SITE/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Field notes</title>
<style>body{font:17px/1.6 Georgia,serif;max-width:640px;margin:48px auto;padding:0 20px;color:#222}h1{font-weight:normal}</style></head>
<body><h1>Field notes</h1><p>Short notes on gardening, small repairs and long walks. New entries appear when the weather allows.</p>
<h2>Tomatoes in a cold spring</h2><p>Start indoors, harden off for a week, and do not rush the soil.</p></body></html>
EOF
  fix_permissions
}

write_units() {
  cat > /etc/systemd/system/ip-browser-hop.service <<EOF
[Unit]
Description=IP Browser HOP (Hysteria 2 + Salamander)
After=network-online.target
Wants=network-online.target
[Service]
User=ipbrowser
ExecStart=$LIB/hysteria server --disable-update-check -c $ETC/hysteria.yaml
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/ip-browser-xray.service <<EOF
[Unit]
Description=IP Browser XHTTP core (Xray)
After=network-online.target
[Service]
User=ipbrowser
ExecStart=$LIB/xray run -c $ETC/xray.json
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/ip-browser-web.service <<EOF
[Unit]
Description=IP Browser website front (Caddy)
After=network-online.target ip-browser-xray.service
[Service]
User=ipbrowser
Environment=XDG_DATA_HOME=/var/lib/ip-browser XDG_CONFIG_HOME=/var/lib/ip-browser
ExecStart=$LIB/caddy run --config $ETC/Caddyfile --adapter caddyfile
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/ip-browser/caddy
ProtectHome=yes
PrivateTmp=yes
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_firewall() {
  cat > "$ETC/hop.nft" <<EOF
table inet ip_browser {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		udp dport $HOP_RANGE redirect to :443
	}
}
EOF
  cat > /etc/systemd/system/ip-browser-hop-ports.service <<EOF
[Unit]
Description=IP Browser HOP port range
After=nftables.service network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'nft delete table inet ip_browser 2>/dev/null; nft -f $ETC/hop.nft'
ExecStop=/bin/sh -c 'nft delete table inet ip_browser 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ip-browser-hop-ports.service >/dev/null 2>&1 || fail firewall "nftables rule for the hop range was refused"
  systemctl restart ip-browser-hop-ports.service
  fix_permissions
  open_port 443/udp; open_port 20000:29999/udp
  if [ ! -f /tmp/ip-browser-no-web ]; then open_port 443/tcp; open_port 80/tcp; fi
}

# Firewall openings are recorded only if THIS installer added them (a rule that was already
# there is the administrator's): uninstall and HOP-only remove exactly what was added.
open_port() { # 443/udp | 20000:29999/udp | 443/tcp | 80/tcp
  local r=$1
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ! ufw show added 2>/dev/null | grep -qx "ufw allow $r"; then
      ufw allow "$r" >/dev/null && record "$ETC/added.ufw" "$r"
    fi
  fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    local f; f=$(printf '%s' "$r" | tr ':' '-')
    if ! firewall-cmd -q --permanent --query-port="$f"; then
      firewall-cmd -q --permanent --add-port="$f" && firewall-cmd -q --reload && record "$ETC/added.firewalld" "$f"
    fi
  fi
}
close_port() { # remove one opening this installer added
  local r=$1 f; f=$(printf '%s' "$r" | tr ':' '-')
  if grep -qx "$r" "$ETC/added.ufw" 2>/dev/null; then
    if command -v ufw >/dev/null; then ufw --force delete allow "$r" >/dev/null 2>&1 || true; fi
    sed -i "\\#^$r\$#d" "$ETC/added.ufw"
  fi
  if grep -qx "$f" "$ETC/added.firewalld" 2>/dev/null; then
    if command -v firewall-cmd >/dev/null && firewall-cmd -q --permanent --remove-port="$f" 2>/dev/null; then
      firewall-cmd -q --reload 2>/dev/null || true
    fi
    sed -i "\\#^$f\$#d" "$ETC/added.firewalld"
  fi
}
record() { touch "$1"; chmod 600 "$1"; grep -qxF "$2" "$1" || echo "$2" >> "$1"; }

# The homes whose authorized_keys may hold the app's keys: root, the user who ran sudo, and
# the administrator recorded at install.
admin_homes() {
  local u
  for u in root "${SUDO_USER:-root}" "$(cat "$ETC/admin" 2>/dev/null || echo root)"; do
    getent passwd "$u" | cut -d: -f6
  done | sort -u
}

# The app's management keys follow ONE rule, whichever version of this installer added them: a key
# stays only while the device it was given with exists on this server, and it runs only the management
# command. A key is the app's by its comment: «ip-browser:<device>», or «ip-browser» (versions before
# 21.11.2026 named no device - such a key belongs to no device and goes: its phone keeps the tunnel and
# installs again to manage the server). Run after every change of devices and keys; $ETC/added.keys
# is what it leaves (<authorized_keys file> <blob> <device>).
reconcile_keys() {
  [ -d "$ETC/devices" ] && [ -x "$MANAGE" ] || return 0
  local h f line dev blob gone=0
  : > "$ETC/added.keys.new"
  for h in $(admin_homes); do
    f=$h/.ssh/authorized_keys
    [ -f "$f" ] || continue
    : > "$f.ipb"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *" ip-browser"|*" ip-browser:"*)
          dev=${line##* ip-browser}; dev=${dev#:}
          blob=$(printf '%s\n' "$line" | grep -o 'ssh-ed25519 [A-Za-z0-9+/=]*' | head -1 | cut -d' ' -f2 || true)
          if [ -n "$dev" ] && valid_name "$dev" && [ -f "$ETC/devices/$dev.hy" ] && [ -n "$blob" ]; then
            echo "restrict,command=\"$MANAGE --ssh\" ssh-ed25519 $blob ip-browser:$dev" >> "$f.ipb"
            echo "$f $blob $dev" >> "$ETC/added.keys.new"
          else
            gone=$((gone + 1))
          fi ;;
        *) printf '%s\n' "$line" >> "$f.ipb" ;;
      esac
    done < "$f"
    if cmp -s "$f" "$f.ipb"; then rm -f "$f.ipb"; else cat "$f.ipb" > "$f"; rm -f "$f.ipb"; fi
  done
  mv -f "$ETC/added.keys.new" "$ETC/added.keys"; chmod 600 "$ETC/added.keys"
  if [ "$gone" -gt 0 ]; then warn legacy_keys "$gone management key(s) of no device on this server were removed"; fi
}

# Servers installed before 21.11.2026 did not write their firewall openings down. Once: the openings
# certainly made by the old installer are recorded as its own; an opening that may be the
# administrator's is kept and named at uninstall.
migrate_legacy() {
  [ -f "$ETC/ip" ] || return 0
  [ "$(cat "$ETC/schema" 2>/dev/null || echo 1)" -ge 2 ] && return 0
  local f
  if [ ! -f "$ETC/added.ufw" ] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    # The old installer allowed 443/udp, the hop range, 443/tcp and 80/tcp, in this order: a TCP
    # rule listed before them was there already (the administrator's).
    local rules first n r
    rules=$(ufw show added 2>/dev/null | sed -n 's/^ufw allow //p')
    first=$(printf '%s\n' "$rules" | grep -nx -e 443/udp -e 20000:29999/udp | head -1 | cut -d: -f1 || true)
    for r in 443/udp 20000:29999/udp 443/tcp 80/tcp; do
      n=$(printf '%s\n' "$rules" | grep -nx "$r" | head -1 | cut -d: -f1 || true)
      [ -n "$n" ] || continue
      if [ "${r#*/}" = udp ] || { [ -n "$first" ] && [ "$n" -gt "$first" ]; }; then record "$ETC/added.ufw" "$r"
      else record "$ETC/kept.ufw" "$r"; fi
    done
  fi
  if [ ! -f "$ETC/added.firewalld" ] && command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for f in 443/udp 20000-29999/udp; do
      if firewall-cmd -q --permanent --query-port="$f"; then record "$ETC/added.firewalld" "$f"; fi
    done
    for f in 443/tcp 80/tcp; do   # no order to tell by
      if firewall-cmd -q --permanent --query-port="$f"; then record "$ETC/kept.firewalld" "$f"; fi
    done
  fi
  echo 2 > "$ETC/schema"
}

# A reinstall from the same phone replaces its own earlier device (the app names it), so the server
# does not keep a second, forgotten access for that phone; its key goes with it (reconcile_keys).
retire_previous() {
  local d changed=""
  for d in ${RETIRE_DEVICES[@]+"${RETIRE_DEVICES[@]}"}; do
    if valid_name "$d" && [ "$d" != "$DEVICE" ] && [ -f "$ETC/devices/$d.hy" ]; then
      rm -f "$ETC/devices/$d".*; changed=1
    fi
  done
  if [ -n "$changed" ]; then write_configs; restart_all; fi
}

restart_all() {
  systemctl enable ip-browser-hop.service ip-browser-xray.service >/dev/null 2>&1
  systemctl restart ip-browser-hop.service ip-browser-xray.service
  # The website front runs only while it can serve (an install before its certificate step, or
  # XHTTP proven): a HOP-only server never gets Caddy back by adding or retiring a device.
  if [ -f "$ETC/xhttp-ok" ] || { [ "$VERB" = install ] && [ -z "${WEB_DECIDED:-}" ]; }; then
    systemctl enable ip-browser-web.service >/dev/null 2>&1
    systemctl restart ip-browser-web.service || true
  fi
  sleep 2
  systemctl is-active --quiet ip-browser-hop.service || fail hop_start "$(journalctl -u ip-browser-hop -n 3 --no-pager -o cat | tr '\n' ' ')"
  systemctl is-active --quiet ip-browser-xray.service || fail core "$(journalctl -u ip-browser-xray -n 3 --no-pager -o cat | tr '\n' ' ')"
}

xhttp_ready() { # a real, publicly trusted certificate is served on the address the phones dial
  local ep; ep=$(cat "$ETC/endpoint" 2>/dev/null || cat "$ETC/ip")
  for _ in $(seq 1 "${1:-45}"); do
    curl -fsS --max-time 4 -o /dev/null "https://$ep/" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

links_for() { # device -> JSON array of share links
  local d=$1 ip ep pass id enc path sni pinv
  ip=$(cat "$ETC/ip"); ep=$(cat "$ETC/endpoint" 2>/dev/null || cat "$ETC/ip"); pass=$(cat "$ETC/devices/$d.hy"); id=$(cat "$ETC/devices/$d.id")
  enc=$(sed -n 2p "$ETC/vlessenc"); path=$(cat "$ETC/path"); sni=$(cat "$ETC/sni"); pinv=$(pin)
  local hop xh out
  hop="hy2://$d:$pass@$ep:443,$HOP_RANGE/?sni=$sni&obfs=salamander&obfs-password=$(cat "$ETC/obfs")&pcs=$pinv#HOP"
  out="[$(jstr "$hop")"
  if [ -f "$ETC/xhttp-ok" ]; then
    # the certificate is checked for the address the phone dials (the site has one for it)
    xh="vless://$id@$ep:443?encryption=$enc&security=tls&type=xhttp&path=$(printf '%s' "$path" | sed 's#/#%2F#g')&mode=auto&alpn=h2&fp=chrome#XHTTP"
    out="$out,$(jstr "$xh")"
  fi
  echo "$out]"
}

# For a person who ran this in the provider's web console (SSH from their network was blocked):
# one ipbrowser:// key to paste into IP Browser, and the same as a QR code to scan.
print_key() {
  local d=$1 links b64 name key
  links=$(links_for "$d" | sed 's/^\[//; s/\]$//; s/","/\n/g; s/^"//; s/"$//')
  b64=$(printf '%s' "$links" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  name=$(hostname | tr -cd 'A-Za-z0-9.-' | cut -c1-30)
  key="ipbrowser://add?n=$name&ip=$(cat "$ETC/ip")&l=$b64"
  echo
  echo "=== IP Browser access key for device '$d' ==="
  echo "In IP Browser: Servers -> Add by key or QR -> paste this line or scan the code."
  echo
  echo "$key"
  echo
  command -v qrencode >/dev/null && qrencode -t ansiutf8 -m 1 "$key"
  echo "Keep it private: anyone with this key uses your server."
}

# The app's management: a root-owned copy of this script behind ONE command. The app's SSH key
# may run only that command (forced command), and a sudo user may run only that command as
# root without a password - never a general root shell.
install_manager() {
  [ -f "$0" ] && grep -q 'IP Browser server installer' "$0" 2>/dev/null || return 0
  install -o root -g root -m 0755 "$0" "$LIB/install.sh.new" && mv -f "$LIB/install.sh.new" "$LIB/install.sh"
  cat > "$MANAGE.new" <<'MANAGER'
#!/bin/sh
# IP Browser: the only commands the app's management key runs (installed by install.sh).
set -eu
set -f
if [ "${1:-}" = "--ssh" ]; then
  # forced command: the requested line is in SSH_ORIGINAL_COMMAND (split on spaces, checked below)
  # shellcheck disable=SC2086
  set -- $(printf '%s' "${SSH_ORIGINAL_COMMAND:-}" | tr -d "'\"")
  case "${1:-}" in ip-browser-manage|/usr/local/sbin/ip-browser-manage) shift ;; true) exit 0 ;; esac
fi
case "${1:-}" in
  list-devices|status|uninstall) [ $# -eq 1 ] || { echo "@@error verb arguments"; exit 2; } ;;
  add-device|revoke-device)
    [ $# -eq 3 ] && [ "$2" = "--device" ] && printf '%s' "$3" | grep -Eq '^[a-z0-9][a-z0-9-]{0,31}$' || { echo "@@error device $*"; exit 2; } ;;
  *) echo "@@error verb ${1:-none}"; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || exec sudo -n /usr/local/sbin/ip-browser-manage "$@"
exec /bin/bash /usr/local/lib/ip-browser/install.sh "$@"
MANAGER
  chown root:root "$MANAGE.new"; chmod 755 "$MANAGE.new"; mv -f "$MANAGE.new" "$MANAGE"
  local admin=${SUDO_USER:-root}
  echo "$admin" > "$ETC/admin"; chmod 600 "$ETC/admin"
  if [ "$admin" != root ] && printf '%s' "$admin" | grep -Eq '^[a-z_][a-z0-9_.-]{0,31}$' && [ -d /etc/sudoers.d ]; then
    printf '# IP Browser: the app manages this server through one command only\n%s ALL=(root) NOPASSWD: %s\n' "$admin" "$MANAGE" > "$SUDOERS.new"
    chmod 440 "$SUDOERS.new"
    if visudo -cf "$SUDOERS.new" >/dev/null 2>&1; then mv -f "$SUDOERS.new" "$SUDOERS"
    else rm -f "$SUDOERS.new"; warn sudoers "visudo refused the rule - devices are managed by password only"; fi
  fi
}

authorize_key() {
  [ -n "$PUBKEY" ] || return 0
  printf '%s' "$PUBKEY" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$' || fail key "management key is not ssh-ed25519"
  local admin=${SUDO_USER:-root} home blob f
  home=$(getent passwd "$admin" | cut -d: -f6); [ -n "$home" ] || home=/root
  blob=$(printf '%s' "$PUBKEY" | cut -d' ' -f2)
  f=$home/.ssh/authorized_keys
  mkdir -p "$home/.ssh"; chmod 700 "$home/.ssh"
  touch "$f"; chmod 600 "$f"
  # The key belongs to the device it was given with (reconcile_keys keeps it while that device exists).
  grep -vF " $blob" "$f" > "$f.ipb" || true
  if [ -x "$MANAGE" ]; then echo "restrict,command=\"$MANAGE --ssh\" ssh-ed25519 $blob ip-browser:$DEVICE" >> "$f.ipb"
  else echo "ssh-ed25519 $blob ip-browser:$DEVICE" >> "$f.ipb"; fi
  cat "$f.ipb" > "$f"; rm -f "$f.ipb"
  chown -R "$admin": "$home/.ssh" 2>/dev/null || true
}

# Every management verb first brings an older server's records up to date, and keys follow devices.
if [ "$VERB" != install ] && [ "$VERB" != uninstall ]; then migrate_legacy; reconcile_keys; fi

case "$VERB" in
  install)
    [ -n "$DEVICE" ] || DEVICE="phone-$(rand 4)"
    step 1 "Checking the server"; install_packages
    step 2 "Downloading Hysteria $HY_VER, Xray $XRAY_VER, Caddy $CADDY_VER (checksums pinned)"; install_binaries
    step 3 "Creating keys"; ensure_secrets
    step 4 "Adding this device"; add_device_files "$DEVICE"
    step 5 "Writing the configuration"; write_configs; write_units
    step 6 "Opening UDP 443 and the hop range"; write_firewall
    step 7 "Starting the tunnel"; restart_all
    step 8 "Getting a certificate for the website front (up to 60 s)"
    if [ ! -f /tmp/ip-browser-no-web ] && xhttp_ready 30; then touch "$ETC/xhttp-ok"
    else rm -f "$ETC/xhttp-ok"; systemctl disable --now ip-browser-web >/dev/null 2>&1 || true
      close_port 443/tcp; close_port 80/tcp
      [ -f /tmp/ip-browser-no-web ] || warn no_certificate "Let's Encrypt gave no certificate for $(cat "$ETC/endpoint") (TCP 80 closed by the provider or NAT) - XHTTP is skipped"; fi
    WEB_DECIDED=1
    install_manager
    authorize_key
    migrate_legacy
    retire_previous
    reconcile_keys
    step 9 "Done"
    result "{\"ip\":$(jstr "$(cat "$ETC/ip")"),\"device\":$(jstr "$DEVICE"),\"xhttp\":$([ -f "$ETC/xhttp-ok" ] && echo true || echo false),\"links\":$(links_for "$DEVICE")}"
    if [ -z "$PUBKEY" ]; then print_key "$DEVICE"; fi
    ;;
  add-device)
    [ -n "$DEVICE" ] || fail device "--device required"
    add_device_files "$DEVICE"; write_configs; restart_all
    result "{\"ip\":$(jstr "$(cat "$ETC/ip")"),\"device\":$(jstr "$DEVICE"),\"links\":$(links_for "$DEVICE")}"
    ;;
  list-devices)
    list=""; for f in "$ETC"/devices/*.hy; do [ -e "$f" ] && list="$list$(jstr "$(basename "$f" .hy)"),"; done
    result "{\"devices\":[${list%,}]}"
    ;;
  revoke-device)
    valid_name "$DEVICE" || fail device "$DEVICE"
    [ -f "$ETC/devices/$DEVICE.hy" ] || fail no_device "$DEVICE"
    count=0; for f in "$ETC"/devices/*.hy; do if [ -e "$f" ]; then count=$((count + 1)); fi; done
    # Without any device the tunnel has no user and cannot run: removing the last one is uninstall.
    [ "$count" -gt 1 ] || fail last_device "$DEVICE is the only device; to remove everything run: sudo $MANAGE uninstall"
    rm -f "$ETC/devices/$DEVICE".*; reconcile_keys; write_configs; restart_all
    result "{\"revoked\":$(jstr "$DEVICE")}"
    ;;
  status)
    result "{\"ip\":$(jstr "$(cat "$ETC/ip" 2>/dev/null)"),\"hop\":\"$(systemctl is-active ip-browser-hop)\",\"xray\":\"$(systemctl is-active ip-browser-xray)\",\"web\":\"$(systemctl is-active ip-browser-web)\",\"versions\":$(jstr "$(cat "$LIB/versions" 2>/dev/null)")}"
    ;;
  uninstall)
    homes=$(admin_homes)
    kept=""
    while read -r r; do kept="$kept$(jstr "ufw allow $r"),"; done < <(cat "$ETC/kept.ufw" 2>/dev/null)
    while read -r r; do kept="$kept$(jstr "firewall-cmd --add-port=$r"),"; done < <(cat "$ETC/kept.firewalld" 2>/dev/null)
    systemctl disable --now ip-browser-hop ip-browser-xray ip-browser-web ip-browser-hop-ports >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ip-browser-*.service; systemctl daemon-reload
    nft delete table inet ip_browser 2>/dev/null || true
    # exactly the firewall openings and management keys this installer added
    while read -r r; do close_port "$r"; done < <(cat "$ETC/added.ufw" 2>/dev/null)
    while read -r r; do close_port "$(printf '%s' "$r" | tr '-' ':')"; done < <(cat "$ETC/added.firewalld" 2>/dev/null)
    # every key of the app carries the comment «ip-browser[:<device>]»
    for h in $homes; do
      if [ -f "$h/.ssh/authorized_keys" ]; then sed -i -e '/ ip-browser$/d' -e '/ ip-browser:[a-z0-9-]*$/d' "$h/.ssh/authorized_keys"; fi
    done
    rm -f "$SUDOERS" "$MANAGE"
    rm -rf "$ETC" "$LIB" /var/lib/ip-browser
    userdel ipbrowser 2>/dev/null || true
    if [ -n "$kept" ]; then
      echo "Left as they were (they may be yours, remove them if not): $(echo "${kept%,}" | tr -d '"' | sed 's/,/; /g')"
    fi
    result "{\"uninstalled\":true,\"kept\":[${kept%,}]}"
    ;;
  *) fail verb "$VERB" ;;
esac
