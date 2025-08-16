cat > /root/functions-bootstrap.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# -------- config --------
ROOT="/opt/functions"
SERV="$ROOT/services"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1. Please install it first."; exit 1; }; }
need docker
need curl

mkdir -p "$SERV"

# -------- base docker-compose with Traefik --------
cat > "$ROOT/docker-compose.yml" <<'YML'
networks:
  functions: {}

services:
  traefik:
    image: traefik:v3.1
    command:
      - --entrypoints.web.address=:8080
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
    ports:
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [functions]
    restart: unless-stopped
YML

# -------- fnctl (function manager) --------
cat > /usr/local/bin/fnctl <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="/opt/functions"
SERV="$ROOT/services"

mkcd(){ mkdir -p "$1" && cd "$1"; }

compose_cmd(){
  local files=("$ROOT/docker-compose.yml")
  shopt -s nullglob
  for f in "$SERV"/*.yml; do files+=("$f"); done
  echo "docker compose ${files[@]/#/-f }"
}

ensure(){
  [[ -d "$ROOT" ]] || { echo "Missing $ROOT"; exit 1; }
  [[ -f "$ROOT/docker-compose.yml" ]] || { echo "Missing base compose"; exit 1; }
  mkdir -p "$SERV"
}

ensure_gateway(){
  ensure
  if ! docker ps --format '{{.Label "com.docker.compose.service"}}' | grep -qx "traefik"; then
    eval "$(compose_cmd)" up -d traefik >/dev/null
  fi
}

wait_route(){
  local ip="${1:-127.0.0.1}" prefix="${2:?prefix required}" tries="${3:-20}"
  for i in $(seq 1 "$tries"); do
    if curl -fsS "http://$ip:8080$prefix/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Route not ready: http://$ip:8080$prefix/healthz" >&2
  return 1
}

new_fn(){
  local name="$1"; local prefix="${2:-/fn/$name}"
  ensure; ensure_gateway
  local appdir="$ROOT/fn-$name"; local svc="$SERV/fn-$name.yml"
  [[ -e "$appdir" || -e "$svc" ]] && { echo "Function '$name' already exists"; exit 1; }

  mkcd "$appdir"
  cat > requirements.txt <<REQ
fastapi
uvicorn
pydantic
REQ
  cat > main.py <<'PY'
from fastapi import FastAPI, Request
from pydantic import BaseModel
app = FastAPI()

@app.get("/healthz")
def health():
    return {"ok": True}

class In(BaseModel):
    msg: str = "world"

@app.post("/invoke")
async def invoke(req: Request):
    try:
        data = await req.json()
        name = data.get("name") if isinstance(data, dict) else None
    except Exception:
        name = None
    return {"message": f"Hello, {name or 'world'}!"}
PY
  cat > Dockerfile <<'DF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
EXPOSE 8000
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8000"]
DF

  cat > "$svc" <<YML
services:
  fn-$name:
    build: ./fn-$name
    labels:
      - traefik.enable=true
      - traefik.http.routers.fn-$name.rule=PathPrefix(\`$prefix\`)
      - traefik.http.middlewares.fn-$name-strip.stripprefix.prefixes=$prefix
      - traefik.http.routers.fn-$name.middlewares=fn-$name-strip
      - traefik.http.services.fn-$name.loadbalancer.server.port=8000
    networks: [functions]
    restart: unless-stopped
YML

  eval "$(compose_cmd)" up -d --build "fn-$name"
  echo "Created function '$name' at $prefix"
}

build_fn(){ ensure; local name="$1"; eval "$(compose_cmd)" up -d --build "fn-$name"; }

test_fn(){
  local name="$1"; local ip="${2:-127.0.0.1}"; local prefix="${3:-/fn/$name}"
  ensure_gateway
  wait_route "$ip" "$prefix" 20
  curl -fsS "http://$ip:8080$prefix/healthz" >/dev/null && echo
  curl -fsS -X POST "http://$ip:8080$prefix/invoke" -H 'Content-Type: application/json' -d '{"name":"Vedant"}' || true
  echo
}

call_fn(){
  local name="$1"; local ip="${2:-127.0.0.1}"; local json="${3:-{"name":"Vedant"}}"
  local prefix="/fn/$name"
  curl -fsS -X POST "http://$ip:8080$prefix/invoke" -H 'Content-Type: application/json' -d "$json" || true
  echo
}

rm_fn(){ ensure; local name="$1"; eval "$(compose_cmd)" rm -s -f "fn-$name" || true; }
restart_fn(){ ensure; local name="$1"; eval "$(compose_cmd)" rm -s -f "fn-$name" || true; eval "$(compose_cmd)" up -d --build "fn-$name"; }

destroy_fn(){
  ensure; local name="$1"
  rm_fn "$name"
  rm -rf "$ROOT/fn-$name" "$SERV/fn-$name.yml"
  echo "Destroyed function '$name'"
}

logs_fn(){ ensure; local name="$1"; eval "$(compose_cmd)" logs -f "fn-$name"; }

list_all(){ ensure; eval "$(compose_cmd)" ps --services | grep -v '^traefik$' | sed 's/^fn-//'; }

status_all(){
  ensure
  out="$(docker ps -a --format '{{.Label "com.docker.compose.service"}} {{.State}}' \
    | awk '$1!="" && $1!="traefik"{print}' | sort -u)"
  if [ -z "$out" ]; then echo "No services found."; return 0; fi
  printf "%-15s%s\n" "FUNCTION" "STATE"
  echo "$out" | awk '{svc=$1; $1=""; sub(/^ /,""); state=$0; sub(/^fn-/,"",svc); printf "%-15s%s\n", svc, state}'
}

quick_fn(){
  local name="$1"; local prefix="${2:-/fn/$name}"
  ensure_gateway
  new_fn "$name" "$prefix"
  wait_route 127.0.0.1 "$prefix" 20
  test_fn "$name" 127.0.0.1 "$prefix"
}

up_all(){ ensure; eval "$(compose_cmd)" up -d --build; }
down_all(){ ensure; eval "$(compose_cmd)" down; }

usage(){
cat <<U
Usage: fnctl <command> [args]
  new <name> [prefix]     Create function (default prefix /fn/<name>) and start it
  build <name>            Rebuild & (re)start a function
  test <name> [ip]        Hit /healthz and /invoke (default ip 127.0.0.1)
  call <name> [ip] [json] POST to /invoke with JSON (default {"name":"Vedant"})
  logs <name>             Tail logs for a function
  restart <name>          Restart a function (recreate container)
  rm <name>               Stop & remove containers for a function
  destroy <name>          rm + delete files (code + service yml)
  list                    List all function names
  status                  Show function names + state
  quick <name> [prefix]   new + test in one go (waits for route)
  up-all                  bring up gateway + all functions
  down-all                stop all
U
}

cmd="${1:-}"; shift || true
case "${cmd:-}" in
  new) new_fn "$@";;
  build) build_fn "$@";;
  test) test_fn "$@";;
  call) call_fn "$@";;
  logs) logs_fn "$@";;
  restart) restart_fn "$@";;
  rm) rm_fn "$@";;
  destroy) destroy_fn "$@";;
  list) list_all;;
  status) status_all;;
  quick) quick_fn "$@";;
  up-all) up_all;;
  down-all) down_all;;
  *) usage;;
esac
BASH
chmod +x /usr/local/bin/fnctl

# -------- fn-suite (concise tester for all functions) --------
cat > /usr/local/bin/fn-suite <<'BASH'
#!/usr/bin/env bash
set -eo pipefail
VERBOSE="${VERBOSE:-0}"; TRACE="${TRACE:-0}"; NO_CLEAN="${NO_CLEAN:-0}"; LOGFILE="${LOGFILE:-}"
[ "$TRACE" = "1" ] && set -x
if [ -n "$LOGFILE" ]; then mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true; exec > >(tee -a "$LOGFILE") 2>&1; fi
run_quiet(){ if [ "$VERBOSE" = "1" ]; then eval "$*"; else eval "$*" >/dev/null 2>&1; fi; }
say(){ printf '%s\n' "$*"; }
ROOT="/opt/functions"; RESET_ON_FAIL="${RESET_ON_FAIL:-1}"; DEFAULT_IP="${DEFAULT_IP:-127.0.0.1}"; FN_BOOTSTRAP="${FN_BOOTSTRAP:-}"
die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
ensure_tools(){ have docker || die "docker not found"; have fnctl || die "fnctl not found"; }
compose_cmd(){ local files=("$ROOT/docker-compose.yml"); shopt -s nullglob; for f in "$ROOT/services"/*.yml; do files+=("$f"); done; echo "docker compose ${files[@]/#/-f }"; }
reset_env(){ say "[reset] removing function containers & files..."; docker ps -a --format '{{.ID}} {{.Label "com.docker.compose.service"}}'|awk '$2 ~ /^fn-/{print $1}'|xargs -r docker rm -f; rm -rf "$ROOT"/services/fn-*.yml "$ROOT"/fn-*; }
extract_prefix(){ local svc="${1:-}" cid key; [ -n "$svc" ] || { echo ""; return 0; }; key="traefik.http.routers.$svc.rule"; cid="$(docker ps -a --filter "label=com.docker.compose.service=$svc" -q | head -n1)"||true; [ -n "$cid" ]||{ echo ""; return 0; }; docker inspect --format '{{range $k,$v := .Config.Labels}}{{printf "%s=%s\n" $k $v}}{{end}}' "$cid" | awk -F= -v target="$key" '$1==target{print $2}' | sed -n 's/.*PathPrefix(`\([^`]*\)`).*/\1/p' | head -n1; }
uniqueness_check(){ mapfile -t names < <(docker ps -a --format '{{.Label "com.docker.compose.service"}}'|awk '$1 ~ /^fn-/{print $1}'|sort -u); if ((${#names[@]}==0)); then say "[check] no functions found."; return 0; fi; if [ "$(printf '%s\n' "${names[@]}"|sort|uniq -d|wc -l)" -ne 0 ]; then say "[fail] duplicate service names detected!"; printf '%s\n' "${names[@]}"|sort|uniq -d; return 1; else say "[ok] function names are unique (${#names[@]} found)."; fi; prefixes=(); for s in "${names[@]}"; do p="$(extract_prefix "$s")"; [ -n "$p" ]||p="/fn/${s#fn-}"; prefixes+=("$p"); done; if [ "$(printf '%s\n' "${prefixes[@]}"|sort|uniq -d|wc -l)" -ne 0 ]; then say "[fail] duplicate URL prefixes detected!"; printf '%s\n' "${prefixes[@]}"|sort|uniq -d; return 1; else say "[ok] URL prefixes are unique."; fi; }
ensure_running(){ local svc="${1:-}"; [ -n "$svc" ] || return 0; docker ps --format '{{.Label "com.docker.compose.service"}}' | grep -qx "$svc" || run_quiet "$(compose_cmd) up -d \"$svc\""; }
wait_route(){ local ip="$1" prefix="$2" tries="${3:-20}"; for i in $(seq 1 "$tries"); do curl -fsS "http://$ip:8080$prefix/healthz" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
invoke_health(){ local ip="$1" prefix="$2"; curl -fsS "http://$ip:8080$prefix/healthz" >/dev/null; }
invoke_adaptive(){ local ip="$1" prefix="$2" code; code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$ip:8080$prefix/invoke" -H 'Content-Type: application/json' -d '{"name":"Vedant"}'); [ "$code" = "200" ] && return 0; code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$ip:8080$prefix/invoke" -H 'Content-Type: application/json' -d '{"a":3.5,"b":4.25}'); [ "$code" = "200" ]; }
duplicate_creation_test(){ local short="$1"; say "[check] duplicate creation for '$short'"; if fnctl new "$short" >/dev/null 2>&1; then say "[fail] duplicate creation unexpectedly succeeded for '$short'"; return 1; else say "[ok] duplicate creation correctly rejected for '$short'"; fi; }
bootstrap_if_requested(){ [ -z "$FN_BOOTSTRAP" ] && return 0; IFS=',' read -r -a arr <<< "$FN_BOOTSTRAP"; for short in "${arr[@]}"; do short="$(echo "$short"|xargs)"; [ -z "$short" ] && continue; say "[bootstrap] ensuring function '$short'"; fnctl new "$short" >/dev/null 2>&1 || say "[bootstrap] '$short' exists; skipping create"; if [ "$short" = "sum" ]; then cat > "$ROOT/fn-sum/main.py" <<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
app = FastAPI()
class In(BaseModel):
    a: float
    b: float
@app.get("/healthz")
def health(): return {"ok": True}
@app.post("/invoke")
def run(inp: In): return {"sum": inp.a + inp.b}
PY
      run_quiet "fnctl build sum"; fi; done; }
suite(){ ensure_tools; local ip="${1:-}"; [ -n "$ip" ] || ip="$(hostname -I | awk '{print $1}')"; [ -n "$ip" ] || ip="127.0.0.1"; say "[info] testing against IP: $ip"; bootstrap_if_requested; mapfile -t svcs < <(docker ps -a --format '{{.Label "com.docker.compose.service"}}'|awk '$1 ~ /^fn-/{print $1}'|sort -u); if ((${#svcs[@]}==0)); then say "[warn] no functions found; nothing to test."; exit 0; fi; uniqueness_check; local start_ts=$(date +%s); for s in "${svcs[@]}"; do short="${s#fn-}"; prefix="$(extract_prefix "$s")"; [ -n "$prefix" ] || prefix="/fn/$short"; say "[test] $short -> $prefix"; ensure_running "$s"; wait_route "$ip" "$prefix" 20 || die "route not ready for $short"; invoke_health "$ip" "$prefix" || die "healthz failed for $short"; invoke_adaptive "$ip" "$prefix" || die "invoke failed for $short"; duplicate_creation_test "$short"; done; if ((${#svcs[@]}>=2)); then say "[cross] checking /healthz across all functions"; for s in "${svcs[@]}"; do short="${s#fn-}"; prefix="$(extract_prefix "$s")"; [ -n "$prefix" ] || prefix="/fn/$short"; invoke_health "$ip" "$prefix" || die "cross healthz failed for $short"; done; fi; local now_ts=$(date +%s); say "[success] all functions passed in $((now_ts - start_ts))s"; }
main(){ if ! suite "$@"; then say "[suite] FAILED"; if [ "${RESET_ON_FAIL:-1}" = "1" ] && [ "$NO_CLEAN" != "1" ]; then reset_env; say "[suite] environment reset due to failure."; else say "[suite] leaving environment intact for inspection."; fi; exit 1; fi; }
main "$@"
BASH
chmod +x /usr/local/bin/fn-suite

# -------- fn-verify-all (full e2e, then cleanup) --------
cat > /usr/local/bin/fn-verify-all <<'BASH'
#!/usr/bin/env bash
set -eo pipefail
VERBOSE="${VERBOSE:-0}"; TRACE="${TRACE:-0}"; LOGFILE="${LOGFILE:-}"
[ "$TRACE" = "1" ] && set -x
if [ -n "$LOGFILE" ]; then mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true; exec > >(tee -a "$LOGFILE") 2>&1; fi
run_quiet(){ if [ "$VERBOSE" = "1" ]; then eval "$*"; else eval "$*" >/dev/null 2>&1; fi; }
say(){ printf '%s\n' "$*"; }

ROOT="/opt/functions"
DEFAULT_IP="$(hostname -I | awk '{print $1}')"; [ -n "$DEFAULT_IP" ] || DEFAULT_IP="127.0.0.1"

die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_tools(){ have docker || die "docker not found"; have fnctl || die "fnctl not found"; have curl || die "curl not found"; }

reset_env(){ say "[reset] removing function containers & files..."; docker ps -a --format '{{.ID}} {{.Label "com.docker.compose.service"}}'|awk '$2 ~ /^fn-/{print $1}'|xargs -r docker rm -f; rm -rf "$ROOT"/services/fn-*.yml "$ROOT"/fn-*; }

wait_route(){ local ip="$1" prefix="$2" tries="${3:-20}"; for i in $(seq 1 "$tries"); do curl -fsS "http://$ip:8080$prefix/healthz" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

adaptive_invoke(){ local ip="$1" prefix="$2" code; code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$ip:8080$prefix/invoke" -H 'Content-Type: application/json' -d '{"name":"Vedant"}'); [ "$code" = "200" ] && return 0; code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$ip:8080$prefix/invoke" -H 'Content-Type: application/json' -d '{"a":3.5,"b":4.25}'); [ "$code" = "200" ]; }

assert_contains(){ local needle="$1"; shift; echo "$@" | grep -qE "$needle" || die "expected to find /$needle/ in: $*"; }
assert_not_contains(){ local needle="$1"; shift; if echo "$@" | grep -qE "$needle"; then die "did NOT expect to find /$needle/ in: $*"; fi; }

get_prefix(){ local short="$1" svc="fn-$1" key="traefik.http.routers.$svc.rule" cid rule; cid="$(docker ps -a --filter "label=com.docker.compose.service=$svc" -q | head -n1)"||true; [ -n "$cid" ] || { echo "/fn/$short"; return 0; }; rule="$(docker inspect --format '{{range $k,$v := .Config.Labels}}{{printf "%s=%s\n" $k $v}}{{end}}' "$cid" | awk -F= -v target="$key" '$1==target{print $2}' | head -n1)"; [ -n "$rule" ] || { echo "/fn/$short"; return 0; }; echo "$rule" | sed -n 's/.*PathPrefix(`\([^`]*\)`).*/\1/p'; }

main(){
  need_tools
  local ip="${1:-$DEFAULT_IP}"
  say "[info] using IP: $ip"
  trap 'say "[finalize] cleaning up all functions"; reset_env' EXIT

  say "[phase] initial reset"; reset_env

  say "[phase] quick create hello (tests: quick, new, build, test)"
  run_quiet "fnctl quick hello"
  curl -fsS -X POST "http://$ip:8080/fn/hello/invoke" -H 'Content-Type: application/json' -d '{"name":"Vedant"}' || true; echo

  out="$(fnctl list || true)";       assert_contains '^hello$' "$out"
  out="$(fnctl status || true)";     assert_contains '^hello[[:space:]]+running' "$out"

  say "[phase] duplicate name rejection (new hello)"
  if fnctl new hello >/dev/null 2>&1; then die "duplicate creation of 'hello' unexpectedly succeeded"; fi

  say "[phase] call hello (tests: call)"
  run_quiet "fnctl call hello \"$ip\" '{\"name\":\"World\"}'"

  say "[phase] create sum (tests: new)"
  run_quiet "fnctl new sum"
  cat > "$ROOT/fn-sum/main.py" <<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
app = FastAPI()
class In(BaseModel):
    a: float
    b: float
@app.get("/healthz")
def health():
    return {"ok": True}
@app.post("/invoke")
def run(inp: In):
    return {"sum": inp.a + inp.b}
PY
  run_quiet "fnctl build sum"

  say "[phase] up-all (tests: up-all)"
  run_quiet "fnctl up-all"

  say "[phase] validate routes (coexistence: hello & sum)"
  for name in hello sum; do
    prefix="$(get_prefix "$name")"
    wait_route "$ip" "$prefix" 20 || die "route not ready for $name"
    curl -fsS "http://$ip:8080$prefix/healthz" >/dev/null
    adaptive_invoke "$ip" "$prefix" || die "/invoke failed for $name"
  done

  say "[phase] logs hello (tests: logs; short read)"
  run_quiet "timeout 2s fnctl logs hello" || true

  say "[phase] restart hello (tests: restart)"
  run_quiet "fnctl restart hello"
  prefix="$(get_prefix hello)"
  wait_route "$ip" "$prefix" 20 || die "route not ready post-restart for hello"
  curl -fsS "http://$ip:8080$prefix/healthz" >/dev/null

  say "[phase] rm hello (tests: rm) — then up-all brings it back"
  run_quiet "fnctl rm hello"
  dps="$(docker ps --format '{{.Label "com.docker.compose.service"}}' | tr -s '\n' ' ')"
  assert_not_contains 'fn-hello' "$dps"
  run_quiet "fnctl up-all"
  prefix="$(get_prefix hello)"
  wait_route "$ip" "$prefix" 20 || die "route not ready after rm + up-all for hello"

  say "[phase] destroy sum (tests: destroy)"
  run_quiet "fnctl destroy sum"
  out="$(fnctl list || true)"; assert_not_contains '^sum$' "$out"

  say "[phase] down-all (tests: down-all)"
  run_quiet "fnctl down-all" || true

  say "[phase] final sanity — no fn-* containers running"
  dps="$(docker ps --format '{{.Label "com.docker.compose.service"}}' | tr -s '\n' ' ')"
  assert_not_contains 'fn-' "$dps"

  say "[result] ALL fnctl subcommands verified ✔"
}
main "$@"
BASH
chmod +x /usr/local/bin/fn-verify-all

# Bring up gateway once
docker compose -f "$ROOT/docker-compose.yml" up -d traefik >/dev/null || true

echo
echo "Bootstrap complete."
echo "Try:"
echo "  fnctl quick hello"
echo "  FN_BOOTSTRAP=\"hello,sum\" fn-suite"
echo "  fn-verify-all"
EOF
chmod +x /root/functions-bootstrap.sh
