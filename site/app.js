/* Ballast site: tabs, scan ledger, copy buttons. Everything works without this file. */
(function () {
  "use strict";
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- tabs (tour + install) ---- */
  function tabs(list) {
    var tabEls = Array.prototype.slice.call(list.querySelectorAll('[role="tab"]'));
    list.hidden = false;
    function show(tab, focus) {
      tabEls.forEach(function (t) {
        var on = t === tab;
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.tabIndex = on ? 0 : -1;
        document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
      });
      if (focus) tab.focus();
    }
    tabEls.forEach(function (t, i) {
      t.addEventListener("click", function () { show(t, false); });
      t.addEventListener("keydown", function (e) {
        var n = null;
        if (e.key === "ArrowRight") n = (i + 1) % tabEls.length;
        else if (e.key === "ArrowLeft") n = (i - 1 + tabEls.length) % tabEls.length;
        else if (e.key === "Home") n = 0;
        else if (e.key === "End") n = tabEls.length - 1;
        if (n !== null) { e.preventDefault(); show(tabEls[n], true); }
      });
    });
    show(tabEls[0], false);
  }
  document.querySelectorAll('[role="tablist"]').forEach(tabs);

  /* ---- copy buttons ---- */
  document.querySelectorAll(".code").forEach(function (box) {
    if (!navigator.clipboard) return;
    var b = document.createElement("button");
    b.type = "button"; b.className = "copy"; b.textContent = "Copy";
    b.setAttribute("aria-label", "Copy command");
    b.addEventListener("click", function () {
      navigator.clipboard.writeText(box.querySelector("pre").innerText.trim()).then(function () {
        b.textContent = "Copied";
        setTimeout(function () { b.textContent = "Copy"; }, 1600);
      }, function () { b.textContent = "Press ⌘C"; });
    });
    box.classList.add("has-copy");
    box.appendChild(b);
  });

  /* ---- categories: collapsible on small screens only ---- */
  var wide = window.matchMedia("(min-width: 720px)");
  function sync() { document.querySelectorAll(".cat details").forEach(function (d) { d.open = wide.matches; }); }
  sync();
  if (wide.addEventListener) wide.addEventListener("change", sync);

  /* ---- scan ledger ---- */
  var ledger = document.getElementById("ledger");
  if (!ledger || reduce) return;
  var rows = Array.prototype.slice.call(ledger.querySelectorAll(".row"));
  var num = document.getElementById("ledger-num");
  var status = document.getElementById("ledger-status");
  var finalText = num.textContent;
  var started = false;

  function run() {
    if (started) return; started = true;
    var total = 0;
    var paths = rows.map(function (r) { return r.querySelector(".path"); });
    var full = paths.map(function (p) { return p.textContent; });
    rows.forEach(function (r) { r.classList.add("pending"); });
    paths.forEach(function (p) { p.textContent = ""; });
    num.textContent = "0.00 GB";
    status.textContent = "Scanning";
    status.classList.add("caret");

    function tween(from, to, ms) {
      var t0 = performance.now();
      (function step(t) {
        var k = Math.max(0, Math.min(1, (t - t0) / ms));
        num.textContent = (from + (to - from) * (1 - Math.pow(1 - k, 3))).toFixed(2) + " GB";
        if (k < 1) requestAnimationFrame(step);
      })(t0);
    }
    function next(i) {
      if (i >= rows.length) {
        status.classList.remove("caret"); status.textContent = "Scan complete";
        num.textContent = finalText; return;
      }
      var r = rows[i], p = paths[i], s = full[i], n = 0;
      r.classList.remove("pending");
      Array.prototype.forEach.call(r.children, function (c) { if (c !== p) c.style.visibility = "hidden"; });
      p.classList.add("caret");
      (function type() {
        n += 2;
        p.textContent = s.slice(0, n);
        if (n < s.length) return setTimeout(type, 22);
        p.classList.remove("caret");
        Array.prototype.forEach.call(r.children, function (c) { c.style.visibility = ""; });
        var safe = parseFloat(r.getAttribute("data-safe"));
        if (safe) { tween(total, total + safe, 500); total += safe; }
        setTimeout(function () { next(i + 1); }, 260);
      })();
    }
    setTimeout(function () { next(0); }, 500);
  }

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (es, o) { if (es[0].isIntersecting) { o.disconnect(); run(); } }, { threshold: 0.3 }).observe(ledger);
  } else { run(); }
})();
