# OSTLua
<img width="480" height="347" alt="image" src="https://github.com/user-attachments/assets/99a8c8d2-789c-49bf-bd4c-16c92cb4630c" />

<img width="1061" height="1142" alt="image" src="https://github.com/user-attachments/assets/d710c679-d87b-4da5-827f-c2ddf21ed7f7" />

---

> **⭐ Now built for [BetterSteamTools](https://github.com/madoiscool/BetterSteamTools).** BST is the actively maintained continuation of OpenSteamTool — **use it instead of OST.** It reads luas from `config\stplug-in` (OST used `config\lua`), so as of **v1.3.0** OSTLua installs there by default.
>
> **Already have luas in the old folder?** Open any store page after updating and OSTLua will offer to **move them for you** — one click, nothing is moved without your OK, and any file that already exists at the destination is left untouched.

> **⚠️ Millennium 3.4.0 users:** update to **v1.3.0 or newer**. Millennium 3.4.0 changed how plugin scripts are injected and older OSTLua builds show no UI at all on it.

---

## Features

- **One-click install**
- **Quick Install**
- **Freeze / downgrade**
- **Multiple download sources**
- **Automatic migration** from the old OpenSteamTool lua folder

---

## Requirements

- [**Millennium**](https://www.google.com/search?q=Millennium+Steam) installed on Steam (**3.4.0+ supported**).
- [**BetterSteamTools**](https://github.com/madoiscool/BetterSteamTools) installed. *(Legacy OpenSteamTool still works — see below.)*

---

## Installation

1. Install Millennium and BetterSteamTools (see their READMEs).
2. Copy the `OSTLua` folder into your Millennium plugins directory:
   ```
   Steam\Millennium\plugins\OSTLua\
   ```
3. Enable **OSTLua** in Millennium's plugin manager.
4. **Restart Steam.**

No config files to set up — the plugin creates everything on first run. Open the **OSTLua** button on any store page to add your Hubcap API key (optional; the free sources need no key).

### Still on OpenSteamTool?

OSTLua writes to `config\stplug-in` by default (BST). If you're still running plain OST, set the folder back by editing `backend\config.json`:

```json
{ "lua_dir_name": "lua" }
```

OSTLua always *reads* from both locations, so freeze/revert keeps working either way.

---

## Downgrade & Freeze

Open a game's Steam store page and click the **OSTLua** button (top-right).

**Downgrade / freeze a version** — open OSTLua → **Load versions from SteamDB** → pick the version you want → **Apply**. This pins the depot to that manifest (via `setManifestid`); the original is kept so **Revert** puts it back anytime.

> **🔑 Log in to SteamDB (through Steam) for full version history.** SteamDB only shows a short, recent slice of manifests to logged-out visitors. When OSTLua opens the SteamDB page, press **"Sign in through Steam"** on SteamDB first — once you're logged in it exposes the game's **full history of versions/updates**, so OSTLua can fetch far more versions to choose from. After signing in, hit **Load versions** again (or the reload ↻ button) to pull the complete list.

**Every depot gets pinned, not just one.** A game's content is usually split across several depots. Pinning only the main one leaves the rest on the newest build, which gives you a half-downgraded game that looks like "it downloaded the latest version anyway". OSTLua resolves *every* depot to the manifest it had at the build you picked, so the whole game lands on one version.

Depots other than the main one need their own SteamDB history first. If any are missing, the picker says so and offers **Load versions for N depots** — do that once and Apply pins them all.

After applying, restart Steam and use **Verify integrity of game files** if Steam reports "no changes" — it sometimes relabels the manifest without actually fetching the older files.

Changes apply live — no restart needed.

---

> **⚠️ Installed games before? Re-download their lua.** Older builds installed games with the manifest pinned, which could silently block Steam updates. If a game isn't updating, **re-download its lua through OSTLua** (or open OSTLua → **Load versions** → **Revert**) — that clears the pin so it updates normally again.

---

## Disclaimer

This project is provided for research and educational purposes only. You are responsible for complying with local laws, platform terms of service, and software licenses.
