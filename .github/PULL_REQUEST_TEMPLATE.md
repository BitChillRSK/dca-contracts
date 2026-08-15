## Summary

<!-- What changed and why. One short paragraph. -->

## Assigned relaunch task spec

<!-- Path under docs/relaunch/, or "n/a — not a relaunch item". -->

- Spec:
- R-item (if any):

## Scope / out of scope

**In scope**

-

**Out of scope (not in this PR)**

-

## Files beyond the spec

<!-- Start from the spec’s file list. If you followed imports, inheritance, mocks, failing tests, or compiler errors, list those extra paths and why. -->

- None

## Tests run

<!-- Exact local commands. CI must be green; do not treat this list as a substitute. -->

```
make check
```

## ABI changes

- [ ] None
- [ ] Yes — describe (functions, events, indexed fields):

## Deployment / script impact

- [ ] None
- [ ] `script/` or deploy config changed (local/test only; this PR must not broadcast)
- [ ] Cutover / frontend note:

## Security considerations

<!-- Point at AGENTS.md protocol invariants. Note any spec that changes one. -->

## Reviewer checklist

- [ ] Matches the assigned spec (or is clearly not a relaunch item)
- [ ] No optional / further-review work unless the spec assigned it
- [ ] PR is small and behavior-scoped; no unrelated refactors
- [ ] Extra files beyond the spec are listed and justified
- [ ] Tests listed above were run; CI matrix is green
- [ ] Protocol invariants in `AGENTS.md` still hold unless the spec changed one
- [ ] No broadcast, live-chain interaction, or secrets in the diff
