// 手机页面用的小工具
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function api(path, data = {}) {
  try {
    const r = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) });
    const j = await r.json().catch(() => ({ ok: false, msg: "服务器返回异常" }));
    if (!r.ok && j.ok === undefined) j.ok = false;
    return j;
  } catch (e) {
    return { ok: false, msg: "连不上主持电脑，检查一下 Wi‑Fi" };
  }
}

function toast(msg) {
  const t = document.createElement("div");
  t.className = "toast";
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 2700);
}

// 服务器时间和本机时间可能不一致，用 view.now 校准
let clockSkew = 0;
function syncClock(serverNow) { clockSkew = serverNow * 1000 - Date.now(); }
function phaseRemaining(phase) {
  if (!phase || !phase.minutes) return null;
  const end = phase.started_at * 1000 + phase.minutes * 60000;
  return Math.round((end - (Date.now() + clockSkew)) / 1000);
}
function fmtSec(s) {
  const neg = s < 0; s = Math.abs(s);
  return (neg ? "-" : "") + String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0");
}
function startTimer(el, getPhase) {
  setInterval(() => {
    const r = phaseRemaining(getPhase());
    if (r === null) { el.textContent = ""; return; }
    el.textContent = fmtSec(r);
    el.classList.toggle("over", r < 0);
  }, 500);
}

function logHTML(entries, meName) {
  return entries.map((e) => {
    const me = meName && e.who === meName ? " me" : "";
    return `<div class="msg ${esc(e.kind)}${me}"><div class="who">${esc(e.who)}</div><div class="body">${esc(e.text)}</div></div>`;
  }).join("");
}

// SSE 连接，断了自动重连（手机锁屏再打开也能接上）
function connect(query, handlers) {
  let es, retry = 1000;
  const badge = document.createElement("div");
  badge.className = "conn chip on hidden";
  document.body.appendChild(badge);
  const setConn = (ok) => { badge.textContent = ok ? "" : "重新连接中…"; badge.classList.toggle("hidden", ok); };
  function open() {
    es = new EventSource("/api/events?" + new URLSearchParams(query));
    es.onopen = () => { retry = 1000; setConn(true); };
    es.onmessage = (m) => {
      const ev = JSON.parse(m.data);
      if (ev.type === "view") { syncClock(ev.data.now); handlers.view && handlers.view(ev.data, ev); }
      else if (ev.type === "kicked") { es.close(); handlers.kicked && handlers.kicked(); }
      else handlers.event && handlers.event(ev);
    };
    es.onerror = async () => {
      es.close(); setConn(false);
      if (handlers.check && !(await handlers.check())) return;
      setTimeout(open, retry); retry = Math.min(retry * 2, 10000);
    };
  }
  open();
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && es && es.readyState === 2) { retry = 1000; open(); }
  });
  return { close: () => es && es.close() };
}

// 图标（线条风格，和 Mac 端一致）
const ICON = {
  feed: '<path d="M4 6h16M4 12h16M4 18h10"/>',
  book: '<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5z"/><path d="M4 20.5A2.5 2.5 0 0 1 6.5 18H20v3H6.5"/>',
  clues: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6"/><circle cx="11" cy="14" r="2.5"/><path d="m13 16 2 2"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  ask: '<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>',
  vote: '<path d="M9 12l2 2 4-4"/><path d="M12 3l7 4v5c0 4.5-3 8-7 9-4-1-7-4.5-7-9V7z"/>',
};
const icon = (name) => `<svg class="i" viewBox="0 0 24 24">${ICON[name]}</svg>`;
