// OSTLua — frontend (injected into Steam's webkit browser)
(function () {
  "use strict";

  var PLUGIN = "ostlua";
  var ACCENT = "#a06bff";

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
      ".hubcap-pin{display:flex;align-items:center;justify-content:space-between;gap:12px;border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:12px 14px;margin:2px 0 12px;background:rgba(255,255,255,.02);}",
      ".hubcap-pin .pi{display:flex;flex-direction:column;gap:6px;align-items:flex-start;}",
      ".hubcap-pin .pt{font:500 12px/1.4 'Motiva Sans';color:#9aa4b2;}",
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
          '<div class="hubcap-mid">current: ' + (dp.current || "not set") + (dp.frozen && dp.original ? '<br>original: ' + dp.original : '') + '</div>' +
          '<div class="hc-ver"></div>';
        host.appendChild(card);
        renderVersionPicker(card.querySelector(".hc-ver"), appid, dp, overlay);
      }

      // game-level update lock (OST pinApp) — stops the game updating at all
      var pinned = st.pinned === true;
      var pinBox = el('<div class="hubcap-pin"></div>');
      pinBox.innerHTML = '<div class="pi"><span class="hubcap-badge ' + (pinned ? "frozen" : "live") + '">' +
        (pinned ? "Pinned" : "Not pinned") + '</span><span class="pt">' +
        (pinned ? "Updates are blocked for this game." : "Lock this game so Steam won\'t update it (keeps the installed version).") +
        '</span></div>';
      var pinBtn = el('<button class="hubcap-btn ' + (pinned ? "r" : "p") + '">' + (pinned ? "Unpin" : "Pin (block updates)") + '</button>');
      pinBox.appendChild(pinBtn); host.appendChild(pinBox);
      pinBtn.addEventListener("click", function () {
        pinBtn.disabled = true;
        call(pinned ? "HubcapUnpin" : "HubcapPin", { appid: appid }).then(function (r) {
          if (r && r.success) { toast(r.message || (pinned ? "Unpinned" : "Pinned")); refresh(appid, overlay); }
          else { toast((r && r.error) || "Failed", false); pinBtn.disabled = false; }
        });
      });

      var foot = el('<div style="display:flex;justify-content:flex-end;margin-top:6px;"><button class="hubcap-btn r" id="hc-remove">Remove install</button></div>');
      host.appendChild(foot);
      foot.querySelector("#hc-remove").addEventListener("click", function () {
        call("HubcapRemove", { appid: appid }).then(function (r) {
          if (r && r.success) { toast("Removed"); refresh(appid, overlay); updateAllFabs(); } else toast((r && r.error) || "Failed", false);
        });
      });
    });
  }

  function applyManifest(appid, dp, id, overlay) {
    call("HubcapFreeze", { appid: appid, depotid: dp.depot, manifestid: id }).then(function (r) {
      if (r && r.success) toast(r.message || "Applied"); else toast((r && r.error) || "Failed", false);
      refresh(appid, overlay);
    });
  }
  function doRevert(appid, dp, overlay) {
    call("HubcapRevert", { appid: appid, depotid: dp.depot }).then(function (r) {
      if (r && r.success) toast("Reverted to original"); else toast((r && r.error) || "Failed", false);
      refresh(appid, overlay);
    });
  }

  function renderVersionPicker(host, appid, dp, overlay) {
    host.innerHTML = '<div class="hubcap-note2">Loading versions…</div>';
    call("HubcapGetManifests", { depot: dp.depot }).then(function (r) {
      var list = (r && r.manifests) || [];
      host.innerHTML = "";
      if (list.length > 0) {
        var bar = el('<div class="hubcap-in"></div>');
        var sel = document.createElement("select"); sel.className = "hubcap-select";
        sel.appendChild(new Option("— choose a version (" + list.length + ") —", ""));
        list.forEach(function (mm) { sel.appendChild(new Option(shortDate(mm.date) + "   —   " + mm.id, mm.id)); });
        var applyB = el('<button class="hubcap-btn p">Apply</button>');
        var reB = el('<button class="hubcap-btn g" title="Reload versions">&#x21bb;</button>');
        bar.appendChild(sel); bar.appendChild(reB); bar.appendChild(applyB);
        if (dp.frozen) { var rv = el('<button class="hubcap-btn r">Revert</button>'); bar.appendChild(rv); rv.onclick = function () { doRevert(appid, dp, overlay); }; }
        host.appendChild(bar);
        applyB.onclick = function () { if (!sel.value) { toast("Pick a version", false); return; } applyManifest(appid, dp, sel.value, overlay); };
        reB.onclick = function () { call("HubcapSaveManifests", { depot: dp.depot, manifests: [] }).then(function () { toast("Cleared — reload from SteamDB"); showSources(host, appid, dp, overlay); }); };
      } else {
        showSources(host, appid, dp, overlay);
      }
    });
  }

  function showSources(host, appid, dp, overlay) {
    host.innerHTML = "";
    var wrap = el('<div></div>');
    var autoB = el('<button class="hubcap-btn p wide">Load versions from SteamDB (auto)</button>');
    wrap.appendChild(autoB);
    var status = el('<div class="hubcap-note2" style="margin-top:10px"></div>'); wrap.appendChild(status);
    wrap.appendChild(el('<div class="hubcap-note2" style="margin-top:8px;opacity:.85">Auto opens SteamDB, copies the page and reads the versions. If it misses, open it yourself, press <b>Ctrl+A</b> then <b>Ctrl+C</b>, and click Grab:</div>'));
    var row1 = el('<div class="hubcap-in"></div>');
    var openB = el('<button class="hubcap-btn g">Open SteamDB &#8599;</button>');
    var grabB = el('<button class="hubcap-btn g">Grab clipboard</button>');
    row1.appendChild(openB); row1.appendChild(grabB); wrap.appendChild(row1);
    wrap.appendChild(el('<div class="hubcap-note2" style="margin-top:10px;opacity:.7">…or paste it here:</div>'));
    var ta = document.createElement("textarea"); ta.className = "hubcap-ta"; ta.placeholder = "Paste the copied SteamDB page here…"; wrap.appendChild(ta);
    var man = el('<div class="hubcap-in" style="margin-top:8px"><input placeholder="…or a single manifest ID" /><button class="hubcap-btn g">Apply</button></div>'); wrap.appendChild(man);
    if (dp.frozen) { var rv = el('<div style="margin-top:8px"><button class="hubcap-btn r">Revert to original</button></div>'); wrap.appendChild(rv); rv.querySelector("button").onclick = function () { doRevert(appid, dp, overlay); }; }
    host.appendChild(wrap);

    function useText(text) {
      var parsed = parseManifestText(text || "");
      if (parsed.length > 0) {
        status.textContent = "Found " + parsed.length + " versions — saving…";
        call("HubcapSaveManifests", { depot: dp.depot, manifests: parsed }).then(function () {
          toast("Loaded " + parsed.length + " versions"); renderVersionPicker(host, appid, dp, overlay);
        });
        return true;
      }
      return false;
    }
    function pollGrab(onDone) {
      var tries = 0;
      var iv = startPoll(function () {
        tries++;
        call("HubcapGrabResult", { depot: dp.depot }).then(function (r) {
          if (r && r.state === "done") {
            clearInterval(iv);
            var okk = useText(r.text);
            if (!okk) status.textContent = "No versions on the clipboard — copy the SteamDB page, or paste below.";
            if (onDone) onDone(okk);
          } else if (tries > 40) { clearInterval(iv); status.textContent = "Timed out reading clipboard."; if (onDone) onDone(false); }
        });
      }, 400);
    }
    function openDb() {
      try { return window.open("https://steamdb.info/depot/" + dp.depot + "/manifests/", "_blank"); }
      catch (e) { call("HubcapOpenUrl", { url: "https://steamdb.info/depot/" + dp.depot + "/manifests/" }); return null; }
    }

    autoB.onclick = function () {
      toast("Opening SteamDB…");
      var w = openDb();
      status.textContent = "Copying versions from SteamDB…";
      setTimeout(function () {
        call("HubcapGrabClipboard", { depot: dp.depot, auto: true }).then(function () {
          pollGrab(function () { try { if (w) w.close(); } catch (e) {} });   // backup close
        });
      }, 400);
    };
    openB.onclick = openDb;
    grabB.onclick = function () {
      status.textContent = "Reading clipboard…";
      call("HubcapGrabClipboard", { depot: dp.depot, auto: false }).then(function () { pollGrab(); });
    };
    man.querySelector("button").onclick = function () {
      var id = (man.querySelector("input").value || "").replace(/[^0-9]/g, "");
      if (!id) { toast("Enter a manifest ID", false); return; }
      applyManifest(appid, dp, id, overlay);
    };
    ta.addEventListener("input", function () { setTimeout(function () { if (ta.value.trim() && !useText(ta.value)) status.textContent = "No manifest IDs found in that text."; }, 60); });
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
    function done(msg, ok) { toast(msg, ok !== false); if (qbtn) { qbtn.classList.remove("busy"); qbtn.querySelector("span").textContent = "Quick Install"; } }
    if (qbtn) { qbtn.classList.add("busy"); qbtn.querySelector("span").textContent = "Downloading…"; }
    toast("Quick Install: downloading lua + manifests…");
    call("HubcapInstall", { appid: appid }).then(function (r) {
      if (!r || !r.success) { done((r && r.error) || "Couldn't start install", false); return; }
      var tries = 0;
      var poll = startPoll(function () {
        tries++;
        call("HubcapInstallStatus", { appid: appid }).then(function (s) {
          if (s && s.state === "done") {
            clearInterval(poll);
            if (!s.success) { done(s.error || "Install failed", false); return; }
            updateAllFabs();
            if (qbtn) qbtn.querySelector("span").textContent = "Fetching versions…";
            toast("Installed from " + (s.source || "?") + " — fetching versions…");
            call("HubcapStatus", { appid: appid }).then(function (st) {
              var depot = st && st.depot && st.depot.depot;
              if (!depot) { done("Installed, but no main depot found in the lua", false); return; }
              var w;
              try { w = window.open("https://steamdb.info/depot/" + depot + "/manifests/", "_blank"); }
              catch (e) { call("HubcapOpenUrl", { url: "https://steamdb.info/depot/" + depot + "/manifests/" }); }
              setTimeout(function () {
                call("HubcapGrabClipboard", { depot: depot, auto: true }).then(function () {
                  var gt = 0;
                  var iv = startPoll(function () {
                    gt++;
                    call("HubcapGrabResult", { depot: depot }).then(function (g) {
                      if (g && g.state === "done") {
                        clearInterval(iv);
                        try { if (w) w.close(); } catch (e) {}
                        var parsed = parseManifestText(g.text || "");
                        if (parsed.length > 0) {
                          call("HubcapSaveManifests", { depot: depot, manifests: parsed }).then(function () {
                            done("Quick Install done — " + parsed.length + " versions loaded");
                          });
                        } else { done("Installed, but couldn't read versions — open OSTLua to load them", false); }
                      } else if (gt > 40) { clearInterval(iv); try { if (w) w.close(); } catch (e) {} done("Installed — version fetch timed out, open OSTLua to retry", false); }
                    });
                  }, 400);
                });
              }, 400);
            });
          } else if (tries > 100) { clearInterval(poll); done("Install timed out — check your API key / source", false); }
        });
      }, 1200);
    });
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

  var lastUrl = "";
  function tick() {
    if (location.href !== lastUrl) { lastUrl = location.href; stopPolls(); setTimeout(function () { ensureFab(); updateAllFabs(); }, 400); }
    else ensureFab();
  }
  setInterval(tick, 1500);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", tick); else tick();
})();
