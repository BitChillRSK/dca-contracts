# Dependency Modifications

## Solidity Version Compatibility

### Background
This project is deployed on Rootstock, which requires Solidity 0.8.19 compatibility. However, several dependencies (Uniswap V3 Core, V3 Periphery, and Swap Router Contracts) use a strict Solidity 0.7.6 version requirement.

### Modifications Made
We patch the pragma statements in the dependency files to allow compatibility with Solidity 0.8.19 while maintaining backward compatibility with 0.7.6:

```bash
make patch-deps
```

`setup.sh`, local builds through `make build` / `make check`, and CI all use this target. The patch mutates vendored submodules under `lib/`; those submodule dirties are expected locally after setup and must not be staged in BitChill PRs.

### Affected Files
The following files had their pragma statements modified from `=0.7.6` to `>=0.7.6 <0.9.0`:

- All Solidity files in:
  - lib/v3-core/
  - lib/v3-periphery/
  - lib/swap-router-contracts/

### Justification
1. This is a known limitation in Foundry: unlike Hardhat, Foundry struggles with compiling projects that mix dependencies requiring different Solidity versions, particularly when using strict version requirements.
2. While Foundry does have compiler override options, they don't work effectively for complex dependency graphs with strict version requirements like those in the Uniswap contracts.
3. The changes are limited to pragma statements only and do not alter any functional code.
4. The interfaces and contracts remain functionally identical.
5. This approach is more maintainable than forking and maintaining custom versions of these dependencies.

### Verification
We have thoroughly tested the modified dependencies to ensure they function correctly with our contracts. All tests pass with the modified pragma statements.
