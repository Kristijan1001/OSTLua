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

## Downgrade & Pin

Open a game's Steam store page and click the **OSTLua** button (top-right).

**Downgrade / freeze a version** — open OSTLua → **Load versions** → pick the version you want → **Apply**. This pins the depot to that manifest (via `setManifestid`); the original is kept so **Revert** puts it back anytime.

**Pin (block updates)** — hit **Pin (block updates)** to lock the game at its currently installed version so Steam won't update it (adds a `pinApp` line). **Unpin** to allow updates again.

Changes apply live — no restart needed.

---

## Disclaimer

This project is provided for research and educational purposes only. You are responsible for complying with local laws, platform terms of service, and software licenses.
