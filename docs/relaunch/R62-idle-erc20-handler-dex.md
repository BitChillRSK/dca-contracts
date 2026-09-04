# R62 — Add the missing `IdleErc20HandlerDex` leaf

Status: **assigned** · Assigned: yes · Optional/further-review: no

## Objective

Add `src/idle/IdleErc20HandlerDex.sol` (`IdleErc20Handler` + `PurchaseUniswap`) so the idle route
has a Uniswap leaf, matching every lending family. Today a user who wants to hold their stablecoin
idle rather than lend it can only buy through MoC, which means only DOC.

## Background

The handler grid is (funding base) × (purchase venue). Three of the four funding bases have both
leaves:

| funding base | MoC leaf | Uniswap leaf |
|---|---|---|
| `IdleErc20Handler` | `IdleDocHandlerMoc` | **missing** |
| `TropykusErc20Handler` | `TropykusDocHandlerMoc` | `TropykusErc20HandlerDex` |
| `SovrynErc20Handler` | `SovrynDocHandlerMoc` | `SovrynErc20HandlerDex` |
| `LayerBankErc20Handler` | `LayerBankDocHandlerMoc` | `LayerBankErc20HandlerDex` |

The gap is a product hole, not a technical one. MoC redemption only works for DOC, so the idle
route is DOC-only today: USDRIF and USDT0 users are forced onto LayerBank lending. `IdleErc20Handler`
is already abstract and already implements `StablecoinSource` for an arbitrary ERC20
(`i_stableToken`), so the leaf is constructor-only, the same shape as `LayerBankErc20HandlerDex`.

Inheritance order matters and is set by precedent: the funding base is listed first so
`i_stableToken` is set before `PurchaseUniswap`'s constructor encodes the swap path from it
(see the `@dev` on `LayerBankErc20HandlerDex`).

`_batchRetrieveStablecoin` on the idle base reverts rather than clamps when a buyer is short.
That is deliberate (`PurchaseRbtc` splits rBTC by the original planned weights) and is unchanged
here — but it now applies on a Uniswap batch, where a revert wastes a swap quote. Confirm the
swapper's pre-flight already filters short buyers before this ships.

## Open product decisions

**Answered 2026-09-04:**

- All three stables are in product scope, but **DOC is never swapped on Uniswap**. DOC idle stays
  `IdleDocHandlerMoc` at `(DOC, 0)`.
- Idle+DEX cutover assignments: `(USDRIF, 0)` and `(USDT0, 0)` → `IdleErc20HandlerDex` (same
  pre-registered idle index as MoC idle DOC).

## Scope

- [x] `src/idle/IdleErc20HandlerDex.sol`: `contract IdleErc20HandlerDex is IdleErc20Handler, PurchaseUniswap`,
      constructor only, NatSpec matching the three sibling `*Dex` leaves.
- [x] Deploy support in `script/DeployIdleHandler.s.sol` (or a `deployIdleHandlerDex` in
      `DeployDexSwaps.s.sol`, whichever matches how the other Dex leaves are reached).
- [x] Unit + fork coverage for the new leaf on the same lanes the other Dex leaves use.

## Out of scope

- [x] Any change to `IdleErc20Handler`, `PurchaseUniswap`, or the shared bases.
- [x] Retiring `IdleDocHandlerMoc`.
- [x] Mainnet route registration or broadcast.

## Files likely touched

- `src/idle/IdleErc20HandlerDex.sol` (new)
- `script/DeployIdleHandler.s.sol`, `script/DeployDexSwaps.s.sol`
- `script/DexHelperConfig.s.sol` if the idle+DEX combination needs a config branch
- matching tests under `test/`

## Required tests

- `make check` (all lanes).
- A `SWAP_TYPE=dex` lane exercising the idle route: deposit → batch purchase → withdraw rBTC.
  Run it on **both** listed stables: `STABLECOIN_TYPE=USDRIF make dex-none` and
  `STABLECOIN_TYPE=USDT0 make dex-none`. USDT0 is the 6-decimal case, so it is the lane that
  exercises `i_stablecoinToUsdScale` and the USDT0 fee bounds on the new leaf, and the only one
  that reaches the live deploy path where no LayerBank aToken exists.
- Assert the short-buyer batch **reverts** rather than clamping, so R62 does not silently change
  the idle base's documented behavior when it reaches a Uniswap batch.
- Live Uniswap fork coverage matching the other Dex leaves:
  `SWAP_TYPE=dexSwaps STABLECOIN_TYPE=USDRIF make fork-none` (peer of
  `SWAP_TYPE=dexSwaps STABLECOIN_TYPE=USDRIF make fork-layerbank`), plus
  `make fork-dex-path` (now runs `DexPathFailoverTest` on LayerBank **and** idle).
- `make fork-sovryn` and `make fork-tropykus` before push, per `AGENTS.md`.

## Success criteria

- [x] Every funding base has both leaves; the grid above has no empty cell.
- [x] The new leaf's runtime size is recorded, with its EIP-170 margin.
- [x] Constructor argument order and inheritance order match the sibling `*Dex` leaves.
- [x] The live deploy assigns the idle leaf at `IDLE_INDEX` and selects it when
      `LENDING_PROTOCOL=none`, on a network with **and** without a LayerBank aToken.

**Size (this PR, `[profile.default]` optimizer 200 / no IR):** `IdleErc20HandlerDex` runtime **12,940 B**, EIP-170 margin **11,636 B**.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Funding base is listed first in the `is` clause, so `i_stableToken` is set before the swap
      path is encoded.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] No change to any existing handler's bytecode.

## ABI / deploy / cutover impact

- ABI: a new contract artifact; no existing ABI changes.
- Scripts: yes — `DeployDexSwaps` Protocol.NONE builds `IdleErc20HandlerDex`; live USDRIF/USDT0
  deploys assign it at `IDLE_INDEX` alongside LayerBank at index 1. DOC stays MoC-only.
- Cutover: frontend / bot / data-api gain idle funding with a DEX purchase venue for USDRIF and
  USDT0 at route index 0 (same idle class as MoC DOC). Consumer issues filed with this PR.
