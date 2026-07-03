#!/usr/bin/env bash
#
# tests/smoke/w5base_smoke_test.sh
# =============================================================================
# W5Base containerized dev-environment SMOKE TEST / HEALTH CHECK
# =============================================================================
#
# WHAT THIS SCRIPT DOES
# ---------------------
# It asserts the FIVE health signals that together prove the containerized
# W5Base local development environment (see docker-compose.yml, docker/) is
# actually up and usable after `docker compose up --build`:
#
#   Check 1  W5Server is up ......... the persistent TCP control plane is
#                                     listening (reachable on its configured
#                                     port from inside the app container).
#   Check 2  Main menu renders ...... HTTP 200 AND the response body is the
#                                     actual main-menu frameset at
#                                     ${W5BASE_BASE_URL}/w5base/auth/base/menu/root
#                                     using HTTP Basic auth (the PRIMARY
#                                     acceptance signal for the whole stack).
#                                     Status 200 ALONE is NOT sufficient: the
#                                     kernel also returns 200 for the first-login
#                                     "account verification" and "GTC
#                                     verification" gates, so this check inspects
#                                     the body for the menu shell (the menutop +
#                                     msel navigation iframes) and FAILS if it
#                                     sees a verification gate instead. This is
#                                     what makes "menu renders" mean the menu,
#                                     not merely a 200 (QA FINAL-B Info-3).
#   Check 3  Install is healthy ..... sbin/W5InstallCheck reports a healthy
#                                     install (exit 0).
#   Check 4  Schema is reconciled ... sbin/W5Event ... TableVersionCheck runs
#                                     clean with no schema-version errors --
#                                     asserted by BOTH its exit code AND the
#                                     ABSENCE of error markers in its output,
#                                     because W5Event exits 0 even on a fatal DB
#                                     outage / failed schema apply (QA FINAL-E
#                                     Issue #1). Exit code alone is not enough.
#   Check 5  Menu is NAVIGABLE ...... a GENERATED menu link carries the /w5base
#                                     app-path prefix AND resolves (HTTP 200).
#                                     Check 2 proves the root frameset RENDERS,
#                                     but the acceptance run showed the root can
#                                     render while every generated nav link is
#                                     still broken: with EventJobBaseUrl empty the
#                                     kernel emits links WITHOUT the /w5base
#                                     segment (e.g. /auth/base/menu/msel/...) and
#                                     every click 404s. This check extracts a real
#                                     generated link and follows it, so "menu
#                                     renders" is upgraded to "menu WORKS"
#                                     (QA FINAL menu-404 acceptance gate).
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
#     required because W5Event closes STDOUT unless verbose/debug is set.
#     IMPORTANT: unlike Check 3, W5Event's exit code is NOT authoritative -- it
#     returns 0 even on a fatal DB-connect / schema-apply failure (QA FINAL-E
#     Issue #1). So Check 4 asserts BOTH a zero exit code AND the absence of
#     error markers in the captured output (see tableversion_output_has_errors),
#     making it a genuine detector of a DB/schema regression rather than a
#     rubber stamp on a misleading exit code.
#   * Menu navigability (Check 5) is the difference between "the menu drew" and
#     "the menu works". The acceptance definition is a developer reaching a
#     logged-in, FUNCTIONING main menu -- not merely a root frameset. Because the
#     kernel derives every menu-tree href and the user-count probe from the
#     EventJobBaseUrl config value, an empty value silently strips the /w5base
#     app-path segment and turns every click into a 404 while Check 2 still
#     passes. Check 5 follows a real generated link so this class of defect can
#     never slip through the gate again (QA FINAL menu-404 acceptance gate).
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
# never embeds the legacy default credentials. It runs all five checks, prints
# a clear per-check PASS/FAIL line plus a final summary, and exits non-zero if
# ANY check fails.
#
# EXIT CODES
# ----------
#   0  all five checks passed
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
# Pure input-validation / parsing helpers (no side effects, no I/O). They are
# defined early so the `--self-test` regression mode below can exercise them
# WITHOUT requiring Docker or any secret/environment variable.
# -----------------------------------------------------------------------------

# trim: echo "$1" with leading/trailing ASCII whitespace removed.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # strip leading whitespace
  s="${s%"${s##*[![:space:]]}"}"   # strip trailing whitespace
  printf '%s' "$s"
}

