# Module Guide: The W5Base Kernel (`lib/` + `mod/base`)

> **Scope.** This guide documents the **kernel** — the metadata-driven engine that
> every other W5Base module builds on. It is written to complement, not repeat,
> the system-wide [Architecture Overview](../ARCHITECTURE.md): that document
> explains the request path and the control plane, while this guide goes one
> level deeper into the kernel classes and the base data objects that ship in
> [`mod/base`](../../mod/base). If you are standing the environment up for the
> first time, start with the [Local Setup runbook](../LOCAL_SETUP.md).

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
CRUD/authorization/rendering plumbing per entity would be enormous and
inconsistent. The kernel factors all of that plumbing into a small set of base
classes, so a new object is a **declaration**, not a subsystem. That is the
single most important idea in the whole codebase.

**How (at a glance).** The kernel lives in [`lib/kernel/`](../../lib/kernel), and
together with [`mod/base`](../../mod/base) it *is* the kernel:

- [`lib/kernel/`](../../lib/kernel) holds the **abstract machinery** — the base
  classes for data objects, fields, application handlers, ACLs, and events.
- [`mod/base`](../../mod/base) holds the **concrete data objects the framework
  itself needs** to be usable — users, groups, tenants ("mandators"), menus,
  history, notes, files, and so on. These are ordinary data objects built with
  the very same kernel every downstream module uses.

---

## 2. How the kernel is organized

The load-bearing classes under [`lib/kernel/`](../../lib/kernel) are:

| Class | File | Role |
|-------|------|------|
| `kernel::DataObj` | [`lib/kernel/DataObj.pm`](../../lib/kernel/DataObj.pm) | Base class of **every** data object; the largest file in the kernel |
| `kernel::Field` | [`lib/kernel/Field.pm`](../../lib/kernel/Field.pm) | Typed-field/attribute abstraction; parent of the field-type catalog |
| `kernel::App` | [`lib/kernel/App.pm`](../../lib/kernel/App.pm) | Base application/handler class (config, DB, logging, templating) |
| `kernel::App::Web` | [`lib/kernel/App/Web.pm`](../../lib/kernel/App/Web.pm) | Web-request specialization of `kernel::App` |
| `kernel::MandatorDataACL` | [`lib/kernel/MandatorDataACL.pm`](../../lib/kernel/MandatorDataACL.pm) | Multi-tenant, field-level access control mixin |
| `kernel::EventController` | [`lib/kernel/EventController.pm`](../../lib/kernel/EventController.pm) | Event dispatch bridging web/CLI requests into the control plane |
| `kernel::WSDLbase` | [`lib/kernel/WSDLbase.pm`](../../lib/kernel/WSDLbase.pm) | SOAP/WSDL exposure base |

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
handler that can drive UI and behavior) **and** a `kernel::WSDLbase`
(SOAP/WSDL-exposable), *the same declaration yields both a web UI mask and a
web-service interface* with no extra code.

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
- build **filters/search** (each field type knows how it can be queried);
- serialize **REST/SOAP payloads** (each field type knows how to marshal
  itself);
- generate the **SQL** needed to read and write the mapped columns.

---

## 4. The field catalog (`kernel::Field`)

`kernel::Field` ([`lib/kernel/Field.pm`](../../lib/kernel/Field.pm)) is the
abstraction that makes generation possible. The framework ships a **large
catalog of field types** — roughly **seventy** of them — under
[`lib/kernel/Field/`](../../lib/kernel/Field). Representative types include:

- **Identity / bookkeeping:** `Id`, `Linenumber`, `RecordUrl`, `Mandator`
- **Scalar values:** `Text`, `Textarea`, `Number`, `Boolean`, `Date`, `Email`
- **Relationships:** `Link`, `TextDrop`, `SubList` (these express joins to other
  data objects)
- **Sensitive / special:** `Password`, `File`, `Contact`

Each type encapsulates three responsibilities — **how to render**, **how to be
filtered**, and **how to serialize**. That is precisely why the kernel can
assemble masks, filters, and API payloads automatically from the declared field
list: the intelligence lives in the field types, not in per-object code.

---

## 5. Storage backends (`kernel::DataObj::*`)

A data object declares *what* it is; a **storage backend** decides *where* its
records live. The backends under
[`lib/kernel/DataObj/`](../../lib/kernel/DataObj) let the same declarative model
sit on very different sources:

| Backend | File | Backing store |
|---------|------|---------------|
| `kernel::DataObj::DB` | [`lib/kernel/DataObj/DB.pm`](../../lib/kernel/DataObj/DB.pm) | Relational database (the default; MySQL/MariaDB here) |
| `kernel::DataObj::REST` | [`lib/kernel/DataObj/REST.pm`](../../lib/kernel/DataObj/REST.pm) | A remote REST service |
| `kernel::DataObj::LDAP` | [`lib/kernel/DataObj/LDAP.pm`](../../lib/kernel/DataObj/LDAP.pm) | An LDAP directory |
| `kernel::DataObj::ElasticSearch` | [`lib/kernel/DataObj/ElasticSearch.pm`](../../lib/kernel/DataObj/ElasticSearch.pm) | An Elasticsearch index |
| `kernel::DataObj::Static` | [`lib/kernel/DataObj/Static.pm`](../../lib/kernel/DataObj/Static.pm) | In-code static rows |

In this containerized dev environment the relational backend
(`kernel::DataObj::DB`) is the one that matters: it is what
`TableVersionCheck` reconciles against MySQL/MariaDB during setup (see the
[Architecture Overview](../ARCHITECTURE.md) and the
[Local Setup runbook](../LOCAL_SETUP.md)). The LDAP backend is deliberately
**not** exercised here — LDAP is out of scope for this base image.

