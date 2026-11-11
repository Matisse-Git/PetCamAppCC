# PetCam

A native iPhone app (SwiftUI, iOS 26, Liquid Glass) for a BHOMEA / Xiongmai pet camera. It replaces the vendor app (Tris Home) for day-to-day use.

- Live video (H.264/H.265), HD/SD with Auto (SD on cellular), pinch and double-tap zoom
- Pan and tilt with a joystick or by swiping the picture
- Listen to the camera, hold-to-talk with slide-up lock and echo cancellation
- Snapshots and clips saved to a "PetCam" album in Photos
- Picture in Picture and full-screen landscape
- Night vision, flip/mirror, auto-tracking and privacy mode, when the camera supports them
- Works away from home through Tailscale, with no vendor cloud involved

It talks to the camera directly over Xiongmai's DVRIP protocol on TCP port 34567, written in Swift with no third-party libraries.

## Setup

See **[docs/SETUP.md](docs/SETUP.md)** for the camera password, the Tailscale routes (gaming PC and Galaxy Tab), and installing with iLoader.

## Building

There's no Mac needed. GitHub Actions (`.github/workflows/build.yml`) generates the Xcode project with XcodeGen from `project.yml`, builds an unsigned `PetCam.ipa`, and publishes it to the rolling [`latest` release](https://github.com/Matisse-Git/PetCamAppCC/releases/tag/latest).

## Layout

```
PetCam/
  App/        app entry
  DVRIP/      protocol: framing, login, config, PTZ, live stream, talk
  Media/      H.264/H.265 decoding, G.711 audio, recording, display
  Camera/     CameraSession (state), discovery, settings, Keychain, Photos
  UI/         SwiftUI screens and controls
tools/
  dump_camera_config.py   read-only settings check (run on a PC)
  make_icon.py            draws the app icon
```

Protocol notes come from the open-source [go2rtc](https://github.com/AlexxIT/go2rtc) DVRIP source and [python-dvr](https://github.com/OpenIPC/python-dvr).
