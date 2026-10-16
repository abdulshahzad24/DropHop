# DropHop for Android and Windows

Ports of the iPhone app (→ **Android**) and the Mac app (→ **Windows**). Same look, same behaviour, same
wire protocol — so any combination works:

|            | Mac app | Windows app |
|------------|---------|-------------|
| **iPhone** | ✅ (existing) | ✅ |
| **Android**| ✅ | ✅ |

The Mac app needs **no changes** to work with the Android app (its menu just says "Pair iPhone…").

> ⚠️ These were written without being able to compile them (no .NET / Android SDK where they were authored).
> They were reviewed by hand, but expect to fix a typo or two on the first build.

## Build

### Easiest: let GitHub build both
Push this folder to a GitHub repo → **Actions → Build DropHop** → download `DropHop-Android-apk` and `DropHop-Windows`.

### Android (`android/`)
Open the folder in **Android Studio** (it fetches Gradle for you) → Run, or *Build → Build APK(s)*.
Needs Android 10+ (API 29). Downloads land in **Downloads/DropHop**.

### Windows (`windows/`)
Install the .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`), then in PowerShell:
```
cd windows
.\build.ps1          # → dist\DropHop.exe  (single file, no .NET needed on the target PC)
```
If Inno Setup 6 is installed it also produces `dist\DropHop-Setup.exe`.

## Using it
1. Start DropHop on the PC (tray icon, bottom-right). Allow it through Windows Firewall on **private** networks when asked.
2. Tray icon → **Pair phone…** → a 6-digit code appears.
3. On the phone open DropHop, pick the computer, type the code. Done.

If the phone can't see the PC in the list (some routers block mDNS), tap **Enter address manually** and type the
address shown at the bottom of the pairing window.

## What differs from the Mac / iPhone versions
* **Summoning the shelf** — Windows can't tell whether *another* app is dragging files, so it watches for a drag that
  starts in **Explorer or on the desktop**. By default the shelf appears when you **hold the dragged file still for ~0.6 s**;
  tray icon → *Show shelf when I…* switches to shake, or either. From other apps, open the shelf from the tray icon
  (dropping onto it works the same).
* **AirDrop button** — no AirDrop on Windows; the button copies the file(s) to the clipboard so you can paste into
  Explorer, e-mail or chat. Also: right-click a row → *Show in Explorer*.
* **Option-drag** is **Alt-drag**; "Reveal in Finder" is "Show in Explorer"; SF Symbols are Segoe icons.
* **Android sharing** uses the system share sheet (which includes Quick Share) instead of AirDrop/ShareLink.
* The sync protocol (Bonjour `_drophop._tcp`, `/v1/pair`, `/v1/manifest`, `/v1/files/<id>`, bearer token, 2-minute
  6-digit code, 5 tries, one paired phone) is identical.
