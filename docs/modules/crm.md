# Module Guide: CRM — a Compact, Representative Module (`mod/crm`)

> **Scope.** This guide documents [`mod/crm`](../../mod/crm), one of the
> **smallest complete modules** in W5Base — just five files. Precisely because
> it is small, it is the **best template** for understanding the *shape* of any
> W5Base module. Read the [Kernel guide](./kernel.md) first for the data-object
> model, then contrast this module with the large [ITIL guide](./itil.md). For
> the system-wide picture see the [Architecture Overview](../ARCHITECTURE.md);
> to run the stack, see the [Local Setup runbook](../LOCAL_SETUP.md).

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

Where [`mod/itil`](./itil.md) shows the framework **at scale**, `mod/crm` shows
the framework **at its minimum**: a single primary data object, its access-control
companion, a shared base class, a menu registration, and one extension helper.
Every larger module is a superset of this shape, so once you can read these five
files you can read any module.

---

## 2. The anatomy of a module (five files)

The entire module is:

| File | Package | Role |
|------|---------|------|
| [`businessprocess.pm`](../../mod/crm/businessprocess.pm) | `crm::businessprocess` | The primary **data object** (the entity) |
| [`businessprocessacl.pm`](../../mod/crm/businessprocessacl.pm) | `crm::businessprocessacl` | **Access-control** object for that entity |
| [`lib/Listedit.pm`](../../mod/crm/lib/Listedit.pm) | `crm::lib::Listedit` | The module's **shared base class** |
| [`menu/root.pm`](../../mod/crm/menu/root.pm) | `crm::menu::root` | **Menu registration** for the module |
| [`ext/ReplaceTool.pm`](../../mod/crm/ext/ReplaceTool.pm) | `crm::ext::ReplaceTool` | An **extension helper** |

That is a complete, working module — a testament to how much the kernel provides.

---

## 3. The data object: `crm::businessprocess`

[`mod/crm/businessprocess.pm`](../../mod/crm/businessprocess.pm) declares the
business-process entity. Its `@ISA` is deliberately small:

```perl
@ISA = qw(crm::lib::Listedit kernel::MandatorDataACL);
```

- `crm::lib::Listedit` (§6) supplies the generated list/edit web behavior and
  relational persistence.
