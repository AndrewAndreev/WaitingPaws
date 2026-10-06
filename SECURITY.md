# Security

Waiting Paws runs an HTTP API on the device (the embedded go2rtc) and links an iPhone to a Mac or PC over the home
network, so reports about either are welcome.

## Reporting a vulnerability

Please report privately: the repository's **Security** tab → **Report a vulnerability**. Don't open a public issue
for a vulnerability. The discussion and the fix will happen in that private advisory.

Supported versions: the latest release on each platform.

## What is in scope

- The guard in front of the embedded go2rtc API (`GoMobile/api/waitingpaws.go`): web pages in a browser on the same
  computer, other devices on the network, access to the camera, the config or the Xiaomi account.
- The iPhone ↔ Mac/PC link: pairing, the handshake and the encrypted frames
  (`Packages/WaitingPawsCore/Sources/WaitingPawsCore/Sync/`, `App/Sources/Sync/`, `Desktop/src/core/node/syncCrypto.ts`,
  `Desktop/src/main/sync/`).
- How the apps keep the Xiaomi sign-in, recordings and logs on the device.

Bugs in go2rtc itself go to [go2rtc](https://github.com/AlexxIT/go2rtc), unless they come from our patches
(`GoMobile/build.sh`, `Desktop/scripts/build-go2rtc.mjs`). Xiaomi's cloud and camera firmware are out of scope.
