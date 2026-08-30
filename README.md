# OSTLua
<img width="480" height="347" alt="image" src="https://github.com/user-attachments/assets/99a8c8d2-789c-49bf-bd4c-16c92cb4630c" />

<img width="1061" height="1142" alt="image" src="https://github.com/user-attachments/assets/d710c679-d87b-4da5-827f-c2ddf21ed7f7" />

---

> **⭐ Built for [BetterSteamTools](https://github.com/madoiscool/BetterSteamTools).** BST is the actively maintained continuation of OpenSteamTool — **use it instead of OST.** It reads luas from `config\stplug-in` (OST used `config\lua`), so OSTLua installs there by default.
>
> **Already have luas in the old folder?** Open any store page after updating and OSTLua will offer to **move them for you** — one click, nothing moves without your OK, and any file that already exists at the destination is left untouched.

> **⚠️ Millennium 3.4.0+ users:** you need **v1.3.0 or newer**. Millennium 3.4.0 changed how plugin scripts are injected and older OSTLua builds show no UI at all on it.

---

## Features

- **One-click install**
- **Quick Install** — installs the lua *and* loads the game's builds in one go
- **Downgrade by build** — pins every depot together, not just one
- **Multiple download sources**
- **Automatic migration** from the old OpenSteamTool lua folder

---

## Requirements

- [**Millennium**](https://www.google.com/search?q=Millennium+Steam) installed on Steam (**3.4.x supported**).
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

OSTLua always *reads* from both locations, so downgrading keeps working either way.

---

## Downgrading

Open a game's Steam store page and click the **OSTLua** button (top-right).

1. **Load builds from SteamDB** — reads the game's build list once (`13 Mar 2026 — build 22277314`, …).
2. Pick a build → **Apply**. OSTLua opens that build's SteamDB page, reads every depot's manifest from it, and pins them together.
3. **Revert** clears every pin and puts the game back on the latest build.

The card shows what's pinned, e.g. `current: 9166256367562763038 · build 22277314 · 13 Mar 2026`.

### Why builds and not single manifests

A game's files are split across several depots. Pinning only the "main" one leaves the rest on the newest build, and you end up with a half-old, half-new install that looks like *"I picked an old version and it downloaded the latest anyway"*.

Applying a **build** fixes that: OSTLua takes the depot manifests off that build's SteamDB page and pins them as a set. Depots the build didn't touch are pinned at the manifest they already had — so nothing silently floats to latest. Depots your lua doesn't contain (blacklisted ones) are ignored.

If the build page can't be read properly, **nothing is written** — it tells you to try again rather than leaving a mixed install behind.

> **🔑 Sign in to SteamDB through Steam.** Logged-out visitors only see a short slice of history. Signed in, you get the game's full build list.

### After applying

Restart Steam, then use **Properties → Installed Files → Verify integrity of game files**. Steam sometimes relabels the manifest without actually fetching the older files; verifying forces it to reconcile against the pins.

Note that Steam's **Build ID** in the game's Updates tab still shows the *latest* build — it records the public branch's id no matter which depot manifests are mounted. The depot manifests are the real state.

---

> **⚠️ Installed games before? Re-download their lua.** Older builds installed games with the manifest pinned, which could silently block Steam updates. If a game isn't updating, **re-download its lua through OSTLua** (or hit **Revert**) — that clears the pin so it updates normally again.

---

## Disclaimer

This project is provided for research and educational purposes only. You are responsible for complying with local laws, platform terms of service, and software licenses.
