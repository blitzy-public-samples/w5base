# `mod/itil` — CMDB / ITSM (the core data-object module)

> **Scope.** This guide documents [`mod/itil`](../../mod/itil), the **largest**
> module in W5Base and the heart of its **CMDB / ITSM** capability
> (Configuration Management Database / IT Service Management). It assumes you have
> read the [Kernel guide](./kernel.md) — nearly every object here is a **declared
> data object** built on that kernel, so `mod/itil` is really the framework shown
> *at full scale*. For the system-wide request path and control plane see the
> [Architecture Overview](../ARCHITECTURE.md); to stand the stack up locally see
> the [Local Setup runbook](../LOCAL_SETUP.md). The compact [CRM guide](./crm.md)
> teaches the module *anatomy* this large module reuses.
>
> **This document only *describes* existing code — it changes nothing.** Every
> `mod/itil` and `sql/itil` path it references is read-only for the
> containerized-environment work.

---

## Table of Contents

1. [What `mod/itil` is (and why it is the largest module)](#1-what-moditil-is-and-why-it-is-the-largest-module)
2. [How it is built on the kernel](#2-how-it-is-built-on-the-kernel)
3. [The flagship object: `itil::appl`](#3-the-flagship-object-itilappl)
4. [The module's shared library (`itil/lib`)](#4-the-modules-shared-library-itillib)
5. [Object families: the CMDB/ITSM domain](#5-object-families-the-cmdbitsm-domain)
   - [5.1 Applications](#51-applications)
   - [5.2 Hardware / assets](#52-hardware--assets)
   - [5.3 Systems & software](#53-systems--software)
   - [5.4 Networking](#54-networking)
   - [5.5 Cloud / cluster / farm](#55-cloud--cluster--farm)
   - [5.6 Business layer](#56-business-layer)
   - [5.7 Contracts / licenses / cost](#57-contracts--licenses--cost)
6. [CMDB relationships: the `lnk*.pm` link objects](#6-cmdb-relationships-the-lnkpm-link-objects)
7. [Configuration-item lifecycle (`kernel::CIStatusTools`)](#7-configuration-item-lifecycle-kernelcistatustools)
8. [Module subdirectories (the recurring anatomy)](#8-module-subdirectories-the-recurring-anatomy)
9. [Schema (`sql/itil/`) and TableVersionCheck](#9-schema-sqlitil-and-tableversioncheck)
10. [Backward-compatibility note](#10-backward-compatibility-note)
11. [Where to go next](#11-where-to-go-next)

---

## 1. What `mod/itil` is (and why it is the largest module)

**What.** [`mod/itil`](../../mod/itil) is W5Base's **Configuration Management
Database (CMDB)** and the surrounding **IT Service Management (ITSM)** domain. It
declares the configuration items (CIs) of an IT estate — applications, hardware
and assets, systems and software, networking, cloud/cluster/farm groupings, the
business layer, and contracts/licenses — **and the relationships between them**.
It is the **largest** module in the repository: **~122 top-level `.pm` files**
(243 `.pm` counting subdirectories) — **nearly all of them declared data
objects**, alongside a small number of web/helper classes.

**Why it is large — breadth, not depth.** A CMDB is valuable only if it can
represent nearly everything in an estate *and* how those things depend on one
another, so the object count is inherently high. Crucially, that size is **not**
plumbing: **nearly every** top-level `.pm` is a **declared data object** that
inherits the kernel base class (typically `kernel::DataObj::DB`, directly or
through an ITIL/CRM/finance base) and expresses itself as a field list, exactly
as taught in the [Kernel guide](./kernel.md). A small number of top-level files
are **web/helper classes** instead — for example
[`FaultAnalytics.pm`](../../mod/itil/FaultAnalytics.pm) inherits
`kernel::App::Web`, not `kernel::DataObj::DB`. `mod/itil` is therefore the
framework demonstrated **at full scale** — broad, not deep.

**How to read this guide.** Rather than enumerate 122 files, this guide groups the
objects into **families** (§5) and then explains the **link objects** (§6) that
turn those families into a navigable graph — the single idea that makes this a
CMDB rather than a pile of inventories.

---

## 2. How it is built on the kernel

Every ITIL object is a kernel **data object** persisted in the relational backend
[`kernel::DataObj::DB`](../../lib/kernel/DataObj/DB.pm) (see
[Kernel §5](./kernel.md#5-storage-backends-kerneldataobj)). On top of that most
objects mix in two kernel capabilities:

- **[`kernel::MandatorDataACL`](../../lib/kernel/MandatorDataACL.pm)** — the
  multi-tenant, field-level access control described in
  [Kernel §6](./kernel.md#6-multi-tenant-field-level-authorization-kernelmandatordataacl).
- **[`kernel::CIStatusTools`](../../lib/kernel/CIStatusTools.pm)** — the
  configuration-item lifecycle helper covered in §7.

Because all of that behavior is **inherited**, an ITIL object's own code is
essentially its `AddFields(...)` declaration plus a few object-specific hooks —
the kernel generates the masks, REST/SOAP interfaces, filtering, and SQL from the
declared field list (see [Kernel §4](./kernel.md#4-the-field-catalog-kernelfield)).

---

## 3. The flagship object: `itil::appl`

[`mod/itil/appl.pm`](../../mod/itil/appl.pm) — the **Application** CI — is the
best single object to read first. In a CMDB the Application is usually the **hub
CI**: systems, software, IP addresses, contacts, contracts, and even other
applications all attach to it, so understanding `itil::appl` unlocks most of the
module. Its `@ISA` shows the full mixin pattern ITIL uses (quoted verbatim from
[`mod/itil/appl.pm`](../../mod/itil/appl.pm)):

```perl
@ISA=qw(kernel::App::Web::Listedit kernel::DataObj::DB
        kernel::App::Web::InterviewLink kernel::CIStatusTools
        kernel::MandatorDataACL itil::lib::Listedit);
```

Each ancestor contributes exactly one capability:

| Ancestor | Contribution |
|----------|--------------|
| [`kernel::App::Web::Listedit`](../../lib/kernel/App/Web/Listedit.pm) | Generated web list/detail masks and the edit flow |
| [`kernel::DataObj::DB`](../../lib/kernel/DataObj/DB.pm) | Relational persistence |
| [`kernel::App::Web::InterviewLink`](../../lib/kernel/App/Web/InterviewLink.pm) | "Interview"/questionnaire linkage |
| [`kernel::CIStatusTools`](../../lib/kernel/CIStatusTools.pm) | CI lifecycle/status handling (§7) |
| [`kernel::MandatorDataACL`](../../lib/kernel/MandatorDataACL.pm) | Multi-tenant field-level ACL |
| [`itil::lib::Listedit`](../../mod/itil/lib/Listedit.pm) | ITIL-wide shared list/edit conventions (§4) |

Once you recognize this pattern, nearly every object in the module reads the
same way: **inherit the plumbing, then declare fields.** Leaner objects use a
shorter ancestry — e.g. [`asset.pm`](../../mod/itil/asset.pm) declares
`@ISA=qw(kernel::App::Web::Listedit kernel::DataObj::DB kernel::CIStatusTools)`.

---

## 4. The module's shared library (`itil/lib`)

[`mod/itil/lib`](../../mod/itil/lib) holds code **shared across ITIL objects**
rather than data objects themselves. Its job is to fix the module's common
ancestry and cross-cutting rules in one place:

- **[`itil::lib::Listedit`](../../mod/itil/lib/Listedit.pm)** — the module-shared
  base class. It is declared
  `@ISA=qw(kernel::App::Web::Listedit kernel::DataObj::DB kernel::CIStatusTools)`,
  so objects that inherit it get generated masks, relational persistence, and CI
  lifecycle in a single step. This is the **same idiom** as
  [`crm::lib::Listedit`](./crm.md#6-the-module-shared-base-crmliblistedit): every
  module defines one shared base so its objects stay consistent.
- **[`itil::lib::BorderChangeHandling`](../../mod/itil/lib/BorderChangeHandling.pm)** —
  logic for changes that cross ownership/tenant "borders".
- **[`itil::lib::SecurityRestrictor`](../../mod/itil/lib/SecurityRestrictor.pm)** —
  extra security-restriction helpers layered on top of the field-level ACL.

---

## 5. Object families: the CMDB/ITSM domain

The module's ~122 objects fall into a handful of **families**. For each family
below, the point is *what it represents* and *why a CMDB needs it* — the named
objects are verified members of [`mod/itil`](../../mod/itil), not an exhaustive
list.

### 5.1 Applications

The Application is the **hub CI** most other CIs attach to, so this family is the
usual entry point into the CMDB.

- [`appl.pm`](../../mod/itil/appl.pm) — the central **Application** CI (§3).
- [`appladv.pm`](../../mod/itil/appladv.pm) — application "advanced"/extended
  attributes.
- [`applgrp.pm`](../../mod/itil/applgrp.pm) — **application groups** that gather
  related applications.
- [`appldoc.pm`](../../mod/itil/appldoc.pm) — **application documents** (attached
  documentation).
- [`applwallet.pm`](../../mod/itil/applwallet.pm) — an application "wallet" of
  associated resources.

### 5.2 Hardware / assets

Assets track the **physical inventory** — the tangible things a service
ultimately runs on — plus the models and vendors behind them.

- [`asset.pm`](../../mod/itil/asset.pm) — a physical/logical **asset** record.
- [`assetphyscore.pm`](../../mod/itil/assetphyscore.pm) and
  [`assetphyscpu.pm`](../../mod/itil/assetphyscpu.pm) — **physical detail**
  (CPU cores / CPUs), needed for capacity and licensing.
- [`hwmodel.pm`](../../mod/itil/hwmodel.pm) — **hardware models**.
- [`producer.pm`](../../mod/itil/producer.pm) — **manufacturers / vendors**.

### 5.3 Systems & software

Between applications and hardware sits the **systems** layer: hosts that **run
software instances**.

- [`system.pm`](../../mod/itil/system.pm) — logical/physical **systems / hosts**.
- [`swinstance.pm`](../../mod/itil/swinstance.pm) — **software instances** (a
  deployment of a product on a system).
- [`software.pm`](../../mod/itil/software.pm) and
  [`softwareset.pm`](../../mod/itil/softwareset.pm) — software **products** and
  curated **sets** of them.
- [`osrelease.pm`](../../mod/itil/osrelease.pm) — **OS releases**.
- [`platform.pm`](../../mod/itil/platform.pm) — platform classification.

### 5.4 Networking

These objects capture the **network topology** of CIs — the addressing and
connectivity that ties systems together.

- [`ipaddress.pm`](../../mod/itil/ipaddress.pm) — individual **IP addresses**.
- [`ipnet.pm`](../../mod/itil/ipnet.pm) — **IP networks / subnets**.
- [`dnsalias.pm`](../../mod/itil/dnsalias.pm) — **DNS aliases**.
- [`network.pm`](../../mod/itil/network.pm) — networks.
- [`netintercon.pm`](../../mod/itil/netintercon.pm) — **network interconnections**
  between networks.

### 5.5 Cloud / cluster / farm

Modern infrastructure is rarely a single host, so these objects provide the
**grouping / hosting abstractions** that model where workloads actually live.

- [`itcloud.pm`](../../mod/itil/itcloud.pm) and
  [`itcloudarea.pm`](../../mod/itil/itcloudarea.pm) — **cloud** and cloud-area
  groupings.
- [`itclust.pm`](../../mod/itil/itclust.pm) — **clusters**.
- [`itfarm.pm`](../../mod/itil/itfarm.pm) — **farms**.

### 5.6 Business layer

These objects tie the technical CIs above to **business meaning**, which is what
turns configuration data into **service management**.

- [`businessprocess.pm`](../../mod/itil/businessprocess.pm) — a **business
  process**. Notably it declares `@ISA=qw(crm::businessprocess)`, so it **extends
  the CRM module's** business-process object (see the [CRM guide](./crm.md)) — a
  clean example of cross-module reuse.
- [`businessservice.pm`](../../mod/itil/businessservice.pm) — a **business
  service** that technical CIs deliver.

### 5.7 Contracts / licenses / cost

The **commercial and compliance** layer records who pays for and is entitled to
the CIs — essential for cost allocation and license/audit compliance.

- [`custcontract.pm`](../../mod/itil/custcontract.pm) — **customer contracts** (it
  extends the finance module's contract base, `@ISA=qw(finance::custcontract)`).
- [`supcontract.pm`](../../mod/itil/supcontract.pm) — **support / supplier
  contracts**.
- [`liccontract.pm`](../../mod/itil/liccontract.pm) and
  [`licproduct.pm`](../../mod/itil/licproduct.pm) — **license contracts** and
  **license products**.
- [`costcenter.pm`](../../mod/itil/costcenter.pm) — **cost centers**.

---

## 6. CMDB relationships: the `lnk*.pm` link objects

**This is the crux of the whole module.** Alongside the CI families above,
`mod/itil` contains **~57 top-level `lnk*.pm` objects** — dedicated data objects
whose entire job is to model a **relationship between two CIs**. Verified
examples:

- [`lnkapplsystem.pm`](../../mod/itil/lnkapplsystem.pm) — **application ↔ system**
  ("this application *runs on* that system").
- [`lnkapplappl.pm`](../../mod/itil/lnkapplappl.pm) — **application ↔ application**
  ("this application *depends on* that one").
- [`lnksoftwaresystem.pm`](../../mod/itil/lnksoftwaresystem.pm) — **software ↔
  system** ("this software is *installed on* that system").

**Why this matters — it is what makes `mod/itil` a CMDB.** A configuration
database is only useful if it captures **how CIs relate**: *runs-on*,
*depends-on*, *hosted-by*, *contracted-under*. By modeling each relationship as
its **own data object** — a first-class row with its own fields, history, and ACL
— W5Base turns a flat collection of inventories into a **navigable relationship
graph**. Impact analysis ("what breaks if this system goes down?"), dependency
mapping, and business-service views all **fall out of these link objects** for
free, because each link is just another declared data object the kernel can
render, query, and traverse. A link object is itself an ordinary ITIL object:
[`lnkapplsystem.pm`](../../mod/itil/lnkapplsystem.pm), for instance, inherits the
shared [`itil::lib::Listedit`](../../mod/itil/lib/Listedit.pm) base described in §4.

> **Takeaway.** The `lnk*.pm` objects are the CMDB's backbone. Inventories tell
> you *what exists*; the link objects tell you *how it all connects* — and that is
> the difference between a set of tables and a real CMDB.

---

## 7. Configuration-item lifecycle (`kernel::CIStatusTools`)

Most ITIL objects mix in
[`kernel::CIStatusTools`](../../lib/kernel/CIStatusTools.pm). CMDB records are not
simply present or absent — a CI moves through a **lifecycle status** (for example
*planned → active → retired*). `CIStatusTools` gives every consuming object a
**consistent** notion of that lifecycle and the transitions around it, so status
semantics are uniform across applications, systems, assets, and the rest rather
than reinvented per object. You can see it in the `@ISA` of `appl` (§3),
[`asset.pm`](../../mod/itil/asset.pm), [`itcloud.pm`](../../mod/itil/itcloud.pm),
and the shared [`itil::lib::Listedit`](../../mod/itil/lib/Listedit.pm) base — so it
reaches nearly every object in the module.

---

## 8. Module subdirectories (the recurring anatomy)

Beyond its top-level objects, [`mod/itil`](../../mod/itil) has **12
subdirectories**. This is the **same subtree shape that recurs in every W5Base
module**, so once you learn the anatomy you recognize it everywhere. The
[CRM guide](./crm.md) teaches that anatomy in detail on a five-file module — see
[CRM §2](./crm.md#2-the-anatomy-of-a-module-five-files) and the "new module"
recipe in [CRM §9](./crm.md#9-the-new-module-recipe-this-illustrates); this
section only maps `mod/itil` onto it, to avoid duplicating the tutorial.

| Subdirectory | Purpose |
|--------------|---------|
| [`lib/`](../../mod/itil/lib) | Module-local helper / base classes (§4) |
| [`menu/`](../../mod/itil/menu) | Menu registration — the module's menu-tree contributions |
| [`event/`](../../mod/itil/event) | Event handlers run via the control plane (`kernel::EventController`) |
| [`workflow/`](../../mod/itil/workflow) | Workflow definitions |
| [`qrule/`](../../mod/itil/qrule) | Quality rules for data hygiene |
| [`w5stat/`](../../mod/itil/w5stat) | Statistics / reporting objects |
| [`ext/`](../../mod/itil/ext) | Extensions / tools |
| [`Explore/`](../../mod/itil/Explore) | Graph / tree exploration views |
| [`MyW5Base/`](../../mod/itil/MyW5Base) | Personalized dashboard contributions |
| [`QuickFind/`](../../mod/itil/QuickFind) | Quick-search integrations |
| [`WebNotify/`](../../mod/itil/WebNotify) | Notifications |
| [`W5Server/`](../../mod/itil/W5Server) | Control-plane (W5Server) hooks / handlers |

---

## 9. Schema (`sql/itil/`) and TableVersionCheck

The **matching relational schema** for these objects lives under `sql/itil/`. That
SQL is **not applied by hand** and is **not touched by this documentation**:
the environment reconciles it against the live database at startup with
**TableVersionCheck**, the schema-version mechanism described in the
[Architecture Overview](../ARCHITECTURE.md#4-schema-versioning-tableversioncheck).
When a field is added to or changed on an ITIL object, the corresponding change is
expressed under `sql/itil/` and reconciled by that mechanism — the framework keeps
the declared objects and the physical tables in step, which is why a fresh
environment comes up with a complete, versioned ITIL schema. This guide describes
the objects only; it never edits `sql/itil/`.

---

## 10. Backward-compatibility note

[`mod/itil`](../../mod/itil) and its schema under `sql/itil/` are **read-only** for
the containerized-environment work this documentation set accompanies. The
environment **renders and validates** these objects (they must appear in the
running application, and their schema is reconciled by TableVersionCheck), but it
**never edits** the module source or its SQL — preserving application behavior and
the schema contract. New functionality belongs in **new** data objects (a new
module, or a new object here), never in edits that change existing behavior —
consistent with the kernel's extension model in
[Kernel §10](./kernel.md#10-backward-compatibility-note).

---

## 11. Where to go next

- **Understand the engine first:** the [Kernel guide](./kernel.md) — the base
  classes (`kernel::DataObj`, `kernel::Field`, the storage backends, the ACL) that
  nearly every object here inherits.
- **See the minimal module anatomy:** the [CRM guide](./crm.md) — the same
  structure this large module reuses, taught on just five files.
- **See the framework end-to-end:** the [Architecture Overview](../ARCHITECTURE.md)
  — request path, control plane, and the TableVersionCheck mechanism.
- **Run it locally:** the [Local Setup runbook](../LOCAL_SETUP.md).
- **Project front door:** the [root README](../../README.md).

