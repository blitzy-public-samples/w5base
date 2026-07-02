# W5Base — Local Setup (Containerized Dev Environment)

This runbook stands up **W5Base** (the "Darwin" application/database framework)
on your machine using Docker. It replaces the repository's legacy install recipe
— which targeted *Debian 5.0 ("Lenny")* and a SourceForge SVN checkout
(`README.txt` L16, L257) — with a modern, reproducible stack:

> **Debian 12 + Apache (prefork MPM) + mod_perl2 + MySQL 8 / MariaDB.**

The goal is deliberately narrow: **clone the repository (the `blitzy` branch),
configure one file, run one command, and reach a logged-in W5Base main menu** at

```
${W5BASE_BASE_URL}/w5base/auth/base/menu/root
```

Everything below describes what the container **actually executes** — the
entrypoint's ordered steps — so this document doubles as an accurate mental model
of the environment. For *how it works* under the hood (framework model, request
path, control plane), read [`./ARCHITECTURE.md`](./ARCHITECTURE.md).

> **Scope & compatibility.** This is a purely *additive* development environment.
> It only **runs and wires to** the repository's own utilities
> (`sbin/W5Server`, `sbin/W5Event`, `sbin/W5InstallCheck`, `bin/app.pl`); it
> changes **no** application code, kernel, or schema.

## Table of Contents

