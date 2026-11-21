#!/bin/bash
# The installer's whole life on a clean, disposable Debian/Ubuntu machine (run as root, it changes
# the machine: use a throwaway VM; tools/vm-test.sh runs it in a local KVM guest):
#   lifecycle.sh fresh   <install.sh>              installed by root, then managed with the app's key
#   lifecycle.sh upgrade <install.sh> <old.sh>     two phones installed with an older installer, then one
#                                                  phone installs again with this one, as an ordinary sudo
#                                                  user with a password
# After every step it checks the rule for the app's management keys: each one belongs to a device that
# exists on the server and runs only the management command. Prints CHECK lines; no secret is printed.
# shellcheck disable=SC2012,SC2015,SC2016  # a test: single quotes are for the guest shell
set -u
MODE=$1; NEW=$2; OLD=${3:-}
say() { echo "CHECK $*"; }
# expect <what> <command...>: a condition the server must meet; every failed one fails the run.
FAILS=0
expect() { local what=$1; shift; if "$@"; then say "ok: $what"; else say "FAIL: $what"; FAILS=$((FAILS + 1)); fi; }
is() { [ "$1" = "$2" ]; }
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release; say "OS $PRETTY_NAME, scenario $MODE"
apt-get -qq update >/dev/null 2>&1; apt-get -qq install -y ufw sudo curl openssh-server >/dev/null 2>&1
systemctl enable --now ssh >/dev/null 2>&1
# the administrator's own rules before IP Browser: SSH, and a website on 443/tcp
ufw allow 22/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw --force enable >/dev/null
BEFORE=$(ufw show added | sort)
# TCP 80 taken by another program: the server offers HOP only (no certificate)
python3 -m http.server 80 --bind 127.0.0.1 >/dev/null 2>&1 &
sleep 1

