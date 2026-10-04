// 三个页面共用的小工具
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function api(path, data = {}, headers = {}) {
  try {
    const r = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(data) });
    const j = await r.json().catch(() => ({ ok: false, msg: "服务器返回异常" }));
    if (!r.ok && j.ok === undefined) j.ok = false;
    return j;
  } catch (e) {
    return { ok: false, msg: "连不上服务器，检查WiFi" };
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

const PHASE_TYPE = { narration: "旁白", reading: "阅读", discuss: "讨论", search: "搜证", vote: "投票", reveal: "复盘" };

function logHTML(entries, meName) {
  return entries.map((e) => {
    const me = meName && e.who === meName ? " me" : "";
    return `<div class="msg ${esc(e.kind)}${me}"><div class="who">${esc(e.who)}</div><div class="body">${esc(e.text)}</div></div>`;
  }).join("");
}

// SSE 连接，断了自动重连
function connect(query, handlers) {
  let es, retry = 1000, retryTimer = null, stopped = false;
  const badge = document.createElement("div");
  badge.className = "conn chip on hidden";
  document.body.appendChild(badge);
  const setConn = (ok) => { badge.textContent = ok ? "" : "重新连接中…"; badge.classList.toggle("hidden", ok); };
  function cancelRetry() {
    if (retryTimer !== null) clearTimeout(retryTimer);
    retryTimer = null;
  }
  function close() {
    stopped = true;
    cancelRetry();
    if (es) es.close();
    document.removeEventListener("visibilitychange", wake);
    badge.remove();
  }
  function open() {
    if (stopped) return;
    cancelRetry();
    if (es) es.close();
    const stream = es = new EventSource("/api/events?" + new URLSearchParams(query));
    const active = () => !stopped && es === stream;
    let checking = false;
    stream.onopen = () => { if (active()) { retry = 1000; setConn(true); } };
    stream.onmessage = (m) => {
      if (!active()) return;
      let ev;
      try { ev = JSON.parse(m.data); } catch (_) { return; }
      if (!ev || typeof ev !== "object") return;
      if (ev.type === "view") { syncClock(ev.data.now); handlers.view && handlers.view(ev.data, ev); }
      else if (ev.type === "kicked") { close(); handlers.kicked && handlers.kicked(); }
      else handlers.event && handlers.event(ev);
    };
    stream.onerror = async () => {
      if (!active() || checking) return;
      checking = true;
      stream.close(); setConn(false);
      let allowed = true;
      try { if (handlers.check) allowed = await handlers.check(); } catch (_) { /* Retry network failures. */ }
      if (!active()) return;
      if (!allowed) { close(); return; }
      retryTimer = setTimeout(open, retry);
      retry = Math.min(retry * 2, 10000);
    };
  }
  function wake() {
    if (!stopped && document.visibilityState === "visible" && es && es.readyState === 2) {
      retry = 1000;
      open();
    }
  }
  document.addEventListener("visibilitychange", wake);
  open();
  return { close };
}

// 浏览器自带语音朗读（大屏用）
const TTS = {
  on: false, buf: "", voice: null,
  init() {
    if (!("speechSynthesis" in window)) return false;
    const pick = () => {
      const vs = speechSynthesis.getVoices();
      this.voice = vs.find((v) => /zh[-_]CN/i.test(v.lang)) || vs.find((v) => /^zh/i.test(v.lang)) || null;
    };
    pick(); speechSynthesis.onvoiceschanged = pick;
    return true;
  },
  say(text) {
    if (!this.on || !text.trim()) return;
    const u = new SpeechSynthesisUtterance(text.trim());
    u.lang = "zh-CN"; if (this.voice) u.voice = this.voice; u.rate = 1.0;
    speechSynthesis.speak(u);
  },
  feed(delta) { // 流式文字：攒够一句就念
    this.buf += delta;
    const m = this.buf.match(/^[\s\S]*?[。！？!?\n…]+/);
    if (m) { this.say(m[0]); this.buf = this.buf.slice(m[0].length); }
  },
  flush() { this.say(this.buf); this.buf = ""; },
  stop() { this.buf = ""; if ("speechSynthesis" in window) speechSynthesis.cancel(); },
};
