#!/usr/bin/env bash
#
# tests/smoke/w5base_smoke_test.sh
# =============================================================================
# W5Base containerized dev-environment SMOKE TEST / HEALTH CHECK
# =============================================================================
#
# WHAT THIS SCRIPT DOES
# ---------------------
# It asserts the FOUR health signals that together prove the containerized
# W5Base local development environment (see docker-compose.yml, docker/) is
# actually up and usable after `docker compose up --build`:
#
#   Check 1  W5Server is up ......... the persistent TCP control plane is
#                                     listening (reachable on its configured
#                                     port from inside the app container).
#   Check 2  Main menu renders ...... HTTP 200 at
#                                     ${W5BASE_BASE_URL}/w5base/auth/base/menu/root
#                                     using HTTP Basic auth (the PRIMARY
#                                     acceptance signal for the whole stack).
#   Check 3  Install is healthy ..... sbin/W5InstallCheck reports a healthy
#                                     install (exit 0).
#   Check 4  Schema is reconciled ... sbin/W5Event ... TableVersionCheck runs
#                                     clean with no schema-version errors
#                                     (exit 0).
#
# WHY EACH SIGNAL MATTERS
# -----------------------
#   * W5Server (Check 1) is "essentially needed to process all asyncron and
#     atomic operation[s]" and the Apache spare processes talk to it over TCP
#     (W5Server.README.txt). The web frontend therefore DEPENDS on it -- a
#     running Apache alone is NOT sufficient, so we probe the control plane
#     explicitly. W5Server restricts callers via W5ServerAllow (default
#     127.0.0.1) and renames its own process (e.g. "W5Sserver-<server>"), so a
#     host-side probe is rejected and `pgrep W5Server` is unreliable; the
#     authoritative test is a TCP reachability probe on 127.0.0.1 executed
#     INSIDE the application container.
#   * The main-menu 200 (Check 2) is the concrete, user-visible definition of
#     "done": a developer reaches a logged-in W5Base main menu. Login uses HTTP
#     Basic auth; the admin identity is granted because REMOTE_USER equals the
#     configured MASTERADMIN (README.txt "Running W5Base and operating hints").
#   * W5InstallCheck (Check 3) validates the install integrity (core Perl
#     modules, config dir/file, config object). Its exit code is authoritative;
#     optional-module warnings do NOT change the exit code, so a non-zero exit
#     is always a hard failure.
#   * TableVersionCheck (Check 4) reconciles the SQL under sql/ against the live
#     database. It is invoked with `-s -d -v` on purpose: `-s` = serverless (a
#     running W5Server is not required for this check) and `-v`/`-d` are
#     required because W5Event closes STDOUT unless verbose/debug is set. Its
#     exit code is authoritative (0 = clean).
#
# HOW TO RUN
# ----------
#   Locally (default, from the repository root, after `docker compose up`):
#       cp .env.example .env      # then edit real values; never commit .env
#       ./tests/smoke/w5base_smoke_test.sh
#
#   In CI (e.g. .github/workflows/smoke.yml):
#       docker compose up --build -d
#       ./tests/smoke/w5base_smoke_test.sh
#
#   Already inside the application container:
#       W5BASE_IN_CONTAINER=1 /opt/w5base/tests/smoke/w5base_smoke_test.sh
#
# The script is fully ENV-DRIVEN and reads every credential/endpoint from the
# environment (or an optional local .env) -- it NEVER hardcodes secrets and it
# never embeds the legacy default credentials. It runs all four checks, prints
# a clear per-check PASS/FAIL line plus a final summary, and exits non-zero if
# ANY check fails.
#
# EXIT CODES
# ----------
#   0  all four checks passed
#   1  one or more checks failed
#   2  configuration error (a required secret/variable is unset)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Small output helpers (all diagnostics go to stderr; PASS/FAIL lines to stdout)
# -----------------------------------------------------------------------------
log()  { printf '%s\n'          "$*"; }
info() { printf '[smoke] %s\n'  "$*" >&2; }
die()  { printf '[smoke][ERROR] %s\n' "$*" >&2; exit 2; }

PASS_ICON="PASS:"
FAIL_ICON="FAIL:"

# -----------------------------------------------------------------------------
# 0. Optionally load a local .env so the script can be run standalone.
#    Compose injects these automatically; this is only for host convenience.
#    Never commit real secrets to .env.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd || printf '%s' "${SCRIPT_DIR}")"

load_env_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  info "loading environment from ${f}"
  set -a
  # shellcheck disable=SC1090  # dynamic path is intentional
  . "$f"
  set +a
}
if [ -n "${W5BASE_ENV_FILE:-}" ]; then
  load_env_file "${W5BASE_ENV_FILE}"
elif [ -f "${PWD}/.env" ]; then
  load_env_file "${PWD}/.env"
elif [ -f "${REPO_ROOT}/.env" ]; then
  load_env_file "${REPO_ROOT}/.env"
fi

