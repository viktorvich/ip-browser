#!/bin/bash
# Runs Server/test/lifecycle.sh in a throwaway local KVM guest and prints its CHECK lines.
#   tools/vm-test.sh <cloud-image.qcow2> fresh
#   tools/vm-test.sh <cloud-image.qcow2> upgrade <older install.sh>
# The image is a Debian or Ubuntu cloud image (e.g. debian-13-genericcloud-amd64.qcow2 from
# cloud.debian.org; check its SHA512). The disk is used as a snapshot: nothing is written to it.
# Needs qemu-system-x86_64 with KVM and python3. QEMU=<binary> and QEMU_ARGS=<extra options, e.g.
# -L firmware directories> override the defaults; IPB_GUEST_TEST=<script> runs another guest test (the
# runner's own checks: a failing script must make this exit non-zero). Exit status: the guest test's; 1 if the
# guest did not finish. The guest reaches the internet through QEMU's user network (it downloads Hysteria,
# Xray and Caddy from GitHub, checksums pinned).
set -euo pipefail
IMAGE=$1; MODE=$2; OLD=${3:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
QEMU=${QEMU:-qemu-system-x86_64}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ipb-vm.XXXXXX")
trap 'kill "${HTTPD:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT
[ "$MODE" = fresh ] || [ -f "$OLD" ] || { echo "upgrade needs the older install.sh" >&2; exit 2; }

file_entry() { # <guest path> <local file>
  printf '  - path: %s\n    permissions: "0755"\n    encoding: b64\n    content: %s\n' "$1" "$(base64 -w0 < "$2")"
}
mkdir -p "$WORK/seed"
cat > "$WORK/run.sh" <<'EOF'
#!/bin/bash
# results go to the kernel log: the serial console shows them even after a login prompt took it
bash /opt/lifecycle.sh "$(cat /opt/mode)" /opt/install.sh /opt/old.sh 2>/root/lifecycle.err |
  while IFS= read -r line; do echo "<4>$line" > /dev/kmsg; done
echo "<4>CHECK EXIT ${PIPESTATUS[0]}" > /dev/kmsg
echo "<4>CHECK END" > /dev/kmsg
sync; poweroff
EOF
echo "$MODE" > "$WORK/mode"
{
  echo "#cloud-config"
  echo "write_files:"
  file_entry /opt/install.sh "$ROOT/Server/install.sh"
  file_entry /opt/lifecycle.sh "${IPB_GUEST_TEST:-$ROOT/Server/test/lifecycle.sh}"
  file_entry /opt/run.sh "$WORK/run.sh"
  file_entry /opt/mode "$WORK/mode"
  if [ -n "$OLD" ]; then file_entry /opt/old.sh "$OLD"; fi
  echo "runcmd:"
  echo "  - [bash, /opt/run.sh]"
} > "$WORK/seed/user-data"
printf 'instance-id: ipb-%s\nlocal-hostname: ipb-%s\n' "$MODE" "$MODE" > "$WORK/seed/meta-data"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
(cd "$WORK/seed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
HTTPD=$!
# shellcheck disable=SC2086
timeout 1500 "$QEMU" ${QEMU_ARGS:-} -enable-kvm -cpu host -smp 2 -m 1536 -nographic -no-reboot \
  -drive "file=$IMAGE,if=virtio,snapshot=on" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -smbios "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:$PORT/" \
  -serial "file:$WORK/serial.log" -monitor none > "$WORK/qemu.out" 2>&1 || true
# The guest's own verdict: its test's exit status, and proof that it ran to the end. A run that stopped early
# (power, timeout, a crashed guest) is a failure, never a quiet success.
RESULTS=$(grep -a -o 'CHECK .*' "$WORK/serial.log" 2>/dev/null | tr -d '\r' || true)
printf '%s\n' "$RESULTS"
STATUS=$(printf '%s\n' "$RESULTS" | sed -n 's/^CHECK EXIT \([0-9]*\)$/\1/p' | tail -1)
if ! printf '%s\n' "$RESULTS" | grep -qx 'CHECK END' || [ -z "$STATUS" ]; then
  echo "vm-test: the guest did not finish its test; QEMU said:" >&2; tail -5 "$WORK/qemu.out" >&2
  exit 1
fi
exit "$STATUS"
