# R123 — Kann configuration follow-ups

Status: **assigned** · Assigned: yes · Optional/further-review: no

Base: `main`, after merged R122 / [#199](https://github.com/BitChillRSK/dca-contracts/pull/199).

## Objective

Implement the approved configuration responses to Kann #12, #23, and #20 item 5:
- the eight named setters reject an unchanged value;
- the three constructors that write configuration emit its existing events;
- `DcaManagerAccessControl` rejects a zero manager.

## Background

- [Kann #12](https://github.com/Kann-Audits/BitChill-Audit/issues/12): eight setters succeed and log a change when the new value equals the stored one. The owner approved the same no-op rejection that R121 applied to swappers (Kann #10). `setFeeRateParams` stays as is: it writes and emits only the fields that change.
- [Kann #23](https://github.com/Kann-Audits/BitChill-Audit/issues/23): `DcaManager`, `PurchaseFees` and `PurchaseUniswap` write nine configuration values at construction without the events their setters emit. Once #12 lands, re-sending a value can no longer log it, so the two changes ship together.
- [Kann #20](https://github.com/Kann-Audits/BitChill-Audit/issues/20), item 5: every sibling constructor rejects a zero address, but `DcaManagerAccessControl` accepts a zero manager. That handler fails closed, so this is for consistency.
- Owner decisions: 2026-11-25. This is the second of four PRs; see `IMPLEMENTATION_ORDER.md`.

## Open product decisions

**none**

## Scope

- [ ] Each setter reverts with a new `…Unchanged` error when the value equals the stored one. The check runs after the existing authorization and validation, so those errors keep their precedence. An unauthorized or invalid call never reports `…Unchanged`.

  | Setter | Error (on the owning interface) |
  |---|---|
  | `PurchaseUniswap.setPurchasePath` | `PurchaseUniswap__PurchasePathUnchanged(bytes32 pathHash)`: the encoded path hash equals the active path's hash. Checked after the allowlist and caller checks. |
  | `PurchaseUniswap.setMocOracle` | `PurchaseUniswap__OracleUnchanged(address oracle)` |
  | `PurchaseUniswap.setAmountOutMinimumPercent` | `PurchaseUniswap__AmountOutMinimumPercentUnchanged(uint256 amountOutMinimumPercent)` |
  | `PurchaseUniswap.setAmountOutMinimumSafetyCheck` | `PurchaseUniswap__AmountOutMinimumSafetyCheckUnchanged(uint256 amountOutMinimumSafetyCheck)` |
  | `PurchaseFees.setFeeCollector` | `PurchaseFees__FeeCollectorUnchanged(address feeCollector)` |
  | `DcaManager.setMinPurchasePeriod` | `DcaManager__MinPurchasePeriodUnchanged(uint256 minPurchasePeriod)` |
  | `DcaManager.setMaxSchedulesPerToken` | `DcaManager__MaxSchedulesPerTokenUnchanged(uint256 maxSchedulesPerToken)` |
  | `DcaManager.setTokenMinPurchaseAmount` | `DcaManager__TokenMinPurchaseAmountUnchanged(address token, uint256 minPurchaseAmount)` |

- [ ] Constructors emit the existing setter events for their nine initial values, after validation and storage. Old/new events report `0` / `address(0)` as the old value.
  - `DcaManager`: `MinPurchasePeriodModified`, `MaxSchedulesPerTokenModified`.
  - `PurchaseFees`: `FeeCollectorAddressSet`, `MinFeeRateSet`, `MaxFeeRateSet`, `PurchaseLowerBoundSet`.
  - `PurchaseUniswap`: `OracleUpdated(address(0), oracle)`, `AmountOutMinimumPercentUpdated(0, value)`, `AmountOutMinimumSafetyCheckUpdated(0, value)`.

  No owner-only setter is called from a constructor.
- [ ] Event NatSpec says each event records the value set at construction as well as later owner changes. Setter NatSpec names the new error. "Idempotent" or "replace" wording that implied a repeat succeeds is corrected.
- [ ] `DcaManagerAccessControl` constructor: `if (dcaManager == address(0)) revert DcaManagerAccessControl__ZeroDcaManager();`, declared on `IDcaManagerAccessControl`.
- [ ] Update tests and Fizz handlers that repeat a setting on purpose. Keep the coverage of invalid calls.

## Out of scope

- [ ] `setFeeRateParams` (unchanged by owner decision), `setPurchasePathAllowed` (it already rejects an unchanged value), and any OperationsAdmin setter.
- [ ] #18 I-09 purchase reentrancy (PR 3), and the remaining documentation and source-consistency sweep (PR 4).
- [ ] New events, changed event signatures, a generic configuration framework, or a second interface.
- [ ] Deployment, consumer code, and consumer pin changes.

## Files likely touched

- `src/DcaManager.sol`, `src/PurchaseFees.sol`, `src/PurchaseUniswap.sol`, `src/DcaManagerAccessControl.sol`
- `src/interfaces/IDcaManager.sol`, `src/interfaces/IPurchaseFees.sol`, `src/interfaces/IPurchaseUniswap.sol`, `src/interfaces/IDcaManagerAccessControl.sol`
- Setter and deployment tests under `test/unit/` and `test/ai-generated/unit/`; Fizz handlers under `test/fizz/`; `PROPERTIES.md` where a property names a repeated setting
- This spec, `docs/relaunch/IMPLEMENTATION_ORDER.md`, `docs/relaunch/README.md`

## Required tests

- Each of the eight setters: an unchanged value reverts with its error, a changed value still succeeds and emits, an unauthorized caller still gets the authorization error, and an invalid value still gets its validation error.
- `setPurchasePath`: re-sending the active path reverts, for the owner and for a swapper. A stranger gets the caller error even for the active path. Switching to another allowlisted path and back succeeds.
- Constructor events: deploy each of `DcaManager`, a MoC leaf and a Dex leaf with `vm.recordLogs()`. Assert each of the nine events comes from the deployed contract and carries the getter's value.
- Zero manager: a handler constructed with `dcaManager == address(0)` reverts with the new error.
- `make check` and `make fork-layerbank` before push. Run the targeted deployment-profile regressions too. No new fork-specific assertion.

## Success criteria

- [ ] All scope items and required tests pass, with no change from PRs 3 or 4.
- [ ] Every consumer that decodes these errors or counts these events has an existing issue updated or a new issue opened when this PR opens.

## Reviewer checklist

- [ ] Authorization and validation errors keep their precedence over the new `…Unchanged` errors.
- [ ] Constructor events come from the deployed leaf and match the getters. No owner-only setter runs during construction.
- [ ] `setFeeRateParams` and `setPurchasePathAllowed` behavior is unchanged.
- [ ] Extra files follow direct dependencies or failing tests and are named in the PR.

## ABI / deploy / cutover impact

- ABI: nine new errors (eight `…Unchanged` and `DcaManagerAccessControl__ZeroDcaManager`). No function or event signature changes.
- Behavior: the eight setters refuse an unchanged write. Deployment logs nine more events, from the deployed `DcaManager` and every handler leaf. Creation code changes, so deterministic deployment addresses can change.
- Scripts: unchanged. Each one sets a token minimum once, from zero.
- Consumers: monitoring decodes the new errors and sees the initial events. Indexers must not read an initial event as a later owner change. Search existing issues first; do not move pins.
