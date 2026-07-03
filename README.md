# W5Base

**W5Base** (branded **"Darwin"**) is a GPL-2.0, **metadata-driven
application/database framework** — most often deployed as a CMDB / ITSM platform —
built on **Apache + mod_perl2 + MySQL**. Its defining idea is that you *declare a
data object once* and the framework generates its web UI (a "mask"), its REST/SOAP
interface, and its relational persistence from that single declaration, so there
is no hand-written form, controller, and schema to keep in sync. For how the
framework works under the hood, see
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**; the original, detailed
Debian install/operations guide remains at **[README.txt](README.txt)** (see
[Documentation](#documentation) below).

## Quick Start (Containerized Dev Environment)

This is the fast path to a running, logged-in W5Base on your machine. It uses a
modern **Debian + Apache (prefork MPM) + mod_perl2 + MySQL / MariaDB** stack, and
it is purely **additive**: it only *runs and wires to* the repository's own
utilities and changes no application code, kernel, or schema.

**Prerequisites:** Docker and Docker Compose v2 (the `docker compose` subcommand)
installed and running.

1. **Configure your environment.** Copy the committed template to a local,
   git-ignored `.env`, then edit it — set real values and **change the legacy
   default credentials** (`dummy/admin` / `acache`). Never commit `.env`.

   ```bash
   cp .env.example .env
   # then edit .env: set W5BASE_ADMIN, W5BASE_ADMIN_PASSWORD, W5BASE_DB_PASSWORD, ...
   ```

2. **Build and start the stack** (the one command that produces a running
   instance):

   ```bash
   docker compose up --build
   ```

3. **Open the main menu** and log in via **HTTP Basic** using the
   `W5BASE_ADMIN` / `W5BASE_ADMIN_PASSWORD` values you set (they map to the
   framework's `MASTERADMIN` admin identity):

   ```
   ${W5BASE_BASE_URL}/w5base/auth/base/menu/root
   # e.g. http://localhost:8080/w5base/auth/base/menu/root
   ```

   When the generated main-menu mask renders, the environment is up — **that
   render is the acceptance signal for the whole stack.**

For the full runbook (prerequisites, first login, and troubleshooting) see
**[docs/LOCAL_SETUP.md](docs/LOCAL_SETUP.md)**.

## Documentation

- **[docs/LOCAL_SETUP.md](docs/LOCAL_SETUP.md)** — onboarding runbook: the single
  command, first login, health checks, security notes, and troubleshooting.
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — architecture overview: the
  metadata-driven framework model, the request path, the control plane
  (`sbin/W5Server`), schema versioning, and the filesystem layout.
- **Module guides** — [docs/modules/kernel.md](docs/modules/kernel.md) (the
  `lib/` + `mod/base` kernel), [docs/modules/itil.md](docs/modules/itil.md) (the
  core CMDB / ITSM module), and [docs/modules/crm.md](docs/modules/crm.md) (a
  compact, representative module).
- **Legacy references (unchanged):** [README.txt](README.txt) is the original,
  still-untouched detailed Debian install/operations guide, and
  [README.ConfigParameters.txt](README.ConfigParameters.txt) documents the
  configuration parameters (`DATAOBJCONNECT`, `DATAOBJUSER`, `DATAOBJPASS`,
  `MASTERADMIN`, ...).

## Tests

W5Base ships no unit-test framework, so environment health is asserted by a
smoke / health-check test at
**[tests/smoke/w5base_smoke_test.sh](tests/smoke/w5base_smoke_test.sh)**. Run it
against the running stack; it verifies the five signals that together prove a
working install: **`sbin/W5Server` is up**, the **main menu returns HTTP 200** at
`/w5base/auth/base/menu/root`, **`sbin/W5InstallCheck`** reports a healthy install,
**`TableVersionCheck`** completes with no schema errors, and a **generated menu
link resolves** under `/w5base` (proving the menu is *navigable*, not just rendered).

```bash
tests/smoke/w5base_smoke_test.sh
```

## License

W5Base is released under the **GNU General Public License v2** — see
[LICENSE](LICENSE).