# is_valid_port: return 0 iff $1 is a decimal TCP port in the range 1..65535.
# EVERY port -- whether env-supplied or parsed from the rendered config -- is
# validated through this before it is ever placed in a shell command, so a
# bogus or hostile value can never be executed.
is_valid_port() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;         # empty or contains a non-digit
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# is_safe_config_name: return 0 iff $1 is a safe W5Base config name -- letters,
# digits, dot, dash and underscore only. This rejects any value that could
# inject shell metacharacters or path traversal when the name is interpolated
# into the "/etc/w5base/<name>.conf" path inside the container.
is_safe_config_name() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# parse_w5server_port: given the raw text of a rendered "W5ServerPort=..." line
# (or a bare value), echo the resolved TCP port, or nothing if no valid port is
# present. The rendered value can be a BARE port ("12833") OR a host:port pair
# ("127.0.0.1:12833"); for host:port we take the segment after the FINAL colon.
# A previous implementation captured only the leading digits, so
# "127.0.0.1:12833" was misread as "127" and Check 1 probed the wrong port and
# false-failed a healthy W5Server -- the `--self-test` cases below lock this
# down.
parse_w5server_port() {
  local raw="${1:-}" value port
  case "$raw" in
    *=*) value="${raw#*=}" ;;        # drop "KEY=" when given a full config line
    *)   value="$raw" ;;
  esac
  value="${value%%#*}"               # strip any trailing inline comment
  value="$(trim "$value")"
  case "$value" in                   # strip one layer of surrounding quotes
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  value="$(trim "$value")"
  port="${value##*:}"                # host:port -> port ; bare port unchanged
  if is_valid_port "$port"; then
    printf '%s' "$port"
  fi
}

# tableversion_output_has_errors: read captured `W5Event ... TableVersionCheck`
# output on STDIN and return 0 (TRUE) iff it contains any schema/DB error marker.
#
# WHY THIS EXISTS (QA FINAL-E Issue #1): sbin/W5Event exits 0 even on FATAL
# DB-connect / schema-apply failures -- verified directly: with the database
# down, every `CREATE TABLE` errors, yet W5Event still returns exit 0 with
# 'msg' => 'OK'. Its exit code is therefore NOT an authoritative "clean schema"
# signal, so Check 4 must ALSO inspect the output. These markers are exactly
# what the kernel logs on failure, and are ABSENT from a clean run (a healthy
# verbose run prints only DEBUG:/INFO: lines and ends with 'msg' => 'OK'):
#   ERROR                -- the kernel error-log prefix, e.g. "ERROR: Connect(",
#                           "ERROR: Command 'CREATE TABLE ...'", "ERROR in command:"
#   Database error       -- a DBI/database failure line
#   Unknown server host  -- the DB host (compose service 'db') is unreachable
#   Connect(             -- a failed DataObj DB-connect attempt, "Connect(<db>):"
#   Line N in file       -- a schema statement failed at sql/<mod>/<file>.sql:N
# The match is case-SENSITIVE on purpose: the kernel emits UPPERCASE "ERROR", so
# this never false-fails a clean run that merely mentions a lowercase word like
# "errors" in an informational line. Reading STDIN (rather than piping into
# grep) keeps the caller free of the `set -o pipefail` + `grep -q` early-exit
# race and lets the --self-test cases below drive it with a here-string.
tableversion_output_has_errors() {
  grep -qE 'ERROR|Database error|Unknown server host|Connect\(|Line [0-9]+ in file'
}

