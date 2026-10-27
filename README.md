# PaneLink

Use the monitors on your Windows PC as extra, wireless displays for your Mac.

PaneLink creates real virtual displays on the Mac, streams them over your LAN with very low
latency (the same kind of pipeline as Sunshine/Moonlight, pointed the other way), and shows them
full screen on the PC's monitors. To macOS they are ordinary displays: drag windows onto them,
arrange them in System Settings, go full screen.

- **Fast**: ScreenCaptureKit → VideoToolbox HEVC → UDP with forward error correction →
  D3D11VA zero-copy decode → tear-free flip presentation. A few milliseconds glass to glass on a
  good LAN; up to 1440p at 120 Hz per monitor (macOS caps virtual displays at 120 Hz).
- **Sharp**: HiDPI ("Retina") virtual displays, rendered at 2× and scaled to the panel.
- **Works on the lock screen**: the Windows side is a service, so the PC can stay locked (or
  have nobody signed in) while you extend onto it.
- **Turns the PC on**: Wake-on-LAN from sleep, or from a full shutdown if the BIOS allows it.
- **Gets out of the way**: turns itself off when someone uses the PC's keyboard/mouse;
  emergency stop on Windows with Ctrl+Alt+Shift+F12.
- **Cursor alignment** (like LittleBigMouse): notches on each shared edge so the pointer crosses
  between differently sized monitors where you expect.
- **Remembers**: arrangement, per-monitor settings, and which windows were on the Windows
  displays.
- **Low power**: 60 fps on battery or on demand, optional GPU clock cap and quiet fans on the PC
  while it only decodes video, and "Rest" to pause the PC's other apps.
- Menu bar switch, global shortcuts (⌃⌥⌘E on/off, ⌃⌥⌘L low power, ⌃⌥⌘S stats overlay,
  ⌃⌥⌘A align), per-monitor colour controls, a stats overlay and a "Lost frames: why" report.

## Requirements

| | |
|---|---|
| Mac | Apple silicon, macOS 14 Sonoma or later |
| PC | Windows 10 or 11, 64-bit, a GPU with hardware HEVC decode (NVIDIA GTX 10-series / AMD RX 400 / Intel 7th gen or newer) |
| Network | Both on the same LAN. PC on Ethernet strongly recommended; Mac on 5 GHz / 6 GHz Wi-Fi or Ethernet |

## Install

Download both zips from the [latest release](../../releases/latest).

**On the Windows PC**

1. Unzip `PaneLink-windows.zip` anywhere.
2. Double-click **`Install.cmd`** (if Windows warns about a downloaded file, choose **Run**)
   and allow administrator access. It installs the PaneLink
   service (starts with Windows) and opens the firewall for your local network only.

**On the Mac**

1. Unzip `PaneLink-mac.zip` and move **PaneLink.app** to Applications.
2. Open it. The release build isn't notarized, so macOS blocks it the first time: open
   **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. (Or run
   `xattr -dr com.apple.quarantine /Applications/PaneLink.app` once.)
3. Allow **Local Network** access when macOS asks. The setup window opens by itself and walks
   you through the rest; afterwards PaneLink lives in the menu bar.

## Pair

