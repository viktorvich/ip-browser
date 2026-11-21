#!/bin/bash
# App Store screenshots from the simulator, in the size App Store Connect asks for an iPhone app: 6.9" (iPhone 17
# Pro Max, 1320x2868), Russian and English: home, a website, the leak test,
# servers, «install on my server», settings. Needs a Debug build of the app
# (its lab hooks open the screens) and an access key of the server the screenshots should show - the review
# server, whose address may be public.
#   tools/screenshots.sh <IPBrowser.app (Debug, simulator)> <key file> <out dir> [website shown in the second shot]
# <key file>.<ru|en>, when present, is used for that language (a server name in the reader's language).
set -euo pipefail
APP=$1; KEY=$2; OUT=$3; SITE=${4:-https://en.wikipedia.org/wiki/Tashkent}
RUNTIME=$(xcrun simctl list runtimes | sed -n 's/^iOS .* - \(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*\)$/\1/p' | tail -1)
shot() { # <device> <file> <seconds> <launch arguments...>: launch, wait, screenshot
  local dev=$1 file=$2 wait=$3; shift 3
  xcrun simctl launch --terminate-running-process "$dev" app.ipbrowser.pos2 "$@" >/dev/null
  sleep "$wait"
  xcrun simctl io "$dev" screenshot --type=png "$file" >/dev/null 2>&1
}
device=iPhone-17-Pro-Max
for lang in ru en; do
  case $lang in ru) locale=ru_RU ;; *) locale=en_US ;; esac
  dev=$(xcrun simctl create "IPB Screens" "com.apple.CoreSimulator.SimDeviceType.$device" "$RUNTIME")
  xcrun simctl boot "$dev"
  xcrun simctl status_bar "$dev" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl install "$dev" "$APP"
  C=$(xcrun simctl get_app_container "$dev" app.ipbrowser.pos2 data)
  k=$KEY; [ -f "$KEY.$lang" ] && k=$KEY.$lang
  mkdir -p "$C/Documents"; cp "$k" "$C/Documents/import-key.txt"
  L=(-AppleLanguages "($lang)" -AppleLocale "$locale")
  d="$OUT/$lang/$device"; mkdir -p "$d"
  shot "$dev" "$d/1-home.png" 25 "${L[@]}"
  shot "$dev" "$d/2-website.png" 25 "${L[@]}" -open "$SITE"
  shot "$dev" "$d/3-leak-test.png" 30 "${L[@]}" -selftest
  shot "$dev" "$d/4-servers.png" 14 "${L[@]}" -ui servers
  shot "$dev" "$d/5-install.png" 14 "${L[@]}" -ui install
  shot "$dev" "$d/6-settings.png" 14 "${L[@]}" -ui settings
  xcrun simctl shutdown "$dev"; xcrun simctl delete "$dev"
done
find "$OUT" -name '*.png' | sort | while read -r f; do echo "$f $(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/{printf "%s ", $2}')"; done
