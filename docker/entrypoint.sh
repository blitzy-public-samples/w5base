#!/usr/bin/env bash
#
# docker/entrypoint.sh — W5Base containerized dev-environment orchestration.
#
# Purpose (AAP 0.5.1 Group 2): deterministically stand up a working W5Base
# instance inside the application container by realizing the documented
# ten-step setup on a modern Debian base. Runs as the container ENTRYPOINT
# (see Dockerfile: ENTRYPOINT ["/opt/w5base/docker/entrypoint.sh"]).
#
# Ordered responsibilities:
#   1. Derive/export runtime environment (never hardcode secrets).
#   2. Create the w5base service account + runtime directories.
#   3. Render the three /etc/w5base config files from docker/w5base/*.tmpl
#      (secrets injected from env at render time only) and materialize the
#      HTTP Basic auth credential file the Apache vhost authenticates against.
#   4. Wait for database readiness, then provision the database + application
#      user with MODERN CREATE USER / GRANT (supersedes legacy INSERT INTO user).
#   5. Build the schema non-interactively via W5Event TableVersionCheck.
#   6. Start the persistent W5Server control plane.
#   7. exec Apache in the foreground as the container's main process.
#
# CONSTRAINTS honored:
#   - This SCRIPT contains NO hardcoded secrets; all secrets arrive via env.
#   - Idempotent: safe to run on every container (re)start.
#   - References — never edits — the repo's own utilities under sbin/.
#
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { printf '[entrypoint][FATAL] %s\n' "$*" >&2; exit 1; }

# require_env <NAME>: abort unless the named variable is set AND non-empty.
# Secrets are supplied ONLY via the environment (AAP §0.7) and are NEVER given a
# default — a missing or empty secret is a hard, fail-fast error rather than a
# silent insecure default (e.g. creating a DB user with an empty password).
require_env() {
  local name="$1"
  [ -n "${!name:-}" ] || die "required environment variable $name is unset or empty"
}

# mysql_escape <value>: render an arbitrary value safe for interpolation inside
# a SINGLE-QUOTED MySQL string literal. Under MySQL's default sql_mode (i.e.
# without NO_BACKSLASH_ESCAPES) a backslash is an escape character inside string
# literals, so we escape backslash FIRST and then the single quote. This stops a
# password that contains a quote or backslash from breaking out of the literal
# or injecting additional statements while connected as root (CWE-89).
mysql_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # every backslash -> double backslash
  s="${s//\'/\\\'}"   # every single quote -> backslash-quote
  printf '%s' "$s"
}

########################################################################
# 1. Environment derivation (defaults mirror etc/w5base/default.conf +
#    README.txt filesystem layout; only NON-secret values get defaults).
########################################################################
export W5BASEINSTDIR="${W5BASEINSTDIR:-/opt/w5base}"
export W5BASESRVUSER="${W5BASESRVUSER:-w5base}"
export W5BASE_OPERATION_MODE="${W5BASE_OPERATION_MODE:-online}"
W5SRVGROUP="${W5BASESRVGROUP:-daemon}"          # W5ServerGroup default (default.conf)
APACHE_USER="${APACHE_RUN_USER:-www-data}"      # Debian apache user
W5CONFDIR="/etc/w5base"
W5STATEDIR="/var/opt/w5base/state"
W5LOGDIR="/var/log/w5base"
W5SERVER_CONFIG="w5server"                       # -> /etc/w5base/w5server.conf
W5APP_CONFIG="w5base"                            # -> /etc/w5base/w5base.conf

DB_NAME="${MYSQL_DATABASE:-w5base}"
DB_APP_USER="${MYSQL_USER:-w5base}"
DB_APP_PASS="${W5BASE_DB_PASSWORD:-${MYSQL_PASSWORD:-}}"
DB_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"

DB_HOST="${W5BASE_DB_HOST:-}"
DB_PORT="${W5BASE_DB_PORT:-}"
if [ -n "${W5BASE_DSN:-}" ]; then
  case "$W5BASE_DSN" in
    *host=*) [ -z "$DB_HOST" ] && DB_HOST="$(printf '%s' "$W5BASE_DSN" | sed -n 's/.*host=\([^;:]*\).*/\1/p')" ;;
  esac
  case "$W5BASE_DSN" in
    *port=*) [ -z "$DB_PORT" ] && DB_PORT="$(printf '%s' "$W5BASE_DSN" | sed -n 's/.*port=\([^;:]*\).*/\1/p')" ;;
  esac