# run_self_test: fast, dependency-free regression coverage for the pure helpers
# that decide a health signal -- the W5ServerPort parser (Check 1) and the
# TableVersionCheck error-marker detector (Check 4, QA FINAL-E Issue #1). It is
# exercised in CI BEFORE the stack is built (see .github/workflows/smoke.yml) so
# a regression in either is caught immediately instead of silently false-failing
# a healthy stack (parser) or silently false-passing a broken one (detector).
run_self_test() {
  local failures=0 got
  assert_port() {                    # $1=input  $2=expected  $3=description
    got="$(parse_w5server_port "$1")"
    if [ "$got" = "$2" ]; then
      log "${PASS_ICON} self-test: $3 ('$1' -> '$got')"
    else
      log "${FAIL_ICON} self-test: $3 ('$1' -> '$got', expected '$2')"
      failures=$((failures + 1))
    fi
  }
  log "=== W5Base smoke-test self-test (W5ServerPort parser + Check 4 error-marker detector) ==="
  # The exact value docker/w5base/w5server.conf.tmpl renders in this environment
  # (the regression that motivated this test):
  assert_port 'W5ServerPort="127.0.0.1:12833"'     '12833' 'rendered host:port line (regression)'
  assert_port '127.0.0.1:12833'                    '12833' 'bare host:port value'
  assert_port 'W5ServerPort=12833'                 '12833' 'bare port line'
  assert_port 'W5ServerPort="12833"'               '12833' 'quoted bare port line'
  assert_port '  W5ServerPort = "127.0.0.1:4711" ' '4711'  'spaced/quoted host:port (code default port)'
  # Invalid inputs must yield NO port so the caller falls back to the default:
  assert_port 'W5ServerPort=""'                    ''      'empty value yields no port'
  assert_port 'W5ServerPort="127.0.0.1:"'          ''      'missing port after colon yields none'
  assert_port 'W5ServerPort="70000"'               ''      'out-of-range port yields none'
  assert_port 'W5ServerPort="abc"'                 ''      'non-numeric yields none'

  # ---- Check 4 error-marker detector (QA FINAL-E Issue #1) ------------------
  # A clean TableVersionCheck run has NO error markers; a DB-down / failed
  # schema apply DOES -- even though W5Event still exits 0. These cases lock the
  # detector down so Check 4 can never regress into the original false-pass, and
  # so it never false-DETECTS a benign lowercase "error" in an informational
  # line. The samples mirror the actual W5Event output observed in each state.
  assert_tvc() {                     # $1=sample output  $2=expected(0=has-errors,1=clean)  $3=description
    if tableversion_output_has_errors <<< "$1"; then got=0; else got=1; fi
    if [ "$got" = "$2" ]; then
      log "${PASS_ICON} self-test: $3"
    else
      log "${FAIL_ICON} self-test: $3 (detector -> '$got', expected '$2')"
      failures=$((failures + 1))
    fi
  }
  assert_tvc "DEBUG: ProcessEvent 'TableVersionCheck'
INFO:  automatic and unattended TableVersionCheck
DEBUG:   0 base/filemgmt.sql              f:85/proc:85
DEBUG:             'exitcode' => 0,
DEBUG:             'msg' => 'OK'"                                        1 'clean output (exit 0, only DEBUG/INFO) has no error markers'
  assert_tvc "ERROR: Connect(w5base): DBI 'Unknown server host 'db' (-5)'" 0 'DB-down connect failure is detected'
  assert_tvc "ERROR: Line 27 in file '/opt/w5base/sql/base/filemgmt.sql'"  0 'failed schema apply (Line N in file) is detected'
  assert_tvc "ERROR: Database error: 'Unknown server host 'db''"          0 'database error line is detected'
  assert_tvc "INFO: 0 errors found; schema is error-free"                 1 'benign lowercase "error" is NOT a false detection'

  log ""
  if [ "$failures" -eq 0 ]; then
    log "self-test RESULT: all self-test cases passed"
    return 0
  fi
  log "self-test RESULT: ${failures} self-test case(s) FAILED"
  return 1
}

# `--self-test` runs the pure regression checks above and exits. It needs
# neither Docker nor any secret, so it is handled BEFORE .env loading and the
# required-secret validation further down.
if [ "${1:-}" = "--self-test" ]; then
  if run_self_test; then exit 0; else exit 1; fi