for k in old other new; do ssh-keygen -q -t ed25519 -N '' -f "/root/$k" -C ip-browser; done
blob() { cut -d' ' -f2 "/root/$1.pub"; }
ADMIN=root; HOME_A=/root
K=$HOME_A/.ssh/authorized_keys
# The rule, checked on the server's own files: app keys without their device, app keys that may run any command.
rule() {
  local f=$1 orphans=0 open=0 line dev
  while IFS= read -r line; do
    case "$line" in *" ip-browser"|*" ip-browser:"*) ;; *) continue ;; esac
    dev=${line##* ip-browser}; dev=${dev#:}
    if [ -z "$dev" ] || [ ! -f "/etc/ip-browser/devices/$dev.hy" ]; then orphans=$((orphans + 1)); fi
    case "$line" in 'restrict,command="/usr/local/sbin/ip-browser-manage --ssh" '*) ;; *) open=$((open + 1)) ;; esac
  done < "$f"
  echo "keys of no device: $orphans, keys that may run any command: $open"
}
# A device's tunnel: its own HOP credentials through the server to an HTTPS echo = the server's exit.
tunnel() {
  local d=$1 seen=""
  cat > /root/hy.yaml <<HY
server: 127.0.0.1:443
auth: $d:$(cat "/etc/ip-browser/devices/$d.hy")
tls:
  sni: $(cat /etc/ip-browser/sni)
  ca: /etc/ip-browser/hy.crt
obfs:
  type: salamander
  salamander:
    password: $(cat /etc/ip-browser/obfs)
socks5:
  listen: 127.0.0.1:10990
HY
  /usr/local/lib/ip-browser/hysteria client --disable-update-check -c /root/hy.yaml >/dev/null 2>&1 &
  local hp=$!
  for _ in $(seq 1 20); do
    seen=$(curl -fsS --max-time 6 --proxy socks5h://127.0.0.1:10990 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n') && [ -n "$seen" ] && break
    sleep 1
  done
  kill $hp 2>/dev/null; rm -f /root/hy.yaml
  [ -n "$seen" ] && [ "$seen" = "$(cat /etc/ip-browser/ip)" ] && echo works || echo "does not work"
}

if [ "$MODE" = upgrade ]; then
  useradd -m -G sudo -s /bin/bash admin1; PW=$(openssl rand -hex 16); echo "admin1:$PW" | chpasswd
  ADMIN=admin1; HOME_A=/home/admin1; K=$HOME_A/.ssh/authorized_keys
  # what the app does: copy the script as the login user, run it as root from that file
  as_app() { # <script> <args...>
    local f; f=$(runuser -u admin1 -- sh -c 'umask 077; f=$(mktemp /tmp/ip-browser-install.XXXXXX) && cat > "$f" && echo "$f"' < "$1"); shift
    runuser -u admin1 -- sudo -k
    printf '%s\n' "$PW" | runuser -u admin1 -- sudo -S -p '' bash "$f" "$@"; local rc=$?
    rm -f "$f"; return $rc
  }
  as_app "$OLD" install --device phone-old --pubkey "$(cat /root/old.pub)" --endpoint 127.0.0.1 > /root/old1.log 2>&1
  as_app "$OLD" install --device phone-other --pubkey "$(cat /root/other.pub)" --endpoint 127.0.0.1 > /root/old2.log 2>&1
  say "older installer: two phones installed, app keys: $(grep -c 'ip-browser' "$K")"
  as_app "$NEW" install --device phone-new --pubkey "$(cat /root/new.pub)" --endpoint 127.0.0.1 \
    --retire-device phone-old --retire-key "$(blob old)" > /root/install.log 2>&1
  RC=$?
else
  bash "$NEW" install --device phone-new --pubkey "$(cat /root/new.pub)" --endpoint 127.0.0.1 > /root/install.log 2>&1
  RC=$?
fi
say "install rc=$RC, warnings: $(grep '^@@warn' /root/install.log | cut -d' ' -f2 | tr '\n' ' ')"
expect "install succeeded" is "$RC" 0
say "after install: $(rule "$K"); this phone's key: $(grep -cF "$(blob new) ip-browser:phone-new" "$K"); its replaced key: $(grep -cF "$(blob old)" "$K")"
expect "every app key belongs to a device and runs one command" is "$(rule "$K")" "keys of no device: 0, keys that may run any command: 0"
expect "this phone's key is there" is "$(grep -cF "$(blob new) ip-browser:phone-new" "$K")" 1
expect "the replaced key is gone" is "$(grep -cF "$(blob old)" "$K")" 0
# the phones dial 127.0.0.1 here and the server leaves from its public address: the cover site serves both
expect "the cover site serves the address phones dial and the exit" grep -q "^https://127.0.0.1, https://$(cat /etc/ip-browser/ip) {" /etc/ip-browser/Caddyfile

systemctl restart ssh; sleep 1
manage() { ssh -o LogLevel=ERROR -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/kh -i /root/new "$ADMIN@127.0.0.1" /usr/local/sbin/ip-browser-manage "$@"; }
r() { grep -E '^@@(result|error)' | head -1 | cut -c3-; }
say "devices: $(manage list-devices | r)"
expect "this phone manages the server" grep -q '^@@result {"devices"' < <(manage list-devices)
say "add a guest: $(manage add-device --device guest | r | cut -c1-40)…; revoke it: $(manage revoke-device --device guest | r)"
say "web front after add/revoke on a HOP-only server: $(systemctl is-active ip-browser-web)/$(systemctl is-enabled ip-browser-web 2>/dev/null)"
say "the app key asks for a shell: $(ssh -o LogLevel=ERROR -o BatchMode=yes -o UserKnownHostsFile=/root/kh -i /root/new "$ADMIN@127.0.0.1" id 2>&1 | head -1)"
expect "the app key gets no shell" is "$(ssh -o LogLevel=ERROR -o BatchMode=yes -o UserKnownHostsFile=/root/kh -i /root/new "$ADMIN@127.0.0.1" id 2>&1 | grep -c 'uid=')" 0

if [ "$MODE" = upgrade ]; then
  say "the other phone (installed with the older version): key $(grep -cF "$(blob other)" "$K"), tunnel $(tunnel phone-other)"
  expect "the older phone's unlinked key is gone" is "$(grep -cF "$(blob other)" "$K")" 0
  expect "the older phone's tunnel still works" is "$(tunnel phone-other)" works
  say "revoke the other phone: $(manage revoke-device --device phone-other | r); its key $(grep -cF "$(blob other)" "$K"), this phone's key $(grep -cF "$(blob new)" "$K"); $(rule "$K")"
  expect "the revoked phone has no key" is "$(grep -cF "$(blob other)" "$K")" 0
  expect "this phone keeps its key" is "$(grep -cF "$(blob new)" "$K")" 1
  say "revoke the last device (this phone): $(manage revoke-device --device phone-new | r | cut -c1-60)"
  say "after the refusal: HOP $(systemctl is-active ip-browser-hop), devices $(manage list-devices | r), this phone's tunnel $(tunnel phone-new)"
  expect "the last device is refused" grep -q 'last_device' < <(manage revoke-device --device phone-new)
  expect "the tunnel still works after the refusal" is "$(tunnel phone-new)" works
else
  manage add-device --device phone-two >/dev/null
  say "this phone revokes itself: $(manage revoke-device --device phone-new | r); its key $(grep -cF "$(blob new)" "$K"); $(rule "$K")"
  expect "a phone that revoked itself has no key" is "$(grep -cF "$(blob new)" "$K")" 0
  say "HOP $(systemctl is-active ip-browser-hop); devices $(bash /usr/local/lib/ip-browser/install.sh list-devices | r); phone-two's tunnel $(tunnel phone-two)"
  expect "the remaining device's tunnel works" is "$(tunnel phone-two)" works
  say "revoke the last device (as root): $(bash /usr/local/lib/ip-browser/install.sh revoke-device --device phone-two | r | cut -c1-60); HOP $(systemctl is-active ip-browser-hop)"
  expect "the last device is refused and HOP stays" is "$(systemctl is-active ip-browser-hop)" active
fi

bash /usr/local/lib/ip-browser/install.sh uninstall > /root/un.log 2>&1
say "uninstall: $(r < /root/un.log)"
AFTER=$(ufw show added | sort)
say "firewall after uninstall identical to before: $([ "$BEFORE" = "$AFTER" ] && echo yes || { echo no:; diff <(echo "$BEFORE") <(echo "$AFTER") | grep '^[<>]' | tr '\n' ' '; })"
expect "the firewall is as before" is "$BEFORE" "$AFTER"
expect "no app key is left" is "$(grep -c 'ip-browser' "$K" 2>/dev/null || true)" 0
expect "nothing of IP Browser is left" is "$(ls -d /etc/ip-browser /usr/local/lib/ip-browser /var/lib/ip-browser /usr/local/sbin/ip-browser-manage /etc/sudoers.d/ip-browser /etc/systemd/system/ip-browser-* 2>/dev/null | wc -l)" 0
say "app keys left: $(grep -c 'ip-browser' "$K" 2>/dev/null || echo 0)"
say "left: sudoers=$(test -e /etc/sudoers.d/ip-browser && echo yes || echo no) manage=$(test -e /usr/local/sbin/ip-browser-manage && echo yes || echo no) etc=$(test -e /etc/ip-browser && echo yes || echo no) lib=$(test -e /usr/local/lib/ip-browser && echo yes || echo no) user=$(getent passwd ipbrowser >/dev/null && echo yes || echo no) units=$(ls /etc/systemd/system/ip-browser-* 2>/dev/null | wc -l) nft=$(nft list table inet ip_browser >/dev/null 2>&1 && echo yes || echo no)"
say "RESULT failed conditions: $FAILS"
[ "$FAILS" -eq 0 ]