fi
DB_HOST="${DB_HOST:-db}"       # compose service name
DB_PORT="${DB_PORT:-3306}"

log "INSTDIR=$W5BASEINSTDIR SRVUSER=$W5BASESRVUSER DB=$DB_APP_USER@$DB_HOST:$DB_PORT/$DB_NAME mode=$W5BASE_OPERATION_MODE"

########################################################################
# 1b. Fail-fast validation of REQUIRED secrets and identifiers.
#     Secrets arrive ONLY from the environment (AAP §0.7): a missing or empty
#     secret is a hard error here, never a silent insecure default. Doing this
#     BEFORE any config rendering or DB provisioning guarantees we never render
#     an incomplete config or create a DB user with an empty password.
########################################################################
for _req in W5BASE_DSN W5BASE_DB_PASSWORD MYSQL_PASSWORD MYSQL_ROOT_PASSWORD \
            W5BASE_ADMIN W5BASE_ADMIN_PASSWORD; do
  require_env "$_req"
done

# The application authenticates with W5BASE_DB_PASSWORD, but the DB is
# provisioned to accept MYSQL_PASSWORD. If the two differ, W5Base cannot log in
# after provisioning — so require they match (the same guarantee .env.example
# documents between W5BASE_DB_PASSWORD and MYSQL_PASSWORD).
[ "$W5BASE_DB_PASSWORD" = "$MYSQL_PASSWORD" ] \
  || die "W5BASE_DB_PASSWORD must equal MYSQL_PASSWORD (the app password and the DB-provisioned password must be identical)"

# DB name and application user are interpolated into DDL that runs as root.
# Constrain them to a strict identifier charset so they can never break the SQL
# or inject statements (CWE-89). They default to the literal 'w5base'; any
# override must still be a plain identifier. The PASSWORD is intentionally NOT
# constrained here — it is safely escaped for its SQL string literal via
# mysql_escape() at provisioning time instead.
case "$DB_NAME" in
  ''|*[!A-Za-z0-9_]*) die "invalid MYSQL_DATABASE '$DB_NAME' (allowed characters: A-Z a-z 0-9 _)" ;;
esac
case "$DB_APP_USER" in
  ''|*[!A-Za-z0-9_]*) die "invalid MYSQL_USER '$DB_APP_USER' (allowed characters: A-Z a-z 0-9 _)" ;;
esac

# Write a SECRET-FREE /etc/profile.local so interactive `docker exec` shells
# and the repo's shell-entry scripts inherit INSTDIR/service context.
umask 022
cat > /etc/profile.local <<EOF
# Generated by docker/entrypoint.sh — SECRET-FREE (no passwords here).
export W5BASEINSTDIR="$W5BASEINSTDIR"
export W5BASESRVUSER="$W5BASESRVUSER"
export W5BASE_OPERATION_MODE="$W5BASE_OPERATION_MODE"
EOF

########################################################################
# 2. Service account + runtime directories (idempotent).
#    Mirrors README.txt L215-L240 (install -m 2770 -o w5base -g daemon ...).
########################################################################
if ! getent group "$W5SRVGROUP" >/dev/null 2>&1; then
  groupadd --system "$W5SRVGROUP"
fi
if ! id "$W5BASESRVUSER" >/dev/null 2>&1; then
  useradd --system --home-dir "$W5BASEINSTDIR" --no-create-home \
          --shell /usr/sbin/nologin --gid "$W5SRVGROUP" "$W5BASESRVUSER"
  log "created service account $W5BASESRVUSER"
fi
# Apache (www-data) must share the w5base group to read 2770 config + write logs.
if id "$APACHE_USER" >/dev/null 2>&1; then
  usermod -aG "$W5SRVGROUP" "$APACHE_USER" || true
fi

for d in "$W5CONFDIR" /var/opt/w5base "$W5STATEDIR" "$W5LOGDIR"; do
  install -d -m 2770 -o "$W5BASESRVUSER" -g "$W5SRVGROUP" "$d"
done
log "runtime directories ready"

########################################################################
# 3. Render config templates -> /etc/w5base (secrets injected from env only).
########################################################################
TMPL_DIR="$W5BASEINSTDIR/docker/w5base"
# shellcheck disable=SC2016  # literal ${VAR} names are intentional: passed to envsubst
ENVSUBST_VARS='${W5BASE_DSN} ${W5BASE_DB_PASSWORD} ${W5BASE_ADMIN} ${W5BASE_OPERATION_MODE} ${W5BASESRVUSER} ${SITENAME} ${AutoLoadMenuPath}'