# -----------------------------------------------------------------------------
# 1. Configuration (all overridable via environment; secrets have NO defaults)
# -----------------------------------------------------------------------------
W5BASEINSTDIR="${W5BASEINSTDIR:-/opt/w5base}"      # install dir inside container
W5BASE_SERVICE="${W5BASE_SERVICE:-w5base}"         # compose app service name
W5BASE_CONFIG="${W5BASE_CONFIG:-w5server}"         # config name for -c (W5InstallCheck/W5Event)
W5BASE_SERVER_CONFIG="${W5BASE_SERVER_CONFIG:-w5server}"  # config that defines W5ServerPort
W5BASE_BASE_URL="${W5BASE_BASE_URL:-http://localhost:8080}"   # host-facing URL
MENU_PATH="/w5base/auth/base/menu/root"
DEFAULT_W5SERVER_PORT="12833"                      # this env's w5server.conf value (code default is 4711)
HTTP_RETRIES="${W5BASE_HTTP_RETRIES:-10}"          # bounded warm-up retries for Check 2
HTTP_RETRY_DELAY="${W5BASE_HTTP_RETRY_DELAY:-3}"   # seconds between retries

# Detect whether we are executing INSIDE the application container.
# Either an explicit flag, or the presence of the in-container install path.
if [ "${W5BASE_IN_CONTAINER:-0}" = "1" ] || [ -x "${W5BASEINSTDIR}/sbin/W5InstallCheck" ]; then
  IN_CONTAINER=1
else
  IN_CONTAINER=0
fi

# Resolve the compose command (docker compose vs legacy docker-compose); only
# needed when driving the container from the host.
COMPOSE_CMD=()
detect_compose() {
  if [ -n "${W5BASE_COMPOSE:-}" ]; then
    # shellcheck disable=SC2206  # intentional word-split of a user-provided command
    COMPOSE_CMD=(${W5BASE_COMPOSE})
    return 0
  fi
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    COMPOSE_CMD=(docker compose)   # best guess; a clear error surfaces if unusable
  fi
}
if [ "${IN_CONTAINER}" -eq 0 ]; then
  detect_compose
  info "run context: HOST (driving service '${W5BASE_SERVICE}' via '${COMPOSE_CMD[*]}')"
else
  info "run context: INSIDE container"
fi

# -----------------------------------------------------------------------------
# 2. Pre-flight: required secrets have NO safe default. Fail fast (exit 2) with
#    a clear message up front rather than a confusing set -u error mid-run.
#    The main-menu check (the primary acceptance signal) needs admin creds.
# -----------------------------------------------------------------------------
require_env() {
  local name="$1"
  local val="${!name:-}"
  if [ -z "${val}" ]; then
    die "required environment variable '${name}' is not set. Copy .env.example to .env and set real values (never commit secrets)."
  fi
}
require_env W5BASE_ADMIN
require_env W5BASE_ADMIN_PASSWORD

# -----------------------------------------------------------------------------
# Single choke point for running a command against the application container.
#   * inside the container  -> run the command directly
#   * from the host         -> wrap in `<compose> exec -T <service>`
# The -T flag disables pseudo-TTY allocation (required for CI / non-interactive).
# -----------------------------------------------------------------------------
in_w5base() {
  if [ "${IN_CONTAINER}" -eq 1 ]; then
    "$@"
  else
    "${COMPOSE_CMD[@]}" exec -T "${W5BASE_SERVICE}" "$@"
  fi
}

# -----------------------------------------------------------------------------
# Result accounting: run every check, never abort on the first failure, then
# summarize and exit non-zero if any failed (so CI shows every failing signal).
# -----------------------------------------------------------------------------
TOTAL=0
PASSED=0
FAILED=0
declare -a SUMMARY=()

record_pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); SUMMARY+=("${PASS_ICON} $1"); log "${PASS_ICON} $1"; }
record_fail() { FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); SUMMARY+=("${FAIL_ICON} $1"); log "${FAIL_ICON} $1"; }

# =============================================================================
# Check 1 -- W5Server (persistent TCP control plane) is up.
# =============================================================================
detect_w5server_port() {
  # Priority: explicit env override -> value in the rendered w5server.conf
  # inside the container -> this environment's documented default (12833).
  if [ -n "${W5BASE_SERVER_PORT:-}" ]; then
    printf '%s' "${W5BASE_SERVER_PORT}"
    return 0
  fi
  local detected=""
  detected="$(in_w5base sh -c "grep -iE '^[[:space:]]*W5ServerPort[[:space:]]*=' /etc/w5base/${W5BASE_SERVER_CONFIG}.conf 2>/dev/null | head -n1" 2>/dev/null \
              | sed -E 's/^[^=]*=[[:space:]]*\"?([0-9]+)\"?.*/\1/' || true)"
  if printf '%s' "${detected}" | grep -qE '^[0-9]+$'; then
    printf '%s' "${detected}"
    return 0
  fi
  printf '%s' "${DEFAULT_W5SERVER_PORT}"
}

