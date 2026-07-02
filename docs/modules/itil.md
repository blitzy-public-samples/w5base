# Module Guide: ITIL — the Core CMDB / ITSM Module (`mod/itil`)

> **Scope.** This guide documents [`mod/itil`](../../mod/itil), the **largest**
> data-object module in W5Base and the heart of its CMDB/ITSM capability. It
> assumes you have read the [Kernel guide](./kernel.md) (data objects, fields,
> ACLs) — ITIL is a **consumer** of that kernel, so understanding the kernel
> first makes this module easy to read. For the system-wide picture see the
> [Architecture Overview](../ARCHITECTURE.md); to run the stack, see the
> [Local Setup runbook](../LOCAL_SETUP.md).

---

## Table of Contents

1. [What the ITIL module is (and why it is large)](#1-what-the-itil-module-is-and-why-it-is-large)
2. [How it is built on the kernel](#2-how-it-is-built-on-the-kernel)
3. [The flagship object: `itil::appl`](#3-the-flagship-object-itilappl)
4. [The module's shared library (`itil/lib`)](#4-the-modules-shared-library-itillib)
5. [Representative object catalog](#5-representative-object-catalog)
6. [Modeling relationships (the "CMDB" part)](#6-modeling-relationships-the-cmdb-part)
7. [Configuration-item lifecycle (`kernel::CIStatusTools`)](#7-configuration-item-lifecycle-kernelcistatustools)
8. [Subdirectories and what they contain](#8-subdirectories-and-what-they-contain)
9. [Backward-compatibility note](#9-backward-compatibility-note)
10. [Where to go next](#10-where-to-go-next)

---

## 1. What the ITIL module is (and why it is large)

**What.** [`mod/itil`](../../mod/itil) implements W5Base's **Configuration
Management Database (CMDB)** and the surrounding **IT Service Management (ITSM)**
entities: applications, systems, assets, software, IP networks, business
services, cost centers, customer contracts, change management, and the many
link objects that connect them.

**Why it is large.** A CMDB's value is in its **breadth and its relationships** —
it must represent nearly everything in an IT estate and how those things depend
on each other. That is why `mod/itil` contains well over a hundred top-level data
objects plus a dozen subdirectories. Crucially, this size does **not** mean a
large amount of plumbing: each object is a **declaration** on top of the kernel
(see the [Kernel guide](./kernel.md)), so the module is broad rather than deep.

---

## 2. How it is built on the kernel

Every ITIL object is a kernel data object persisted in the relational backend
`kernel::DataObj::DB` (see [Kernel §5](./kernel.md#5-storage-backends-kerneldataobj)).
Most objects also mix in:

- **`itil::lib::Listedit`** ([`mod/itil/lib/Listedit.pm`](../../mod/itil/lib/Listedit.pm)) —
  the **module-shared base** that gives ITIL objects a consistent
  list/edit behavior. It is itself declared as
  `@ISA = qw(kernel::App::Web::Listedit kernel::DataObj::DB kernel::CIStatusTools)`,
  so it bundles the common ancestry every ITIL object wants.
- **`kernel::MandatorDataACL`** — the multi-tenant field-level ACL described in
  [Kernel §6](./kernel.md#6-multi-tenant-field-level-authorization-kernelmandatordataacl).
- **`kernel::CIStatusTools`**
  ([`lib/kernel/CIStatusTools.pm`](../../lib/kernel/CIStatusTools.pm)) — the
  **configuration-item lifecycle** helper (see §7).

Because the plumbing is inherited, an ITIL object's own code is essentially its
`AddFields(...)` declaration plus a few object-specific hooks.

---

## 3. The flagship object: `itil::appl`

[`mod/itil/appl.pm`](../../mod/itil/appl.pm) — the **application** configuration
item — is the best single object to read to understand the module. Its `@ISA`
shows the full mixin pattern ITIL uses (quoted verbatim):

```perl
@ISA=qw(kernel::App::Web::Listedit kernel::DataObj::DB
        kernel::App::Web::InterviewLink kernel::CIStatusTools
        kernel::MandatorDataACL itil::lib::Listedit);
```

Each ancestor contributes one capability:

| Ancestor | Contribution |
|----------|--------------|
| [`kernel::App::Web::Listedit`](../../lib/kernel/App/Web/Listedit.pm) | Generated web list/detail masks and edit flow |
| [`kernel::DataObj::DB`](../../lib/kernel/DataObj/DB.pm) | Relational persistence |
| [`kernel::App::Web::InterviewLink`](../../lib/kernel/App/Web/InterviewLink.pm) | "Interview"/questionnaire linkage |
| [`kernel::CIStatusTools`](../../lib/kernel/CIStatusTools.pm) | CI lifecycle/status handling (§7) |
| [`kernel::MandatorDataACL`](../../lib/kernel/MandatorDataACL.pm) | Multi-tenant field-level ACL |
| [`itil::lib::Listedit`](../../mod/itil/lib/Listedit.pm) | ITIL-wide shared list/edit conventions |

This is the same pattern used across the module — e.g.
[`mod/itil/asset.pm`](../../mod/itil/asset.pm) declares the leaner
`@ISA = qw(kernel::App::Web::Listedit kernel::DataObj::DB kernel::CIStatusTools)`.
Once you recognize the pattern, every ITIL object reads the same way: **inherit
the plumbing, then declare fields.**

---

## 4. The module's shared library (`itil/lib`)

[`mod/itil/lib`](../../mod/itil/lib) holds code shared across ITIL objects rather
than data objects themselves:

- [`itil::lib::Listedit`](../../mod/itil/lib/Listedit.pm) — the shared base
  class described in §2.
- [`itil::lib::BorderChangeHandling`](../../mod/itil/lib/BorderChangeHandling.pm) —
  logic for handling changes that cross ownership/tenant "borders".
- [`itil::lib::SecurityRestrictor`](../../mod/itil/lib/SecurityRestrictor.pm) —
  additional security restriction helpers layered on top of the ACL.

---

## 5. Representative object catalog

A small, representative slice of the CMDB entities (there are many more):

| Data object | File | Represents |
|-------------|------|------------|
| `itil::appl` | [`appl.pm`](../../mod/itil/appl.pm) | Applications (the flagship CI) |
| `itil::system` | [`system.pm`](../../mod/itil/system.pm) | Systems / hosts |
| `itil::asset` | [`asset.pm`](../../mod/itil/asset.pm) | Physical/logical assets |
| `itil::software` | [`software.pm`](../../mod/itil/software.pm) | Software products |
| `itil::swinstance` | [`swinstance.pm`](../../mod/itil/swinstance.pm) | Deployed software instances |
| `itil::businessservice` | [`businessservice.pm`](../../mod/itil/businessservice.pm) | Business services |
| `itil::ipaddress` | [`ipaddress.pm`](../../mod/itil/ipaddress.pm) | IP addresses |
| `itil::ipnet` | [`ipnet.pm`](../../mod/itil/ipnet.pm) | IP networks/subnets |
| `itil::costcenter` | [`costcenter.pm`](../../mod/itil/costcenter.pm) | Cost centers |
| `itil::custcontract` | [`custcontract.pm`](../../mod/itil/custcontract.pm) | Customer contracts |
| `itil::chmmgmt` | [`chmmgmt.pm`](../../mod/itil/chmmgmt.pm) | Change management |

---

## 6. Modeling relationships (the "CMDB" part)

A CMDB is only as useful as the **relationships** between configuration items.
W5Base models these with dedicated **link data objects** — small objects whose
job is to connect two others. For example:

- [`itil::lnkapplsystem`](../../mod/itil/lnkapplsystem.pm) — links an
  **application** to the **system(s)** it runs on.
- [`itil::lnkapplappl`](../../mod/itil/lnkapplappl.pm) — links an **application**
  to another **application** (application-to-application dependencies).

Within an object, relationships are also expressed **inline** through relational
field types (`Link`, `TextDrop`, `SubList`) that declare a join to another data
object — the same declarative mechanism explained in
[Kernel §4](./kernel.md#4-the-field-catalog-kernelfield). Together, link objects
and relational fields are what turn a set of tables into a genuine, navigable
CMDB.

---

## 7. Configuration-item lifecycle (`kernel::CIStatusTools`)

Most ITIL objects mix in `kernel::CIStatusTools`
([`lib/kernel/CIStatusTools.pm`](../../lib/kernel/CIStatusTools.pm)). CMDB
records are not simply present or absent — they have a **lifecycle status**
(e.g. planned → active → retired). `CIStatusTools` gives every consuming object a
consistent notion of that lifecycle and the transitions/validations around it,
so status semantics are uniform across applications, systems, assets, and the
rest — rather than reinvented per object.

---

## 8. Subdirectories and what they contain

[`mod/itil`](../../mod/itil) is organized into these subtrees:

| Subdirectory | Purpose |
|--------------|---------|
| [`lib/`](../../mod/itil/lib) | Shared base classes and helpers (§4) |
| [`menu/`](../../mod/itil/menu) | The module's menu tree ([`menu/root.pm`](../../mod/itil/menu/root.pm)) |
| [`workflow/`](../../mod/itil/workflow) | Workflow definitions for ITIL processes |
| [`qrule/`](../../mod/itil/qrule) | Quality rules that validate CMDB data |
| [`w5stat/`](../../mod/itil/w5stat) | Statistics/reporting objects |
| [`event/`](../../mod/itil/event) | Event handlers (dispatched via `kernel::EventController`) |
| [`ext/`](../../mod/itil/ext) | Extension points |
| [`Explore/`](../../mod/itil/Explore) | Exploration/browsing UI helpers |
| [`MyW5Base/`](../../mod/itil/MyW5Base) | Per-user "MyW5Base" dashboard contributions |
| [`QuickFind/`](../../mod/itil/QuickFind) | Quick-find/search contributions |
| [`WebNotify/`](../../mod/itil/WebNotify) | Web notification contributions |
| [`W5Server/`](../../mod/itil/W5Server) | Control-plane (W5Server) contributions for this module |

---

## 9. Backward-compatibility note

`mod/itil` is **read-only** for the containerized-environment work documented in
this repository. The environment stands up and validates the running application
(so these objects render and their schema is reconciled by `TableVersionCheck`),
but it does **not** modify any ITIL source or its SQL. New functionality belongs
in **new** data objects, never in edits to these files — consistent with the
kernel's extension model in [Kernel §10](./kernel.md#10-backward-compatibility-note).

---

## 10. Where to go next

- **Understand the engine first:** the [Kernel guide](./kernel.md).
- **A compact contrast:** the [CRM module guide](./crm.md) — the same patterns in
  a five-file module.
- **System-wide view:** the [Architecture Overview](../ARCHITECTURE.md).
- **Run it locally:** the [Local Setup runbook](../LOCAL_SETUP.md).
- **Project front door:** the [root README](../../README.md).
