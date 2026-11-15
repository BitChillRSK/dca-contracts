# DOC redemption through Money on Chain

Research date: 2026-10-22. BitChill source: `c82bc47a`.
This note records protocol research. It makes no contract changes.

## Conclusion

The current MoC deployment does not require `redeemDocRequest` before `redeemFreeDoc`.
The deployed request function returns without further calls or token movement.
Current upstream source defines it as an empty function.
Therefore, its removal does not remove a working redemption path.
[MoC source](https://github.com/money-on-chain/main-RBTC-contract/blob/0043303da89f43d7f4e67a0288c561da8bf3de1b/contracts/MoC.sol#L123-L138)

## Historical dates

BTCX removal occurred in 2023. The request function's source code remained after that model change.
The source available in January 2024 still called `settlement.addRedeemRequest(docAmount, msg.sender)`.
However, `redeemFreeDoc` already followed an independent path without a prior-request requirement.
[Historical request function](https://github.com/money-on-chain/main-RBTC-contract/blob/fd7669e0cf633b9be936c07c6ce3d16c0e54fa05/contracts/MoC.sol#L123-L138),
[historical immediate redemption](https://github.com/money-on-chain/main-RBTC-contract/blob/fd7669e0cf633b9be936c07c6ce3d16c0e54fa05/contracts/MoC.sol#L318-L348),
[historical exchange calculation](https://github.com/money-on-chain/main-RBTC-contract/blob/fd7669e0cf633b9be936c07c6ce3d16c0e54fa05/contracts/MoCExchange.sol#L371-L405)

Commit `a73ade591ba2ffe04adaf501ff575d419cd5cf94` replaced the request body with an empty function on **2026-05-11**.
That is the source commit date. This research does not establish the exact mainnet upgrade date.
The fork evidence below confirms the empty deployed behavior by 2026-10-22.
[Removal commit](https://github.com/money-on-chain/main-RBTC-contract/commit/a73ade591ba2ffe04adaf501ff575d419cd5cf94)

## Meaning of free DOC

`freeDoc()` returns the DOC amount accounted for in the base bucket, `C0`.
This is protocol accounting, not a separate class of ERC-20 balances.
“Free” means available for immediate redemption. It does not mean redemption has no fees.
[MoCState source](https://github.com/money-on-chain/main-RBTC-contract/blob/0043303da89f43d7f4e67a0288c561da8bf3de1b/contracts/MoCState.sol#L302-L308)

Historically, BTCX leveraged positions used DOC allocations outside `C0`.
DOC outside that immediate capacity needed the settlement mechanism.
MoC removed BTCX in 2023. Its official explanation states that settlement no longer exists.
The current BTCX mint function always reverts.
[Protocol explanation](https://moneyonchain.com/simplification-of-the-money-on-chain-model/),
[disabled mint function](https://github.com/money-on-chain/main-RBTC-contract/blob/0043303da89f43d7f4e67a0288c561da8bf3de1b/contracts/MoC.sol#L287-L292)

Minting increases DOC supply and the DOC amount in `C0` equally.
Redemption decreases both equally.
Consequently, ordinary minting and redemption preserve `freeDoc() == totalSupply()` when all DOC remains in `C0`.
Another holder's redemption decreases both values; it does not leave the remaining DOC outside `C0`.
This is an inference from the accounting code and the removal of leveraged positions.
[Mint accounting](https://github.com/money-on-chain/main-RBTC-contract/blob/0043303da89f43d7f4e67a0288c561da8bf3de1b/contracts/MoCExchange.sol#L348-L368),
[redemption accounting](https://github.com/money-on-chain/main-RBTC-contract/blob/0043303da89f43d7f4e67a0288c561da8bf3de1b/contracts/MoCExchange.sol#L509-L514)

MoC computes immediate redemption as:

```text
DOC redeemed = min(requested DOC, freeDoc(), caller DOC balance)
```

MoC burns that DOC and calculates rBTC from its oracle price, with applicable commissions.
It can therefore return a positive partial redemption when the free capacity is insufficient.
[Redemption implementation](https://github.com/money-on-chain/main-RBTC-contract/blob/0043303da89f43d7f4e67a0288c561da8bf3de1b/contracts/MoCExchange.sol#L304-L337)

## Pinned deployment evidence

Rootstock block: **9,346,460**.
Block timestamp: **2026-10-22 09:18:18 UTC**, or **11:18:18 Europe/Madrid**.
Read-only RPC calls used the same block for every value.
The existing fork probe also used this block.

| Value | DOC amount |
| --- | ---: |
| `DOC.totalSupply()` | 2,898,437.941557856933183408 |
| `MoCState.freeDoc()` | 2,898,437.941557856933183408 |
| `BProxManager.getBucketNDoc(C0)` | 2,898,437.941557856933183408 |
| `BProxManager.getBucketNDoc(X2)` | 0 |

The first three raw amounts equal `2898437941557856933183408` at 18 decimals.

| Contract | Address |
| --- | --- |
| MoC proxy | `0xf773B590aF754D597770937Fa8ea7AbDf2668370` |
| Observed MoC implementation | `0xfaF8b802c934aF857B58471B6DAA66DC5d8a7D07` |
| DOC | `0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db` |
| MoCState proxy | `0xb9C42EFc8ec54490a37cA91c423F7285Fa01e257` |
| BProxManager proxy | `0xC4fBFa2270Be87FEe5BC38f7a1Bb6A9415103b6c` |

The request probe delegated to the implementation and stopped, with no subsequent calls.
It changed neither DOC nor rBTC balances.
The immediate redemption probe spent exactly 10 DOC without a request.
It received `122272288648680` wei of rBTC.
That payout reflects the probe holder's fee configuration; it is not a universal redemption quote.
[Probe source](../test/mainnet-debug/moc-redeem-free-doc/MocRedeemFreeDocProbe.t.sol)

The observed implementation was not independently matched byte-for-byte against verified source.
The fork trace establishes the deployed request behavior directly.
The pinned upstream source independently confirms the empty request function.

## BitChill behavior and risk

The pre-relaunch MoC handlers called the request function and then performed immediate redemption.
`PurchaseMoc` calls only `redeemFreeDoc` and measures received rBTC.
`PurchaseRbtc` separately requires exact DOC consumption.
A partial redemption reverts the complete transaction, including previous accounting and token movements.
[PurchaseMoc](../src/PurchaseMoc.sol), [PurchaseRbtc](../src/PurchaseRbtc.sol),
[regression tests](../test/unit/PurchaseMocBehaviorTest.t.sol)

Current MoC pause, protection mode, oracle, fee, gas-price, and transfer conditions can still block purchases.
An empty request function cannot bypass those conditions.
If governance restores asynchronous redemption, BitChill needs a separate request-and-settlement lifecycle.
Adding one request selector cannot provide delayed payout allocation or pending-request accounting.
[MoC redemption gates](https://github.com/money-on-chain/main-RBTC-contract/blob/0043303da89f43d7f4e67a0288c561da8bf3de1b/contracts/MoC.sol#L299-L336)

Liquidation uses MoC's separate `redeemAllDoc` function, which current BitChill handlers do not expose.
Users can withdraw DOC without calling MoC, subject to BitChill withdrawal rules and the lending protocol's liquidity.
This separates a purchase failure from an automatic loss of access to the user's DOC claim.
It does not guarantee lending liquidity or DOC solvency.
[MoC liquidation entry](https://github.com/money-on-chain/main-RBTC-contract/blob/0043303da89f43d7f4e67a0288c561da8bf3de1b/contracts/MoC.sol#L330-L337),
[DOC transfer](../src/TokenHandler.sol), [lending withdrawal](../src/LendingHandler.sol),
[manager withdrawal](../src/DcaManager.sol)

`IMocProxy` declares only `redeemFreeDoc`, so first-party code cannot call the request function.
The probe declares the request function locally to show that it pays nothing.
[Local interface](../src/interfaces/IMocProxy.sol), [probe](../test/mainnet-debug/moc-redeem-free-doc/MocRedeemFreeDocProbe.t.sol)

## Validation

```sh
make probe-moc-redeem-free-doc PROBE_VERBOSITY=-vvvv
forge test --match-contract PurchaseMocBehaviorTest -vv
```

Results: two fork tests passed; four unit tests passed.
The unit tests cover immediate redemption, original revert propagation, partial-consumption rollback, and zero-output rejection.
Fork execution used Anvil/revm. It does not prove Rootstock opcode or gas compatibility.
No transactions were broadcast.