fi

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
# Check 5 GETs this GENERATED menu-tree frame and asserts the in-app links it
# emits carry the /w5base app-path prefix and actually resolve (HTTP 200). See
# check_generated_menu_link for the rationale (QA menu-404 acceptance gate).
MENU_FRAME_PATH="/w5base/auth/base/menu/menuframe/MyW5Base"
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
# 2b. Private credential material for the HTTP Basic main-menu check (Check 2).
#     The admin password must NEVER be passed on the command line: argv is
#     world-visible via `ps`/process listings and can leak into CI logs. We
#     instead write the credentials into a mode-0600 curl config (read via
#     `curl -K`) and a matching wgetrc (read via $WGETRC) inside a private
#     mktemp directory, and remove them on exit via a trap. Both the username
#     and the password come from the environment -- nothing is typed on a
#     command line or embedded in the script.
# -----------------------------------------------------------------------------
CRED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/w5base_smoke.XXXXXX")"
chmod 700 "${CRED_DIR}"
CURL_CRED_FILE="${CRED_DIR}/curl.cfg"
WGET_CRED_FILE="${CRED_DIR}/wgetrc"
# shellcheck disable=SC2317  # invoked indirectly by the EXIT/INT/TERM trap below
cleanup_creds() { rm -rf "${CRED_DIR}" 2>/dev/null || true; }
trap cleanup_creds EXIT INT TERM
# curl config: `user = "<user>:<password>"` is equivalent to `-u` but keeps the
# secret out of argv. wgetrc: http_user/http_password do the same for wget.
printf 'user = "%s:%s"\n' "${W5BASE_ADMIN}" "${W5BASE_ADMIN_PASSWORD}" > "${CURL_CRED_FILE}"
{
  printf 'http_user=%s\n'     "${W5BASE_ADMIN}"
  printf 'http_password=%s\n' "${W5BASE_ADMIN_PASSWORD}"
} > "${WGET_CRED_FILE}"
chmod 600 "${CURL_CRED_FILE}" "${WGET_CRED_FILE}"

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
  #
  # SECURITY/CORRECTNESS: every candidate is normalized through
  # parse_w5server_port (which accepts bare ports AND host:port pairs, taking
  # the segment after the FINAL colon) and validated as a 1..65535 TCP port
  # before use. The config NAME is validated against a strict charset and is
  # passed to the container shell as a POSITIONAL PARAMETER, never interpolated
  # into the command text -- so neither a malformed config value nor a hostile
  # W5BASE_SERVER_CONFIG can inject shell syntax.

  # 1. Explicit override wins (a host:port override is accepted and normalized).
  if [ -n "${W5BASE_SERVER_PORT:-}" ]; then
    local override
    override="$(parse_w5server_port "${W5BASE_SERVER_PORT}")"
    if is_valid_port "${override}"; then
      printf '%s' "${override}"
      return 0
    fi
    info "ignoring invalid W5BASE_SERVER_PORT='${W5BASE_SERVER_PORT}' (not a 1..65535 port)"
  fi

  # 2. Read the rendered config -- only when the config name is safe. The name
  #    is passed as $1 to the container shell (positional), not interpolated.
  if is_safe_config_name "${W5BASE_SERVER_CONFIG}"; then
    local raw port
    # shellcheck disable=SC2016  # $1 is a POSITIONAL PARAM for the container sh -c, intentionally NOT expanded here (F3 injection hardening)
    raw="$(in_w5base sh -c \
        'grep -iE "^[[:space:]]*W5ServerPort[[:space:]]*=" "/etc/w5base/$1.conf" 2>/dev/null | head -n1' \
        sh "${W5BASE_SERVER_CONFIG}" 2>/dev/null || true)"
    port="$(parse_w5server_port "${raw}")"
    if is_valid_port "${port}"; then
      printf '%s' "${port}"
      return 0
    fi
  else
    info "W5BASE_SERVER_CONFIG='${W5BASE_SERVER_CONFIG}' has unsafe characters; skipping config probe"
  fi

  # 3. This environment's documented default (see DEFAULT_W5SERVER_PORT).
  printf '%s' "${DEFAULT_W5SERVER_PORT}"
}

check_w5server_up() {
  local port
  port="$(detect_w5server_port)"
  # detect_w5server_port only ever returns a validated port, but re-check here
  # as defense in depth before the value is used in any shell context.
  if ! is_valid_port "${port}"; then
    record_fail "could not determine a valid W5Server port (got '${port}')"
    return 1
  fi
  info "Check 1: probing W5Server TCP port ${port} on 127.0.0.1 (inside container)"
  # The port is passed as a POSITIONAL PARAMETER ($1) to the container shell and
  # never interpolated into the command string. bash /dev/tcp is guaranteed
  # (the Debian base ships bash); nc is a fallback.
  # shellcheck disable=SC2016  # $1 is a POSITIONAL PARAM for the container shell, intentionally NOT expanded here (F3 injection hardening)
  if in_w5base bash -c 'exec 3<>/dev/tcp/127.0.0.1/"$1" && exec 3>&-' bash "${port}" >/dev/null 2>&1; then
    record_pass "W5Server is up (TCP 127.0.0.1:${port} reachable inside '${W5BASE_SERVICE}')"
    return 0
  fi
  # shellcheck disable=SC2016  # $1 is a POSITIONAL PARAM for the container shell, intentionally NOT expanded here (F3 injection hardening)
  if in_w5base sh -c 'command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$1"' sh "${port}" >/dev/null 2>&1; then
    record_pass "W5Server is up (TCP 127.0.0.1:${port} reachable via nc inside '${W5BASE_SERVICE}')"
    return 0
  fi
  record_fail "W5Server is NOT reachable on 127.0.0.1:${port} (control plane down?)"
  return 1
}

