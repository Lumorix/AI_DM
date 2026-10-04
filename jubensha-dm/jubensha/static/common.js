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
  mode: "browser", controller: null, audio: null, audioURL: null,
  status(message) { const el = document.querySelector("#voiceStatus"); if (el) el.textContent = message; },
  fail(message) {
    this.stop(); this.on = false;
    const button = document.querySelector('#ttsBtn');
    if (button) button.textContent = '🔇 语音朗读：关';
    this.status(message);
  },
  on: false, buf: "", voice: null, queue: [], current: null, generation: 0,
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
    const pieces = text.trim().match(/[\s\S]{1,120}/gu) || [];
    this.queue.push(...pieces);
    this.next();
  },
  next() {
    if (!this.on || this.current || !this.queue.length) return;
    if (this.mode === "local") { this.nextLocal(); return; }
    const u = new SpeechSynthesisUtterance(this.queue.shift());
    const generation = this.generation;
    this.current = u;
    u.lang = "zh-CN"; if (this.voice) u.voice = this.voice; u.rate = 1.0;
    const finish = () => {
      if (generation !== this.generation || this.current !== u) return;
      this.current = null;
      this.next();
    };
    u.onend = finish;
    u.onerror = () => {
      if (generation !== this.generation || this.current !== u) return;
      this.fail('浏览器朗读失败，请检查声音设置后重新开启');
    };
    speechSynthesis.speak(u);
  },
  async nextLocal() {
    const item = {}, generation = this.generation;
    const text = this.queue.shift();
    this.current = item;
    const controller = this.controller = new AbortController();
    const active = () => this.current === item && generation === this.generation;
    this.status("正在生成八千代语音…");
    try {
      let r;
      for (let attempt = 0; attempt < 120; attempt++) {
        if (!active()) return;
        r = await fetch('/api/voice/speech', {method:'POST', signal:controller.signal,
          headers:{'Content-Type':'application/json'}, body:JSON.stringify({text})});
        if (!active()) return;
        if (r.status !== 429) break;
        this.status('模型正在完成上一句，等待生成…');
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
      if (!active()) return;
      if (!r.ok) {
        const body = await r.json().catch(() => ({}));
        throw new Error(body.error?.message || '语音生成失败');
      }
      const blob = await r.blob();
      if (!active()) return;
      this.audioURL = URL.createObjectURL(blob);
      const audio = this.audio = new Audio(this.audioURL);
      audio.onended = () => {
        if (!active()) return;
        this.releaseLocal(); this.current = null; this.status(''); this.next();
      };
      audio.onerror = () => { if (active()) this.fail('音频播放失败；文字内容仍可查看'); };
      await audio.play();
      if (active()) this.status('正在播放八千代语音（实验）');
    } catch (e) {
      if (!active()) return;
      this.fail(e.name === 'NotAllowedError' ? '浏览器阻止自动播放，请重新点击开启朗读' : e.message);
    }
  },
  releaseLocal() {
    if (this.controller) this.controller.abort();
    this.controller = null;
    if (this.audio) { this.audio.onended = null; this.audio.onerror = null; this.audio.pause(); this.audio.removeAttribute('src'); }
    this.audio = null;
    if (this.audioURL) URL.revokeObjectURL(this.audioURL);
    this.audioURL = null;
  },
  feed(delta) { // 流式文字：攒够一句就念
    if (!this.on) return;
    this.buf += delta;
    let m;
    while ((m = this.buf.match(/^[\s\S]*?[。！？!?\n…]+/))) {
      this.say(m[0]); this.buf = this.buf.slice(m[0].length);
    }
  },
  flush() { this.say(this.buf); this.buf = ""; },
  skip() {
    this.generation++;
    this.current = null;
    this.releaseLocal(); this.status('');
    if ("speechSynthesis" in window) speechSynthesis.cancel();
    this.next();
  },
  stop() {
    this.buf = ""; this.queue = []; this.generation++; this.current = null;
    this.releaseLocal(); this.status('');
    if ("speechSynthesis" in window) speechSynthesis.cancel();
  },
};
