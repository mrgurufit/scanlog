/* First-visit privacy notice.

   The site sets no third-party cookies and runs no ad/tracking networks. It
   uses functional local storage (language, preferences) and a cookieless,
   fully-anonymous once-per-session visit counter (traffic.js). Israeli and EU
   privacy practice still asks that we DISCLOSE this and offer a real choice, so
   this shows a one-time notice with a genuine opt-out that traffic.js honors.

   Zero Make operations: this is pure DOM + localStorage. It never calls a
   webhook. Shown once; the choice is remembered per browser. */
(function () {
  "use strict";
  var LS = "mgf_analytics";           // "on" | "off"  (unset = not yet chosen)
  var lang = "en";
  try { lang = localStorage.getItem("mgf_lang") || "en"; } catch (e) {}

  var T = {
    he: { msg: "האתר משתמש באחסון מקומי לתפעול ובמונה ביקורים אנונימי לחלוטין — ללא קוקיז וללא מעקב. ",
          more: "פרטים", ok: "אישור", no: "ללא אנליטיקס" },
    en: { msg: "This site uses functional local storage and a fully anonymous, cookieless visit counter — no cookies, no tracking. ",
          more: "Details", ok: "Got it", no: "No analytics" },
    ru: { msg: "Сайт использует локальное хранилище и полностью анонимный счётчик визитов без cookie и слежки. ",
          more: "Подробнее", ok: "Понятно", no: "Без аналитики" },
    ar: { msg: "يستخدم الموقع تخزيناً محلياً وعدّاد زيارات مجهول تماماً بلا كوكيز وبلا تتبّع. ",
          more: "تفاصيل", ok: "حسناً", no: "بدون تحليلات" }
  };
  var t = T[lang] || T.en;
  var rtl = (lang === "he" || lang === "ar");
  var privHref = /\/(app|get|join|privacy|terms|accessibility)\//.test(location.pathname) ? "../privacy/" : "privacy/";

  try { if (localStorage.getItem(LS)) return; } catch (e) { return; }

  function choose(v) {
    try { localStorage.setItem(LS, v); } catch (e) {}
    if (bar && bar.parentNode) bar.parentNode.removeChild(bar);
  }

  var bar = document.createElement("div");
  bar.setAttribute("role", "region");
  bar.setAttribute("aria-label", rtl ? "הודעת פרטיות" : "Privacy notice");
  bar.dir = rtl ? "rtl" : "ltr";
  bar.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:70;" +
    "background:#12161fF2;border-top:1px solid #2a3244;backdrop-filter:blur(6px);" +
    "padding:11px 14px calc(11px + env(safe-area-inset-bottom));" +
    "display:flex;flex-wrap:wrap;align-items:center;justify-content:center;gap:9px;" +
    "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,'Noto Sans Hebrew',sans-serif;";

  var msg = document.createElement("span");
  msg.style.cssText = "color:#c2cad8;font-size:12.5px;max-width:560px;line-height:1.5;";
  msg.textContent = t.msg;
  var a = document.createElement("a");
  a.href = privHref; a.textContent = t.more;
  a.style.cssText = "color:#8ab4f8;font-size:12.5px;";
  msg.appendChild(a);

  function btn(label, primary) {
    var b = document.createElement("button");
    b.type = "button"; b.textContent = label;
    b.style.cssText = "font-family:inherit;font-size:12.5px;font-weight:700;cursor:pointer;" +
      "border-radius:9px;padding:8px 15px;border:1px solid #2a3244;" +
      (primary ? "background:#ffd21e;color:#141005;border-color:#ffd21e;"
               : "background:#1b2130;color:#c2cad8;");
    b.addEventListener("focus", function () { b.style.outline = "2px solid #ffd21e"; b.style.outlineOffset = "2px"; });
    b.addEventListener("blur", function () { b.style.outline = "none"; });
    return b;
  }
  var no = btn(t.no, false), ok = btn(t.ok, true);
  no.addEventListener("click", function () { choose("off"); });
  ok.addEventListener("click", function () { choose("on"); });

  bar.appendChild(msg); bar.appendChild(no); bar.appendChild(ok);

  function mount() { (document.body || document.documentElement).appendChild(bar); }
  if (document.body) mount(); else document.addEventListener("DOMContentLoaded", mount);
})();
