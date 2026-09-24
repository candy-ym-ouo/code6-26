#!/usr/bin/env bash
# Local-only launcher for the Code6-26 A/B recording.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

STATE="/Users/a1-6/.cache/code6-26-a"
RUN="$STATE/run"
DATA="$STATE/data"
API_PORT=31001
GATE_PORT=31011
WEB_PORT=5273

mkdir -p "$STATE" "$RUN" "$DATA"
rm -f "$STATE/api-url" "$STATE/web-url"
: > "$RUN/pids"

listener_cwd() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }

api_listener_pid() {
  for pid in $(lsof -ti tcp:"$API_PORT" 2>/dev/null || true); do
    if [ "$(listener_cwd "$pid")" = "$DATA" ]; then echo "$pid"; return 0; fi
  done
  return 1
}

kill_own_listener() {
  for pid in $(api_listener_pid || true); do kill -9 "$pid" 2>/dev/null || true; done
}

free_own_ports() {
  for port in "$API_PORT" "$GATE_PORT" "$WEB_PORT"; do
    for pid in $(lsof -ti tcp:"$port" 2>/dev/null || true); do
      [ "$(listener_cwd "$pid")" = "$DATA" ] && { kill -9 "$pid" 2>/dev/null || true; continue; }
      cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
      case "$(listener_cwd "$pid") $cmd" in
        *"$STATE"*|*code6-26-a*|*code6-26-b*) kill -9 "$pid" 2>/dev/null || true ;;
      esac
    done
  done
}

cleanup() {
  trap - EXIT INT TERM
  while read -r pid; do
    [ -n "$pid" ] || continue
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done < "$RUN/pids"
  kill_own_listener
}
trap cleanup EXIT INT TERM

free_own_ports
if [ "${SKIP_INSTALL:-0}" != "1" ]; then
  echo "[start] installing dependencies (npm install)"
  npm install --no-audit --no-fund
else
  echo "[start] SKIP_INSTALL=1 (reusing installed dependencies)"
fi
if [ -f "$DATA/data.json" ]; then mv "$DATA/data.json" "$DATA/data.json.previous"; fi

cat > "$STATE/port-patch.cjs" <<'PATCH'
const http = require("node:http");
const target = Number(process.env.AB_API_PORT);
const original = http.Server.prototype.listen;
http.Server.prototype.listen = function patchedListen(...args) {
  if (typeof args[0] === "number" && target) args[0] = target;
  return original.apply(this, args);
};
PATCH

echo "[start] api supervisor on 127.0.0.1:$API_PORT (cwd $DATA, isolated from other runs)"
(
  set +e
  cd "$DATA"
  while :; do
    AB_API_PORT="$API_PORT" node \
      --require "$STATE/port-patch.cjs" \
      --require "$ROOT/node_modules/tsx/dist/preflight.cjs" \
      --import "file://$ROOT/node_modules/tsx/dist/loader.mjs" \
      "$ROOT/api/server.ts"
    echo "[supervisor] api process exited (status $?) at $(date +%T), restarting in 1s"
    sleep 1
  done
) >"$RUN/api.log" 2>&1 &
echo $! >> "$RUN/pids"

API_PID=""
for _ in $(seq 1 60); do
  API_PID="$(api_listener_pid || true)"
  [ -n "$API_PID" ] && break
  sleep 0.5
done
[ -n "$API_PID" ] || { echo "[start] api did not come up on $API_PORT"; cat "$RUN/api.log"; exit 1; }
curl -fsS "http://127.0.0.1:$API_PORT/health/live" >/dev/null
printf '%s\n' "$API_PID" > "$STATE/api.pid"
echo "[start] api up (pid $API_PID on port $API_PORT)"

echo "[start] web dev server (base port $WEB_PORT)"
"$ROOT/node_modules/.bin/vite" --config web/vite.config.ts --port "$WEB_PORT" >"$RUN/web.log" 2>&1 &
echo $! >> "$RUN/pids"

VITE_URL=""
for _ in $(seq 1 160); do
  VITE_URL="$(grep -Eo 'http://localhost:[0-9]+/' "$RUN/web.log" 2>/dev/null | head -1 || true)"
  [ -n "$VITE_URL" ] && break
  sleep 0.5
done
[ -n "$VITE_URL" ] || { echo "[start] web server did not start"; cat "$RUN/web.log"; exit 1; }
VITE_URL="${VITE_URL%/}"
VITE_PORT="${VITE_URL##*:}"
echo "[start] vite up on $VITE_URL"

cat > "$STATE/gate.mjs" <<'GATE'
import http from "node:http";
const API = "http://127.0.0.1:" + process.env.API_PORT;
const WEB = "http://127.0.0.1:" + process.env.WEB_PORT;
const PORT = Number(process.env.GATE_PORT);

function forward(target, req, res) {
  const headers = { ...req.headers, host: target.replace("http://", "") };
  const up = http.request(target + req.url, { method: req.method, headers }, (upstream) => {
    res.writeHead(upstream.statusCode ?? 502, upstream.headers);
    upstream.pipe(res);
  });
  up.on("error", () => {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ code: "GATEWAY_ERROR" }));
  });
  req.pipe(up);
}

http
  .createServer((req, res) => {
    if (req.url === "/health/ready") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
      return;
    }
    if (req.url.startsWith("/api/") || req.url === "/health/live") return forward(API, req, res);
    return forward(WEB, req, res);
  })
  .listen(PORT, "127.0.0.1");
GATE
API_PORT="$API_PORT" WEB_PORT="$VITE_PORT" GATE_PORT="$GATE_PORT" node "$STATE/gate.mjs" >>"$RUN/gate.log" 2>&1 &
echo $! >> "$RUN/pids"

for _ in $(seq 1 40); do
  curl -fsS "http://127.0.0.1:$GATE_PORT/health/ready" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS "http://127.0.0.1:$GATE_PORT/api/v1/content/bootstrap" >/dev/null

echo "http://127.0.0.1:$GATE_PORT" > "$STATE/api-url"
echo "http://127.0.0.1:$GATE_PORT" > "$STATE/web-url"
echo "[start] ready api=http://127.0.0.1:$GATE_PORT web=http://127.0.0.1:$GATE_PORT"

wait