- [1. Prerequisites](#1-prerequisites)
- [2. The Single Command](#2-the-single-command)
- [3. First Login](#3-first-login)
- [4. Verifying Health (Smoke Test)](#4-verifying-health-smoke-test)
- [5. Security (Change the Defaults)](#5-security-change-the-defaults)
- [6. Troubleshooting](#6-troubleshooting)
- [7. Operation Modes](#7-operation-modes)
- [8. Next Steps and References](#8-next-steps-and-references)

---

## 1. Prerequisites

- **Docker Engine** and **Docker Compose v2** (the `docker compose` subcommand,
  not the legacy `docker-compose` script) installed and running. Verify with:

  ```bash
  docker --version
  docker compose version
  ```

- **Network access on the first build.** The initial image build pulls the
  Debian base image and installs Apache/mod_perl2, the system Perl module set,
  and the build toolchain via `apt`. It does **not** perform a Git checkout:
  the build copies your already-checked-out working tree into the image with
  explicit `COPY --chown=w5base:daemon …` directives (see the `COPY` lines in the
  [`Dockerfile`](../Dockerfile)), then builds the Perl dependencies it needs from
  source. (`git` is installed in the image only as tooling that modernizes the
  legacy SVN recipe, not to fetch code during the build — so you clone/checkout
  the repository yourself *before* running Compose, as in the next bullet.)
  Subsequent builds are cached and fast.

- **The repository, checked out on the `blitzy` branch.** All commands below are
  run from the repository root (the directory that contains `Dockerfile`,
  `docker-compose.yml`, and `.env.example`).

- **Patience on the first build.** From `dependence/mandatory` the image compiles
  only the vendored Perl modules that are genuinely required **and** are not
  available as a reliable Debian package — `RPC-Smart`, `Env-C`, and
  `HTML-TagFilter` — each with the standard `perl Makefile.PL && make && make
  install` flow, and each **failing the build on error** (no best-effort masking
  that could let the image build while `sbin/W5InstallCheck` later fails). The
  other modules the install checker needs — `DateTime::Set`, `Data::HexDump`, and
  `Spreadsheet::WriteExcel` — are installed from Debian packages
  (`libdatetime-set-perl`, `libdata-hexdump-perl`, `libspreadsheet-writeexcel-perl`),
  so they are **not** built from source. `IPC-Smart` is **omitted entirely**: it is
  unused by the kernel, absent from every `sbin/W5InstallCheck` probe (the check
  exits `0` without it), and does not compile on a modern gcc/glibc toolchain — so
  building it would add only a guaranteed-failing step. This source build is why
  the first build takes several minutes. **Why it matters:** `RPC::Smart` is a hard
  prerequisite of the control plane — `sbin/W5Server` and the shell entry points
  such as `sbin/W5Event` `use RPC::Smart::Client` to talk over TCP, so the
  environment cannot boot without it.

- **Resources.** Budget roughly **~4 GB of free disk** and a couple of GB of RAM.
  (The legacy guide sized a full OS install at 4 GB total — `README.txt` L18 —
  and the containerized stack is comfortable in the same ballpark.)

---

## 2. The Single Command

The happy path is three short actions: **configure once, run one command, open
the browser.**

### Step 1 — Configure your environment

Copy the committed template to a local, git-ignored `.env` and edit it:

```bash
cp .env.example .env
# then edit .env: set real values and CHANGE the legacy defaults (see §5)
```

`.env.example` is the **canonical, committed list** of every variable the stack
consumes (it is read by `docker-compose.yml` via `env_file:`, exported by
`docker/entrypoint.sh`, and rendered into `/etc/w5base/*.conf`). It contains
**placeholders only**. Your real `.env` is **git-ignored and must never be
committed** with real secrets.

The variables you will set are:

| Variable | Purpose | Example / default in template |
|----------|---------|-------------------------------|
| `W5BASE_DSN` | DBI connect string for the `w5base` schema. The host is the Compose service name **`db`**, not `localhost`. | `dbi:mysql:database=w5base;host=db;port=3306` |
| `W5BASE_DB_PASSWORD` | Password for the `w5base` application DB user. **Must equal `MYSQL_PASSWORD`.** | `change-me-w5base-db-password` |
| `W5BASE_ADMIN` | REMOTE_USER always treated as master admin. Rendered as `MASTERADMIN`. | `local/admin` |
| `W5BASE_ADMIN_PASSWORD` | HTTP Basic password for that admin identity (seeds the container `htpasswd`). | `change-me-admin-password` |
| `W5BASEINSTDIR` | Install directory inside the container. | `/opt/w5base` |
| `W5BASESRVUSER` | Service account that owns the runtime dirs and runs `sbin/W5Server`. | `w5base` |
| `W5BASE_BASE_URL` | Base URL used to reach the app from your host. Port must match the published port. | `http://localhost:8080` |
| `W5BASE_OPERATION_MODE` | Application operation mode (see §7). | `normal` |
| `MYSQL_ROOT_PASSWORD` | Root password for the `db` container (administration only). | `change-me-root-password` |
| `MYSQL_DATABASE` | Schema created on first DB-container start. Keep as `w5base`. | `w5base` |
| `MYSQL_USER` | App DB user the container creates and grants. Keep as `w5base`. | `w5base` |
| `MYSQL_PASSWORD` | Password assigned to `MYSQL_USER`. **Must equal `W5BASE_DB_PASSWORD`.** | `change-me-w5base-db-password` |

### Step 2 — Build and start the stack

```bash
docker compose up --build
```

This is the one command that produces a running instance. Here is **what
happens, in order** — this ordering is what makes the one-command experience
deterministic:

1. The **`db`** service (MySQL 8 / MariaDB) starts and initializes the `w5base`
   schema and application user from the `MYSQL_*` variables.
2. Compose **gates** the app on database readiness
   (`depends_on: db: condition: service_healthy`), using a MySQL healthcheck
   (`mysqladmin ping`) with a `start_period` of about **60 s**. Only once the
   database reports *healthy* does the **`w5base`** app service proceed — so its
   schema build cannot race an uninitialized database (see §6).
3. The app service's `docker/entrypoint.sh` then runs, in dependency order:
   - **exports** the environment variables from `.env`;
   - **creates** the `w5base` service account and the runtime directories
     `/etc/w5base`, `/var/opt/w5base`, `/var/opt/w5base/state`, and
     `/var/log/w5base`;
   - **renders** `/etc/w5base/w5server.conf`, `/etc/w5base/w5base.conf`, and
     `/etc/w5base/databases.conf` from the templates in `docker/w5base/`;
   - **creates and grants** the `w5base` database user with modern
     `CREATE USER` / `GRANT` (replacing the legacy `INSERT INTO user` recipe —
     `README.txt` L145-L164);
   - **builds the schema non-interactively** with
     `sbin/W5Event -c <config> -s -d -v TableVersionCheck` (running this off the
     web path avoids a web-server timeout — `README.txt` L456-L459);
   - **starts** the persistent control-plane process server `sbin/W5Server`;
   - **runs Apache in the foreground** (`apache2ctl -D FOREGROUND`) as the
     container's main process.

Deeper detail on each component lives in
[`./ARCHITECTURE.md`](./ARCHITECTURE.md).

### Step 3 — Open the application

```
${W5BASE_BASE_URL}/w5base/auth/base/menu/root
# e.g. http://localhost:8080/w5base/auth/base/menu/root
```

The published host port is **`8080:80`** (host `8080` → container `80`), so with
the template's `W5BASE_BASE_URL=http://localhost:8080` the main menu is at the
URL above. When the generated main-menu mask renders, the environment is up.

---

## 3. First Login

**Auth model.** For this development base, Apache performs **HTTP Basic**
authentication on `/w5base/auth` and passes the authenticated identity
(`REMOTE_USER`) to W5Base. The kernel treats the configured **`MASTERADMIN`** as
an administrator **always** — regardless of whether that account is a member of
the `admin` group and even before in-application user administration is
initialized (`README.ConfigParameters.txt` L82-L86). `MASTERADMIN` is rendered
from **`W5BASE_ADMIN`**, and the container seeds its `htpasswd` from
`W5BASE_ADMIN` / `W5BASE_ADMIN_PASSWORD`, so those two values are all you need
for a first login.

**Log in** with the credentials you set in `.env`:

- **Username:** the value of `W5BASE_ADMIN` (e.g. `local/admin`)
- **Password:** the value of `W5BASE_ADMIN_PASSWORD`

On success, the generated main-menu mask renders at
`/w5base/auth/base/menu/root`. **That render is the acceptance signal for the
whole environment.**

**Why the first login reaches the menu (and not a verification page).** W5Base's
kernel treats an authenticated identity that is not yet linked to an *active*
internal `contact` record as a brand-new user, and diverts every request to a
first-login **account-verification** page — and then a **GTC-acceptance** page.
Completing those pages requires an e-mail round-trip through an SMTP server,
which this minimal development base intentionally does **not** run (mail, LDAP,
and Oracle are out of scope). To keep the "one command → main menu" promise,
`docker/entrypoint.sh` **seeds an active, GTC-accepted `contact` for
`MASTERADMIN` and links it to the login account** immediately after the schema
build. This writes only the same runtime *data* rows the framework itself would
create once verification completed — it changes **no application code and no
schema** — so your first login lands directly on the menu. The seed is
**idempotent** (skipped once the admin account is already active), and the
seeded contact's e-mail defaults to `${W5BASE_ADMIN}@w5base.local` (override with
the optional `W5BASE_ADMIN_EMAIL` in `.env`).

> **Note on the DB host.** Unlike the legacy single-host install, the app and
> database run in **separate containers**. The database host in `W5BASE_DSN` is
> therefore the Compose **service name `db`** (e.g.
> `dbi:mysql:database=w5base;host=db;port=3306`), *not* `localhost`. Compose's
> internal DNS resolves `db` to the database container.

---

## 4. Verifying Health (Smoke Test)

Because W5Base ships **no unit-test framework**, environment health is asserted
by a smoke test that checks the four signals that together prove a working
install. Run it against the running stack:

```bash
tests/smoke/w5base_smoke_test.sh
```

The script asserts **four health signals**, and each one matters for a distinct
reason:

1. **`sbin/W5Server` is up.** The web frontend cannot function without the
   persistent control-plane process server — *"The W5Base Web-Frontend needs a
   running sbin/W5Server"* (`README.txt` L481-L483). If it is down, pages error
   and events never complete.
2. **The main menu renders at `/w5base/auth/base/menu/root`.** The smoke test
   requires HTTP `200` **and** verifies the response *body* is the real main-menu
   frameset (it contains the `menutop` + `msel` navigation iframes). A bare `200`
   is deliberately **not** treated as sufficient: the kernel also returns `200`
   for the first-login *account verification* and *GTC verification* gates, so
   the test explicitly rejects those pages and passes only on the actual menu —
   proving it renders end-to-end (Apache → mod_perl2 → `bin/app.pl` → kernel →
   database).
3. **`sbin/W5InstallCheck` reports a healthy install.** This tool verifies the
   integrity of the installation and catches most setup mistakes
   (`README.txt` L448-L451).
4. **`TableVersionCheck` is clean.** The schema reconciled by
   `sbin/W5Event ... -v TableVersionCheck` completes with no schema errors
   (`README.txt` L453-L459).

You can reproduce signal (2) manually from your host with `curl`. Pass the admin
credentials through a **temporary, mode-`0600` curl config file** rather than on
the command line, so the password never appears in your shell history or in
process listings (`ps`). This is the same non-argv mechanism the automated
[smoke test](../tests/smoke/w5base_smoke_test.sh) uses:

```bash
# Write the Basic-auth credentials into a private 0600 file (never on the argv)...
cred="$(mktemp)"; chmod 600 "$cred"
printf 'user = "%s:%s"\n' "$W5BASE_ADMIN" "$W5BASE_ADMIN_PASSWORD" > "$cred"
# ...save the body so we can confirm it is the MENU, not a 200-returning gate...
body="$(mktemp)"
# ...remove both automatically when the shell exits...
trap 'rm -f "$cred" "$body"' EXIT
# ...and let curl read the credentials from the file with -K:
code="$(curl -K "$cred" -s -o "$body" -w '%{http_code}' \
        "$W5BASE_BASE_URL/w5base/auth/base/menu/root")"
echo "HTTP $code"
# The main-menu frameset contains the menutop + msel navigation iframes; the
# first-login gates (which also return 200) do not.
grep -qi 'menutop' "$body" && grep -qi 'msel' "$body" \
  && echo "OK: main menu rendered" \
  || echo "NOT the menu (a 200 here is likely the account-verification / GTC gate)"
```

A `200` **with** the `menutop`/`msel` menu frames confirms the main menu rendered
for the admin identity. A `200` **without** them means you reached a first-login
*account verification* or *GTC* gate — verify that `docker/entrypoint.sh` seeded
the `MASTERADMIN` contact (see [§3, First Login](#3-first-login)). A `401` means
the Basic-auth credentials did not match the container `htpasswd` (re-check
`W5BASE_ADMIN` / `W5BASE_ADMIN_PASSWORD` in `.env`).

---

## 5. Security (Change the Defaults)

> **Change the legacy default credentials.** W5Base's historically documented
> default is user **`dummy/admin`** with password **`acache`** (the password is
> tied to the external `mod_auth_ae` / `acache` cache that this base deliberately
> excludes) — `README.txt` L474-L479. **These MUST be changed.** Set your own
> **`W5BASE_ADMIN`** and **`W5BASE_ADMIN_PASSWORD`** in `.env` before you start
> the stack.

- **Never hardcode secrets.** Every credential flows one way:
  `.env` → Compose `env_file` → `docker/entrypoint.sh` → the rendered
  `/etc/w5base/*.conf` files (and the container `htpasswd`). The templates and
  config files contain **only `${...}` references**, never literal secrets.
- **Do not commit `.env`.** Only the placeholder template `.env.example` is
  committed. Keep real values in `.env`, which is git-ignored.
- **Oracle and LDAP are intentionally out of scope for this base.** Running
  `Net::LDAP` together with `DBD::Oracle` in the same process is a documented
  segmentation-fault hazard (`README.txt` L465-L467), so neither is installed
  here. Do not add them to this environment.

---

## 6. Troubleshooting

Each item below explains **why** the problem happens, not just the fix.

### Prefork MPM is mandatory

**Why:** mod_perl2 embeds a persistent Perl interpreter in each Apache process
and is only supported on the **prefork** MPM; the threaded worker/event MPM will
fail to load mod_perl. The legacy guide's package list reflects this by
installing `apache2-mpm-prefork` (`README.txt` L34). **How the image handles
it:** the build disables the threaded MPMs and enables prefork plus mod_perl
(`a2dismod mpm_event mpm_worker`, then `a2enmod mpm_prefork perl`). **How to
check** inside the running app container:

```bash
docker compose exec w5base apachectl -M | grep -E 'perl|prefork'
# expect: perl_module (shared) and mpm_prefork_module (shared/static)
```

### "Lost connection to MySQL server during query"

**Why:** W5Base sometimes issues very long-running queries directly over the
network, and mod_perl / `Apache::DBI` keeps pooled connections idle for long
periods. With MySQL's default timeouts, the server drops such connections
mid-query and you see this error. **Fix (already applied):** the environment
mounts `docker/mysql/my.cnf` into the `db` service, which raises
`net_read_timeout`, `net_write_timeout`, and `wait_timeout`
(`README.txt` L490-L497). If you still hit it under an unusually heavy query,
raise those values further in `docker/mysql/my.cnf` and restart the `db` service.

### The web frontend errors — is W5Server running?

**Why:** the persistent `sbin/W5Server` process handles all *"asyncron and
atomic"* operations over TCP for the web frontend
(`W5Server.README.txt` L1-L6); if it is not running, pages error or events never
complete. **How to check / recover** inside the app container: confirm the
W5Server process is listening on its control port (`12833`). To reload module
code without a full restart, send it a **`USR1`** (soft restart); this takes up
to ~15 s while running events finish cleanly (`W5Server.README.txt` L18-L23).

### The app started before the database was ready

**Why:** a bare `depends_on` waits only for the dependency container to *start*,
not to be *ready to accept connections* — which causes connection-refused races
on first boot. **How the environment prevents it:** the app is gated with
`depends_on: db: condition: service_healthy` plus a MySQL healthcheck and a
`start_period` of ~60 s, so the entrypoint's `TableVersionCheck` never runs
against an uninitialized database. If you ever remove that gate, expect
first-boot races.

### Rebuild / reset

```bash
# stop the stack (keeps the database volume)
docker compose down

# stop AND drop the db_data volume for a clean schema rebuild
docker compose down -v      # WARNING: -v deletes all database data

# rebuild and start fresh
docker compose up --build
```

Use `docker compose down -v` when you want `TableVersionCheck` to rebuild the
schema from scratch. **`-v` permanently deletes the database volume**, so only
use it when you intend to discard local data.

### Where to look — logs

```bash
docker compose logs w5base   # app container: entrypoint, W5Server, Apache
docker compose logs db       # database container
```

Inside the app container, application and web logs are under
**`/var/log/w5base/`** (including the Apache error log configured by the vhost).

---

## 7. Operation Modes

`W5BASE_OPERATION_MODE` is rendered into `w5base.conf` as the framework key
**`W5BaseOperationMode`**, which selects how the application behaves at runtime.
The framework reference `etc/w5base/default.conf` ships **`online`**; the
committed `.env.example` sets **`normal`** as a safe local-development default.

Valid values (from `etc/w5base/default.conf` L40) are:

```
test | automodify | online | normal | maintenance | offline | dev | slave | readonly[:comment]
```

(An additional `baseslave` mode makes all main tables read-only and skips table
version control — `README.txt` L559-L562.)

> **Critical rule:** the operation mode **must be set identically for both
> `sbin/W5Server` and the web frontend** — *"Ensure, that the
> W5BaseOperationMode is set for W5Server AND Userfrontend!"* (`README.txt`
> L557). In this environment both read the same rendered configuration, so a
> single `W5BASE_OPERATION_MODE` keeps them in sync.

See [`./ARCHITECTURE.md#7-operation-modes`](./ARCHITECTURE.md#7-operation-modes)
for the full semantics of each mode.

---

## 8. Next Steps and References

- **How it works:** [`./ARCHITECTURE.md`](./ARCHITECTURE.md) — the
  metadata-driven framework model, the request path, and the control plane.
- **Module guides:** [`./modules/kernel.md`](./modules/kernel.md) (the `lib/` +
  `mod/base` kernel), [`./modules/itil.md`](./modules/itil.md) (the core
  CMDB/ITSM module), and [`./modules/crm.md`](./modules/crm.md) (a compact
  representative module).
- **Root pointer:** [`../README.md`](../README.md) — the repository's
  "Quick Start" section that links here.
- **Legacy references (unchanged):**
  [`../README.txt`](../README.txt) is the original, still-untouched detailed
  install/operation guide; [`../README.ConfigParameters.txt`](../README.ConfigParameters.txt)
  documents configuration keys such as `DATAOBJCONNECT`, `DATAOBJUSER`,
  `DATAOBJPASS`, and `MASTERADMIN`; and
  [`../W5Server.README.txt`](../W5Server.README.txt) covers the control-plane
  server's signals and operation.

