# LAN link: 3lay iOS to 3lay Mac

How the phone finds a Mac on the same Wi-Fi network and sends it a scan. The constants live in
`packages/scan-link/Sources/ScanLinkCore/LanProtocol.swift`. Both apps compile that file, so
change them there and update this page in the same commit.

## Flow

1. 3lay Mac starts an HTTP receiver (port 8765 if free) and publishes it on Bonjour as
   `_scanbench._tcp`, named after the Mac (for example "Studio MacBook").
2. in 3lay iOS, **Find a Mac nearby** browses for that service (`NWBrowser`). The user picks
   the Mac and types the six-digit **pairing code** shown in 3lay Mac.
3. The phone resolves the service to an IPv4 address, calls `GET /api/hello` to confirm it is
   3lay Mac, then `GET /api/auth` with the code. Only if both succeed does it store the Mac
   (name, address, code) in the Keychain.
4. After a capture, **Send to <Mac>** reconstructs a USDZ on the phone and `PUT`s it to the Mac.
   Before the upload the phone re-checks the code, and if the Mac's address changed it looks the
   Mac up again by its Bonjour name.
5. 3lay Mac saves the file in `~/Library/Application Support/3lay Mac/inbox/`, converts USDZ to
   STL (`convert_usdz.swift`) and opens it on the plate.

If Bonjour is blocked (guest Wi-Fi, some routers, VPN), the phone also accepts a typed address
such as `192.168.1.20` or `studio.local`, shown in 3lay Mac under **Import a scan**.

## HTTP contract

| Route | Auth | Purpose |
| --- | --- | --- |
| `GET /` | none | Browser upload page (STL, OBJ, ASCII PLY, USDZ). |
| `GET /api/hello` | none | `{service:"scanbench", version, name, maxBytes, extensions}`. Never contains the code. |
| `GET /api/auth` | code | 200 if the code is right. Used to validate a typed code. |
| `PUT /upload/<url-encoded filename>` | code | Raw file bytes, `Content-Length` required, 100 MB max. 200 when saved. |

The code is sent as `Authorization: Bearer <code>` (iOS) or `?code=` (browser page). Errors:
`403` wrong code, `429` locked, `411` no length, `413` too large, `415` wrong file type.

## Security model

- Traffic is **plain HTTP** on the local network, so anyone on the same Wi-Fi can read the code
  and the scan. Use a network you trust. The code only stops other people from *sending* files
  to your Mac. It does not encrypt anything.
- Five wrong codes lock the receiver for 60 seconds. A six-digit code is otherwise guessable.
- The code persists across launches so paired phones keep working. **New code** in 3lay Mac
  revokes every paired phone.
- The iOS app refuses any address outside private, link-local, loopback, CGNAT or `.local`
  ranges, and the LAN session disables cellular, so a scan cannot be sent to the internet by mistake.
- This code is separate from the server device token. The token still only travels over HTTPS
  (`PairingLink.isAllowed` is unchanged).
- iOS needs `NSLocalNetworkUsageDescription`, `NSBonjourServices` and
  `NSAllowsLocalNetworking` (in `apps/3lay-ios/project.yml`).

## Troubleshooting

- **Mac not listed:** both devices on the same Wi-Fi (not guest, not "client isolation")? Local
  Network allowed for the app in iOS Settings? macOS firewall prompt answered with Allow?
  Otherwise type the address.
- **"Code does not match":** the Mac's code was changed. Pair again.
- **"Was not found on this Wi-Fi":** 3lay Mac is closed, or the Mac is asleep.
- **USDZ does not open:** conversion needs the Swift toolchain (`xcode-select --install`).

## Checks

Automated (macOS CI, `.github/workflows/apps.yml`):

- `swift test --package-path packages/scan-link`: address parsing, local-network rules, filename
  encoding, hello contract.
- `apps/3lay-mac/rebuild_check`: runs the real `LanClient` against the real `PhoneReceiver`
  on loopback: hello, code check, OBJ and USDZ upload, wrong type, rotated code, lockout.

Not covered by anything automated, check by hand on a real phone and Mac:

- [ ] Local Network prompt appears on first use and the Mac shows up in the list.
- [ ] Wrong code is reported on the phone; right code pairs.
- [ ] Send a real LiDAR scan: the model appears on the 3lay Mac plate with plausible size.
- [ ] Restart the Mac or change its IP: the phone finds it again by name.
- [ ] Turn Wi-Fi off mid-send: the phone shows an error and keeps the scan.
- [ ] Mac app launched by double-click (not from Terminal) saves into Application Support.
