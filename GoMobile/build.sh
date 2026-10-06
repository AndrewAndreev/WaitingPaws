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
# account (/api/xiaomi/logout), cameras of shared homes (/api/xiaomi/cameras), the API guard, runtime LAN
# credentials and re-listening after iOS suspension (internal/api/waitingpaws.go).
cp "$HERE"/xiaomi/*.go "$SRC/internal/xiaomi/"
cp "$HERE"/api/*.go "$SRC/internal/api/"

# Local patches for the in-app build (see GoMobile/README.md):
# 1-2. Xiaomi CS2 transport: our copy of pkg/xiaomi/miss/cs2/conn.go (bigger UDP and reorder buffers, a full command
#      queue drops instead of killing the connection, no "unknown msg" spam, stats in the log). It is a copy of
#      v1.9.14: compare with upstream before changing GO2RTC_VERSION.
[ "$GO2RTC_VERSION" = "v1.9.14" ] || { echo "GoMobile/xiaomi-cs2/conn.go and GoMobile/mp4/muxer.go are based on v1.9.14: port them to $GO2RTC_VERSION first"; exit 1; }
cp "$HERE"/xiaomi-cs2/*.go "$SRC/pkg/xiaomi/miss/cs2/"
# 2a. Recordings keep real time: our copy of pkg/mp4/muxer.go keeps the source's pauses (frames the camera never sent,
#     a reconnect) in /api/stream.mp4 instead of cutting each one over 1 s down to 1 ms, and the Xiaomi sound follows
#     the camera's clock (audioclock.go) instead of counting from 0 on every connect. The live player is unchanged.
cp "$HERE"/mp4/*.go "$SRC/pkg/mp4/"
cp "$HERE"/xiaomi-miss/*.go "$SRC/pkg/xiaomi/miss/"
MP4API="$SRC/internal/mp4/mp4.go"
sed -i '' 's|^	cons := mp4.NewConsumer(medias)$|&; cons.KeepTimeline() // Waiting Paws: GoMobile/mp4/muxer.go|' "$MP4API"
grep -q 'cons.KeepTimeline() // Waiting Paws' "$MP4API" || { echo "stream.mp4 timeline patch failed"; exit 1; }
MISS="$SRC/pkg/xiaomi/miss/producer.go"
sed -i '' 's|^	var audioTS uint32$|&; audio := newAudioClock(p.client) // Waiting Paws: audioclock.go|' "$MISS"
sed -i '' 's|^		p.Recv += len(pkt.Payload)$|&; audioTS = audio.follow(audioTS, pkt) // Waiting Paws|' "$MISS"
grep -q 'audio := newAudioClock(p.client)' "$MISS" && grep -q 'audioTS = audio.follow(audioTS, pkt)' "$MISS" ||
  { echo "xiaomi audio clock patch failed"; exit 1; }
# 2b. Each viewer (MSE player, recording, linked iPhone) gets a queue of 64 frames (~3 s at 20 fps); a viewer that
#     falls behind for longer loses frames and freezes until the next keyframe. 256 frames ride out such hiccups.
TRACK="$SRC/pkg/core/track.go"
sed -i '' 's|bufSize = 64$|bufSize = 256 // Waiting Paws: 64 upstream|' "$TRACK"
grep -q 'bufSize = 256 // Waiting Paws' "$TRACK" || { echo "sender buffer patch failed"; exit 1; }
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
