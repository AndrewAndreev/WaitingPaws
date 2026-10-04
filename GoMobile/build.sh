#!/usr/bin/env bash
# Builds Frameworks/Go2RTC.xcframework (iOS, iOS Simulator, macOS) from go2rtc + GoMobile/mobile.
#
# Requirements: Go 1.24+, Xcode, and gomobile (same x/mobile version as below):
#   go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20260908204917-8b95e45f8d3e && gomobile init
set -euo pipefail

GO2RTC_VERSION="${GO2RTC_VERSION:-v1.9.14}"
# Pinned so the same sources always give the same framework (gobind and the bind package must match).
XMOBILE_VERSION="v0.0.0-20260908204917-8b95e45f8d3e"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
BUILD="$HERE/build"
SRC="$BUILD/go2rtc"
OUT="$ROOT/Frameworks/Go2RTC.xcframework"
export PATH="$HOME/go/bin:$PATH"

if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git clone --depth 1 --branch "$GO2RTC_VERSION" https://github.com/AlexxIT/go2rtc "$SRC"
fi

mkdir -p "$SRC/mobile"
cp "$HERE"/mobile/*.go "$SRC/mobile/"
# Additions to go2rtc's own packages: camera settings via Mi Cloud (/api/xiaomi/miot), forgetting an
# account (/api/xiaomi/logout), the API guard, runtime LAN credentials and re-listening after iOS
# suspension (internal/api/waitingpaws.go).
cp "$HERE"/xiaomi/*.go "$SRC/internal/xiaomi/"
cp "$HERE"/api/*.go "$SRC/internal/api/"

# Local patches for the in-app build (see README):
# 1. Xiaomi CS2 media queue: 100 frames die after ~2 s of consumer stall (WebKit throttling, Wi-Fi roaming);
#    keep ~20 s instead.
# 2. Drop the "cs2: unknown msg" stdout spam.
CS2="$SRC/pkg/xiaomi/miss/cs2/conn.go"
sed -i '' 's/newDataChannel(250, 100)/newDataChannel(250, 1000)/' "$CS2"
#    The command queue (10 entries) is only read during the handshake; unsolicited camera messages
#    overflow it minutes later and kill the whole connection. Enlarge it and drop on overflow instead.
sed -i '' 's/newDataChannel(0, 10)/newDataChannel(0, 100)/' "$CS2"
sed -i '' 's|return fmt.Errorf("pop buffer is full")|// Waiting Paws patch: drop the packet instead of failing the connection|' "$CS2"
grep -q "pop buffer is full" "$CS2" && { echo "cs2 overflow patch failed"; exit 1; }
sed -i '' 's|fmt.Printf("%s: unknown msg: %x\\n", "cs2", buf\[:n\])|_ = n // unknown msg, ignored|' "$CS2"
grep -q "newDataChannel(250, 1000)" "$CS2" || { echo "cs2 patch failed"; exit 1; }
# 3. HEVC in MP4: go2rtc writes the `hev1` sample entry, Apple (AVFoundation, Photos, Safari) only plays `hvc1`.
#    The hvcC box with parameter sets is written anyway, so renaming the atom is enough.
ISO="$SRC/pkg/iso"
sed -i '' 's/m.StartAtom("hev1")/m.StartAtom("hvc1")/' "$ISO/codecs.go"
sed -i '' 's/case "avc1", "hev1":/case "avc1", "hev1", "hvc1":/' "$ISO/reader.go"
grep -q 'StartAtom("hvc1")' "$ISO/codecs.go" || { echo "hvc1 patch failed"; exit 1; }
# 4. API (see GoMobile/api/waitingpaws.go): the guard wraps the mux, Basic auth reads credentials that can
#    change at runtime, and a failed listener is an error instead of log.Fatal (iOS closes the listening
#    socket of a suspended app; exiting would kill the whole app when it comes back).
API="$SRC/internal/api/api.go"
sed -i '' 's|Handler = http.DefaultServeMux // 4th|Handler = guard(http.DefaultServeMux) // 4th|' "$API"
sed -i '' 's/if !ok || user != username || pass != password {/if !ok || !credentialsOK(user, pass, username, password) {/' "$API"
sed -i '' 's/log.Fatal().Err(err).Msg("\[api\] serve")/log.Error().Err(err).Msg("[api] serve")/' "$API"
sed -i '' 's/log.Fatal().Err(err).Msg("\[api\] tls serve")/log.Error().Err(err).Msg("[api] tls serve")/' "$API"
grep -q 'Handler = guard(http.DefaultServeMux)' "$API" || { echo "api guard patch failed"; exit 1; }
grep -q 'credentialsOK(user, pass, username, password)' "$API" || { echo "api auth patch failed"; exit 1; }
grep -q 'log.Fatal' "$API" && { echo "api fatal patch failed"; exit 1; }

cd "$SRC"
go get -tool "golang.org/x/mobile/cmd/gobind@$XMOBILE_VERSION" >/dev/null
go get "golang.org/x/mobile/bind@$XMOBILE_VERSION" >/dev/null
go mod tidy >/dev/null

# Build next to the sources and swap at the end, so an Xcode build started meanwhile still finds the old one.
NEW="$BUILD/Go2RTC.xcframework"
rm -rf "$NEW"
gomobile bind -target ios,iossimulator,macos -iosversion 17.0 -ldflags="-s -w" -o "$NEW" ./mobile
rm -rf "$OUT"
mv "$NEW" "$OUT"
echo "Built $OUT"
