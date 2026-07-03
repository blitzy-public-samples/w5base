# Module Guide: The W5Base Kernel (`lib/` + `mod/base`)

> **Scope.** This guide documents the **kernel** — the metadata-driven engine that
> every other W5Base module builds on. The repository defines the kernel in one
> line: <code>librarys - this and mod/base is w5base kernel</code>
> ([`README.txt`](../../README.txt):L510). In other words the kernel is
> [`lib/`](../../lib) **together with** [`mod/base`](../../mod/base).
>
> This guide complements, rather than repeats, the system-wide
> [Architecture Overview](../ARCHITECTURE.md): that document explains the
> end-to-end request path and the control plane, while this guide goes one level
> deeper into the kernel classes under [`lib/kernel/`](../../lib/kernel) and the
> base data objects that ship in [`mod/base`](../../mod/base). If you are standing
> the environment up for the first time, start with the
> [Local Setup runbook](../LOCAL_SETUP.md).
>
> **This document only *describes* existing code — it changes nothing.** Every
> path it references is read-only for the containerized-environment work.

---

## Table of Contents

1. [What the kernel is (and why it exists)](#1-what-the-kernel-is-and-why-it-exists)
2. [How the kernel is organized](#2-how-the-kernel-is-organized)
3. [The data-object model: one declaration, many faces](#3-the-data-object-model-one-declaration-many-faces)
4. [The field catalog (`kernel::Field`)](#4-the-field-catalog-kernelfield)
5. [Storage backends (`kernel::DataObj::*`)](#5-storage-backends-kerneldataobj)
6. [Multi-tenant field-level authorization (`kernel::MandatorDataACL`)](#6-multi-tenant-field-level-authorization-kernelmandatordataacl)
7. [Event dispatch and the control plane (`kernel::EventController`)](#7-event-dispatch-and-the-control-plane-kerneleventcontroller)
8. [What `mod/base` ships](#8-what-modbase-ships)
9. [How to read a data object](#9-how-to-read-a-data-object)
10. [Backward-compatibility note](#10-backward-compatibility-note)
11. [Where to go next](#11-where-to-go-next)

---

## 1. What the kernel is (and why it exists)

**What.** W5Base (branded *Darwin*) is a **metadata-driven application/database
framework**. Instead of hand-writing a controller, an HTML form, a REST handler,
a SOAP interface, and a set of SQL statements for every entity, a developer
**declares a "data object"** — a class that lists its typed fields and how they
map to storage — and the kernel **generates** the UI "masks", the REST/SOAP
interfaces, filtering, export, and persistence from that single declaration.

**Why.** A CMDB/ITSM platform has hundreds of related entities (applications,
assets, IP networks, contracts, business processes, …). Re-implementing the same
CRUD / authorization / rendering plumbing per entity would be enormous and
inconsistent. The kernel factors all of that plumbing into a small set of base
classes, so a new object is a **declaration**, not a subsystem. That is the
single most important idea in the whole codebase.

**How (at a glance).** The repository itself draws the boundary (attributed
above to [`README.txt`](../../README.txt):L510): the kernel is the abstract
machinery in `lib/` plus the concrete base objects in `mod/base`.

- [`lib/kernel/`](../../lib/kernel) holds the **abstract machinery** — the base
  classes for data objects, fields, application handlers, ACLs, events, rendering,
  menus, and workflow.
- [`mod/base`](../../mod/base) holds the **concrete data objects the framework
  itself needs** to be usable — users, groups, tenants ("mandators"), menus,
  status catalogs, files, statistics, and so on. These are ordinary data objects
  built with the very same kernel every downstream module uses.

Because both halves use one model, learning the kernel means you can read *any*
module: [ITIL](./itil.md) and [CRM](./crm.md) are simply larger and smaller
collections of the same kind of declarations.

---

## 2. How the kernel is organized

### Core classes

The load-bearing classes under [`lib/kernel/`](../../lib/kernel) — and their
verified inheritance (`@ISA`) — are:

| Class | File | `@ISA` | Role |
|-------|------|--------|------|
| `kernel::DataObj` | [`DataObj.pm`](../../lib/kernel/DataObj.pm) (~171 KB, the largest kernel file) | `qw(kernel::App kernel::WSDLbase)` | Base class of **every** data object (see §3) |
| `kernel::Field` | [`Field.pm`](../../lib/kernel/Field.pm) (~51 KB) | `qw(kernel::Universal)` | Typed-field abstraction; parent of the field-type catalog (see §4) |
| `kernel::App` | [`App.pm`](../../lib/kernel/App.pm) (~69 KB) | `qw(kernel::Universal kernel::TemplateParsing)` | Base application/handler class (config, DB, session, templating) |
| `kernel::EventController` | [`EventController.pm`](../../lib/kernel/EventController.pm) | `qw(kernel::App)` | Event dispatch into the control plane (see §7) |
| `kernel::MandatorDataACL` | [`MandatorDataACL.pm`](../../lib/kernel/MandatorDataACL.pm) | *(utility package — no `@ISA`)* | Multi-tenant, field-level access control (see §6) |
| `kernel::WSDLbase` | [`WSDLbase.pm`](../../lib/kernel/WSDLbase.pm) | — | SOAP/WSDL exposure base mixed into `kernel::DataObj` |

`kernel::App` is the hub of this table: `kernel::DataObj`, `kernel::EventController`,
and standalone admin tools (such as `sbin/W5InstallCheck`) all inherit from it,
which is why they share the same config, database, session, and templating
plumbing. Its own parent `kernel::TemplateParsing` is what supplies mask/template
rendering.

### Supporting kernel modules

`lib/kernel/` also contains the machinery the base classes lean on. You rarely
subclass these directly, but knowing what they do makes the request path legible:

| Module(s) | Role |
|-----------|------|
| [`MenuTree.pm`](../../lib/kernel/MenuTree.pm) / [`MenuRegistry.pm`](../../lib/kernel/MenuRegistry.pm) | Build and register the navigable menu tree that the main menu renders from |
| [`Output.pm`](../../lib/kernel/Output.pm) / [`Formater.pm`](../../lib/kernel/Formater.pm) / [`TemplateParsing.pm`](../../lib/kernel/TemplateParsing.pm) | Render the generated masks — output buffering, value formatting, and template parsing |
| [`database.pm`](../../lib/kernel/database.pm) / [`config.pm`](../../lib/kernel/config.pm) / [`cgi.pm`](../../lib/kernel/cgi.pm) | Low-level database access, parsing of the `/etc/w5base/*.conf` files, and HTTP request/response I/O |
| [`WSDLbase.pm`](../../lib/kernel/WSDLbase.pm) | The SOAP/WSDL base that gives every data object a web-service face |
| [`QRule.pm`](../../lib/kernel/QRule.pm) | The **quality-rule** engine that validates stored data against declared rules |
| [`Wf.pm`](../../lib/kernel/Wf.pm) / [`WfClass.pm`](../../lib/kernel/WfClass.pm) / [`WfStep.pm`](../../lib/kernel/WfStep.pm) | The **workflow** engine — workflow instances, classes, and steps |
| [`Timetool.pm`](../../lib/kernel/Timetool.pm) | Time/date handling shared across objects and fields |

The storage backends live under [`lib/kernel/DataObj/`](../../lib/kernel/DataObj)
and the field types under [`lib/kernel/Field/`](../../lib/kernel/Field); both are
covered below.

---

## 3. The data-object model: one declaration, many faces

Every data object inherits from `kernel::DataObj`, whose own inheritance is the
key to the "one declaration, many faces" idea
([`lib/kernel/DataObj.pm`](../../lib/kernel/DataObj.pm)):

```perl
package kernel::DataObj;
@ISA = qw(kernel::App kernel::WSDLbase);
```

Because a data object is **simultaneously** a `kernel::App` (an application
handler that can drive interactive UI and behavior) **and** a `kernel::WSDLbase`
(SOAP/WSDL-exposable), *the same declaration yields both a web UI mask and a
web-service interface* with no extra code. This dual inheritance is the mechanism
behind "declare once → UI **and** SOAP/WSDL for free."

**How a declaration looks.** In a data object's constructor, the object calls
`AddFields(...)` with a list of typed `kernel::Field::*` objects. Each field
carries its label, its storage mapping (`dataobjattr`), and — where relevant —
how it joins to other objects. A compact, real example is walked through in the
[CRM module guide](./crm.md); the shape is:

```perl
$self->AddFields(
   new kernel::Field::Linenumber(name => 'linenumber', label => 'No.'),
   new kernel::Field::Id(name => 'id', label => 'W5BaseID',
                         dataobjattr => 'businessprocess.id'),
   new kernel::Field::RecordUrl(),
   new kernel::Field::Mandator(),
   # ... more typed fields ...
);
```

**Why this matters.** From that declared field list the kernel can, without
per-object code:

- render **list and detail masks** (each field type knows how to display and
  edit itself);
- build **filters / search** (each field type knows how it can be queried);
- serialize **REST/SOAP payloads** (each field type knows how to marshal itself);
- generate the **SQL** needed to read and write the mapped columns.

---

## 4. The field catalog (`kernel::Field`)

`kernel::Field` ([`lib/kernel/Field.pm`](../../lib/kernel/Field.pm),
`@ISA = qw(kernel::Universal)`) is the abstraction that makes generation
possible. A data object declares a **set of typed fields**, and the framework
ships a **large catalog of field types** — more than **seventy** of them — under
[`lib/kernel/Field/`](../../lib/kernel/Field), each a `kernel::Field::*` subclass.
Representative, real types include:

- **Identity / bookkeeping:** `Id`, `Linenumber`, `RecordUrl`, `Mandator`
- **Scalar values:** `Text`, `Textarea`, `Number`, `Currency`, `Boolean`, `Date`
- **Choice & contact:** `Select`, `Email`, `Contact`
- **Relationships:** `Link`, `SubList` (these express joins to other data objects)
- **Sensitive / special:** `Password`, `File`

**Why field types matter.** Each type encapsulates three responsibilities — **how
to render**, **how to be filtered**, and **how to serialize/marshal**. That is
precisely why masks, filter forms, list columns, and REST/SOAP payloads can be
**generated automatically** from the declared field list: the intelligence lives
in the field types, not in per-object code. Adding a differently-behaving column
usually means picking a different `kernel::Field::*` type, not writing new
rendering or query logic.

---

## 5. Storage backends (`kernel::DataObj::*`)

A data object declares *what* it is; a **storage backend** decides *where* its
records live. `kernel::DataObj` is deliberately **storage-agnostic**: a module
author declares fields once and selects a backend, and the same UI and API then
work over SQL, a REST service, LDAP, and so on. The backends are the
`kernel::DataObj::*` subclasses under
[`lib/kernel/DataObj/`](../../lib/kernel/DataObj):

| Backend | File | Backing store |
|---------|------|---------------|
| `kernel::DataObj::DB` | [`DB.pm`](../../lib/kernel/DataObj/DB.pm) | Relational database (the common case; MySQL/MariaDB here) |
| `kernel::DataObj::REST` | [`REST.pm`](../../lib/kernel/DataObj/REST.pm) | A remote REST service |
| `kernel::DataObj::LDAP` | [`LDAP.pm`](../../lib/kernel/DataObj/LDAP.pm) | An LDAP directory |
| `kernel::DataObj::ElasticSearch` | [`ElasticSearch.pm`](../../lib/kernel/DataObj/ElasticSearch.pm) | An Elasticsearch index |
| `kernel::DataObj::SOAPuCMDB` | [`SOAPuCMDB.pm`](../../lib/kernel/DataObj/SOAPuCMDB.pm) | A SOAP-based uCMDB source |
| `kernel::DataObj::ShellConnectJSON` | [`ShellConnectJSON.pm`](../../lib/kernel/DataObj/ShellConnectJSON.pm) | JSON emitted by an external shell/connector command |
| `kernel::DataObj::Static` | [`Static.pm`](../../lib/kernel/DataObj/Static.pm) | In-code static rows |

**Most persistent business objects inherit `kernel::DataObj::DB`** (which is
itself `@ISA = qw(kernel::DataObj UNIVERSAL)`), so "a data object" in practice
usually means "a `kernel::DataObj::DB` subclass". You will see exactly this in the
[ITIL](./itil.md) and [CRM](./crm.md) guides. But the abstraction is real: for
example, [`base::cistatus`](../../mod/base/cistatus.pm) uses
`kernel::DataObj::Static` — a small, code-defined status catalog with no table of
its own — proving that the *same* field/mask/API machinery runs over a non-SQL
store.

In this containerized dev environment the relational backend is the one that
matters: it is what `TableVersionCheck` reconciles against MySQL/MariaDB during
setup (see the [Architecture Overview](../ARCHITECTURE.md) and the
[Local Setup runbook](../LOCAL_SETUP.md)). The LDAP backend is deliberately
**not** exercised here — LDAP is out of scope for this base image.

---

## 6. Multi-tenant field-level authorization (`kernel::MandatorDataACL`)

`kernel::MandatorDataACL`
([`lib/kernel/MandatorDataACL.pm`](../../lib/kernel/MandatorDataACL.pm)) is the
kernel's **multi-tenant** (W5Base calls a tenant a **"mandator"**) **field-level
access-control** layer. It is a small utility package (it declares no `@ISA`) that
data objects call into.

- **What it does.** Its `expandByDataACL` method takes a mandator (or list of
  mandators) plus a starting set of **field-groups** and expands that set
  according to stored **allow/deny** rules — so different tenants and roles see
  different **subsets of fields** on the *same* object. This is W5Base's
  field-level authorization.
- **How.** `expandByDataACL` reads the rules from the
  [`base::mandatordataacl`](../../mod/base/mandatordataacl.pm) data object, filtered
  by the object and the mandator(s). Each rule carries a `dataname` (the
  field-group), an `aclmode` (`allow` or `deny`, where `deny` contributes a
  negating `!` rule), and a `target`. A rule applies when its `target` is
  [`base::grp`](../../mod/base/grp.pm) and the current user is a member of that
  group, or when its `target` is [`base::user`](../../mod/base/user.pm) and matches
  the current user id. The method returns the expanded field-group list, which the
  caller uses to decide which columns to show.
- **Why it is factored out.** Authorization is orthogonal to what an object *is*,
  so it lives in one reusable place rather than being copied into every object.
  Downstream objects — for example [CRM's `businessprocess`](./crm.md) and
  [ITIL's `appl`](./itil.md) — reuse this same field-group ACL.

---

## 7. Event dispatch and the control plane (`kernel::EventController`)

`kernel::EventController`
([`lib/kernel/EventController.pm`](../../lib/kernel/EventController.pm),
`@ISA = qw(kernel::App)`) is the **event dispatch** layer. It loads and runs
event handlers and carries work from a web or CLI request into the **persistent
control plane** — the `sbin/W5Server` process described in the
[Architecture Overview](../ARCHITECTURE.md). Because it inherits `kernel::App`, an
event handler has the same config/DB/session context a normal request does.

It is the seam between synchronous request handling and asynchronous/atomic
background work: a request can hand an operation to the controller, which
cooperates with W5Server so the work runs in the long-lived process rather than
in the short-lived web worker. The full control-plane topology — how W5Server is
started and reached — is documented in the
[Architecture Overview](../ARCHITECTURE.md); this guide only names the entry
point.

---

## 8. What `mod/base` ships

[`mod/base`](../../mod/base) is the other half of the kernel. It contains
**113 top-level entries** — 100 `*.pm` data objects/helpers plus 13
subdirectories — all built with the same kernel every other module uses. The
important objects fall into a few groups (this is a curated tour, not the full
list).

**Identity & access** — the backbone of who-can-see-what:

- [`base::grp`](../../mod/base/grp.pm) — groups (also used to model
  organizations/customers via joins)
- [`base::user`](../../mod/base/user.pm),
  [`base::useraccount`](../../mod/base/useraccount.pm),
  [`base::userlogon`](../../mod/base/userlogon.pm) — user identity and login
- [`base::lnkgrpuser`](../../mod/base/lnkgrpuser.pm) /
  [`base::lnkgrpuserrole`](../../mod/base/lnkgrpuserrole.pm) — user↔group
  membership and the role held within a group
- [`base::mandator`](../../mod/base/mandator.pm) — tenants ("mandators")
- [`base::mandatordataacl`](../../mod/base/mandatordataacl.pm) — the persisted
  field-group ACL rules consumed by `kernel::MandatorDataACL` (§6)

**Platform / CMDB base** — objects the whole platform depends on:

- [`base::cistatus`](../../mod/base/cistatus.pm) — configuration-item lifecycle
  status (a `kernel::DataObj::Static` catalog, see §5)
- [`base::load`](../../mod/base/load.pm) — bulk load/import support
- [`base::filemgmt`](../../mod/base/filemgmt.pm) — attachment / file management
- [`base::w5stat`](../../mod/base/w5stat.pm) — statistics/reporting objects

**Navigation & process** — the menu tree and long-running work:

- [`base::menu`](../../mod/base/menu.pm) — the menu/masks tree; the main menu at
  `/w5base/auth/base/menu/root` is served from here
- [`base::workflow`](../../mod/base/workflow.pm) and its family
  ([`base::workflowaction`](../../mod/base/workflowaction.pm),
  [`base::workflowkey`](../../mod/base/workflowkey.pm), …) — workflow data
- [`base::qrule`](../../mod/base/qrule.pm) — quality rules
- [`base::joblog`](../../mod/base/joblog.pm) — job logging

### Subdirectories (13)

`mod/base` is organized into the same subtree shape that recurs across functional
modules — so once you learn this layout you recognize it everywhere. The
[CRM guide](./crm.md) teaches the canonical module anatomy in detail.

| Subdirectory | Purpose |
|--------------|---------|
| [`lib/`](../../mod/base/lib) | Shared base classes/helpers reused by `base::*` objects |
| [`menu/`](../../mod/base/menu) | The module's menu-tree contributions |
| [`workflow/`](../../mod/base/workflow) | Workflow definitions |
| [`qrule/`](../../mod/base/qrule) | Quality rules that validate data |
| [`w5stat/`](../../mod/base/w5stat) | Statistics/reporting objects |
| [`event/`](../../mod/base/event) | Event handlers (dispatched via `kernel::EventController`) |
| [`ext/`](../../mod/base/ext) | Extension points/helpers |
| [`Explore/`](../../mod/base/Explore) | Exploration/browsing UI helpers |
| [`MyW5Base/`](../../mod/base/MyW5Base) | Per-user "MyW5Base" dashboard contributions |
| [`QuickFind/`](../../mod/base/QuickFind) | Quick-find/search contributions |
| [`WebNotify/`](../../mod/base/WebNotify) | Web-notification contributions |
| [`ObjectEventHandler/`](../../mod/base/ObjectEventHandler) | Object-level event-handler registrations |
| [`W5Server/`](../../mod/base/W5Server) | Control-plane (W5Server) contributions |

### Preloaded into mod_perl at Apache startup

A privileged subset of `mod/base` objects is **preloaded into mod_perl when
Apache starts**, by [`sbin/ApacheStartup.pl`](../../sbin/ApacheStartup.pl). This
matters for two reasons: (1) the Perl interpreter is **warm** — these classes are
compiled once at startup instead of on the first request — and (2) under the
prefork MPM the compiled code is **shared** across worker processes, lowering
memory use and latency. Before loading anything, `ApacheStartup.pl` first
prepends `$W5V2::INSTDIR/mod` and `$W5V2::INSTDIR/lib` to Perl's `@INC` so these
`base::*` modules (and the kernel) resolve.

The verified preload set is:

```text
base::start        base::MyW5Base     base::workflow     base::grp
base::user         base::useraccount  base::userlogon    base::userbookmark
base::lnkcontact   base::lnkgrpuser   base::workflowkey  base::cistatus
base::load         base::filemgmt     base::w5stat       base::menu
base::qrule        base::joblog       base::mandator     base::userdefault
base::usermask
```

For how this vhost wiring fits into the overall request path (the
`$W5V2::INSTDIR` + `require .../sbin/ApacheStartup.pl` + `Apache::DBI` pattern),
see the [Architecture Overview](../ARCHITECTURE.md).

### Why this is the foundation

Every functional module — [`mod/itil`](../../mod/itil), [`mod/crm`](../../mod/crm),
and the rest — is just a set of declared data objects that **inherit
`kernel::DataObj`** (usually via `kernel::DataObj::DB`) and reuse the field system,
storage backends, field-level ACLs, menus, rendering, and workflow provided here.
Adding a feature therefore means **declaring metadata in a module**, not rewriting
kernel plumbing — which is exactly why the kernel is off-limits to routine feature
work (see §10).

---

## 9. How to read a data object

When exploring any object (in `mod/base` or a downstream module), read it in this
order — it is the fastest way to understand an unfamiliar entity:

1. **The `package` line and `@ISA`** — tells you which storage backend
   (`kernel::DataObj::DB`, `::Static`, …) and which mixins (e.g.
   `kernel::MandatorDataACL`) apply.
2. **The `AddFields(...)` list in `new`** — this *is* the entity: its columns,
   labels, storage mapping (`dataobjattr`), and joins to other objects.
3. **Any per-object action / permission hooks** — these implement object-specific
   authorization on top of the field-level ACL from §6.

Everything else (masks, REST/SOAP, SQL) is generated from those declarations by
the kernel, so once you can read the field list you can predict the UI, the API,
and the schema.

---

## 10. Backward-compatibility note

The kernel — both [`lib/`](../../lib) and [`mod/base`](../../mod/base) — is
**read-only** for the containerized-environment work this documentation set
accompanies. The environment **invokes** and **wires to** these files; it never
edits them, preserving application behavior and the schema contract. If you are
extending W5Base with real functionality, you add a **new** data object in a
module rather than modifying the kernel — that is the framework's intended
extension model, and it keeps upgrades safe.

---

## 11. Where to go next

- **See the framework end-to-end:** the [Architecture Overview](../ARCHITECTURE.md)
  (request path, control plane, schema versioning, operation modes).
- **Run it locally:** the [Local Setup runbook](../LOCAL_SETUP.md).
- **A large module built on this kernel:** the [ITIL module guide](./itil.md)
  (the core CMDB/ITSM module).
- **A compact module + the canonical module anatomy:** the
  [CRM module guide](./crm.md).
- **Authoritative legacy reference:** [`README.txt`](../../README.txt).

