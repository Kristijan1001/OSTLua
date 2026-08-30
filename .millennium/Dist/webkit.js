// OSTLua — frontend (injected into Steam's webkit browser)
(function () {
  "use strict";

  var PLUGIN = "ostlua";
  var ACCENT = "#a06bff";

  var ACCEPT_BUILDS = "patchnotes/\\d{7,10}";

  function call(method, args) {
    return new Promise(function (resolve) {
      try {
        if (typeof Millennium === "undefined" || !Millennium.callServerMethod) { resolve(null); return; }
        Millennium.callServerMethod(PLUGIN, method, { contentScriptQuery: "", payload: JSON.stringify(args || {}) })
          .then(function (r) { try { resolve(typeof r === "string" ? JSON.parse(r) : r); } catch (e) { resolve(null); } })
          .catch(function () { resolve(null); });
      } catch (e) { resolve(null); }
    });
  }

  // extract {date,id} pairs from arbitrary text (scraped rows OR pasted page).
  // Works even when a date and its id land on different lines: each id is paired
  // with the nearest date that appears before it (within a small window).
  function parseManifestText(text) {
    text = text || "";
    var dates = [], m;
    var dre = /(\d{1,2}\s+[A-Za-z]{3,}\s+\d{4})/g;            // "12 June 2026"
    while ((m = dre.exec(text)) !== null) dates.push({ pos: m.index, val: m[1] });
    var out = [], seen = {}, im;
    var ire = /(\d{12,})/g;                                    // manifest id = 12+ digit run
    while ((im = ire.exec(text)) !== null) {
      var id = im[1]; if (seen[id]) continue; seen[id] = 1;
      var d = "";
      for (var i = dates.length - 1; i >= 0; i--) {
        if (dates[i].pos < im.index && (im.index - dates[i].pos) < 400) { d = dates[i].val; break; }
      }
      out.push({ date: d, id: id });
    }
    return out;
  }

  // ── SteamDB scraper: runs when this JS is injected on a steamdb depot page ──
  function trySteamDbScrape() {
    if ((location.hostname || "").indexOf("steamdb.info") < 0) return false;
    var m = location.pathname.match(/\/depot\/(\d+)\/manifests/);
    if (!m) return false;
    var depot = m[1];
    var tries = 0;
    var iv = setInterval(function () {
      tries++;
      var lines = [];
      document.querySelectorAll("tr[data-branch]").forEach(function (tr) {
        if (tr.getAttribute("data-branch") === "public") lines.push(tr.textContent || "");
      });
      var out = parseManifestText(lines.join("\n"));
      if (out.length > 0) {
        clearInterval(iv);
        try { if (window.opener) window.opener.postMessage({ __hubcap: "manifests", depot: depot, manifests: out }, "*"); } catch (e) {}
        try { call("HubcapSaveManifests", { depot: depot, manifests: out }); } catch (e) {}
        setTimeout(function () { try { window.close(); } catch (e) {} }, 800);
      } else if (tries > 40) { clearInterval(iv); }   // ~28s to clear Cloudflare
    }, 700);
    return true;
  }
  if (trySteamDbScrape()) return;   // steamdb page: scrape only, no FAB

  if (window.__HubcapFreezeLoaded) return;
  window.__HubcapFreezeLoaded = true;

  // Active polling intervals. Cancelled on dialog close / navigation so an
  // abandoned install/grab loop can't keep hammering the backend.
  var _polls = [];
  function startPoll(fn, ms) { var id = setInterval(fn, ms); _polls.push(id); return id; }
  function stopPolls() { for (var i = 0; i < _polls.length; i++) clearInterval(_polls[i]); _polls = []; }

  // Receive scraped manifests postMessage'd from a steamdb tab we opened.
  // Registered AFTER the guard so re-injection into the same page context
  // can't stack duplicate listeners.
  window.addEventListener("message", function (ev) {
    var d = ev && ev.data;
    if (!d || d.__hubcap !== "manifests" || !d.depot) return;
    call("HubcapSaveManifests", { depot: d.depot, manifests: d.manifests || [] });
    if (window.__hubcapOnManifests) { try { window.__hubcapOnManifests(String(d.depot), d.manifests || []); } catch (e) {} }
  });

  function getAppId() {
    var m = location.href.match(/store\.steampowered\.com\/app\/(\d+)/) ||
            location.href.match(/steamcommunity\.com\/app\/(\d+)/);
    return m ? m[1] : null;
  }
  function getGameName() {
    try {
      var e = document.querySelector("#appHubAppName, .apphub_AppName");
      if (e && e.textContent.trim()) return e.textContent.trim();
      var t = (document.title || "").replace(/\s+on Steam.*$/i, "").replace(/^Save .* on /, "").trim();
      if (t && t.toLowerCase() !== "steam") return t;
    } catch (e) {}
    return null;
  }
  function detectDenuvo() {
    try {
      var nodes = document.querySelectorAll(".DRM_notice, #game_area_purchase, .game_area_description, .game_area_details_specs_ctn, .game_area_dlc_bubble");
      for (var i = 0; i < nodes.length; i++) if (/denuvo/i.test(nodes[i].textContent || "")) return true;
    } catch (e) {}
    return false;
  }
  function shortDate(d) {
    if (!d) return "";
    var m = d.match(/(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})/);
    return m ? (m[1] + " " + m[2].slice(0, 3) + " " + m[3]) : String(d).split("–")[0].trim();
  }

  function injectStyles() {
    if (document.getElementById("hubcap-styles")) return;
    var s = document.createElement("style");
    s.id = "hubcap-styles";
    s.textContent = [
      ".hubcap-fab{position:fixed;right:20px;top:134px;z-index:99998;display:flex;align-items:center;gap:9px;padding:11px 16px;border-radius:30px;background:linear-gradient(135deg," + ACCENT + ",#6a3fd0);color:#fff;font:600 13px/1 'Motiva Sans',Arial,sans-serif;cursor:pointer;border:none;box-shadow:0 6px 22px rgba(0,0,0,.5),0 0 0 1px rgba(255,255,255,.08);transition:transform .15s,box-shadow .15s;}",
      ".hubcap-fab:hover{transform:translateY(-2px);box-shadow:0 10px 28px rgba(0,0,0,.6),0 0 0 1px rgba(160,107,255,.5);}",
      ".hubcap-fab svg{width:16px;height:16px;fill:#fff;}",
      ".hubcap-fab .st{font:700 10px/1;letter-spacing:.4px;text-transform:uppercase;padding:3px 7px;border-radius:20px;background:rgba(0,0,0,.28);}",
      ".hubcap-fab .st.on{background:rgba(92,184,92,.9);}.hubcap-fab .st.off{background:rgba(0,0,0,.32);}",
      ".hubcap-qfab{position:fixed;right:20px;top:182px;z-index:99998;display:flex;align-items:center;gap:8px;padding:10px 15px;border-radius:30px;background:linear-gradient(135deg,#2fb36b,#1c8a52);color:#fff;font:600 12px/1 'Motiva Sans',Arial,sans-serif;cursor:pointer;border:none;box-shadow:0 6px 22px rgba(0,0,0,.5),0 0 0 1px rgba(255,255,255,.08);transition:transform .15s,box-shadow .15s;}",
      ".hubcap-qfab:hover{transform:translateY(-2px);box-shadow:0 10px 28px rgba(0,0,0,.6),0 0 0 1px rgba(47,179,107,.55);}",
      ".hubcap-qfab svg{width:15px;height:15px;fill:#fff;}",
      ".hubcap-qfab.busy{opacity:.6;pointer-events:none;}",
      ".hubcap-denuvo-fab{position:fixed;right:20px;top:100px;z-index:99998;background:rgba(255,176,32,.96);color:#241700;font:800 11px/1 'Motiva Sans';letter-spacing:.3px;padding:6px 12px;border-radius:14px;box-shadow:0 4px 14px rgba(0,0,0,.45);}",
      ".hubcap-overlay{position:fixed;inset:0;z-index:99999;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.72);backdrop-filter:blur(10px);}",
      ".hubcap-modal{width:600px;max-width:92vw;max-height:88vh;display:flex;flex-direction:column;border-radius:16px;background:#15171d;color:#dfe3ea;border:1px solid rgba(255,255,255,.08);box-shadow:0 24px 80px rgba(0,0,0,.7);animation:hubcapUp .14s ease-out;}",
      "@keyframes hubcapUp{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}",
      ".hubcap-hd{display:flex;align-items:center;gap:10px;padding:18px 22px;border-bottom:1px solid rgba(255,255,255,.07);flex:0 0 auto;}",
      ".hubcap-hd .t{font:700 17px/1 'Motiva Sans',Arial;}.hubcap-hd .dot{width:9px;height:9px;border-radius:50%;background:" + ACCENT + ";box-shadow:0 0 10px " + ACCENT + ";}.hubcap-hd .sp{flex:1;}",
      ".hubcap-statebadge{font:700 10px/1;letter-spacing:.5px;text-transform:uppercase;padding:5px 10px;border-radius:20px;}",
      ".hubcap-statebadge.on{background:rgba(92,184,92,.16);color:#5cb85c;border:1px solid rgba(92,184,92,.4);}",
      ".hubcap-statebadge.off{background:rgba(255,255,255,.08);color:#9aa4b2;border:1px solid rgba(255,255,255,.14);}",
      ".hubcap-x{cursor:pointer;opacity:.6;font-size:20px;line-height:1;padding:2px 6px;border-radius:6px;margin-left:4px;}.hubcap-x:hover{opacity:1;background:rgba(255,255,255,.08);}",
      ".hubcap-body{padding:18px 22px;overflow:auto;flex:1 1 auto;}",
      ".hubcap-key{display:flex;align-items:center;gap:8px;background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.08);border-radius:10px;padding:10px 12px;margin-bottom:14px;font:500 12px/1.3 'Motiva Sans';color:#9aa4b2;}",
      ".hubcap-key .k{font-family:monospace;color:#cfd6e0;}.hubcap-key .usage{flex:1;color:#7fb2ff;font:600 11px/1;}",
      ".hubcap-key input{flex:1;background:#0e0f13;border:1px solid rgba(255,255,255,.12);border-radius:8px;color:#fff;padding:8px 10px;font:500 12px/1 monospace;outline:none;}.hubcap-key input:focus{border-color:" + ACCENT + ";}",
      ".hubcap-denuvo{display:flex;gap:9px;align-items:flex-start;background:rgba(255,176,32,.09);border:1px solid rgba(255,176,32,.32);color:#ffc861;border-radius:10px;padding:11px 13px;margin-bottom:14px;font:600 12px/1.45 'Motiva Sans';}",
      ".hubcap-install{display:flex;flex-direction:column;align-items:center;gap:14px;padding:20px 10px 8px;text-align:center;}",
      ".hubcap-install .hc-shield{width:50px;height:50px;opacity:.9;}.hubcap-install .msg{font:500 13px/1.55 'Motiva Sans';color:#aab2bf;max-width:430px;}",
      ".hubcap-depot{border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:14px 16px;margin-bottom:14px;background:rgba(255,255,255,.02);}",
      ".hubcap-migrate{position:fixed;right:20px;bottom:20px;z-index:99999;width:390px;max-width:calc(100vw - 40px);background:#1b2129;border:1px solid rgba(160,107,255,.45);border-radius:14px;padding:16px 18px;box-shadow:0 14px 40px rgba(0,0,0,.6);font:400 13px/1.55 'Motiva Sans',Arial,sans-serif;color:#c7cdd6;}",
      ".hubcap-migrate .mt{font:700 14px/1.3 'Motiva Sans';color:#fff;margin-bottom:7px;}",
      ".hubcap-migrate .mm{color:#9aa4b2;font-size:12.5px;}",
      ".hubcap-migrate .mm code{background:rgba(255,255,255,.07);padding:1px 5px;border-radius:4px;color:#c9b6ff;font-size:11.5px;}",
      ".hubcap-migrate .mw{color:#e0b055;font-size:11.5px;}",
      ".hubcap-migrate .mr{display:flex;gap:9px;justify-content:flex-end;margin-top:13px;}",
      ".hubcap-src{display:flex;align-items:center;gap:10px;flex-wrap:wrap;background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.08);border-radius:10px;padding:9px 12px;margin-bottom:14px;font:500 12px/1.3 'Motiva Sans';color:#9aa4b2;}",
      ".hubcap-src .lbl{font-weight:700;color:#c7cdd6;}",
      ".hubcap-select.sm{padding:5px 8px;font-size:12px;}",
      ".hubcap-chk{display:flex;align-items:center;gap:6px;cursor:pointer;margin-left:auto;}",
      ".hubcap-chk input{accent-color:" + ACCENT + ";cursor:pointer;}",
      ".hubcap-depot .row{display:flex;align-items:center;gap:10px;margin-bottom:10px;}.hubcap-depot .did{font:700 14px/1.1 'Motiva Sans';}",
      ".hubcap-badge{font:700 10px/1;letter-spacing:.5px;text-transform:uppercase;padding:4px 8px;border-radius:20px;}",
      ".hubcap-badge.frozen{background:rgba(160,107,255,.18);color:" + ACCENT + ";border:1px solid rgba(160,107,255,.4);}",
      ".hubcap-badge.live{background:rgba(92,184,92,.15);color:#5cb85c;border:1px solid rgba(92,184,92,.35);}",
      ".hubcap-mid{font:500 12px/1.5 monospace;color:#9aa4b2;word-break:break-all;margin-bottom:6px;}",
      ".hubcap-note2{font:500 12px/1.5 'Motiva Sans';color:#8b95a3;margin:4px 0 8px;}",
      ".hubcap-in{display:flex;gap:8px;margin-top:8px;}",
      ".hubcap-in input,.hubcap-select{flex:1;background:#0e0f13;border:1px solid rgba(255,255,255,.12);border-radius:8px;color:#fff;padding:9px 11px;font:500 13px/1 monospace;outline:none;min-width:0;}",
      ".hubcap-select{font-family:'Motiva Sans',monospace;}.hubcap-in input:focus,.hubcap-select:focus{border-color:" + ACCENT + ";}",
      ".hubcap-ta{width:100%;box-sizing:border-box;height:88px;margin-top:8px;background:#0e0f13;border:1px solid rgba(255,255,255,.12);border-radius:8px;color:#fff;padding:9px 11px;font:500 12px/1.4 monospace;outline:none;resize:vertical;}.hubcap-ta:focus{border-color:" + ACCENT + ";}",
      ".hubcap-btn{border:none;border-radius:8px;padding:9px 14px;font:700 12px/1 'Motiva Sans';cursor:pointer;color:#fff;white-space:nowrap;}",
      ".hubcap-btn.wide{padding:12px 26px;font-size:13px;border-radius:9px;}",
      ".hubcap-btn.p{background:" + ACCENT + ";}.hubcap-btn.p:hover{background:#8f57f0;}",
      ".hubcap-btn.g{background:rgba(255,255,255,.09);}.hubcap-btn.g:hover{background:rgba(255,255,255,.16);}",
      ".hubcap-btn.r{background:rgba(200,70,70,.85);}.hubcap-btn.r:hover{background:rgba(220,80,80,1);}",
      ".hubcap-btn:disabled{opacity:.45;cursor:default;}",
      ".hubcap-note{font:500 12px/1.5 'Motiva Sans';color:#8b95a3;margin:2px 0 14px;}",
      ".hubcap-foot{display:flex;align-items:center;gap:12px;padding:14px 22px;border-top:1px solid rgba(255,255,255,.07);flex:0 0 auto;}.hubcap-foot .hint{flex:1;font:500 11px/1.4 'Motiva Sans';color:#7b8492;}",
      ".hubcap-toast{position:fixed;bottom:78px;right:20px;z-index:100000;background:#1b1e26;color:#fff;padding:12px 16px;border-radius:10px;border:1px solid rgba(160,107,255,.4);box-shadow:0 8px 24px rgba(0,0,0,.5);font:600 13px/1.3 'Motiva Sans';max-width:340px;animation:hubcapUp .14s ease-out;}"
    ].join("");
    document.head.appendChild(s);
  }

  function toast(msg, ok) {
    var t = document.createElement("div"); t.className = "hubcap-toast";
    t.style.borderColor = ok === false ? "rgba(200,70,70,.6)" : "rgba(160,107,255,.4)";
    t.textContent = msg; document.body.appendChild(t);
    setTimeout(function () { t.style.transition = "opacity .3s"; t.style.opacity = "0"; setTimeout(function () { t.remove(); }, 300); }, 2800);
  }
  function el(h) { var d = document.createElement("div"); d.innerHTML = h; return d.firstElementChild; }
  function closeDialog() { stopPolls(); var o = document.querySelector(".hubcap-overlay"); if (o) o.remove(); }

  function openDialog() {
    var appid = getAppId(); if (!appid) return;
    injectStyles(); closeDialog();
    var overlay = document.createElement("div");
    overlay.className = "hubcap-overlay";
    overlay.addEventListener("click", function (e) { if (e.target === overlay) closeDialog(); });
    overlay.innerHTML =
      '<div class="hubcap-modal">' +
      '  <div class="hubcap-hd"><span class="dot"></span><span class="t">OSTLua</span><span class="sp"></span>' +
      '     <span class="hubcap-statebadge off" id="hc-state">…</span><span class="hubcap-x">&times;</span></div>' +
      '  <div class="hubcap-body"><div id="hc-key"></div><div id="hc-src"></div><div id="hc-denuvo"></div><div class="hubcap-content">Loading…</div></div>' +
      '  <div class="hubcap-foot"><span class="hint">Changes apply live — no restart needed. Restart only if Steam looks stuck.</span>' +
      '     <button class="hubcap-btn g" id="hc-restart">&#x21bb; Restart Steam</button></div>' +
      '</div>';
    document.body.appendChild(overlay);
    overlay.querySelector(".hubcap-x").addEventListener("click", closeDialog);
    overlay.querySelector("#hc-restart").addEventListener("click", function () {
      this.disabled = true; this.textContent = "Restarting…";
      call("HubcapRestartSteam", {}).then(function () { toast("Steam is restarting…"); });
    });
    if (detectDenuvo()) {
      overlay.querySelector("#hc-denuvo").appendChild(el(
        '<div class="hubcap-denuvo"><span>&#9888;</span><span><b>Denuvo Anti-Tamper detected.</b> ' +
        'Downgrading or freezing a Denuvo game burns activations — proceed carefully.</span></div>'));
    }
    renderKeyRow(overlay.querySelector("#hc-key"));
    renderSourceRow(overlay.querySelector("#hc-src"));
    refresh(appid, overlay);
  }

  // Source picker + fallback toggle. Persists to config; both the Install button
  // and the Quick Install FAB obey the saved choice.
  function renderSourceRow(host) {
    call("HubcapGetConfig", {}).then(function (c) {
      host.innerHTML = "";
      var sources = (c && c.sources) || [];
      if (!sources.length) return;
      var main = (c && c.mainSource) || "hubcap";
      var fb = !!(c && c.fallback);
      var row = el('<div class="hubcap-src"><span class="lbl">Source</span></div>');
      var sel = document.createElement("select"); sel.className = "hubcap-select sm";
      sources.forEach(function (s) {
        var suffix = s.id === "hubcap" ? " [Recommended] (Needs API Key)" : (s.keyed ? " (Needs API Key)" : "");
        var o = new Option(s.name + suffix, s.id);
        if (s.id === main) o.selected = true;
        sel.appendChild(o);
      });
      row.appendChild(sel);
      var lab = el('<label class="hubcap-chk"><input type="checkbox"' + (fb ? " checked" : "") +
        ' /><span>Fall back to other sources</span></label>');
      row.appendChild(lab);
      host.appendChild(row);
      function save() {
        call("HubcapSetSourcePrefs", { mainSource: sel.value, fallback: lab.querySelector("input").checked })
          .then(function () { toast("Source: " + sel.options[sel.selectedIndex].text.replace(/ \[Recommended\]| \(Needs API Key\)/g, "") + (lab.querySelector("input").checked ? " + fallback" : "")); });
      }
      sel.addEventListener("change", save);
      lab.querySelector("input").addEventListener("change", save);
    });
  }

  function renderKeyRow(host) {
    call("HubcapGetConfig", {}).then(function (c) {
      host.innerHTML = "";
      if (c && c.hasKey) {
        var row = el('<div class="hubcap-key"><span>Hubcap API Key</span><span class="k">' + (c.apiKeyMasked || "(set)") +
          '</span><span class="usage" id="hc-usage"></span><button class="hubcap-btn g" id="hc-chg">Change</button></div>');
        host.appendChild(row);
        row.querySelector("#hc-chg").addEventListener("click", function () { editKey(host); });
        call("HubcapUsage", {}).then(function (u) {
          var us = row.querySelector("#hc-usage");
          if (!us) return;
          if (u && u.success && u.dailyLimit) {
            var left = u.dailyLimit - (u.dailyUsage || 0);
            if (left < 0) left = 0;
            us.textContent = left + " / " + u.dailyLimit + " downloads left today";
          } else if (u && u.exhausted) {
            us.textContent = "0 downloads left today (quota reached)";
          } else {
            us.textContent = "usage unavailable";
          }
        });
      } else { editKey(host, true); }
    });
  }
  function editKey(host, needed) {
    host.innerHTML = "";
    var row = el('<div class="hubcap-key">' + (needed ? '<span style="color:#ff7bd1">Hubcap API Key needed:</span>' : '<span>Hubcap API Key</span>') +
      '<input type="text" placeholder="smm_..." /><button class="hubcap-btn p" id="hc-save">Save</button>' +
      (needed ? '' : '<button class="hubcap-btn g" id="hc-cancel">Cancel</button>') + '</div>');
    host.appendChild(row);
    row.querySelector("#hc-save").addEventListener("click", function () {
      var v = (row.querySelector("input").value || "").trim();
      call("HubcapSetApiKey", { apiKey: v }).then(function (r) {
        if (r && r.success) { toast(v ? "Hubcap API Key saved" : "Hubcap API Key cleared"); renderKeyRow(host); } else toast("Save failed", false);
      });
    });
    var cx = row.querySelector("#hc-cancel");
    if (cx) cx.addEventListener("click", function () { renderKeyRow(host); });
  }

  function setState(overlay, installed) {
    var b = overlay.querySelector("#hc-state"); if (!b) return;
    b.textContent = installed ? "Installed" : "Not Installed";
    b.className = "hubcap-statebadge " + (installed ? "on" : "off");
  }

  function refresh(appid, overlay) {
    var host = overlay.querySelector(".hubcap-content");
    host.textContent = "Loading…";
    call("HubcapStatus", { appid: appid }).then(function (st) {
      host.innerHTML = "";
      if (!st || !st.success) { host.innerHTML = '<div class="hubcap-note">Backend not reachable — restart Steam.</div>'; setState(overlay, false); return; }
      setState(overlay, st.installed === true);

      if (!st.installed) {
        var box = el('<div class="hubcap-install"></div>');
        box.appendChild(el('<svg class="hc-shield" viewBox="0 0 24 24" fill="' + ACCENT + '"><path d="M12 2 4 6v6c0 5 3.4 8.5 8 10 4.6-1.5 8-5 8-10V6l-8-4zm0 5 4 2v3c0 2.8-1.7 4.9-4 5.8-2.3-.9-4-3-4-5.8V9l4-2z"/></svg>'));
        box.appendChild(el('<div class="msg">This game has no manifest set up on this PC.<br><b>Install</b> grabs its lua + depot manifests so the game can download — then you can freeze or downgrade it.</div>'));
        var ib = el('<button class="hubcap-btn p wide">Install</button>');
        box.appendChild(ib); host.appendChild(box);
        ib.addEventListener("click", function () {
          ib.disabled = true; ib.textContent = "Downloading…";
          function fail(m) { toast(m, false); ib.disabled = false; ib.textContent = "Install"; }
          call("HubcapInstall", { appid: appid }).then(function (r) {
            if (!r || !r.success) { fail((r && r.error) || "Couldn't start install"); return; }
            var tries = 0;
            var poll = startPoll(function () {
              tries++;
              call("HubcapInstallStatus", { appid: appid }).then(function (s) {
                if (s && s.state === "done") { clearInterval(poll); if (s.success) { toast("Installed from " + (s.source || "?")); refresh(appid, overlay); updateAllFabs(); } else fail(s.error || "Install failed"); }
                else if (tries > 100) { clearInterval(poll); fail("Install timed out — check your API key / source"); }
              });
            }, 1200);
          });
        });
        return;
      }

      // installed — show ONLY the main game depot
      var gameName = getGameName();
      var dp = st.depot;
      if (!dp) { host.appendChild(el('<div class="hubcap-note">Installed, but no main depot found in the lua.</div>')); }
      else {
        host.appendChild(el('<div class="hubcap-note">Pick a version to freeze / downgrade the main game.</div>'));
        var card = el('<div class="hubcap-depot"></div>');
        var title = gameName ? (gameName + '  ·  depot ' + dp.depot) : ('Depot ' + dp.depot);
        card.innerHTML = '<div class="row"><span class="did">' + title + '</span>' +
          '<span class="hubcap-badge ' + (dp.frozen ? "frozen" : "live") + '">' + (dp.frozen ? "Frozen" : "Live") + '</span></div>' +
          '<div class="hubcap-mid">current: ' + (dp.current || "not set") +
            (st.build ? '  \u00b7  build ' + st.build + (st.buildDate ? ' \u00b7 ' + shortDate(st.buildDate) : '') : '') +
            (dp.frozen && dp.original ? '<br>original: ' + dp.original : '') + '</div>' +
          '<div class="hc-ver"></div>';
        host.appendChild(card);
        renderVersionPicker(card.querySelector(".hc-ver"), appid, dp, overlay);
      }

      var foot = el('<div style="display:flex;justify-content:flex-end;margin-top:6px;"><button class="hubcap-btn r" id="hc-remove">Remove install</button></div>');
      host.appendChild(foot);
      foot.querySelector("#hc-remove").addEventListener("click", function () {
        call("HubcapRemove", { appid: appid }).then(function (r) {
          if (r && r.success) { toast("Removed"); refresh(appid, overlay); updateAllFabs(); } else toast((r && r.error) || "Failed", false);
        });
      });
    });
  }

  // ── SteamDB build pages ────────────────────────────────────────────────────
  // Two pages replace the old per-depot scraping:
  //   app/<appid>/patchnotes/   -> every build:  date + BuildID
  //   patchnotes/<buildid>/     -> that build's depots + their new manifest
  // One build page pins the whole game, so there is no per-depot tab juggling
  // and no dropdown with 400 manifest rows.

  // Build list -> [{date, build}].
  //
  // The whole app page is in the clipboard, not just the builds table: the
  // header carries the store Release Date, and other tabs link builds too
  // (branches table, tested_build_id). Pairing "nearest date before the link"
  // across that soup shifted every row by one. So scope to a single <tr>: a row
  // holds exactly one build and one date. Prefer the ISO datetime attribute,
  // which is exact, over the rendered prose.
  var MONTH_NAMES = ["January","February","March","April","May","June",
                     "July","August","September","October","November","December"];

  function isoToPretty(y, m, d) {
    var name = MONTH_NAMES[parseInt(m, 10) - 1] || m;
    return parseInt(d, 10) + " " + name + " " + y;
  }

  // "13 March 2026" -> 20260313, for sorting newest first
  function dateKey(str) {
    var m = String(str || "").match(/(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})/);
    if (!m) return 0;
    var mi = -1;
    for (var i = 0; i < MONTH_NAMES.length; i++) {
      if (MONTH_NAMES[i].toLowerCase().indexOf(m[2].toLowerCase()) === 0) { mi = i + 1; break; }
    }
    if (mi < 0) return 0;
    return parseInt(m[3], 10) * 10000 + mi * 100 + parseInt(m[1], 10);
  }

  function parseBuildList(text, excludeId) {
    text = text || "";
    var out = [], seen = {};

    if (/<tr[\s>]/i.test(text)) {
      // A build can appear in more than one table - the Depots tab's branches
      // row links the current build too, dated by when it was BUILT rather than
      // released. The Builds table comes later in the page, so let a later row
      // win, then sort newest first so page order stops mattering at all.
      var byId = {};
      text.split(/<tr[\s>]/i).forEach(function (row) {
        var idm = row.match(/patchnotes\/(\d{6,10})\//);
        if (!idm) return;
        var id = idm[1];
        if (id === String(excludeId)) return;

        var date = "";
        var iso = row.match(/datetime="(\d{4})-(\d{2})-(\d{2})/);
        if (iso) date = isoToPretty(iso[1], iso[2], iso[3]);
        else {
          var pm = row.match(/(\d{1,2}\s+[A-Za-z]{3,}\s+\d{4})/);
          if (pm) date = pm[1];
        }
        if (!date) return;          // no date in this row -> not a build row
        byId[id] = date;            // later row overwrites earlier
      });

      Object.keys(byId).forEach(function (id) { out.push({ date: byId[id], build: id }); });
      if (out.length) {
        out.sort(function (a, b) { return dateKey(b.date) - dateKey(a.date); });
        return out;
      }
    }

    // text flavor: "13 March 2026  Fri  05:16  No title  22277314"
    text.split(/\r?\n/).forEach(function (L) {
      var d = L.match(/(\d{1,2}\s+[A-Za-z]{3,}\s+\d{4})/);
      if (!d) return;
      var ids = L.match(/\b\d{7,10}\b/g);
      if (!ids) return;
      var b = ids[ids.length - 1];
      if (b === String(excludeId) || seen[b]) return;
      seen[b] = 1;
      out.push({ date: d[1], build: b });
    });
    return out;
  }

  // From a build page: the depots it changed and their NEW manifest.
  //
  // The clipboard's HTML flavor is ONE long line, so this has to scan the whole
  // blob with a global regex - matching per line only ever returned the first
  // depot, which is why applies reported "pinned 1 depot".
  //
  // Each depot heading links to ?changeid=M:<new manifest>. The "Manifest ID
  // changed" rows link the OLD id too, but the heading comes first and we keep
  // the first sighting, so the new one wins. Text flavor is the fallback: there
  // the ids only show up once a depot's file list has lazy-loaded.
  function parseBuildDepots(text) {
    text = text || "";
    var out = [], seen = {}, m;

    var re = /depot\/(\d{4,})\/history\/\?changeid=M:(\d{12,})/g;
    while ((m = re.exec(text)) !== null) {
      if (seen[m[1]]) continue;
      seen[m[1]] = 1;
      out.push({ depot: m[1], manifest: m[2] });
    }
    if (out.length) return out;

    // plain text: "Depot 3764201" … "Manifest ID changed - <old> > <new>"
    var cur = null;
    text.split(/\r?\n/).forEach(function (L) {
      var dm = L.match(/Depot[^\d]{0,4}(\d{4,})/);
      if (dm) { cur = dm[1]; return; }
      if (/Manifest ID changed/i.test(L)) {
        var ids = L.match(/\d{12,}/g);
        if (cur && ids && ids.length && !seen[cur]) {
          seen[cur] = 1;
          out.push({ depot: cur, manifest: ids[ids.length - 1] });
        }
        cur = null;
      }
    });
    return out;
  }

  // Clears the pins on every depot of this game (the backend walks them all,
  // since a build apply pins them together).
  function doRevert(appid, dp, overlay) {
    call("HubcapRevert", { appid: appid, depotid: dp.depot }).then(function (r) {
      if (r && r.success) toast(r.changed ? "Reverted to original" : "Nothing to revert");
      else toast((r && r.error) || "Failed", false);
      refresh(appid, overlay);
    });
  }

  // Opening a SteamDB tab only works from a real user gesture. From a timer
  // Steam silently refuses (window.open returns null rather than throwing), so
  // anything needing a page must open it on the click and read it later - which
  // is what Quick Install does while the lua downloads.
  function openSteamDb(url) {
    try { window.open(url, "_blank"); } catch (e) {}
  }

  // Read whichever SteamDB tab is open, matched by `title`. `key` namespaces the
  // helper's result file, `accept` is the regex it uses to know the copy worked.
  // The helper closes the tab when done.
  function readSteamDb(key, accept, title, waitMs, say, cb) {
    setTimeout(function () {
      if (say) say("Reading the page\u2026");
      call("HubcapGrabClipboard", { depot: key, auto: true, accept: accept, title: title }).then(function () {
        var tries = 0;
        var iv = startPoll(function () {
          tries++;
          call("HubcapGrabResult", { depot: key }).then(function (r) {
            if (r && r.state === "done") { clearInterval(iv); cb(r.text || ""); }
            else if (tries > 60)         { clearInterval(iv); cb(""); }
          });
        }, 400);
      });
    }, waitMs || 900);
  }

  // Open then read, for buttons that do both off one click.
  function grabSteamDb(url, key, accept, title, waitMs, say, cb) {
    openSteamDb(url);
    readSteamDb(key, accept, title, waitMs, say, cb);
  }

  function renderVersionPicker(host, appid, dp, overlay) {
    host.innerHTML = '<div class="hubcap-note2">Loading builds…</div>';
    call("HubcapGetBuilds", { appid: appid }).then(function (r) {
      var builds = (r && r.builds) || [];
      host.innerHTML = "";

      var status = el('<div class="hubcap-note2" style="margin-top:8px"></div>');
      function say(m) { status.textContent = m; }

      if (!builds.length) {
        var b0 = el('<button class="hubcap-btn p wide">Load builds from SteamDB</button>');
        host.appendChild(b0); host.appendChild(status);
        host.appendChild(el('<div class="hubcap-note2" style="margin-top:8px;opacity:.85">Reads the game\u2019s build list once. Then pick a build and hit Apply \u2014 OSTLua fetches that build\u2019s depot manifests at that moment and pins them all.</div>'));
        b0.onclick = function () {
          b0.disabled = true;
          say("Opening SteamDB build list\u2026");
          grabSteamDb("https://steamdb.info/app/" + appid + "/patchnotes/", appid,
                      ACCEPT_BUILDS, "Patches and Updates", 1500, say, function (text) {
            var list = parseBuildList(text, appid);
            if (!list.length) { say("Couldn\u2019t read the build list \u2014 make sure the SteamDB tab finished loading, then try again."); b0.disabled = false; return; }
            call("HubcapSaveBuilds", { appid: appid, builds: list }).then(function () {
              toast("Found " + list.length + " builds");
              renderVersionPicker(host, appid, dp, overlay);
            });
          });
        };
        return;
      }

      var bar = el('<div class="hubcap-in"></div>');
      var sel = document.createElement("select"); sel.className = "hubcap-select";
      sel.appendChild(new Option("\u2014 choose a build (" + builds.length + ") \u2014", ""));
      builds.forEach(function (b) {
        sel.appendChild(new Option(shortDate(b.date) + "   \u2014   build " + b.build, b.build));
      });
      var applyB = el('<button class="hubcap-btn p">Apply</button>');
      var reB = el('<button class="hubcap-btn g" title="Reload build list">&#x21bb;</button>');
      bar.appendChild(sel); bar.appendChild(reB); bar.appendChild(applyB);
      if (dp.frozen) {
        var rv = el('<button class="hubcap-btn r">Revert</button>');
        bar.appendChild(rv);
        rv.onclick = function () { doRevert(appid, dp, overlay); };
      }
      host.appendChild(bar); host.appendChild(status);
      host.appendChild(el('<div class="hubcap-note2" style="margin-top:8px;opacity:.8">Apply opens that build\u2019s SteamDB page, reads every depot\u2019s manifest from it, and pins them together.</div>'));

      reB.onclick = function () {
        call("HubcapSaveBuilds", { appid: appid, builds: [] }).then(function () {
          renderVersionPicker(host, appid, dp, overlay);
        });
      };

      applyB.onclick = function () {
        if (!sel.value) { toast("Pick a build", false); return; }
        var build = sel.value;
        var buildDate = "";
        for (var bi = 0; bi < builds.length; bi++)
          if (String(builds[bi].build) === String(build)) { buildDate = builds[bi].date; break; }
        applyB.disabled = true; sel.disabled = true;
        // the list tab may still be open; a second SteamDB window is exactly
        // what confused the window picker before
        try { if (window.__ostluaDbTab && !window.__ostluaDbTab.closed) window.__ostluaDbTab.close(); } catch (e) {}
        say("Opening build " + build + " on SteamDB\u2026");
        grabSteamDb("https://steamdb.info/patchnotes/" + build + "/", build,
                    "changeid=M:\\d+", "update for", 900, say, function (text) {
          var pins = parseBuildDepots(text);
          if (!pins.length) {
            say("Couldn\u2019t read that build page \u2014 open it yourself, Ctrl+A / Ctrl+C, then hit Apply again.");
            applyB.disabled = false; sel.disabled = false;
            return;
          }
          say("Pinning " + pins.length + " depot(s) from build " + build + "\u2026");
          call("HubcapFreezePins", { appid: appid, pins: pins, build: build,
                                     date: buildDate }).then(function (res) {
            applyB.disabled = false; sel.disabled = false;
            if (res && res.success) {
              // Every depot ends up pinned: some get a new manifest from this
              // build, the rest were already on the right one for it. Saying
              // "pinned 2 (+3 unchanged)" read like a partial failure.
              var n = (res.applied || []).length, c = (res.carried || []).length;
              var total = n + c;
              toast("Locked all " + total + " depots to build " + build +
                    (buildDate ? " (" + shortDate(buildDate) + ")" : "") +
                    " — " + n + " changed in this build");
              refresh(appid, overlay);
            } else {
              toast((res && res.error) || "Failed", false);
            }
          });
        });
      };
    });
  }

  function updateAllFabs() {
    var appid = getAppId(); if (!appid) return;
    var st = document.querySelector(".hubcap-fab .st"); if (!st) return;
    call("HubcapStatus", { appid: appid }).then(function (r) {
      var on = r && r.installed === true;
      st.textContent = on ? "Installed" : "Not installed";
      st.className = "st " + (on ? "on" : "off");
    });
  }

  // One-click: install the lua+manifests, then auto-open SteamDB for THIS game's
  // main depot and load its version list. Single game only — no bulk scraping.
  function quickInstall(appid, qbtn) {
    function label(t) { if (qbtn) qbtn.querySelector("span").textContent = t; }
    function done(msg, ok) { toast(msg, ok !== false); if (qbtn) { qbtn.classList.remove("busy"); label("Quick Install"); } }
    if (qbtn) qbtn.classList.add("busy");

    // Builds FIRST, lua second.
    //
    // Steam only honours window.open during a real click, so the SteamDB page
    // has to be opened from this handler - not from a callback after the
    // install. Doing the read up front means the window is only up for the
    // couple of seconds it takes to copy the page, instead of sitting there for
    // the whole download waiting to be closed by the user.
    label("Reading builds\u2026");
    toast("Quick Install: reading builds from SteamDB\u2026");

    grabSteamDb("https://steamdb.info/app/" + appid + "/patchnotes/", appid,
                ACCEPT_BUILDS, "Patches and Updates", 1500,
                function (m) { label(m); },
                function (text) {
      var list = parseBuildList(text, appid);
      if (list.length) {
        call("HubcapSaveBuilds", { appid: appid, builds: list });
      }
      installLua(list.length);
    });

    function installLua(buildCount) {
      label("Downloading\u2026");
      toast("Downloading lua + manifests\u2026");
      call("HubcapInstall", { appid: appid }).then(function (r) {
        if (!r || !r.success) { done((r && r.error) || "Couldn't start install", false); return; }
        var tries = 0;
        var poll = startPoll(function () {
          tries++;
          call("HubcapInstallStatus", { appid: appid }).then(function (st) {
            if (st && st.state === "done") {
              clearInterval(poll);
              if (!st.success) { done(st.error || "Install failed", false); return; }
              updateAllFabs();
              if (buildCount) {
                done("Quick Install done \u2014 " + buildCount + " builds loaded, pick one and Apply");
              } else {
                done("Installed from " + (st.source || "?") +
                     " \u2014 couldn't read builds, use Load builds in OSTLua", false);
              }
            } else if (tries > 100) {
              clearInterval(poll); done("Install timed out \u2014 check your API key / source", false);
            }
          });
        }, 1200);
      });
    }
  }

  function ensureFab() {
    if (!getAppId()) {
      var ex = document.querySelector(".hubcap-fab"); if (ex) ex.remove();
      var qx = document.querySelector(".hubcap-qfab"); if (qx) qx.remove();
      var db = document.querySelector(".hubcap-denuvo-fab"); if (db) db.remove();
      return;
    }
    if (document.querySelector(".hubcap-fab")) return;
    injectStyles();
    var b = document.createElement("button");
    b.className = "hubcap-fab";
    b.innerHTML = '<svg viewBox="0 0 24 24"><path d="M12 2 4 6v6c0 5 3.4 8.5 8 10 4.6-1.5 8-5 8-10V6l-8-4zm0 5 4 2v3c0 2.8-1.7 4.9-4 5.8-2.3-.9-4-3-4-5.8V9l4-2z"/></svg><span>OSTLua</span><span class="st off">…</span>';
    b.addEventListener("click", openDialog);
    document.body.appendChild(b);
    var q = document.createElement("button");
    q.className = "hubcap-qfab";
    q.innerHTML = '<svg viewBox="0 0 24 24"><path d="M13 2 3 14h7l-1 8 10-12h-7l1-8z"/></svg><span>Quick Install</span>';
    q.addEventListener("click", function () { var id = getAppId(); if (id) quickInstall(id, q); });
    document.body.appendChild(q);
    if (detectDenuvo() && !document.querySelector(".hubcap-denuvo-fab")) {
      var dv = document.createElement("div");
      dv.className = "hubcap-denuvo-fab";
      dv.textContent = "⚠ Denuvo game";
      document.body.appendChild(dv);
    }
    updateAllFabs();
  }

  // ── one-time move prompt: config/lua (OpenSteamTool) -> config/stplug-in ──
  // BetterSteamTools only reads config/stplug-in, so luas dropped by older
  // OSTLua builds are invisible to it. Ask once; nothing moves without a yes.
  var migrateAsked = false;
  function offerMigration() {
    if (migrateAsked) return;
    migrateAsked = true;
    call("HubcapMigrateStatus", {}).then(function (st) {
      if (!st || !st.success || st.dismissed || !st.pending) return;
      if (document.querySelector(".hubcap-migrate")) return;

      var n = st.pending;
      var box = el('<div class="hubcap-migrate"></div>');
      box.innerHTML =
        '<div class="mt">Move your luas to BetterSteamTools?</div>' +
        '<div class="mm">Found <b>' + n + '</b> lua file' + (n === 1 ? '' : 's') + ' in the old OpenSteamTool folder ' +
        '(<code>config\\lua</code>). BetterSteamTools only reads <code>config\\stplug-in</code>, ' +
        'so these games won\'t unlock until they\'re moved.' +
        (st.conflicts ? '<br><span class="mw">' + st.conflicts + ' already exist at the destination and will be left alone.</span>' : '') +
        '</div>';
      var row = el('<div class="mr"></div>');
      var yes = el('<button class="hubcap-btn p">Move ' + n + ' file' + (n === 1 ? '' : 's') + '</button>');
      var no  = el('<button class="hubcap-btn g">Not now</button>');
      row.appendChild(yes); row.appendChild(no); box.appendChild(row);
      document.body.appendChild(box);

      no.addEventListener("click", function () {
        box.remove();
        call("HubcapMigrateDismiss", {});
      });
      yes.addEventListener("click", function () {
        yes.disabled = true; no.disabled = true; yes.textContent = "Moving…";
        call("HubcapMigrateRun", {}).then(function (r) {
          box.remove();
          if (r && r.success) {
            toast("Moved " + r.moved + " lua" + (r.moved === 1 ? "" : "s") + " to stplug-in — restart Steam to apply");
            updateAllFabs();
          } else {
            toast((r && r.error) || "Move failed", false);
          }
        });
      });
    });
  }

  var lastUrl = "";
  function tick() {
    if (location.href !== lastUrl) { lastUrl = location.href; stopPolls(); setTimeout(function () { ensureFab(); updateAllFabs(); }, 400); }
    else ensureFab();
    offerMigration();
  }
  setInterval(tick, 1500);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", tick); else tick();
})();