check_w5server_up() {
  local port
  port="$(detect_w5server_port)"
  info "Check 1: probing W5Server TCP port ${port} on 127.0.0.1 (inside container)"
  # bash /dev/tcp is guaranteed (Debian base ships bash); nc is a fallback.
  if in_w5base bash -c "exec 3<>/dev/tcp/127.0.0.1/${port} && exec 3>&-" >/dev/null 2>&1; then
    record_pass "W5Server is up (TCP 127.0.0.1:${port} reachable inside '${W5BASE_SERVICE}')"
    return 0
  fi
  if in_w5base sh -c "command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 ${port}" >/dev/null 2>&1; then
    record_pass "W5Server is up (TCP 127.0.0.1:${port} reachable via nc inside '${W5BASE_SERVICE}')"
    return 0
  fi
  record_fail "W5Server is NOT reachable on 127.0.0.1:${port} (control plane down?)"
  return 1
}

# =============================================================================
# Check 2 -- Main menu renders (HTTP 200) -- the PRIMARY acceptance signal.
# =============================================================================
http_status() {
  local url="$1" user="$2" pass="$3" out=""
  if command -v curl >/dev/null 2>&1; then
    # curl prints the numeric status (000 when it cannot connect); capture once.
    out="$(curl -sS -o /dev/null -w '%{http_code}' -u "${user}:${pass}" "${url}" 2>/dev/null)" || true
    printf '%s' "${out:-000}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null --server-response --user="${user}" --password="${pass}" "${url}" 2>&1 \
      | awk 'tolower($1)=="http/1.0"||tolower($1)=="http/1.1"{code=$2} END{printf "%s", (code==""?"000":code)}'
  else
    printf '000'
  fi
}

check_main_menu() {
  # Inside the container the app is on :80; from the host use the published URL.
  local base
  if [ "${IN_CONTAINER}" -eq 1 ]; then
    base="${W5BASE_INTERNAL_URL:-http://localhost:80}"
  else
    base="${W5BASE_BASE_URL}"
  fi
  local url="${base%/}${MENU_PATH}"
  info "Check 2: GET ${url} (HTTP Basic as '${W5BASE_ADMIN}'), up to ${HTTP_RETRIES} attempts"

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    record_fail "main menu check needs curl or wget, neither found on PATH"
    return 1
  fi

  local attempt=1 code="000"
  while [ "${attempt}" -le "${HTTP_RETRIES}" ]; do
    code="$(http_status "${url}" "${W5BASE_ADMIN}" "${W5BASE_ADMIN_PASSWORD}")"
    if [ "${code}" = "200" ]; then
      record_pass "main menu renders (HTTP 200) at ${url}"
      return 0
    fi
    info "  attempt ${attempt}/${HTTP_RETRIES}: HTTP ${code} (app may still be warming up)"
    if [ "${attempt}" -lt "${HTTP_RETRIES}" ]; then
      sleep "${HTTP_RETRY_DELAY}"
    fi
    attempt=$((attempt + 1))
  done
  record_fail "main menu did NOT return 200 (last HTTP ${code}) at ${url}"
  return 1
}

# =============================================================================
# Check 3 -- sbin/W5InstallCheck reports a healthy install (exit 0).
# =============================================================================
check_install() {
  info "Check 3: ${W5BASEINSTDIR}/sbin/W5InstallCheck -c ${W5BASE_CONFIG} (inside container)"
  if in_w5base "${W5BASEINSTDIR}/sbin/W5InstallCheck" -c "${W5BASE_CONFIG}" >/dev/null 2>&1; then
    record_pass "W5InstallCheck reports a healthy install (exit 0)"
    return 0
  fi
  record_fail "W5InstallCheck reported a mandatory failure (non-zero exit)"
  return 1
}

# =============================================================================
# Check 4 -- TableVersionCheck reconciles the schema cleanly (exit 0).
# =============================================================================
check_tableversion() {
  info "Check 4: ${W5BASEINSTDIR}/sbin/W5Event -c ${W5BASE_CONFIG} -s -d -v TableVersionCheck (inside container)"
  if in_w5base "${W5BASEINSTDIR}/sbin/W5Event" -c "${W5BASE_CONFIG}" -s -d -v TableVersionCheck >/dev/null 2>&1; then
    record_pass "TableVersionCheck is clean -- schema reconciled with no errors (exit 0)"
    return 0
  fi
  record_fail "TableVersionCheck reported schema-version errors (non-zero exit)"
  return 1
}

# =============================================================================
# Run all four checks. `if <check>; then` protects each from `set -e` so a
# single failure does not abort the run -- we want every signal reported.
# =============================================================================
log "=== W5Base environment smoke test ==="
if check_w5server_up;   then :; fi
if check_main_menu;     then :; fi
if check_install;       then :; fi
if check_tableversion;  then :; fi

log ""
log "--- summary ---"
for line in "${SUMMARY[@]}"; do
  log "  ${line}"
done
log ""
log "RESULT: ${PASSED}/${TOTAL} checks passed"

if [ "${FAILED}" -gt 0 ]; then
  exit 1
fi
exit 0