# =============================================================================
# Check 2 -- Main menu RENDERS -- the PRIMARY acceptance signal.
#
# A bare HTTP 200 is NOT sufficient proof: the W5Base kernel returns 200 for its
# first-login "account verification" and "GTC verification" gates too, so a
# status-only check would report success while the developer is actually stuck
# on a gate and the main menu is unreachable (the exact QA FINAL-B Issue #1 /
# Info-3 failure). This check therefore fetches the response BODY and asserts it
# is the real main-menu frameset before passing.
# =============================================================================

# fetch_url <url> <body_out_file>: GET the URL with HTTP Basic auth, save the
# response body to <body_out_file>, and print the numeric HTTP status (000 on a
# connection failure). Credentials are read from the mode-0600 curl config / the
# wgetrc so the password never appears in argv (same posture as before).
fetch_url() {
  local url="$1" body="$2" out=""
  : > "${body}" 2>/dev/null || true
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -sS -o "${body}" -w '%{http_code}' -K "${CURL_CRED_FILE}" "${url}" 2>/dev/null)" || true
    printf '%s' "${out:-000}"
  elif command -v wget >/dev/null 2>&1; then
    # $WGETRC supplies http_user/http_password, keeping the password out of argv.
    # Body -> file; server-response headers -> a sidecar we parse for the status.
    local hdr="${body}.hdr"
    WGETRC="${WGET_CRED_FILE}" wget -q -O "${body}" --server-response "${url}" 2>"${hdr}" || true
    awk 'tolower($1)=="http/1.0"||tolower($1)=="http/1.1"{code=$2} END{printf "%s", (code==""?"000":code)}' "${hdr}" 2>/dev/null || printf '000'
    rm -f "${hdr}" 2>/dev/null || true
  else
    printf '000'
  fi
}

# body_is_account_gate <body_file> / body_is_gtc_gate <body_file>: recognize the
# two 200-returning first-login gates by their page titles (set in
# lib/kernel/App/Web.pm). Used both to REJECT a gate as "menu renders" and to
# emit a precise, actionable failure message.
body_is_account_gate() { grep -qiE 'account verification' "$1"; }
body_is_gtc_gate()     { grep -qiE 'GTC verification'     "$1"; }