---

## 6. Multi-tenant field-level authorization (`kernel::MandatorDataACL`)

`kernel::MandatorDataACL`
([`lib/kernel/MandatorDataACL.pm`](../../lib/kernel/MandatorDataACL.pm)) is the
kernel's **multi-tenant** (W5Base calls a tenant a **"mandator"**) **data
access-control** layer, mixed into data objects that need it.

- **What it does.** It resolves per-group / per-user **allow/deny field-group
  rules** so that different tenants and roles see different **subsets of
  fields** on the *same* object — W5Base's field-level authorization.
- **How.** Those rules are persisted through the
  [`base::mandatordataacl`](../../mod/base/mandatordataacl.pm) data object and
  applied when a record is read, so two users can open the same record and be
  shown different columns.
- **Why it is a mixin.** Authorization is orthogonal to what an object *is*, so
  it is added via `@ISA` rather than baked into `kernel::DataObj`. Downstream
  objects — for example [CRM's `businessprocess`](./crm.md) and
  [ITIL's `appl`](./itil.md) — pull it in exactly this way.

---

## 7. Event dispatch and the control plane (`kernel::EventController`)

`kernel::EventController`
([`lib/kernel/EventController.pm`](../../lib/kernel/EventController.pm),
`@ISA = qw(kernel::App)`) is the **event dispatch** layer. It loads and runs
event handlers and carries work from a web or CLI request into the **persistent
control plane** (the `sbin/W5Server` process described in the
[Architecture Overview](../ARCHITECTURE.md)). It cooperates with W5Server's
signal handling so that, on a soft restart, in-flight events can finish cleanly
rather than being cut off. This is the seam between synchronous request handling
and asynchronous/atomic background work.

---

## 8. What `mod/base` ships

[`mod/base`](../../mod/base) contains the **framework's own data objects** —
built with the same kernel every other module uses. They fall into a few groups.

**Identity, tenancy, and permissions** (the backbone of who-can-see-what):

- [`base::user`](../../mod/base/user.pm) — user accounts / identities
- [`base::grp`](../../mod/base/grp.pm) — groups (also used to model
  organizations/customers via joins, as CRM does)
- [`base::lnkgrpuser`](../../mod/base/lnkgrpuser.pm) — user↔group membership
- [`base::lnkgrpuserrole`](../../mod/base/lnkgrpuserrole.pm) — the **role**
  assigned to a user within a group (W5Base models roles through this link
  object rather than a standalone `role` object)
- [`base::mandator`](../../mod/base/mandator.pm) — tenants ("mandators")
- [`base::mandatordataacl`](../../mod/base/mandatordataacl.pm) — the persisted
  field-group ACL rules consumed by `kernel::MandatorDataACL` (§6)

**Navigation** (the menu tree the request path renders):

- [`base::menu`](../../mod/base/menu.pm) — the menu/masks tree; the main menu at
  `/w5base/auth/base/menu/root` is served from here
- [`base::menuacl`](../../mod/base/menuacl.pm) — access control for menu entries

**Cross-cutting base objects** used throughout the platform, e.g.
[`base::history`](../../mod/base/history.pm) (audit trail),
[`base::note`](../../mod/base/note.pm),
[`base::msg`](../../mod/base/msg.pm),
[`base::location`](../../mod/base/location.pm), and
[`base::filemgmt`](../../mod/base/filemgmt.pm) (attachment/file management).

`mod/base` also carries a handful of **base application modules** (not plain data
objects) such as [`base::Explore`](../../mod/base/Explore.pm),
[`base::MyW5Base`](../../mod/base/MyW5Base.pm), and
[`base::WebNotify`](../../mod/base/WebNotify.pm).

---

## 9. How to read a data object

When exploring any object (in `mod/base` or a downstream module), read it in this
order — it is the fastest way to understand an unfamiliar entity:

1. **The `package` line and `@ISA`** — tells you which storage backend and which
   mixins (e.g. `kernel::MandatorDataACL`) apply.
2. **The `AddFields(...)` list in `new`** — this *is* the entity: its columns,
   labels, storage mapping (`dataobjattr`), and joins (`vjointo`,
   `vjoinon`) to other objects.
3. **Any `IfRequestedAction*` / permission hooks** — these implement per-object
   authorization on top of the field-level ACL.

Everything else (masks, REST/SOAP, SQL) is generated from those declarations by
the kernel, so once you can read the field list you can predict the UI, the API,
and the schema.

---

## 10. Backward-compatibility note

The kernel and `mod/base` are **read-only** for this containerized-environment
work. The environment **invokes** and **wires to** these files — it never edits
them — preserving application behavior and the schema contract. If you are
extending W5Base with real functionality, you add a **new** data object in a
module rather than modifying the kernel; that is the framework's intended
extension model and it keeps upgrades safe.

---

## 11. Where to go next

- **See the framework end-to-end:** the [Architecture Overview](../ARCHITECTURE.md)
  (request path, control plane, schema versioning, operation modes).
- **Run it locally:** the [Local Setup runbook](../LOCAL_SETUP.md).
- **A large module built on this kernel:** the [ITIL module guide](./itil.md)
  (the core CMDB/ITSM module).
- **A compact module built on this kernel:** the [CRM module guide](./crm.md).
- **Project front door:** the [root README](../../README.md).
- **Authoritative legacy reference:** [`README.txt`](../../README.txt).
