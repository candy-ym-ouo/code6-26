#!/usr/bin/env bash
# Prompt reproduction for: 修复跨存档幂等键串单和重启重放失效问题
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

STATE="/Users/a1-6/.cache/code6-26-b"
export STATE_DIR="$STATE"
export API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:3101}"
CHECK="$STATE/reproduce-check.mjs"

cat > "$CHECK" <<'JS'
import fs from "node:fs";
import assert from "node:assert/strict";

const BASE = process.env.API_BASE_URL.replace(/\/$/, "") + "/api/v1";
const STATE = process.env.STATE_DIR;
const KEY = "shared-key-0001";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const api = async (p, o = {}) => {
  const r = await fetch(BASE + p, {
    headers: { "Content-Type": "application/json", ...(o.headers ?? {}) },
    ...o,
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${p} -> ${r.status} ${JSON.stringify(d)}`);
  return d;
};

const draft = (t) => ({
  playId: "moon",
  assignments: {},
  timeline: [{ actionId: "enter", actorIds: [t.actors[0].id], act: 0, slot: 0 }],
  endings: [0, 0, 0],
});

async function readyTour(name) {
  const { tour } = await api("/tours", { method: "POST", body: JSON.stringify({ name }) });
  await api(`/tours/${tour.id}/investigations`, { method: "POST", body: JSON.stringify({ kind: "market" }) });
  const cur = (await api(`/tours/${tour.id}`)).tour;
  await api(`/tours/${tour.id}/production`, { method: "PUT", body: JSON.stringify(draft(cur)) });
  return (await api(`/tours/${tour.id}`)).tour;
}

let failures = 0;
const check = (label, fn) => {
  try {
    fn();
    console.log(`  PASS  ${label}`);
  } catch (error) {
    failures += 1;
    console.log(`  FAIL  ${label} :: ${error.message}`);
  }
};

console.log(`== 复现目标：跨存档幂等键串单 / 重启重放失效（key=${KEY}）==`);
console.log("== 场景一：同存档同键重放，不得重复产生副作用 ==");
const a = await readyTour("甲剧团");
const r1 = await api(`/tours/${a.id}/performances`, {
  method: "POST",
  headers: { "Idempotency-Key": KEY },
  body: JSON.stringify(draft(a)),
});
const r2 = await api(`/tours/${a.id}/performances`, {
  method: "POST",
  headers: { "Idempotency-Key": KEY },
  body: JSON.stringify(draft(a)),
});
check("首次演出正常结算（funds " + r1.tour.funds + "）", () => assert.equal(r1.replayed, undefined));
check("同键重试命中重放 replayed=true", () => assert.equal(r2.replayed, true));
check("重放返回同一份演出快照", () => assert.equal(r2.performance.id, r1.performance.id));
check("重放不得重复入账资金", () => assert.equal(r2.tour.funds, r1.tour.funds));
check("重放不得追加历史", () => assert.equal(r2.tour.history.length, r1.tour.history.length));
check("重放不得改动版本号", () => assert.equal(r2.tour.version, r1.tour.version));

console.log("== 场景二：跨存档相同幂等键，不得串单 ==");
const b = await readyTour("乙剧团");
const r3 = await api(`/tours/${b.id}/performances`, {
  method: "POST",
  headers: { "Idempotency-Key": KEY },
  body: JSON.stringify(draft(b)),
});
check("乙剧团用相同键独立结算（未命中甲剧团记录）", () => assert.equal(r3.replayed, undefined));
check("两个存档的演出快照不同", () => assert.notEqual(r3.performance.id, r1.performance.id));
check("乙剧团演出正常入账", () => assert.ok(r3.tour.funds > b.funds));

console.log("== 场景三：重启进程后重放，记录须按剧团持久化 ==");
const pid = Number(fs.readFileSync(`${STATE}/api.pid`, "utf8").trim());
await sleep(1200);
process.kill(pid, "SIGKILL");
console.log(`  已 kill API 进程 pid=${pid}，等待 supervisor 重启…`);
const deadline = Date.now() + 30000;
let restarted = false;
while (Date.now() < deadline) {
  try {
    const res = await fetch(`${BASE}/tours`);
    if (res.ok) { restarted = true; break; }
  } catch {}
  await sleep(400);
}
if (!restarted) {
  console.log("  FAIL  API 未能在重启后恢复");
  process.exit(1);
}
console.log("  API 已用同一份 data.json 重新启动");

const { tours } = await api("/tours");
const ta = tours.find((t) => t.name === "甲剧团");
const tb = tours.find((t) => t.name === "乙剧团");
const beforeA = (await api(`/tours/${ta.id}`)).tour;
const beforeB = (await api(`/tours/${tb.id}`)).tour;
const ra = await api(`/tours/${ta.id}/performances`, {
  method: "POST",
  headers: { "Idempotency-Key": KEY },
  body: JSON.stringify(draft(beforeA)),
});
const rb = await api(`/tours/${tb.id}/performances`, {
  method: "POST",
  headers: { "Idempotency-Key": KEY },
  body: JSON.stringify(draft(beforeB)),
});
check("甲剧团重启后同键重试仍命中重放", () => assert.equal(ra.replayed, true));
check("甲剧团重启后重放不重复入账", () => assert.equal(ra.tour.funds, beforeA.funds));
check("甲剧团重启后重放不追加历史", () => assert.equal(ra.tour.history.length, beforeA.history.length));
check("乙剧团重启后重放同样生效", () => assert.equal(rb.replayed, true));
check("乙剧团重启后重放不重复入账", () => assert.equal(rb.tour.funds, beforeB.funds));
check("两个存档各自返回各自的演出快照", () => assert.notEqual(ra.performance.id, rb.performance.id));

try {
  const rows = JSON.parse(fs.readFileSync(`${STATE}/data/data.json`, "utf8"));
  const summary = rows
    .map((t) => `${t.name}=${Object.keys(t.idempotency ?? t.performanceKeys ?? {}).join("|") || "空"}`)
    .join("  ");
  console.log(`  data.json 持久化的幂等记录：${summary}`);
} catch (error) {
  console.log(`  FAIL  读取 data.json 失败 :: ${error.message}`);
  failures += 1;
}

console.log(failures === 0 ? "复现结论：全部场景 PASS" : `复现结论：${failures} 项 FAIL`);
process.exit(failures === 0 ? 0 : 1);
JS

node "$CHECK"