# body_is_main_menu <body_file>: TRUE only when the body is the actual main-menu
# frameset. The base::menu root mask renders a two-iframe shell -- a top
# navigation bar (name=menutop, MOD=base::menu&FUNC=root) and the menu-tree
# selector (name=msel) -- neither of which appears on the verification gates.
# Requiring BOTH iframe names (and explicitly rejecting the gate titles) is what
# makes this assert "the MENU rendered", not merely "a 200 came back".
body_is_main_menu() {
  local body="$1"
  [ -s "${body}" ] || return 1
  if body_is_account_gate "${body}" || body_is_gtc_gate "${body}"; then
    return 1
  fi
  grep -qi 'menutop' "${body}" && grep -qi 'msel' "${body}"
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

  # Response body goes into the private, mode-700 CRED_DIR so it is removed by the
  # existing cleanup trap and never world-readable.
  local body="${CRED_DIR}/menu_body.html"
  local attempt=1 code="000"
  while [ "${attempt}" -le "${HTTP_RETRIES}" ]; do
    code="$(fetch_url "${url}" "${body}")"
    if [ "${code}" = "200" ]; then
      # 200 received -- the body content is now deterministic (driven by DB
      # state, not warm-up), so decide pass/fail from the body immediately.
      if body_is_main_menu "${body}"; then
        record_pass "main menu renders at ${url} (HTTP 200 + menu frameset: menutop/msel iframes present)"
        return 0
      fi
      if body_is_account_gate "${body}"; then
        record_fail "main menu URL returned HTTP 200 but rendered the first-login ACCOUNT VERIFICATION gate, not the menu, at ${url} -- seed an active MASTERADMIN account (docker/entrypoint.sh) so first login reaches the menu"
      elif body_is_gtc_gate "${body}"; then
        record_fail "main menu URL returned HTTP 200 but rendered the GTC VERIFICATION gate, not the menu, at ${url} -- the MASTERADMIN account needs an accepted-GTC state"
      else
        record_fail "main menu URL returned HTTP 200 but the body is not the menu frameset (menutop/msel iframes absent) at ${url}"
      fi
      return 1
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
# Check 4 -- TableVersionCheck reconciles the schema cleanly.
#
# The exit code is NOT sufficient on its own: sbin/W5Event returns exit 0 even
# on a FATAL DB-connect / schema-apply failure (QA FINAL-E Issue #1 -- with the
# database down, every CREATE TABLE errors yet W5Event still exits 0 with
# 'msg' => 'OK'). So this check captures W5Event's combined output and FAILS on
# a non-zero exit OR on any error marker in that output (see
# tableversion_output_has_errors). That makes Check 4 a genuine, independent
# detector of a DB/schema regression instead of trusting a misleading exit code.
# sbin/W5Event itself is left untouched (Preserve Backward Compatibility) -- the
# fix lives entirely in how this test interprets its output.
# =============================================================================
check_tableversion() {
  info "Check 4: ${W5BASEINSTDIR}/sbin/W5Event -c ${W5BASE_CONFIG} -s -d -v TableVersionCheck (inside container)"
  # Capture W5Event's COMBINED stdout+stderr AND its exit code. The output goes
  # into the private, mode-0700 CRED_DIR (removed by the cleanup trap, never
  # world-readable), mirroring how Check 2 stores the menu body. `|| rc=$?`
  # keeps `set -e` from aborting on a non-zero exit so we can report the signal.
  local out="${CRED_DIR}/tableversioncheck.out"
  local rc=0
  in_w5base "${W5BASEINSTDIR}/sbin/W5Event" -c "${W5BASE_CONFIG}" -s -d -v TableVersionCheck \
    > "${out}" 2>&1 || rc=$?

  # A non-zero exit is an unambiguous failure.
  if [ "${rc}" -ne 0 ]; then
    record_fail "TableVersionCheck failed (W5Event exited ${rc})"
    return 1
  fi
  # Exit 0 is NOT proof of success: fail if the output carries error markers
  # (DB unreachable, a failed schema apply, a "Database error", etc.). This is
  # the fix for the exit-0-on-DB-down false-pass.
  if tableversion_output_has_errors < "${out}"; then
    record_fail "TableVersionCheck reported schema/DB errors despite exit 0 (database unreachable or a schema apply failed) -- W5Event's exit code is not authoritative for a clean schema"
    return 1
  fi
  record_pass "TableVersionCheck is clean -- schema reconciled with no errors (exit 0 and no error markers in output)"
  return 0
}

# =============================================================================
# Check 5 -- Generated in-app menu links carry the /w5base app-path prefix AND
# resolve (HTTP 200) -- i.e. the menu is actually NAVIGABLE, not just rendered.
#
# WHY this is a distinct, mandatory check (QA FINAL acceptance gate / Issue #1):
# Check 2 proves the root menu FRAMESET renders, but the acceptance run showed
# the root frame can render HTTP 200 while EVERY generated navigation link is
# still broken. The read-only kernel (mod/base/menu.pm) builds the left-hand
# menu-tree hrefs and the live "current user count" JSONP probe from the config
# value EventJobBaseUrl. When that value is EMPTY the kernel normalizes it to
# "/", so the links render WITHOUT the "/w5base" app-path segment (e.g.
# "/auth/base/menu/msel/MyW5Base/userenv") -- and because Apache only mounts the
# app under "/w5base/..." (docker/apache/w5base.conf), clicking any such link
# 404s. A status-only or root-frameset-only assertion is blind to this: the root
# renders fine while navigation is dead. This check closes that gap.
#
# HOW: fetch a GENERATED menu-tree frame (MENU_FRAME_PATH), extract a real
# generated menu link exactly as the kernel emitted it (stripping the historic
# leading-space WebSSO hack in the href), then (1) ASSERT the link's PATH begins
# with the app segment "/<app>/auth/" -- a bare "/auth/..." is precisely the QA
# 404 defect and FAILS the check -- and (2) FOLLOW the link and ASSERT HTTP 200.
# The link path is always re-based onto the same origin Check 2 uses, so the
# check works whether EventJobBaseUrl is the path-only "/w5base/" form or the
# full "http://host/w5base/" form. No application code is touched: this only
# reads what the running app generated (Preserve Backward Compatibility).
# =============================================================================
check_generated_menu_link() {
  # Same origin selection as Check 2: container -> :80, host -> published URL.
  local base
  if [ "${IN_CONTAINER}" -eq 1 ]; then
    base="${W5BASE_INTERNAL_URL:-http://localhost:80}"
  else
    base="${W5BASE_BASE_URL}"
  fi
  # The app-path segment the generated auth links MUST carry (derived from
  # MENU_PATH's first segment, e.g. "w5base"), so this stays correct if the
  # mount path is ever changed in one place.
  local app_seg
  app_seg="$(printf '%s' "${MENU_PATH#/}" | cut -d/ -f1)"
  local frame_url="${base%/}${MENU_FRAME_PATH}"
  info "Check 5: GET ${frame_url} then assert a generated menu link carries '/${app_seg}/auth/' and returns 200"

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    record_fail "generated-link check needs curl or wget, neither found on PATH"
    return 1
  fi

  # Fetch the generated navigation frame into the private, mode-700 CRED_DIR
  # (removed by the cleanup trap, never world-readable) -- same posture as Check 2.
  local frame="${CRED_DIR}/menuframe.html"
  local code
  code="$(fetch_url "${frame_url}" "${frame}")"
  if [ "${code}" != "200" ]; then
    record_fail "could not fetch the generated menu frame (HTTP ${code}) at ${frame_url}"
    return 1
  fi

  # Extract the first generated menu-tree link (a base/menu/msel entry -- the
  # exact family the QA click-through exercised). grep keeps the raw href value,
  # which begins with the kernel's leading-space WebSSO hack; strip href="..."
  # wrapping and any leading whitespace to recover the link the browser would use.
  local raw link
  raw="$(grep -oE 'href="[^"]*base/menu/msel[^"]*"' "${frame}" | head -n 1)"
  if [ -z "${raw}" ]; then
    record_fail "no generated menu link (base/menu/msel) found in the menu frame at ${frame_url} -- menu tree empty?"
    return 1
  fi
  link="$(printf '%s' "${raw}" | sed -E 's/^href="//; s/"$//; s/^[[:space:]]+//')"

  # Reduce the link to its PATH: full-URL forms (http://host/PATH) are stripped
  # to "/PATH" so the assertion and the follow-up GET are host/port agnostic.
  local path
  case "${link}" in
    http://*|https://*) path="/$(printf '%s' "${link}" | sed -E 's#^[a-z]+://[^/]+/##')" ;;
    *)                  path="${link}" ;;
  esac

  # ASSERT (1): the generated path carries the "/<app>/auth/" prefix. A bare
  # "/auth/..." path is the QA menu-404 defect (missing /<app> segment) -> FAIL.
  case "${path}" in
    /"${app_seg}"/auth/*) : ;;  # correct -- link carries the app-path prefix
    /auth/*)
      record_fail "generated menu link '${path}' is root-relative and MISSING the '/${app_seg}' app-path prefix -- this is the QA menu-404 defect; set EventJobBaseUrl in the app config so links resolve under /${app_seg}"
      return 1 ;;
    *)
      record_fail "generated menu link has an unexpected path '${path}' (neither '/${app_seg}/auth/...' nor a bare '/auth/...') at ${frame_url}"
      return 1 ;;
  esac

  # ASSERT (2): the generated link actually resolves. Re-base the PATH onto the
  # same origin and GET it -- this is the programmatic equivalent of the QA
  # browser click-through that previously 404'd.
  local nav_url="${base%/}${path}"
  local nav_body="${CRED_DIR}/menu_nav_body.html"
  local nav_code
  nav_code="$(fetch_url "${nav_url}" "${nav_body}")"
  if [ "${nav_code}" = "200" ]; then
    record_pass "generated menu link resolves: '${path}' carries the '/${app_seg}' app path and returns HTTP 200 (navigation works)"
    return 0
  fi
  record_fail "generated menu link '${path}' did NOT return 200 (HTTP ${nav_code}) at ${nav_url} -- navigation is broken"
  return 1
}

# =============================================================================
# Run all five checks. `if <check>; then` protects each from `set -e` so a
# single failure does not abort the run -- we want every signal reported.
# =============================================================================
log "=== W5Base environment smoke test ==="
if check_w5server_up;        then :; fi
if check_main_menu;          then :; fi
if check_install;            then :; fi
if check_tableversion;       then :; fi
if check_generated_menu_link; then :; fi

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
