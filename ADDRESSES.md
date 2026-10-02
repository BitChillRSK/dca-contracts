# Addresses

## BitChill contracts

The relaunch contracts are not deployed yet. After cutover, the nine addresses `DeployFinal` logs
(`OperationsAdmin`, `DcaManager`, seven handlers) are recorded here.

| Role | Rootstock mainnet | Source |
|---|---|---|
| Owner after handoff (BitChill Safe) | `0xdeAbdc410aB7B0f1Da830A6b355B5b938208315f` | `MAINNET_OWNER` |
| Fee collector | `0x3caB92C050514A0368D71815CAc42ad746350F16` | `MAINNET_FEE_COLLECTOR` |

## External contracts the deployment binds to (Rootstock mainnet)

Taken from `script/DeployFinal.s.sol` and `script/Constants.sol`, which are the source of truth. The
last column says how each address reaches a handler. Addresses passed to a constructor are immutable
there, except the MoC oracle, which a Dex handler's owner can replace with `setMocOracle`. Swap paths
are an owner-managed allowlist: the owner can allow or revoke paths through other tokens and pools
with `setPurchasePathAllowed`.

| Contract | Address | How it is bound |
|---|---|---|
| DOC | `0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db` | Constructor of the DOC handlers |
| USDRIF | `0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37` | Constructor of the USDRIF handlers |
| USDT0 (6 decimals) | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | Constructor of the USDT0 handlers. Also the intermediate token of the USDRIF handlers' initial path, which their constructor allowlists |
| USDT (6 decimals) | `0xAf368c91793CB22739386DFCbBb2F1A9e4bCBeBf` | Intermediate token of a second USDRIF path. `DeployFinal` allowlists it with `setPurchasePathAllowed` after construction; the owner can revoke it |
| WRBTC | `0x542fDA317318eBF1d3DEAf76E0b632741A7e677d` | Constructor of the Dex handlers |
| Money on Chain proxy | `0xf773B590aF754D597770937Fa8ea7AbDf2668370` | Constructor of the DOC handlers (`redeemFreeDoc`) |
| Money on Chain BTC/USD oracle | `0xe2927A0620b82A66D67F678FC9b826B0E01B1bFD` | Constructor of the Dex handlers (swap floor); replaceable |
| Uniswap V3 SwapRouter02 | `0x0B14ff67f0014046b4b99057Aec4509640b3947A` | Constructor of the Dex handlers |
| Sovryn iToken for DOC (iSUSD) | `0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1` | Constructor of `SovrynDocHandlerMoc` |
| LayerBank aToken, DOC (lRooDOC) | `0x3F04280C66314b78E9712A41BF8C1A214460cAa2` | Constructor of `LayerBankDocHandlerMoc` |
| LayerBank aToken, USDRIF (lRooUSDRIF) | `0xc96fBD12bE56Dd565b258d243344bCf792A51128` | Constructor of `LayerBankHandlerDex` (USDRIF) |
| LayerBank aToken, USDT0 (lRooUSDT0) | `0x6bE7d4cfCe825b106aa88F6916A412c5af230Ec0` | Constructor of `LayerBankHandlerDex` (USDT0) |
| LayerBank Pool | `0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9` | Not passed in. Each LayerBank handler reads it from its aToken's `POOL()` at construction and stores it as an immutable |

Explorer: <https://rootstock.blockscout.com>.

`DeployFinal` does not run on Rootstock testnet, which has no LayerBank aTokens or Uniswap V3
deployment for this map. Testnet and local addresses used by the test lanes are in
`script/MocHelperConfig.s.sol`, `script/DexHelperConfig.s.sol`, and `script/UsdrifHelperConfig.s.sol`.