1. Open PaneLink (menu bar → **Set up your Windows PC…**). Your PC shows up in the list
   automatically; click **Pair**. (Not listed? Type the PC's IP address instead.)
2. A 6-digit code appears on the PC's monitors, even on the lock screen. Type it on the Mac.
3. Allow **Screen Recording** (the setup window has a button that opens the right page in
   System Settings). It's needed to stream the virtual displays.
4. Done. Flip the switch in the menu bar (or press ⌃⌥⌘E) to extend.

Optional: **Accessibility** permission enables cursor alignment and putting windows back where
they were.

Pairing is per Mac. To forget a PC on the Mac: Windows PC tab → **Forget this PC…**. To make
the PC forget every Mac: delete `C:\ProgramData\PaneLink\private\paired.txt`.

## Optional extras

**Turn the PC on from a full shutdown.** PaneLink learns the PC's wired MAC address when it
pairs and sends Wake-on-LAN when you turn extending on. Waking from sleep usually just works.
From a full shutdown, the BIOS has to allow it: disable *ErP Ready* / deep sleep, enable *Power
On By PCI-E* / Wake on LAN (ASUS: Advanced → APM Configuration), and keep Windows Fast Startup
off. Expect about a minute for a cold boot.

**Away from home.** Add a [Tailscale](https://tailscale.com) address after the LAN address in
Windows PC → *Windows address(es)*; it's used for control if the LAN address doesn't answer.
Video over the internet is not what PaneLink is built for.

**Quiet fans while extending.** If `C:\ProgramData\PaneLink\fans-quiet.cmd` and
`fans-normal.cmd` exist, the agent runs the first when extending starts and the second when it
stops. Point them at anything you like, e.g. switching [FanControl](https://getfancontrol.com)
profiles (`FanControl.exe -c quiet.json`). Turn on *Quiet fans* in the Windows PC tab.

**GPU low power.** On NVIDIA cards the agent caps the core clock with `nvidia-smi -lgc` while
extending and resets it afterwards.

**Scripts without pairing.** Addresses listed in `C:\ProgramData\PaneLink\trusted.txt` (one per
line) are accepted without a token.

## Build from source

```sh
brew install mingw-w64
scripts/fetch-deps.sh          # FFmpeg (LGPL) for the Windows build
mac/bundle.sh                  # builds, signs, installs /Applications/PaneLink.app
windows/build.sh               # cross-compiles windows/dist/ (copy it to the PC, run Install.cmd)
scripts/package.sh             # both, zipped for a release, in dist/
```

`mac/bundle.sh` signs with your first *Apple Development* certificate if you have one (so macOS
keeps the Screen Recording permission across rebuilds), otherwise ad hoc. Override with
`SIGN_ID=...`. Pushing a `v*` tag builds both apps on GitHub Actions and attaches them to a
release.

Layout:

```
mac/        Swift package: menu bar app (virtual displays, capture, encoder, sender, UI)
windows/    panelink.c: service + viewer in one exe (control server, decoder, presenter)
PROTOCOL.md wire protocol (discovery, pairing, control, video, feedback)
```

## Troubleshooting

- **PC not found**: both devices on the same network? Guest Wi-Fi / client isolation blocks
  discovery; type the PC's IP instead. Check the *PaneLink display receiver* service is running.
- **Black or no picture**: macOS Screen Recording permission (System Settings → Privacy &
  Security), then toggle extending off and on.
- **Stutter / lost frames**: Performance → *Lost frames: why* says whether it was Wi-Fi,
  packet loss or the PC. Put the PC on Ethernet, use 5/6 GHz Wi-Fi, lower the bitrate.
- **Logs**: Mac `~/Library/Logs/PaneLink.log`; PC `C:\ProgramData\PaneLink\*.log`.

## Uninstall

- Mac: quit PaneLink and delete it from Applications.
- PC: `powershell -ExecutionPolicy Bypass -File "C:\Program Files\PaneLink\uninstall.ps1"`
  (add `-Purge` to also delete logs and pairings) from an administrator prompt.

## Security notes

The control channel and video are not encrypted; PaneLink is meant for your own LAN. Pairing
stops other devices on the network from controlling the PC, but someone who can sniff your LAN
could see the token and the video. The firewall rules only accept the local subnet and Tailscale.

The Mac app uses the private `CGVirtualDisplay` API (as do BetterDisplay and similar tools),
which is why it isn't on the App Store.

## License

MIT, see [LICENSE](LICENSE). The Windows build ships FFmpeg's libavcodec/libavutil as LGPL
shared libraries (BtbN builds); their license is included in the Windows zip.
