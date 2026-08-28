# R49 — Rename `DcaDetails` to `DcaSchedule`

Status: **assigned** · Assigned: yes · Optional/further-review: no

PR 40 of the relaunch stack. Stack on R19 (PR 39). **Land before R18**, which repacks this struct.

## Objective

Rename the schedule struct from `DcaDetails` to `DcaSchedule` so the type is named after the domain
entity it represents, matching the noun the rest of the codebase already uses everywhere else.
Rename-only: no storage layout, selector, event, error, or behavior change.

## Background

`Details` is a noise word — it carries no information, because every struct is "details about
something". The type should name what it *is*, so that `X is a Y` reads true: "a user's DCA
arrangement is a schedule" parses; "…is a details" does not.

The codebase has already voted. Storage is `s_dcaSchedules`; the surface is `createDcaSchedule`,
`deleteDcaSchedule`, `getDcaSchedule(s)`, `scheduleId`, `scheduleIndex`, `setSchedulePaused`,
`s_maxSchedulesPerToken`; the errors are `DcaManager__InexistentScheduleIndex` and
`DcaManager__ScheduleIdAndIndexMismatch`. Every local instance of the type is already named
`dcaSchedule` ([`DcaManager.sol`](../../src/DcaManager.sol) `depositToken`, `updatePurchaseAmount`,
`updatePurchasePeriod`, `deleteDcaSchedule`). When every instance of a type is instinctively named
`x` but the type is named `Y`, the type is misnamed.

This is the same class of correction as [R26](./R26-share-terminology.md) ("lending token" → shares)
and [R35](./R35-route-index-terminology.md) (`lendingProtocolIndex` → `routeIndex`), and it follows
the same rule those did: settle the noun before the freeze, and before a PR rewrites the same lines
for another reason.

**`DcaSettings` was considered and rejected.** The struct holds `tokenBalance` and
`lastPurchaseTimestamp` — runtime state the protocol writes, not user-supplied knobs. Naming a mixed
identity+config+state record after its config half invites treating it as safe to replace wholesale,
which is precisely the stale-write-back hazard [R6](./R6-hot-path-cleanup.md) analysed on
`updateDcaSchedule`. `Schedule` is honest about the struct being the whole entity.

## Open product decisions

**none** — the target name is `DcaSchedule`. Do not rename fields, functions, events, or errors.

## Scope

- [ ] `struct DcaDetails` → `struct DcaSchedule` in `IDcaManager`, and every reference in `src/` and
      `test/`.
- [ ] Nothing else changes: field names and order, function names, selectors, events, errors,
      storage layout, and all behavior stay exactly as they are.

## Out of scope

- [ ] Storage packing, field reordering, or type narrowing — that is [R18](./R18-storage-packing.md),
      which stacks on this.
- [ ] Renaming `s_dcaSchedules`, `createDcaSchedule`, `getDcaSchedule`, `scheduleId`,
      `scheduleIndex`, or any other already-correct identifier.
- [ ] Renaming the local variables `dcaSchedule` / `dcaScheduleStorage`. They are already right.
- [ ] Any behavior, gas, or ABI-surface change. If a diff line changes more than the type name, it
      does not belong in this PR.

## Files likely touched

- `src/interfaces/IDcaManager.sol` (the declaration), `src/DcaManager.sol`
- The test files that name the type: `test/unit/`, `test/ai-generated/`, `test/mainnet-debug/`

## Required tests

No new tests — a rename with no behavior change should be provable by the existing suite passing
unchanged. Confirm the type name is gone (`grep -rn "DcaDetails" src test script` returns nothing)
and that the storage layout and selectors are byte-identical to the base branch:

```
forge inspect DcaManager storageLayout
forge inspect DcaManager methodIdentifiers
make check
make fork-sovryn
make fork-tropykus
```

## Success criteria

- [ ] No `DcaDetails` remains in `src/`, `test/`, or `script/`.
- [ ] `forge inspect DcaManager storageLayout` differs from base only in the struct's type label.
- [ ] `forge inspect DcaManager methodIdentifiers` is byte-identical to base.
- [ ] Full suite passes with no test edits beyond the type name.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Every changed line changes only the type name — no opportunistic edits rode along.
- [ ] Selectors and storage layout verified unchanged, not assumed.
- [ ] Protocol invariants in `AGENTS.md` still hold; none is touched.

## ABI / deploy / cutover impact

- ABI: **no selector or event change.** A struct name is not part of a function selector — the
  tuple encoding is identical. It *does* appear in the ABI JSON's `internalType` and therefore in
  generated bindings (wagmi/typechain), so consumers that codegen types will see the type rename.
- Scripts: none.
- Cutover: consumers regenerating types should do it after [R18](./R18-storage-packing.md) rather
  than after this PR, since R18 narrows the same struct's field types — otherwise they do it twice.
