# R62 — Add the missing `IdleErc20HandlerDex` leaf

Status: **not started** · Assigned: no · Optional/further-review: no

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
route is DOC-only today: USDRIF and USDT0 users are forced onto LayerBank lending, and DOC users
who do not want lending exposure cannot use a DEX purchase path. `IdleErc20Handler` is already
abstract and already implements `StablecoinSource` for an arbitrary ERC20 (`i_stableToken`), so the
leaf is constructor-only, the same shape as `LayerBankErc20HandlerDex`.

Inheritance order matters and is set by precedent: the funding base is listed first so
`i_stableToken` is set before `PurchaseUniswap`'s constructor encodes the swap path from it
(see the `@dev` on `LayerBankErc20HandlerDex`).

`_batchRetrieveStablecoin` on the idle base reverts rather than clamps when a buyer is short.
That is deliberate (`PurchaseRbtc` splits rBTC by the original planned weights) and is unchanged
here — but it now applies on a Uniswap batch, where a revert wastes a swap quote. Confirm the
swapper's pre-flight already filters short buyers before this ships.

## Open product decisions

- [ ] Which stablecoins get an idle+DEX route on mainnet at cutover (DOC, USDRIF, USDT0, or a
      subset), and at which `routeIndex`. Route index 0 is pre-registered as idle and non-lending;
      whether this leaf reuses index 0 or takes a new idle index is a registry decision, because
      `OperationsAdmin` route assignment is add-only.

## Scope

- [ ] `src/idle/IdleErc20HandlerDex.sol`: `contract IdleErc20HandlerDex is IdleErc20Handler, PurchaseUniswap`,
      constructor only, NatSpec matching the three sibling `*Dex` leaves.
- [ ] Deploy support in `script/DeployIdleHandler.s.sol` (or a `deployIdleHandlerDex` in
      `DeployDexSwaps.s.sol`, whichever matches how the other Dex leaves are reached).
- [ ] Unit + fork coverage for the new leaf on the same lanes the other Dex leaves use.

## Out of scope

- [ ] Any change to `IdleErc20Handler`, `PurchaseUniswap`, or the shared bases.
- [ ] Retiring `IdleDocHandlerMoc`.
- [ ] Mainnet route registration or broadcast.

## Files likely touched

- `src/idle/IdleErc20HandlerDex.sol` (new)
- `script/DeployIdleHandler.s.sol`, `script/DeployDexSwaps.s.sol`
- `script/DexHelperConfig.s.sol` if the idle+DEX combination needs a config branch
- matching tests under `test/`

## Required tests

- `make check` (all lanes).
- A `SWAP_TYPE=dex` lane exercising the idle route: deposit → batch purchase → withdraw rBTC.
- Assert the short-buyer batch **reverts** rather than clamping, so R62 does not silently change
  the idle base's documented behavior when it reaches a Uniswap batch.
- `make fork-sovryn` and `make fork-tropykus` before push, per `AGENTS.md`.

## Success criteria

- [ ] Every funding base has both leaves; the grid above has no empty cell.
- [ ] The new leaf's runtime size is recorded, with its EIP-170 margin.
- [ ] Constructor argument order and inheritance order match the sibling `*Dex` leaves.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Funding base is listed first in the `is` clause, so `i_stableToken` is set before the swap
      path is encoded.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] No change to any existing handler's bytecode.

## ABI / deploy / cutover impact

- ABI: a new contract artifact; no existing ABI changes.
- Scripts: yes — a new deploy branch. Local-only until the product decision above is answered.
- Cutover: the frontend gains a route class it has not seen (idle funding with a DEX purchase
  venue). File a consumer issue once the route indices are decided.
