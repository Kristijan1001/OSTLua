# OSTLua

<img width="1066" height="860" alt="steamwebhelper_kE02wileFk" src="https://github.com/user-attachments/assets/01781d90-524a-474d-917f-342395f4363e" />

<img width="371" height="164" alt="steamwebhelper_JeBbUrheaa" src="https://github.com/user-attachments/assets/992fcf4d-6ede-4bdb-8ad5-8fc265253841" />

---

> **⚠️ Installed games before? Re-download their lua.** Older builds installed games with the manifest pinned, which could silently block Steam updates. If a game isn't updating, **re-download its lua through OSTLua** (or open OSTLua → **Load versions** → **Revert**) — that clears the pin so it updates normally again.

---

## Features

- **One-click install**
- **Quick Install**
- **Freeze / downgrade**
- **Multiple download sources**

---

## Requirements

- [**Millennium**](https://www.google.com/search?q=Millennium+Steam) installed on Steam.
- **OST** installed.

---

## Installation

1. Install Millennium and OST (see their READMEs).
2. Copy the `OSTLua` folder into your Millennium plugins directory:
   ```
   Steam\Millennium\plugins\OSTLua\
   ```
3. Enable **OSTLua** in Millennium's plugin manager.
4. **Restart Steam.**

No config files to set up — the plugin creates everything on first run. Open the **OSTLua** button on any store page to add your Hubcap API key (optional; the free sources need no key).

---

## Downgrade & Freeze

Open a game's Steam store page and click the **OSTLua** button (top-right).

**Downgrade / freeze a version** — open OSTLua → **Load versions from SteamDB** → pick the version you want → **Apply**. This pins the depot to that manifest (via `setManifestid`); the original is kept so **Revert** puts it back anytime.

> **🔑 Log in to SteamDB (through Steam) for full version history.** SteamDB only shows a short, recent slice of manifests to logged-out visitors. When OSTLua opens the SteamDB page, press **"Sign in through Steam"** on SteamDB first — once you're logged in it exposes the game's **full history of versions/updates**, so OSTLua can fetch far more versions to choose from. After signing in, hit **Load versions** again (or the reload ↻ button) to pull the complete list.

Changes apply live — no restart needed.

---

## Disclaimer

This project is provided for research and educational purposes only. You are responsible for complying with local laws, platform terms of service, and software licenses.
