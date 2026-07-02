# `mod/crm` — a compact module (canonical module anatomy)

> **Scope.** This guide documents [`mod/crm`](../../mod/crm), one of the
> **smallest complete modules** in W5Base — just five files. Precisely because
> it is small, it is the **best teaching example** for the *shape* every W5Base
> module follows: once you can read these five files, you can read any module,
> including the giant [ITIL module](./itil.md). Read the
> [Kernel guide](./kernel.md) first for the data-object model, then use this
> guide as the "how a module is put together" reference. For the system-wide
> picture see the [Architecture Overview](../ARCHITECTURE.md); to run the stack,
> see the [Local Setup runbook](../LOCAL_SETUP.md).
>
> **Read-only.** Like all of `mod/**` and `sql/**`, this module is *described*
> here, never modified — see [§10](#10-backward-compatibility-note).

---

## Table of Contents

1. [Why start with CRM](#1-why-start-with-crm)
2. [The anatomy of a module (five files)](#2-the-anatomy-of-a-module-five-files)
3. [The data object: `crm::businessprocess`](#3-the-data-object-crmbusinessprocess)
4. [Reading the field declaration](#4-reading-the-field-declaration)
5. [The ACL companion: `crm::businessprocessacl`](#5-the-acl-companion-crmbusinessprocessacl)
6. [The module-shared base: `crm::lib::Listedit`](#6-the-module-shared-base-crmliblistedit)
7. [The menu: `crm::menu::root`](#7-the-menu-crmmenuroot)
8. [The extension helper: `crm::ext::ReplaceTool`](#8-the-extension-helper-crmextreplacetool)
9. [The "new module" recipe this illustrates](#9-the-new-module-recipe-this-illustrates)
10. [Backward-compatibility note](#10-backward-compatibility-note)
11. [Where to go next](#11-where-to-go-next)

---

## 1. Why start with CRM

Where [`mod/itil`](./itil.md) shows the framework **at scale** (~122 top-level
data objects), `mod/crm` shows the framework **at its minimum**: **two** data
objects, one module-local base class, one menu registration, and one extension
helper. Every larger module is a superset of this same shape, so `mod/crm` is
the fastest way to internalize the reusable mental model — and the payoff is
immediate: the anatomy you learn here is exactly the anatomy you will recognize
in [ITIL §8](./itil.md#8-module-subdirectories-the-recurring-anatomy).

The mental model in one line:

> **top-level `*.pm` = data objects · `menu/` = registration · `lib/` = module-local helpers/bases · `ext/` = tools.**

The rest of this guide walks each of those four structural roles, explaining
**what** it is, **why** it exists, and **how** it is wired — grounded entirely
in the five files that make up `mod/crm`.

---

## 2. The anatomy of a module (five files)

The entire module is just five files, and they map cleanly onto the four
structural roles above:

| File | Package | Structural role |
|------|---------|-----------------|
| [`businessprocess.pm`](../../mod/crm/businessprocess.pm) | `crm::businessprocess` | Top-level `*.pm` — the primary **data object** |
| [`businessprocessacl.pm`](../../mod/crm/businessprocessacl.pm) | `crm::businessprocessacl` | Top-level `*.pm` — an **access-control** data object |
| [`menu/root.pm`](../../mod/crm/menu/root.pm) | `crm::menu::root` | `menu/` — **menu registration** |
| [`lib/Listedit.pm`](../../mod/crm/lib/Listedit.pm) | `crm::lib::Listedit` | `lib/` — the module's **shared base class** |
| [`ext/ReplaceTool.pm`](../../mod/crm/ext/ReplaceTool.pm) | `crm::ext::ReplaceTool` | `ext/` — an **extension / tool** |

That is a complete, working module — a testament to how much the kernel
provides. The four roles are examined in turn in [§3](#3-the-data-object-crmbusinessprocess)–[§8](#8-the-extension-helper-crmextreplacetool),
and generalized in [§9](#9-the-new-module-recipe-this-illustrates).

---

## 3. The data object: `crm::businessprocess`

**What.** [`mod/crm/businessprocess.pm`](../../mod/crm/businessprocess.pm)
declares the business-process entity — the module's primary data object.

**Why / how it is wired.** Its inheritance is a real, minimal example of
composing a data object from a **module-local base** *and* a **kernel mixin**:
`@ISA = qw(crm::lib::Listedit kernel::MandatorDataACL)`.

- `crm::lib::Listedit` ([§6](#6-the-module-shared-base-crmliblistedit)) is the
  module-local base that supplies generated list/edit web behavior and
  relational persistence.
- `kernel::MandatorDataACL`
  ([`lib/kernel/MandatorDataACL.pm`](../../lib/kernel/MandatorDataACL.pm)) is the
  kernel mixin that adds multi-tenant, field-level authorization, described in
  [Kernel §6](./kernel.md#6-multi-tenant-field-level-authorization-kernelmandatordataacl).

**Reaching the kernel base class (the key teaching point).** Follow the
`@ISA` links and the object resolves to the kernel's root data-object class:

```
crm::businessprocess → crm::lib::Listedit → kernel::DataObj::DB → kernel::DataObj
```

That chain is the concrete proof of the "everything is a data object" claim from
[Kernel §3](./kernel.md#3-the-data-object-model-one-declaration-many-faces): a
tiny module-specific class that, a few `@ISA` hops away, ultimately *is a*
`kernel::DataObj`.
(`crm::lib::Listedit` inherits `kernel::DataObj::DB`, whose own `@ISA` names
`kernel::DataObj` — [`lib/kernel/DataObj/DB.pm`](../../lib/kernel/DataObj/DB.pm).)
Everything else about the entity is expressed as a **field declaration**, not as
per-object UI, API, or SQL code.

---

## 4. Reading the field declaration

Inside `new`, `crm::businessprocess` calls `AddFields(...)` to declare its
columns — this list *is* the entity. Rather than reproduce it here, note the
shape: it opens with the standard bookkeeping fields nearly every object
declares (`Linenumber`, `Id`, `RecordUrl`, `Mandator`), then adds the
domain-specific fields. A single field pins one attribute to one column, e.g.
`new kernel::Field::Id(name => 'id', dataobjattr => 'businessprocess.id')`
maps the object's id to the `businessprocess.id` database column
(`mod/crm/businessprocess.pm`).

Relationships are declared inline too: the `customer` field is a
`kernel::Field::TextDrop` with `vjointo => 'base::grp'`, resolving the customer
by joining to the base [`base::grp`](../../mod/base/grp.pm) object (groups double
as organizations/customers) and displaying its `fullname`. From the field list
alone the kernel generates the list mask, the edit form, the filters, the
REST/SOAP payload, and the persistence.

To learn how to read *any* field list, follow the three-step recipe in
[Kernel §9](./kernel.md#9-how-to-read-a-data-object); for the full set of field
types see the [field catalog in Kernel §4](./kernel.md#4-the-field-catalog-kernelfield).

---

## 5. The ACL companion: `crm::businessprocessacl`

**What / how.** [`mod/crm/businessprocessacl.pm`](../../mod/crm/businessprocessacl.pm)
is the module's **second** top-level data object — a small **access-control**
object declared `@ISA = qw(kernel::App::Web::AclControl kernel::DataObj::DB)`.

**Why.** By inheriting
[`kernel::App::Web::AclControl`](../../lib/kernel/App/Web/AclControl.pm) it
provides the administrative surface for **who may do what** with business
processes, persisted — like every other object — through
[`kernel::DataObj::DB`](../../lib/kernel/DataObj/DB.pm). Pairing an entity with a
dedicated `*acl` object is a common W5Base convention for object-level
authorization, complementing the field-level ACL that the
`kernel::MandatorDataACL` mixin brings to the entity itself
([§3](#3-the-data-object-crmbusinessprocess)).

---

## 6. The module-shared base: `crm::lib::Listedit`

**What.** [`mod/crm/lib/Listedit.pm`](../../mod/crm/lib/Listedit.pm) is the
module's **shared base class**, declared
`@ISA = qw(kernel::App::Web::Listedit kernel::DataObj::DB kernel::CIStatusTools)`.

**Why / how.** `lib/` holds code shared across a module's objects rather than
data objects themselves. This base bundles the common ancestry the module's
objects want in one place — generated list/edit masks
([`kernel::App::Web::Listedit`](../../lib/kernel/App/Web/Listedit.pm)),
relational persistence ([`kernel::DataObj::DB`](../../lib/kernel/DataObj/DB.pm)),
and configuration-item lifecycle handling
([`kernel::CIStatusTools`](../../lib/kernel/CIStatusTools.pm)) — so a data object
gets all three simply by extending it (as `crm::businessprocess` does in
[§3](#3-the-data-object-crmbusinessprocess)). This is the **same idiom** as
[`itil::lib::Listedit`](./itil.md#4-the-modules-shared-library-itillib): every
module defines one shared base so its objects stay consistent.

---

## 7. The menu: `crm::menu::root`

**What.** [`mod/crm/menu/root.pm`](../../mod/crm/menu/root.pm) registers the
module in the navigation tree, declared `@ISA = qw(kernel::MenuRegistry)`.

**Why / how.** Inheriting
[`kernel::MenuRegistry`](../../lib/kernel/MenuRegistry.pm) is how a module
contributes entries to the menu system whose root is served at
`/w5base/auth/base/menu/root` — the very URL the
[smoke test](../../tests/smoke/w5base_smoke_test.sh) asserts returns HTTP 200.
Its `Init` method calls `RegisterObj(...)` once per node to build a
**`customerportal`** menu tree that points at the module's data objects and gates
each entry with a `defaultacl` token. The verified entries are:

| Menu node | Points at | `defaultacl` / options |
|-----------|-----------|------------------------|
| `customerportal` | `tmpl/welcome` (a welcome template) | `['valid_user']` |
| `customerportal.bp` | `crm::businessprocess` ([§3](#3-the-data-object-crmbusinessprocess)) | `['admin']` |
| `customerportal.bp.acl` | `crm::businessprocessacl` ([§5](#5-the-acl-companion-crmbusinessprocessacl)) | *(inherited)* |
| `customerportal.bp.new` | `crm::businessprocess` | `func => 'New'`, `['admin']` |

This is exactly **how a module exposes its data objects in the navigable UI and
gates them by ACL**: a `valid_user` reaches the portal landing page, while the
business-process list, its ACL admin, and the "create new" action are restricted
to `admin`. No node here is invented — the table mirrors `menu/root.pm` one-to-one.

---

## 8. The extension helper: `crm::ext::ReplaceTool`

**What / how.** [`mod/crm/ext/ReplaceTool.pm`](../../mod/crm/ext/ReplaceTool.pm)
is a lightweight helper declared `@ISA = qw(kernel::Universal)`.

**Why.** `kernel::Universal`
([`lib/kernel/Universal.pm`](../../lib/kernel/Universal.pm)) is the common root
utility class. Objects under an `ext/` subtree are **extension points** — small
tools that support the module without being full data objects. `ReplaceTool`
exposes a control record used by the framework's mass-replace tooling (for
substituting a referenced record, e.g. a `base::user`, across
`crm::businessprocess` rows), illustrating that `ext/` is where auxiliary
capabilities live.

---

## 9. The "new module" recipe this illustrates

Reading `mod/crm` top to bottom yields the recipe every W5Base module follows:

1. **Define a shared base** (`lib/Listedit.pm`) that fixes the module's common
   ancestry ([§6](#6-the-module-shared-base-crmliblistedit)).
2. **Declare one or more data objects** (`businessprocess.pm`) as a field list on
   top of that base ([§3](#3-the-data-object-crmbusinessprocess)).
3. **Add an ACL object** (`businessprocessacl.pm`) for object-level authorization
   where needed ([§5](#5-the-acl-companion-crmbusinessprocessacl)).
4. **Register a menu** (`menu/root.pm`) so the objects are reachable and gated
   ([§7](#7-the-menu-crmmenuroot)).
5. **Add extension helpers** (`ext/*.pm`) for anything that is not a data object
   ([§8](#8-the-extension-helper-crmextreplacetool)).

### How this generalizes

The reusable rule is: *every* W5Base module is built from the same structural
roles — top-level `*.pm` (data objects that ultimately inherit
`kernel::DataObj`), `menu/` (registration), `lib/` (module-local helpers/bases),
and `ext/` (tools). As a module grows it simply adds **more of the same shape**
plus optional subtrees:

| Optional subtree | Grows into |
|------------------|-----------|
| `event/` | event handlers run via the control plane (`kernel::EventController`) |
| `qrule/` | quality rules for data hygiene |
| `workflow/` | workflow definitions |
| `w5stat/` | statistics / reporting objects |
| `WebNotify/` | notifications |
| `Explore/` | graph / tree exploration views |
| `QuickFind/` | quick-search integrations |
| `W5Server/` | control-plane (W5Server) hooks / handlers |
| `MyW5Base/` | personalized dashboard contributions |

Nothing about the shape changes with size — only the count of files. To see the
identical anatomy scaled up to a large CMDB/ITSM module, read
[ITIL §8](./itil.md#8-module-subdirectories-the-recurring-anatomy): the same
`lib/`, `menu/`, and `ext/` roles, now alongside `event/`, `qrule/`, `workflow/`,
and the rest. Two data objects here, ~122 there — one anatomy.

This is also the intended, **additive** way to extend W5Base: new files in a
(new) module, never edits to the kernel.

---

## 10. Backward-compatibility note

`mod/crm`, like all of `mod/**` and its schema under `sql/crm/` (e.g.
`sql/crm/crm.sql`, which defines the `businessprocess` table), is **read-only**
for the containerized-environment work this documentation set accompanies. The
environment **renders and validates** these objects — it reconciles `sql/crm/`
against the live database at startup via **TableVersionCheck** (see the
[Architecture Overview](../ARCHITECTURE.md#4-schema-versioning-tableversioncheck)) —
but it never edits the module or its SQL, preserving application behavior and the
schema contract (mirroring [Kernel §10](./kernel.md#10-backward-compatibility-note)).

---

## 11. Where to go next

- **Understand the engine:** the [Kernel guide](./kernel.md).
- **See the patterns at scale:** the [ITIL module guide](./itil.md).
- **System-wide view:** the [Architecture Overview](../ARCHITECTURE.md).
- **Run it locally:** the [Local Setup runbook](../LOCAL_SETUP.md).
- **Project front door:** the [root README](../../README.md).