render_tmpl() {
  src="$1"; dst="$2"
  [ -f "$src" ] || die "missing template: $src"
  envsubst "$ENVSUBST_VARS" < "$src" > "$dst"
  chown "$W5BASESRVUSER:$W5SRVGROUP" "$dst"
  chmod 0640 "$dst"      # contains DB password -> not world-readable
  log "rendered $(basename "$dst")"
}
render_tmpl "$TMPL_DIR/databases.conf.tmpl" "$W5CONFDIR/databases.conf"
render_tmpl "$TMPL_DIR/w5server.conf.tmpl"  "$W5CONFDIR/w5server.conf"
render_tmpl "$TMPL_DIR/w5base.conf.tmpl"    "$W5CONFDIR/w5base.conf"

# --- Materialize the HTTP Basic auth credential file (part of step 3) --------
# The Apache vhost (docker/apache/w5base.conf) authenticates /w5base/auth against
# 'AuthUserFile /etc/w5base/htpasswd'. That vhost documents this file as written
# at runtime here from ${W5BASE_ADMIN}/${W5BASE_ADMIN_PASSWORD}, and the
# Basic-auth username MUST equal MASTERADMIN (=${W5BASE_ADMIN}) so the kernel
# elevates the authenticated REMOTE_USER to admin and the main menu renders at
# /w5base/auth/base/menu/root. Credentials are read from the environment ONLY
# (never hardcoded); the password is piped via STDIN so it never appears in the
# process list (same posture as MYSQL_PWD below). The file is group-readable by
# Apache — www-data was added to the w5base group in step 2.
# W5BASE_ADMIN and W5BASE_ADMIN_PASSWORD were already validated non-empty by the
# fail-fast block in step 1b, so they are guaranteed usable here.
W5HTPASSWD="$W5CONFDIR/htpasswd"
if command -v htpasswd >/dev/null 2>&1; then
  # -c create, -B bcrypt, -i read password from STDIN (keeps it out of ps).
  printf '%s' "$W5BASE_ADMIN_PASSWORD" | htpasswd -c -B -i "$W5HTPASSWD" "$W5BASE_ADMIN"
else
  # Fallback when apache2-utils is unavailable: Apache-compatible APR1 (MD5) hash.
  printf '%s:%s\n' "$W5BASE_ADMIN" \
    "$(printf '%s' "$W5BASE_ADMIN_PASSWORD" | openssl passwd -apr1 -stdin)" > "$W5HTPASSWD"
fi
chown "$W5BASESRVUSER:$W5SRVGROUP" "$W5HTPASSWD"
chmod 0640 "$W5HTPASSWD"
log "wrote HTTP Basic auth file for admin user '$W5BASE_ADMIN'"

########################################################################
# 4. Wait for DB readiness, then modern CREATE USER / GRANT (idempotent).
#    Compose already gates on service_healthy; this is defence-in-depth.
########################################################################
log "waiting for database at $DB_HOST:$DB_PORT ..."
tries=0
until mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" --silent >/dev/null 2>&1; do
  tries=$((tries + 1))
  [ "$tries" -ge 60 ] && die "database not reachable after $tries attempts"
  sleep 2
done
log "database is reachable"

