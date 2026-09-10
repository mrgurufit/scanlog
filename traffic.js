/* One measurement call per visit - not one per page.

   Until 2026-09-10 this fired on EVERY page view, on all four public pages,
   and each call costs 4 Make operations. That is a bill that grows with
   traffic: 5,000 page views in a day after a video lands would spend the whole
   month's 20,000 operations in that day and take every other automation in the
   project down with it, which is exactly what happened on 2026-09-09 for a
   different reason.

   A visit is now counted once per browsing session, on the first page. Later
   pages in the same session, refreshes and back-navigation cost nothing at
   all. The number this produces is VISITS; there is no per-page view count any
   more, and there should not be one at this price.

   The next step, when it is worth doing, is moving this to a free analytics
   service (Cloudflare Web Analytics is unlimited and needs one script tag) and
   deleting the webhook entirely - the ops floor for measurement should be 0. */
(function () {
  "use strict";
  var HOOK = "https://hook.us2.make.com/iwafet153pkallo64gaqd7ryoutllx4x";
  try {
    // No sessionStorage (private mode, some in-app browsers) means we cannot
    // tell a first page from a fifth. Counting once and moving on beats
    // counting every page, so this path also sends at most one per page load
    // and the rare over-count is cheaper than the old behaviour ever was.
    var first = true;
    try {
      if (sessionStorage.getItem("mgf_seen")) first = false;
      else sessionStorage.setItem("mgf_seen", "1");
    } catch (e) { /* keep first = true */ }
    if (!first) return;

    var u = HOOK + "?s=1&p=" + encodeURIComponent(location.pathname);
    if (navigator.sendBeacon) navigator.sendBeacon(u);
    else fetch(u, { mode: "no-cors", keepalive: true }).catch(function () {});
  } catch (e) { /* measurement must never break the page */ }
})();