- `kernel::MandatorDataACL`
  ([`lib/kernel/MandatorDataACL.pm`](../../lib/kernel/MandatorDataACL.pm)) adds
  the multi-tenant field-level ACL described in
  [Kernel §6](./kernel.md#6-multi-tenant-field-level-authorization-kernelmandatordataacl).

Everything else about the entity is expressed as a **field declaration**, not
as code.

---

## 4. Reading the field declaration

Inside `new`, the object calls `AddFields(...)`. An abridged but faithful excerpt
shows the declarative style (see the file for the full list):

```perl
$self->AddFields(
   new kernel::Field::Linenumber(name => 'linenumber', label => 'No.'),

   new kernel::Field::Id(name => 'id', label => 'W5BaseID',
                         sqlorder => 'desc',
                         dataobjattr => 'businessprocess.id'),

   new kernel::Field::RecordUrl(),

   new kernel::Field::Mandator(),

   new kernel::Field::TextDrop(
                name          => 'customer',
                label         => 'Organisation/Customer',
                vjointo       => 'base::grp',
                vjoinon       => ['customerid' => 'grpid'],
                vjoindisp     => 'fullname'),

   new kernel::Field::Link(name => 'customerid',
                           dataobjattr => 'businessprocess.customer'),

   new kernel::Field::Text(name => 'shortname', maxlength => 99),
);
```

What to notice — this is the whole model in miniature:

- **`Id` / `Linenumber` / `RecordUrl` / `Mandator`** are the standard
  bookkeeping fields nearly every object declares (see the field catalog in
  [Kernel §4](./kernel.md#4-the-field-catalog-kernelfield)).
- **`dataobjattr`** maps a field to its database column (e.g.
  `businessprocess.id`) — this is how the declaration drives the generated SQL.
- **`TextDrop` with `vjointo => 'base::grp'`** is a **cross-object join**: the
  `customer` field is resolved by joining to the base
  [`base::grp`](../../mod/base/grp.pm) object (groups double as
  organizations/customers), displaying its `fullname`. This is exactly how
  W5Base expresses relationships inline via relational field types
  ([`kernel::Field::TextDrop`](../../lib/kernel/Field/TextDrop.pm),
  [`kernel::Field::Link`](../../lib/kernel/Field/Link.pm)).

From this list alone the kernel generates the list mask, the edit form, the
filters, the REST/SOAP payload, and the persistence — no per-object UI, API, or
SQL code is written.

---

## 5. The ACL companion: `crm::businessprocessacl`

[`mod/crm/businessprocessacl.pm`](../../mod/crm/businessprocessacl.pm) is a small
**access-control** data object:

```perl
@ISA = qw(kernel::App::Web::AclControl kernel::DataObj::DB);
```

By inheriting [`kernel::App::Web::AclControl`](../../lib/kernel/App/Web/AclControl.pm)
it provides the administrative surface for **who may do what** with business
processes, persisted (like everything else) through `kernel::DataObj::DB`. Pairing
an entity with a dedicated `*acl` object is a common W5Base convention for
object-level authorization, complementing the field-level ACL from the mixin in
§3.

---

## 6. The module-shared base: `crm::lib::Listedit`

[`mod/crm/lib/Listedit.pm`](../../mod/crm/lib/Listedit.pm) is the module's shared
base class:

```perl
@ISA = qw(kernel::App::Web::Listedit kernel::DataObj::DB kernel::CIStatusTools);
```

It bundles the common ancestry the module's objects want — generated list/edit
masks ([`kernel::App::Web::Listedit`](../../lib/kernel/App/Web/Listedit.pm)),
relational persistence ([`kernel::DataObj::DB`](../../lib/kernel/DataObj/DB.pm)),
and CI lifecycle handling ([`kernel::CIStatusTools`](../../lib/kernel/CIStatusTools.pm)).
This is the **same idiom** as [`itil::lib::Listedit`](./itil.md#4-the-modules-shared-library-itillib):
a module defines one shared base so its objects stay consistent.

---

## 7. The menu: `crm::menu::root`

[`mod/crm/menu/root.pm`](../../mod/crm/menu/root.pm) registers the module in the
navigation tree:

```perl
@ISA = qw(kernel::MenuRegistry);
```

Inheriting [`kernel::MenuRegistry`](../../lib/kernel/MenuRegistry.pm) is how a
module contributes entries to the menu system whose root is served at
`/w5base/auth/base/menu/root` — the very URL the
[smoke test](../../tests/smoke/w5base_smoke_test.sh) asserts returns HTTP 200.

---

## 8. The extension helper: `crm::ext::ReplaceTool`

[`mod/crm/ext/ReplaceTool.pm`](../../mod/crm/ext/ReplaceTool.pm) is a lightweight
helper:

```perl
@ISA = qw(kernel::Universal);
```

`kernel::Universal` ([`lib/kernel/Universal.pm`](../../lib/kernel/Universal.pm))
is the common root utility class. Objects under an `ext/` subtree are **extension
points** — small tools that support the module without being full data objects.

---

## 9. The "new module" recipe this illustrates

Reading `mod/crm` top to bottom yields the recipe every W5Base module follows:

1. **Define a shared base** (`lib/Listedit.pm`) that fixes the module's common
   ancestry.
2. **Declare one or more data objects** (`businessprocess.pm`) as a field list on
   top of that base.
3. **Add an ACL object** (`businessprocessacl.pm`) for object-level
   authorization where needed.
4. **Register a menu** (`menu/root.pm`) so the objects are reachable.
5. **Add extension helpers** (`ext/*.pm`) for anything that is not a data object.

This is the intended, additive way to extend W5Base — new files in a new module,
not edits to the kernel.

---

## 10. Backward-compatibility note

`mod/crm`, like the rest of `mod/**`, is **read-only** for the
containerized-environment work in this repository. The environment renders and
validates these objects but never edits them or their SQL, preserving application
behavior and the schema contract (see
[Kernel §10](./kernel.md#10-backward-compatibility-note)).

---

## 11. Where to go next

- **Understand the engine:** the [Kernel guide](./kernel.md).
- **See the patterns at scale:** the [ITIL module guide](./itil.md).
- **System-wide view:** the [Architecture Overview](../ARCHITECTURE.md).
- **Run it locally:** the [Local Setup runbook](../LOCAL_SETUP.md).
- **Project front door:** the [root README](../../README.md).
