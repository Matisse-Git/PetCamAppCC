# PetCam setup guide

PetCam talks directly to the camera at **192.168.1.2** using the camera's own protocol (DVRIP, port 34567). At home that works over Wi-Fi. Away from home it works through **Tailscale**, with one or two devices at home acting as the route to the camera.

```
iPhone (5G / other Wi-Fi) ──Tailscale──▶ gaming PC  ─┐
                                        Galaxy Tab ──┴─▶ camera 192.168.1.2:34567
```

---

## 1. Camera device password (in Tris Home)

PetCam logs in with the camera's **device** password, not your Tris Home account password.

1. Open **Tris Home** and tap the camera.
2. Open its settings (gear icon). Look for **Device password**, **Modify device password** or **Password settings**. On iCSee-style apps it's often under *Advanced* or *Security*.
3. Set a strong password and write it down. The username is almost always `admin`.

If you can't find the setting, the camera may have no password yet. You can leave the password empty in PetCam, but it's worth setting one.

## 2. Read-only settings check (on the gaming PC)

This shows which settings your camera exposes (night vision, auto-tracking, privacy mode, etc.). It only reads and never changes anything.

```bash
python tools/dump_camera_config.py
```

Type the username (Enter for `admin`) and the device password when asked. The result goes to `tools/camera_config_dump.json`, which stays on the PC and isn't committed to git.

## 3. Gaming PC as a route to the camera (works today)

The PC already runs Tailscale as `gaming-desktop`.

**Today, while you're at work:** advertise only the camera's address. This doesn't affect Moonlight, which connects to the PC's own Tailscale address.

```bash
tailscale set --advertise-routes=192.168.1.2/32
```

Then in the [Tailscale admin console](https://login.tailscale.com/admin/machines), open `gaming-desktop` → **Edit route settings** and approve `192.168.1.2/32`.

To undo it (from your phone, without the PC), untick the route in the same place.

**Later, once the tablet is set up (step 4):** switch both devices to the whole home network. That lets PetCam find the camera even if it gets a new address after being unplugged. Do this from home:

```bash
tailscale set --advertise-routes=192.168.1.0/24 --accept-routes=false
```

Approve `192.168.1.0/24` in the admin console and remove the old `/32` route.

Keep in mind:
- **NordVPN:** while it's connected on the PC, it can take over routing and break the route to the camera.
- **Sleep:** the PC must stay awake. Sleep is currently set to *never*.

## 4. Galaxy Tab A8 as the always-on route

1. Install **Tailscale** from the Play Store and sign in with the same account (`galaxy-tab-a8` is already in the account).
2. In Tailscale: avatar menu → **Settings** → **Subnet routing** → **Add route** → `192.168.1.0/24`.
3. Leave **Allow LAN access** under *Exit Node* **off**, so the tablet acts only as a subnet router.
4. Approve the route for `galaxy-tab-a8` in the admin console.
5. Samsung settings, so it survives 24/7 on the charger:
   - **Settings → Battery → More battery settings → Protect battery** (stops charging at 85%).
   - **Settings → Battery → Background usage limits → Never sleeping apps** → add Tailscale.
   - **Settings → Apps → Tailscale → Battery → Unrestricted**.
6. Keep it plugged in and on the home Wi-Fi.

With both the PC and the tablet advertising `192.168.1.0/24`, Tailscale uses one of them and fails over to the other within about 15 seconds. You can't choose which one it prefers: it uses the one that was set up first.

## 5. iPhone

1. Install **Tailscale** from the App Store and sign in (`iphone` is already in the account). Turn it on.
2. To test before PetCam is installed, open **http://192.168.1.2** in Safari on 5G. If the camera's "Web Viewer" page loads, the tunnel works.
3. If you're ever on a Wi-Fi network that also uses 192.168.1.x and can't reach devices on *that* network, turn Tailscale off for a moment.

## 6. Install PetCam with iLoader

Every push to `master` builds an unsigned `PetCam.ipa` on GitHub Actions. It's attached to the **latest** release:

https://github.com/Matisse-Git/PetCamAppCC/releases/tag/latest

1. Download `PetCam.ipa` to the PC.
2. Connect the iPhone by cable and install the `.ipa` with **iLoader** (your free Apple ID signs it).
3. First time only: on the iPhone, go to **Settings → Privacy & Security → Developer Mode** and turn it on (the iPhone restarts). Then, if asked, trust your Apple ID under **Settings → General → VPN & Device Management**.
4. With a free Apple ID the app stops opening after **7 days**. Reinstall it with iLoader to refresh it.

## 7. First launch

- **Address:** `192.168.1.2` (or tap **Find Camera on Network**).
- **Username:** `admin`
- **Password:** the device password from step 1.
- Allow **Local Network** access when iOS asks, or PetCam can't reach the camera.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Camera is offline" at home | Camera unplugged, or Local Network access is off (Settings → PetCam). |
| "Camera is offline" away from home | Tailscale off on the iPhone, or no route approved in the admin console, or both home devices offline. |
| "Password needed" | Wrong device password. Update it in PetCam → Settings → Connection. |
| Camera turns the wrong way | PetCam → Settings → Movement → Reverse Left/Right or Up/Down. |
| Talk doesn't come out of the camera | Talk support isn't verified on this camera yet. Report it so the audio format can be adjusted. |