# MYSQL_ROOT_PASSWORD was validated non-empty in step 1b, so we always provision
# the schema and application user ourselves via modern CREATE USER / GRANT.
#   * MYSQL_PWD passes the root password without exposing it in the process list.
#   * The application password is escaped with mysql_escape() so a quote or
#     backslash cannot terminate the string literal or inject SQL (CWE-89).
#   * DB_NAME / DB_APP_USER were validated to a strict identifier charset in
#     step 1b, so their interpolation into the identifier positions is safe.
#   * Grants are SCOPED to the application schema only (least privilege).
DB_APP_PASS_SQL="$(mysql_escape "$DB_APP_PASS")"
MYSQL_PWD="$DB_ROOT_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${DB_APP_USER}'@'%' IDENTIFIED BY '${DB_APP_PASS_SQL}';
ALTER USER '${DB_APP_USER}'@'%' IDENTIFIED BY '${DB_APP_PASS_SQL}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER,
      CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE,
      CREATE VIEW, SHOW VIEW, REFERENCES
  ON \`${DB_NAME}\`.* TO '${DB_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL
log "database/user provisioned via modern CREATE USER/GRANT"

########################################################################
# 5. Non-interactive schema build (reconcile sql/ against live DB).
#    README.txt L456. -s serverless so it does NOT require W5Server yet.
########################################################################
cd "$W5BASEINSTDIR"
log "running TableVersionCheck (schema build) ..."
# Capture the schema-build output so it can be scanned for SQL errors while
# still streaming it to the container log. W5Event runs the build in serverless
# mode and returns exit 0 EVEN WHEN individual DDL statements were rejected by
# the database (see the "tables > 0" note further below), so a bare invocation
# would let a partially-built schema pass unnoticed. `|| true` keeps a non-zero
# pipe status from aborting under `set -e`/`pipefail`; the explicit checks below
# decide pass/fail.
TVC_LOG="$(mktemp)"
"$W5BASEINSTDIR/sbin/W5Event" -c "$W5APP_CONFIG" -s -d -v TableVersionCheck 2>&1 | tee "$TVC_LOG" >&2 || true

# FAIL FAST on a schema-build SQL SYNTAX error. The definitive signature of the
# reserved-word failure class (e.g. MySQL 8 rejecting the legacy unquoted
# `create table system`) is the database's "error in your SQL syntax" message,
# which W5Event echoes. Such an error aborts the offending SQL file mid-way and
# cascades (dependent files never process), leaving the schema INCOMPLETE. It is
# a hard, non-recoverable failure (unlike a transient ordering issue, which
# surfaces as "table ... doesn't exist" and is intentionally NOT matched here),
# so we stop rather than start Apache against half a schema. This closes the QA
# "silent-failure masking" gap: W5Event's exit 0 no longer hides a broken build.
if grep -Eq 'error in your SQL syntax' "$TVC_LOG"; then
  log "TableVersionCheck emitted SQL syntax error(s) (first matches):"
  grep -nE 'error in your SQL syntax|ERROR: Line [0-9]+ in file' "$TVC_LOG" | head -n 20 >&2 || true
  rm -f "$TVC_LOG"
  die "schema build FAILED: TableVersionCheck reported SQL syntax error(s), so the \
schema is incomplete. This is the classic reserved-word collision - the database \
engine rejected part of the legacy W5Base schema (e.g. an unquoted 'system' table \
under MySQL 8). Use the MariaDB engine pinned in docker-compose.yml (db.image: \
mariadb:10.11), then recreate on a fresh volume: docker compose down -v && docker \
compose up -d --build."
fi
rm -f "$TVC_LOG"

# ----------------------------------------------------------------------------
# Reconcile the KNOWN cross-file schema ORDERING defect (in-scope; no sql/ edit).
#
#   sql/itil/itinv.sql, near its end (line 1857), runs
#       alter table autodiscrec add key ...
#   but the `autodiscrec` table is CREATEd by a DIFFERENT file,
#   sql/itil/itinvautodisc.sql. TableVersionCheck orders files by an optional
#   `# DEPEND <file>` directive on each file's `use <db>;` line (see the DEPEND
#   parser in mod/base/menu.pm) and otherwise by glob order. sql/itil/itinv.sql
#   is MISSING a `# DEPEND itil/itinvautodisc.sql` directive, and "itinv.sql"
#   sorts BEFORE "itinvautodisc.sql", so the alter runs before its table exists
#   and fails with "Table 'w5base.autodiscrec' doesn't exist". That error halts
#   the ENTIRE check (mod/base/menu.pm does `last` on a file error), leaving the
#   schema INCOMPLETE (~158/193 tables) and, crucially, INCONSISTENT — which
#   makes W5Base divert every authenticated request to the "Table Version
#   Control" page instead of the menu (the QA-2 primary-acceptance failure).
#
#   sql/** is READ-ONLY (AAP §0.6.2 / Preserve Backward Compatibility), so we do
#   NOT add the missing DEPEND to the source. Instead we mirror the documented
#   host workaround WITHOUT editing any application/schema file: pre-apply the
#   dependency file's DDL (with FOREIGN_KEY_CHECKS disabled, exactly as the
#   framework's own dbtool does) so `autodiscrec` et al. exist, record the file
#   as fully processed in the `tableversion` tracker so the framework skips
#   re-creating those tables, then re-run TableVersionCheck. itinv.sql's trailing
#   alter then succeeds and the remaining files process, yielding the full,
#   consistent schema (193 tables) with zero SQL errors.
#
#   IDEMPOTENT + SELF-DISABLING: the block only fires while itinvautodisc.sql is
#   not yet fully tracked in `tableversion`. Container restarts (schema already
#   reconciled) and any future upstream fix that adds the DEPEND both skip it.
#   All DB access uses the APPLICATION user (as W5Event itself does), MYSQL_PWD
#   keeps the password out of the process list, and the only interpolated values
#   are a hardcoded relative path and an integer line count (no injection).
# ----------------------------------------------------------------------------
DEP_REL="itil/itinvautodisc.sql"
DEP_ABS="$W5BASEINSTDIR/sql/$DEP_REL"
if [ -f "$DEP_ABS" ]; then
  DEP_LINES="$(wc -l < "$DEP_ABS")"; DEP_LINES="${DEP_LINES//[^0-9]/}"
  DEP_DONE="$(MYSQL_PWD="$DB_APP_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_APP_USER" -N -B \
    -e "SELECT COALESCE(MAX(linenumber),-1) FROM \`${DB_NAME}\`.tableversion WHERE filename='${DEP_REL}'" 2>/dev/null || echo -1)"
  case "$DEP_DONE" in ''|*[!0-9-]*) DEP_DONE=-1 ;; esac
  if [ "${DEP_DONE:-0}" -lt "${DEP_LINES:-0}" ]; then
    log "reconciling known schema ordering defect: pre-applying $DEP_REL (itil/itinv.sql lacks its '# DEPEND') ..."
    # 1) Apply the dependency file's DDL with FK checks off (as the dbtool does),
    #    so autodiscrec and its sibling autodisc tables exist.
    if ! { printf 'SET FOREIGN_KEY_CHECKS=0;\n'; cat "$DEP_ABS"; } \
         | MYSQL_PWD="$DB_APP_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_APP_USER" "$DB_NAME"; then
      die "schema reconciliation failed: could not pre-apply $DEP_REL"
    fi
    # 2) Record it as fully processed (linenumber >= file line count) so
    #    TableVersionCheck skips re-creating those tables. DELETE+INSERT is used
    #    (the tableversion table has no UNIQUE key on filename) and is safe: the
    #    guard above ensures we only reach here when the file is not yet done.
    MYSQL_PWD="$DB_APP_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_APP_USER" "$DB_NAME" \
      -e "DELETE FROM tableversion WHERE filename='${DEP_REL}'; \
          INSERT INTO tableversion (filename,linenumber) VALUES ('${DEP_REL}',${DEP_LINES});" \
      || die "schema reconciliation failed: could not record tableversion for $DEP_REL"
    # 3) Re-run TableVersionCheck: itinv.sql's trailing alter now succeeds and
    #    every remaining file processes.
    log "re-running TableVersionCheck after dependency pre-seed ..."
    TVC_LOG2="$(mktemp)"
    "$W5BASEINSTDIR/sbin/W5Event" -c "$W5APP_CONFIG" -s -d -v TableVersionCheck 2>&1 | tee "$TVC_LOG2" >&2 || true
    # The reconciled schema MUST now be clean: no syntax errors and no residual
    # "doesn't exist" ordering errors. Fail loudly if the build did not converge.
    if grep -Eq 'error in your SQL syntax|ERROR: Line [0-9]+ in file|ERROR: Database error' "$TVC_LOG2"; then
      log "TableVersionCheck STILL reports errors after reconciliation (first matches):"
      grep -nE 'error in your SQL syntax|ERROR: Line [0-9]+ in file|ERROR: Database error' "$TVC_LOG2" | head -n 20 >&2 || true
      rm -f "$TVC_LOG2"
      die "schema reconciliation did not converge: TableVersionCheck still reports SQL errors after \
pre-applying $DEP_REL. Inspect the log above; recreate on a fresh volume if needed \
(docker compose down -v && docker compose up -d --build)."
    fi
    rm -f "$TVC_LOG2"
    log "schema reconciliation complete (full schema, TableVersionCheck clean)"
  fi
fi

# Defense-in-depth: W5Event runs the schema build in serverless mode and returns
# exit 0 even when the build FAILED internally (e.g. the database rejected the
# legacy schema under a strict sql_mode). Because that failure is invisible to
# `set -e`, the container would otherwise proceed to start Apache against an EMPTY
# database and appear "up" while every request fails. Verify the build actually
# produced tables and fail loudly (rather than silently) if it did not. This is a
# READ-ONLY probe against the schema we just built; it changes nothing.
#   * MYSQL_PWD keeps the root password out of the process list (as in step 4).
#   * DB_NAME was validated to a strict identifier charset in step 1b, so its
#     interpolation into the query string literal is safe (no injection, CWE-89).
#   * `|| true` + integer sanitization keep a transient probe hiccup from aborting
#     under `set -o pipefail`; only a definitive count of 0 is treated as failure,
#     so a partially-built schema still passes (this guard targets exactly the
#     "zero tables" silent-failure class, without over-constraining).
schema_tables="$(MYSQL_PWD="$DB_ROOT_PASS" mysql -h "$DB_HOST" -P "$DB_PORT" -u root -N -B \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" 2>/dev/null || true)"
case "$schema_tables" in
  ''|*[!0-9]*) schema_tables=0 ;;
esac
if [ "$schema_tables" -eq 0 ]; then
  die "schema build produced 0 tables in database '${DB_NAME}': TableVersionCheck failed silently. \
The database most likely rejected the legacy W5Base schema under a strict sql_mode - ensure \
docker/mysql/my.cnf sets sql_mode=\"\" (see README.txt gotchas), then recreate the db service on a \
fresh volume: docker compose down -v && docker compose up -d --build."
fi
log "schema build complete ($schema_tables tables present)"

########################################################################
# 6. Start the persistent W5Server control plane (daemonizes, self-drops
#    privileges to W5ServerUser/Group). Remove stale pidfile for idempotency.
########################################################################
rm -f "$W5STATEDIR/W5Server.${W5SERVER_CONFIG}.pid"
log "starting W5Server ..."
"$W5BASEINSTDIR/sbin/W5Server" -c "$W5SERVER_CONFIG"
log "W5Server started"

# FAIL FAST if the control plane did not actually come up. sbin/W5Server
# daemonizes and returns exit 0 to this shell BEFORE its background child binds
# the listen socket, so a bind failure (historically: Net::Server defaulting to
# the IPv6 "::" wildcard, which has no loopback in this container) is invisible
# to `set -e` here and Apache would otherwise start against a DEAD control plane
# — the exact state that renders "W5Server is not available". We derive the bind
# address from the rendered w5server.conf (W5ServerPort may be "host:port" or a
# bare "port") and probe it via bash's /dev/tcp until it accepts a connection.
# This closes the QA "silent-failure masking" gap for the control plane.
W5SRV_BIND="$(sed -n 's/^[[:space:]]*W5ServerPort[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$W5CONFDIR/w5server.conf" | head -n 1)"
case "$W5SRV_BIND" in
  *:*) W5SRV_PROBE_HOST="${W5SRV_BIND%:*}"; W5SRV_PROBE_PORT="${W5SRV_BIND##*:}" ;;
  *)   W5SRV_PROBE_HOST="127.0.0.1";        W5SRV_PROBE_PORT="${W5SRV_BIND:-12833}" ;;
esac
# A wildcard/empty bind host is not directly connectable — probe the loopback.
case "$W5SRV_PROBE_HOST" in ''|'0.0.0.0'|'*'|'::') W5SRV_PROBE_HOST="127.0.0.1" ;; esac
log "probing W5Server control plane at $W5SRV_PROBE_HOST:$W5SRV_PROBE_PORT ..."
probe_tries=0
until (exec 3<>"/dev/tcp/$W5SRV_PROBE_HOST/$W5SRV_PROBE_PORT") 2>/dev/null; do
  probe_tries=$((probe_tries + 1))
  [ "$probe_tries" -ge 30 ] && die "W5Server is not listening on \
$W5SRV_PROBE_HOST:$W5SRV_PROBE_PORT after $probe_tries attempts. The control plane \
failed to start - inspect /var/log/w5base/*NetW5Server*.log for a bind error. The \
web frontend requires a running, reachable W5Server."
  sleep 1
done
log "W5Server control plane is listening on $W5SRV_PROBE_HOST:$W5SRV_PROBE_PORT"

########################################################################
# 7. Hand off to Apache in the foreground (container main process).
########################################################################
log "starting Apache (prefork + mod_perl2) in foreground"
: "${APACHE_RUN_DIR:=/var/run/apache2}"
install -d -m 0755 "${APACHE_RUN_DIR}" 2>/dev/null || true
exec apache2ctl -D FOREGROUND
