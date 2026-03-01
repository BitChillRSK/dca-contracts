# Security Audits

BitChill has undergone rigorous independent security audits to ensure the safety of user funds and protocol integrity.

## Audit Reports

| Date | Auditor | Scope | Findings | Report |
|------|---------|-------|----------|--------|
| April 2025 | [Ivan Fitro](https://twitter.com/FitroIvan) | Full protocol review | 3 Medium, 4 Low, 2 Info | [PDF](./2025-04-29-Ivan-Fitro.pdf) |
| June 2025 | [Ivan Fitro](https://twitter.com/FitroIvan) | Mitigations + Uniswap V3 integration | 1 Low, 1 Info | [PDF](./2025-06-02-Ivan-Fitro.pdf) |

## Summary

### Initial Audit (April 2025)

A comprehensive security review covering 11 core contracts including `DcaManager`, `FeeHandler`, token handlers for Tropykus and Sovryn, and the Money on Chain purchase integration.

**Contracts Reviewed:**
- AdminOperations.sol
- DcaManager.sol
- DcaManagerAccessControl.sol
- FeeHandler.sol
- PurchaseMoc.sol
- SovrynDocHandler.sol / SovrynDocHandlerMoc.sol
- TokenHandler.sol / TokenLending.sol
- TropykusDocHandler.sol / TropykusDocHandlerMoc.sol

**Key Findings (all resolved):**
- **[M-01]** rBTC withdrawal to non-receiving contracts → Added stuck funds recovery
- **[M-02]** `withdrawAllAccumulatedRbtc()` revert conditions → Added balance checks
- **[M-03]** Fee frontrunning via purchase period manipulation → Restricted period changes
- **[L-01]** Zero-balance schedule deletion → Added balance check before withdrawal
- **[L-02]** Schedule ID collisions → Implemented user-specific nonce
- **[L-03]** DoS via excessive schedules → Added schedule limit per user
- **[L-04]** Unrestricted rBTC withdrawal → Added `onlyDcaManager` modifier

### Mitigation Review + Uniswap V3 (June 2025)

A follow-up audit verifying all previous findings were properly mitigated, plus a security review of the new Uniswap V3 swap integration.

**Additional Contracts Reviewed:**
- PurchaseUniswap.sol
- PurchaseRbtc.sol
- SovrynErc20HandlerDex.sol
- TropykusErc20HandlerDex.sol

**Findings (all resolved):**
- **[L-01]** Oracle price staleness check → Implemented `getPriceInfo()` validation
- **[I-01]** Immutable oracle address → Added owner-controlled oracle update function

## Audit Status

✅ **All findings from both audits have been addressed and verified.**

## Auditor Background

Ivan Fitro is an independent security researcher specializing in smart contract audits with a proven track record of identifying vulnerabilities across blockchain protocols. Since auditing BitChill, Ivan joined [Pashov Audit Group](https://www.pashov.com/) in late 2025 and [OpenZeppelin](https://www.openzeppelin.com/) in March 2026—demonstrating that BitChill's smart contracts were reviewed by tier-1 security talent.
