# OSTLua

---

## Features

- **One-click install**
- **Quick Install**
- **Freeze / downgrade**
- **Pin (block updates)**
- **Multiple download sources**

---

## Requirements

- [**Steam Homebrew**](https://www.google.com/search?q=Steam+Homebrew) installed on Steam.
- **OST** installed.

---

## Installation

1. Install Steam Homebrew and OST (see their READMEs).
2. Copy the `OSTLua` folder into your Steam Homebrew plugins directory:
   ```
   Steam\Steam Homebrew\plugins\OSTLua\
   ```
3. Enable it — add `"ostlua"` to `enabledPlugins` in `Steam\Steam Homebrew\config\config.json`, or toggle it on in Steam Homebrew's plugin manager.
4. Create your config: copy `backend\config.example.json` to `backend\config.json`. This is where your Hubcap key and source preferences are stored — it's git-ignored so your key is never committed.
5. **Restart Steam.**

---

## Downgrade & Pin

Open a game's Steam store page and click the **OSTLua** button (top-right).

**Downgrade / freeze a version** — open OSTLua → **Load versions** → pick the version you want → **Apply**. This pins the depot to that manifest (via `setManifestid`); the original is kept so **Revert** puts it back anytime.

**Pin (block updates)** — hit **Pin (block updates)** to lock the game at its currently installed version so Steam won't update it (adds a `pinApp` line). **Unpin** to allow updates again.

Changes apply live — no restart needed.

---

## Disclaimer

This project is provided for research and educational purposes only. You are responsible for complying with local laws, platform terms of service, and software licenses.
