# RideScreen iOS

Shows a dashboard from an iPhone on motorcycle TFT screens that speak the EasyConn/Carbit protocol
(the ones that display a pairing QR). Flutter UI; the protocol and H.264 encoder are native Swift.

Based on the protocol notes and behaviour of [RideScreen AA](../ridescreen-aa) (AGPL-3.0, so this is too).

## Layout
- `lib/` Flutter UI (paste the QR link, join the dash Wi-Fi, Connect, live log)
- `packages/easyconn_core/` Flutter plugin bridging Dart to Swift
- `packages/easyconn_core/ios/easyconn_core/EasyConnKit/` pure-Swift protocol core (frames, handshake,
  RSA, VideoToolbox H.264, TCP servers on 10920-10922). `swift test` runs without a device, including a
  loopback test with a fake dash.

## Run
`flutter run` on a real iPhone (iOS 15+). Join the dash Wi-Fi by hand (a free Apple ID cannot do it for you),
then press Connect. Screen lock: a silent audio loop keeps the app alive in the background and the encoder is rebuilt if iOS revokes it,
but whether the hardware H.264 encoder survives a lock is **untested on a device**. The Dim button (brightness 0,
app stays in front) is the safe fallback.

## Status
Protocol logic is verified against the reference notes with a fake dash, **not yet against a real dash**.
Dashboard: heading-up CPU-rendered map (raster tiles), speed gauge, trip data, and turn-by-turn navigation
(Valhalla motorcycle routing, Photon search, spoken guidance, auto re-route). Navigation is covered by tests
against real service responses; riding it is untested.
