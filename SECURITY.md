# Security Policy

## Reporting a vulnerability

Email arynyestos@gmail.com with enough detail to reproduce the issue. Do not open a public GitHub issue
for an unfixed vulnerability in a live deployment.

## Bug bounty

There is no formal bug-bounty program and no guaranteed reward. Significant, good-faith reports may be
acknowledged and rewarded at BitChill's discretion.

## Incident response

Production contracts are immutable: no proxies, no upgradeability, and no owner migration of user
funds. A vulnerability in deployed bytecode cannot be patched in place. The response is:

1. Contain: revoke the swapper, pause deposits on the affected routes, stop the bot.
2. Deploy fixed contracts at new route indexes where needed.
3. Users exit the old handlers and re-enter on the new routes themselves.

Off-chain consumers (front end, bot, monitoring) can be updated independently.

## Supported deployments

| Deployment | Support |
| ---------- | ------- |
| Relaunch deployment (after cutover) | Incident response as above |
| Pre-relaunch mainnet contracts | None. Users should exit |

## License

`src/` is licensed under the Business Source License 1.1 (see [`LICENSE`](./LICENSE)), with an
Additional Use Grant for non-production use and a Change License of `GPL-2.0-or-later` after the Change
Date. `script/` and `test/` are MIT.
