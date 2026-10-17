# DropHop

A floating **shelf** for your files. Drag something onto it, leave it there, and pick it up later: on the same
computer, on your phone, or through a link you send to somebody else.

One app, four versions that talk to each other over your Wi-Fi:

| | Computer app | Phone app |
|---|---|---|
| **Apple** | **Mac** (`mac/`) | **iPhone** (`ios/`) |
| **Others** | **Windows** (`windows/`) | **Android** (`android/`) |

Any computer app works with any phone app, because they all speak the same small protocol (see [How sync works](#how-sync-works)).

---

## Features

### The shelf (computer apps)
- **Floating shelf** that stays out of the way in the tray (Windows) or menu bar (Mac) until you need it.
- **Drag files in, drag files out.** Folders are zipped automatically on the way in, so the shelf only ever holds single files.
- **Pops up when you drag.** On Windows: hold a dragged file still for about 0.6 s, or shake it (tray icon, then *Show shelf when I…* to choose). On Mac: shake the dragged file.
- **Groups.** Make named groups (the chips under the counter) to keep things sorted. Drop files straight onto a chip, move files between groups, rename or delete a group.
- **Clear** empties the shelf in one click.
- **Move the window** by its handle or with **Alt + drag anywhere** (Option-drag on Mac).
- **Copy to clipboard** (Windows, in place of AirDrop), plus *Show in Explorer* from the row's right-click menu.
- **Start with Windows** (Windows): on by default the first time you run the new build. Switch it off from the tray menu.
- **Tray notifications** when a file arrives from your phone (Windows).

### Share links (computer apps)
- **One-click link** for any file or a whole group: free, no account, auto-expiring.
- **Choose how long it lives:** 1, 12, 24 or 72 hours.
- **Whole group as one link:** the group is zipped and uploaded as a single file.
- **Hosts are tried in order** (Windows: Litterbox, then tmpfiles.org). If one is blocked or down, the next is used.
- **Programs are wrapped in a zip** (`.exe`, `.msi`, `.bat`, `.dll`, …) because free hosts refuse them.
- **Readable errors.** If a link fails, the reason shows under the file name (hover for the full text) and is logged to `error.log`.

### Phone sync
- **Automatic discovery** over your Wi-Fi (Bonjour/mDNS), or type the address by hand if your router blocks it.
- **Pair once** with a 6-digit code shown only on the computer.
- **See the shelf on your phone**, grouped like the computer, refreshed every few seconds or with pull-to-refresh.
- **Download** a file with one tap. Android saves to `Downloads/DropHop`. Then open it, share it, or remove the download.
- **Get a link from your phone:** ask the computer to make the share link and copy it.
- **Send files from your phone to the computer** (Android to Windows): see below.

### Send files from the phone to the PC (Android → Windows)
- Tap **SEND FILES TO COMPUTER** on the Android shelf screen and pick one or more files.
- The files **stream straight to the PC's disk** (up to 4 GB each), with a live progress bar in the button.
- They appear on the PC's shelf immediately, and a tray notification says what arrived.
- Uses the same pairing token as downloads. Nothing leaves your own network.

### Look and feel
- Same dark, warm design on every platform: capsule buttons, round icon tiles, monospace labels.
- Android uses Android's own share sheet (which includes Quick Share). iPhone uses the share sheet.

---

## Feature matrix

| Feature | Windows | Mac | Android | iPhone |
|---|:-:|:-:|:-:|:-:|
| Floating shelf, drag in/out | ✅ | ✅ | – | – |
| Folders zipped automatically | ✅ | ✅ | – | – |
| Groups | ✅ | ✅ | view only | view only |
| Share links (1/12/24/72 h) | ✅ | ✅ | via computer | via computer |
| Group link as one zip | ✅ | ✅ | – | – |
| Pair a phone with a code | ✅ | ✅ | ✅ | ✅ |
| Download from the shelf | serves | serves | ✅ | ✅ |
| **Send files phone → computer** | **receives** | not yet | **sends** | not yet |
| Start at login | ✅ | – | – | – |
| Tray / menu-bar app | ✅ | ✅ | – | – |

---

## Get the apps

### Easiest: let GitHub build them
Push the repo to GitHub. Every push runs two workflows under the **Actions** tab:

| Workflow | Job | Download (artifact) |
|---|---|---|
| **Build DropHop** (`build.yml`) | android | `DropHop-Android-apk` |
| | windows | `DropHop-Windows` (`DropHop.exe`) |
| **Build Mac and iOS** (`apple.yml`) | mac | `DropHop-Mac-dmg` (`DropHop.dmg`) |
| | ios | `DropHop-iOS-unsigned-ipa` |

Open a finished run, scroll to **Artifacts**, and download. Each artifact is a zip with the file inside.
To give the apps to other people, attach the files to a **Release** (repo page, then *Releases*, then *Create a new release*).
Release links work without a GitHub login on public repos, and don't expire after 90 days like artifacts.

> The Apple jobs run on GitHub's `xcode-27` machines, because the iOS project uses the Xcode 27 file format.
> The normal `macos-latest` machines only have Xcode 26 and cannot open it.

### Install on each platform

**Windows.** Run `DropHop.exe`. It is a single file and needs no .NET. Allow it through Windows Firewall on **private** networks when asked.

**Android.** Copy the `.apk` to the phone and open it (allow *Install unknown apps* for your file manager or browser). Needs Android 10+.

**Mac.** Open `DropHop.dmg`, drag **DropHop** to **Applications**. The build is universal (Apple Silicon and Intel) and signed with a free ad-hoc signature, so on other people's Macs the first launch is blocked: open **System Settings, then Privacy & Security** and click **Open Anyway**. A warning-free install needs the paid Apple Developer account plus notarization.

**iPhone.** Apple only runs signed apps, and GitHub can't sign for you. Pick one:

| Way | Cost | Notes |
|---|---|---|
| **Xcode, direct install** | Free | Plug the iPhone into a Mac, open `ios/DropHopMobile.xcodeproj`, press Run. With a free Apple ID the app expires after 7 days; reinstall to renew. |
| **AltStore / Sideloadly** + the `DropHop-iOS-unsigned-ipa` artifact | Free | No Xcode needed. They sign the app with your Apple ID, with the same 7-day limit (AltStore can renew it automatically). |
| **TestFlight** | $99/year | Builds last 90 days; share an install link. |
| **App Store** | $99/year | Public release. |

---

## Using it

1. **Start DropHop on the computer.** Look for the tray icon (Windows, bottom right) or menu-bar icon (Mac).
2. **Pair the phone.** Tray/menu icon, then **Pair phone…** (Windows) or **Pair iPhone…** (Mac). A 6-digit code appears.
3. **On the phone,** open DropHop, pick the computer from the list, and type the code. Done.
4. **Add files:** drag a file; hold it still (or shake it) and the shelf pops up; drop it in. It now shows on the phone too.
5. **Make a link:** click the link button on a row, choose how long it should live, then use the copy button.
6. **Send from phone to PC (Android + Windows):** tap **SEND FILES TO COMPUTER**, choose files.

If the phone can't see the computer in the list (some routers block mDNS), tap **Enter address manually** and type the address shown at the bottom of the pairing window.

---

## How sync works

The computer app runs a tiny web server on your local network and advertises it as `_drophop._tcp`. The phone finds it, pairs once, then polls it.

| Request | Purpose | Needs token |
|---|---|:-:|
| `GET /v1/ping` | Is a DropHop here, and is it paired? | no |
| `POST /v1/pair` | Exchange the 6-digit code for a token | no (needs the code) |
| `GET /v1/manifest` | List of files and groups | yes |
| `GET /v1/files/<id>` | Download a file (folders arrive as zips) | yes |
| `POST /v1/files/<id>/link` | Ask the computer to create a share link | yes |
| `PUT /v1/upload?name=<file>` | Phone sends a file to the computer (streamed to disk) | yes |

`PUT /v1/upload` is currently implemented by the Windows app and the Android app only.

### Security model
- Only `/v1/ping` and `/v1/pair` work without the token.
- Pairing needs a **6-digit code that only the computer's screen shows**. It lasts 2 minutes and allows 5 tries.
- **One phone at a time.** Pairing a new phone replaces the old one; **Unpair** on either side revokes access.
- The computer stores only a **hash** of the token. The phone keeps it in secure storage (Android encrypted store, iOS Keychain).
- Share links never go through the sync protocol, and are never sent to the phone's manifest.
- Sync traffic is **plain HTTP on your local network**. It isn't encrypted, so pair and sync on a network you trust.

### Where things are stored
- **Windows:** `%APPDATA%\DropHop\` holds `items.json`, one folder per file, `pairing.json`, `settings.json`, `window.json`, and `error.log`.
- **Android:** downloads go to `Downloads/DropHop`; the pairing token is in the app's encrypted store.

---

## Build it yourself

### Windows (`windows/`)
Needs the .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`).
```powershell
cd windows
.\build.ps1          # produces dist\DropHop.exe (single file, self-contained)
```
If **Inno Setup 6** is installed it also produces `dist\DropHop-Setup.exe`. Use `-Arch win-arm64` for ARM PCs.

### Android (`android/`)
Open the folder in **Android Studio** and press Run, or build from the command line:
```bash
gradle -p android assembleRelease
```
The APK appears in `android/app/build/outputs/apk/release/`. It is signed with the debug key so it installs for personal use.

### Mac (`mac/`)
Needs the Xcode Command Line Tools (`xcode-select --install`).
```bash
cd mac
bash build.sh        # quick build for this Mac, then launches it
bash make-dmg.sh     # universal DropHop.dmg (Apple Silicon + Intel)
```
For a Developer-ID-signed build: `DEV_ID="Developer ID Application: Your Name (TEAMID)" bash make-dmg.sh`, then notarize as the script prints.

### iPhone (`ios/`)
Open `ios/DropHopMobile.xcodeproj` in Xcode (27 or newer), pick your team under *Signing & Capabilities*, choose your iPhone, and press Run.

---

## Repository layout

```
.github/workflows/
  build.yml        Android + Windows builds
  apple.yml        Mac .dmg + unsigned iOS .ipa
android/           Android app (Kotlin, Jetpack Compose)
windows/           Windows app (C#, WPF, .NET 8) + build.ps1 + installer.iss
mac/               Mac app (Swift) + build.sh + make-dmg.sh
ios/               iPhone app (Swift, SwiftUI) Xcode project
README.md
```

---

## Differences between the platforms

- **Summoning the shelf:** Windows can't tell whether *another* app is dragging files, so it watches for a drag that starts in **Explorer or on the desktop**. From other apps, open the shelf from the tray icon; dropping onto it works the same.
- **AirDrop** doesn't exist on Windows. The button copies the file(s) to the clipboard so you can paste into Explorer, e-mail or chat.
- **Option-drag** on Mac is **Alt-drag** on Windows. *Reveal in Finder* is *Show in Explorer*.
- **Sharing on phones:** Android uses the system share sheet (including Quick Share); iPhone uses the iOS share sheet.

## Troubleshooting

| Problem | What to try |
|---|---|
| Phone doesn't list the computer | Same Wi-Fi? Allow DropHop through the firewall on **private** networks. Otherwise use **Enter address manually**. |
| "Can't reach your computer" | Make sure DropHop is running on the computer and both are on the same Wi-Fi. |
| Link creation fails | Hover over the red text under the file for the full reason, or open `%APPDATA%\DropHop\error.log`. Free hosts sometimes block or go down; retry in a minute. |
| File you dropped doesn't appear until you move the window | The current build forces a redraw after every change. Make sure you're on the latest build, and report it if it still happens. |
| Mac says the app can't be opened | System Settings, then Privacy & Security, then **Open Anyway** (see above). |
| iPhone app stops opening after a week | A free Apple ID signs for 7 days only. Reinstall from Xcode, or let AltStore renew it. |
| GitHub build fails | Open the failed job in **Actions**, and send the red lines to whoever maintains the repo. |

## Known limitations

- **Mac and iPhone can't yet receive or send files from the phone** (the `PUT /v1/upload` feature). Only Windows and Android have it.
- The **Mac app's link maker** still lists `0x0.st` among its hosts. That host has switched uploads off, so it is skipped automatically after failing, and Litterbox or tmpfiles handles the link.
- A link made through the **tmpfiles.org fallback** lasts 1 hour whatever duration you picked.
- **Tested so far:** the Windows app has been built on GitHub and run on a real PC, and the Android app builds on GitHub. **Phone-to-PC sending has not yet been tried end to end**, and the **Mac and iOS workflow is new**, so the first run of either may need a small fix.
- Free hosts apply their own file-size limits (Litterbox about 1 GB, tmpfiles 100 MB).
