# Variables
SWAP_TYPE ?= mocSwaps
LENDING_PROTOCOL ?= tropykus
STABLECOIN_TYPE ?= DOC
# Forge clap allows only one --no-match-path. Local/CI skip mainnet-debug; forks also skip ai-generated
# (mocks + vm.prank with raw addresses → RPC 429 and revert-depth failures).
# Invariants are a dedicated `make invariants*` lane (64×512 calls) — do not fold them into every unit run.
# ComparePurchaseMethods is Anvil-noop / mainnet-only and is not a CI gate.
TEST_CMD := forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods --no-match-path "test/mainnet-debug/**" -j 1
FORK_TEST_CMD := forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods --no-match-path "test/{mainnet-debug,ai-generated}/**" -j 1
# Rootstock mainnet 2026-04-05, comfortably before Tropykus paused kDOC mint. Measured by bisecting
# mint on a fork: block 8739512 (2026-04-16 16:20 UTC) still mints, 8740674 (2026-04-17 00:13 UTC)
# reverts with kToken error "C2". Do not raise this past 8739512.
FORK_BLOCK_TROPYKUS ?= 8700000
# Rootstock mainnet 2026-08-31 10:39:35 UTC. Pins the R51 Dex quote-vs-floor table
# (`make probe-dex-quote-floor`) so its rows reproduce. Bump only when re-observing.
FORK_BLOCK_DEX_QUOTE ?= 9198813
# Live SIP-0094 probe (`make probe-sovryn-exit-fee`). Override with PROBE_VERBOSITY=-vvvv
# or PROBE_MATCH=test_controllerFlagAndVault.
PROBE_VERBOSITY ?= -vv
PROBE_MATCH ?=

# Targets
.PHONY: all test moc dex help check ci check-deploy build build-deploy patch-deps slither moc-none moc-layerbank moc-tropykus moc-sovryn dex-none dex-tropykus dex-sovryn dex-layerbank invariants invariants-sovryn fork fork-none fork-tropykus fork-sovryn fork-layerbank fork-dex-path probe-sovryn-exit-fee probe-dex-quote-floor coverage

all: help

# Default test target
test:
	@echo "Running tests for SWAP_TYPE=$(SWAP_TYPE), LENDING_PROTOCOL=$(LENDING_PROTOCOL), STABLECOIN_TYPE=$(STABLECOIN_TYPE)"
	@if [ "$(SWAP_TYPE)" = "mocSwaps" ]; then \
		make moc; \
	elif [ "$(SWAP_TYPE)" = "dexSwaps" ]; then \
		make dex; \
	else \
		echo "Invalid SWAP_TYPE: $(SWAP_TYPE)"; \
		exit 1; \
	fi

# Local "am I done" gate. Mirrors required CI lanes and includes the local Tropykus mock lane.
# Does not run forge fmt --check (src is not fmt-clean). Run `make slither` explicitly when needed.
check: build
	$(MAKE) moc-none
	$(MAKE) moc-layerbank
	$(MAKE) moc-sovryn
	STABLECOIN_TYPE=USDRIF $(MAKE) dex-none
	STABLECOIN_TYPE=USDT0 $(MAKE) dex-none
	STABLECOIN_TYPE=USDRIF $(MAKE) dex-sovryn
	STABLECOIN_TYPE=USDRIF $(MAKE) dex-layerbank
	STABLECOIN_TYPE=USDT0 $(MAKE) dex-layerbank
	$(MAKE) invariants-sovryn

ci:
	FOUNDRY_PROFILE=ci $(MAKE) build
	FOUNDRY_PROFILE=ci $(MAKE) moc-none
	FOUNDRY_PROFILE=ci $(MAKE) moc-layerbank
	FOUNDRY_PROFILE=ci $(MAKE) moc-sovryn
	FOUNDRY_PROFILE=ci STABLECOIN_TYPE=USDRIF $(MAKE) dex-none
	FOUNDRY_PROFILE=ci STABLECOIN_TYPE=USDT0 $(MAKE) dex-none
	FOUNDRY_PROFILE=ci STABLECOIN_TYPE=USDRIF $(MAKE) dex-sovryn
	FOUNDRY_PROFILE=ci STABLECOIN_TYPE=USDRIF $(MAKE) dex-layerbank
	FOUNDRY_PROFILE=ci STABLECOIN_TYPE=USDT0 $(MAKE) dex-layerbank
	FOUNDRY_PROFILE=ci $(MAKE) invariants-sovryn

# R60: what actually gets deployed. [profile.deploy] compiles src/, test/ and script/ under via_ir
# (foundry.toml), so every lane here runs the full suite against the same optimized IR bytecode
# `forge script` would broadcast — a test's `new DcaManager(...)` deploys the identical artifact.
# Not part of `check` or `ci`: via-IR compiles slowly, so this only runs before an actual deploy.
# Never deploy without this passing green on the commit being deployed.
check-deploy: build-deploy
	FOUNDRY_PROFILE=deploy $(MAKE) moc-none
	FOUNDRY_PROFILE=deploy $(MAKE) moc-layerbank
	FOUNDRY_PROFILE=deploy $(MAKE) moc-sovryn
	FOUNDRY_PROFILE=deploy STABLECOIN_TYPE=USDRIF $(MAKE) dex-none
	FOUNDRY_PROFILE=deploy STABLECOIN_TYPE=USDT0 $(MAKE) dex-none
	FOUNDRY_PROFILE=deploy STABLECOIN_TYPE=USDRIF $(MAKE) dex-sovryn
	FOUNDRY_PROFILE=deploy STABLECOIN_TYPE=USDRIF $(MAKE) dex-layerbank
	FOUNDRY_PROFILE=deploy STABLECOIN_TYPE=USDT0 $(MAKE) dex-layerbank
	FOUNDRY_PROFILE=deploy $(MAKE) invariants-sovryn

build-deploy: patch-deps
	FOUNDRY_PROFILE=deploy forge --version
	FOUNDRY_PROFILE=deploy forge build

build: patch-deps
	forge --version
	forge build

patch-deps:
	@echo "Applying Solidity pragma compatibility patch to vendored Uniswap dependencies..."
	@if [ "$$(uname)" = "Darwin" ]; then \
		find lib/ -type f -name "*.sol" -exec sed -i '' 's/pragma solidity =0.7.6;/pragma solidity >=0.7.6 <0.9.0;/g' {} \; ; \
	else \
		find lib/ -type f -name "*.sol" -exec sed -i 's/pragma solidity =0.7.6;/pragma solidity >=0.7.6 <0.9.0;/g' {} \; ; \
	fi

slither:
	@command -v slither >/dev/null 2>&1 || { echo "slither is not installed. pipx install slither-analyzer"; exit 1; }
	slither . --config-file slither.config.json

# MocSwaps specific tests
# EXPECTED_LENDING_PROTOCOL is a canary: tests assert LENDING_PROTOCOL was not overwritten by vm.setEnv.
moc:
	@echo "Executing MocSwaps tests with $(LENDING_PROTOCOL) and $(STABLECOIN_TYPE)..."
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=$(LENDING_PROTOCOL) EXPECTED_LENDING_PROTOCOL=$(LENDING_PROTOCOL) STABLECOIN_TYPE=DOC $(TEST_CMD)
moc-none:
	@echo "Executing MocSwaps idle (none) tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none EXPECTED_LENDING_PROTOCOL=none STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
moc-layerbank:
	@echo "Executing MocSwaps LayerBank tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
moc-tropykus:
	@echo "Executing MocSwaps Tropykus tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
moc-sovryn:
	@echo "Executing MocSwaps Sovryn tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)

# Forge reads SWAP_TYPE via vm.envString (no fallback). Make's ?= default is not
# exported, so fork recipes must pass it. --fork-url is expanded by Make/shell
# before Forge loads .env, so source .env here and fail if the RPC is missing.
fork:
	@if [ "$(LENDING_PROTOCOL)" = "sovryn" ]; then \
		$(MAKE) fork-sovryn; \
	elif [ "$(LENDING_PROTOCOL)" = "layerbank" ]; then \
		$(MAKE) fork-layerbank; \
	elif [ "$(LENDING_PROTOCOL)" = "none" ]; then \
		$(MAKE) fork-none; \
	else \
		$(MAKE) fork-tropykus; \
	fi
fork-tropykus:
	@echo "Executing Tropykus fork tests with SWAP_TYPE=$(SWAP_TYPE) $(STABLECOIN_TYPE) at block $(FORK_BLOCK_TROPYKUS)..."
	@set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$$RSK_MAINNET_RPC_URL" ]; then \
		echo "error: RSK_MAINNET_RPC_URL is not set. Add it to .env or export it."; \
		exit 1; \
	fi; \
	SWAP_TYPE=$(SWAP_TYPE) LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=$(STABLECOIN_TYPE) \
	$(FORK_TEST_CMD) --fork-url $$RSK_MAINNET_RPC_URL --fork-block-number $(FORK_BLOCK_TROPYKUS)
fork-none:
	@echo "Executing idle (none) fork tests with SWAP_TYPE=$(SWAP_TYPE) $(STABLECOIN_TYPE)..."
	@set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$$RSK_MAINNET_RPC_URL" ]; then \
		echo "error: RSK_MAINNET_RPC_URL is not set. Add it to .env or export it."; \
		exit 1; \
	fi; \
	SWAP_TYPE=$(SWAP_TYPE) LENDING_PROTOCOL=none EXPECTED_LENDING_PROTOCOL=none STABLECOIN_TYPE=$(STABLECOIN_TYPE) \
	$(FORK_TEST_CMD) --fork-url $$RSK_MAINNET_RPC_URL
fork-sovryn:
	@echo "Executing Sovryn fork tests with SWAP_TYPE=$(SWAP_TYPE) $(STABLECOIN_TYPE)..."
	@set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$$RSK_MAINNET_RPC_URL" ]; then \
		echo "error: RSK_MAINNET_RPC_URL is not set. Add it to .env or export it."; \
		exit 1; \
	fi; \
	SWAP_TYPE=$(SWAP_TYPE) LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=$(STABLECOIN_TYPE) \
	$(FORK_TEST_CMD) --fork-url $$RSK_MAINNET_RPC_URL
fork-layerbank:
	@echo "Executing LayerBank fork tests with SWAP_TYPE=$(SWAP_TYPE) $(STABLECOIN_TYPE)..."
	@set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$$RSK_MAINNET_RPC_URL" ]; then \
		echo "error: RSK_MAINNET_RPC_URL is not set. Add it to .env or export it."; \
		exit 1; \
	fi; \
	SWAP_TYPE=$(SWAP_TYPE) LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=$(STABLECOIN_TYPE) \
	$(FORK_TEST_CMD) --fork-url $$RSK_MAINNET_RPC_URL
# Dex path allowlist (R52). Full `fork-layerbank` / `fork-none` + dexSwaps still run purchase
# tests against live Uniswap pools; those can revert `Too little received` and are not this gate.
# Idle+DEX (R62) shares PurchaseUniswap, so the allowlist suite runs on both funding bases.
fork-dex-path:
	@echo "Executing Dex path allowlist fork tests (USDRIF / LayerBank + idle / dexSwaps)..."
	@set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$$RSK_MAINNET_RPC_URL" ]; then \
		echo "error: RSK_MAINNET_RPC_URL is not set. Add it to .env or export it."; \
		exit 1; \
	fi; \
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=USDRIF \
	$(FORK_TEST_CMD) --match-contract DexPathFailoverTest --fork-url $$RSK_MAINNET_RPC_URL && \
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=none EXPECTED_LENDING_PROTOCOL=none STABLECOIN_TYPE=USDRIF \
	$(FORK_TEST_CMD) --match-contract DexPathFailoverTest --fork-url $$RSK_MAINNET_RPC_URL

# Live iSUSD burn probe for SIP-0094 (excluded from check/fork/CI). See
# test/mainnet-debug/sovryn-exit-fee/README.md. PROBE_VERBOSITY=-vvvv for the burn trace.
probe-sovryn-exit-fee:
	@echo "Probing live Sovryn iSUSD burn for SIP-0094 exit fee..."
	@set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$$RSK_MAINNET_RPC_URL" ]; then \
		echo "error: RSK_MAINNET_RPC_URL is not set. Add it to .env or export it."; \
		exit 1; \
	fi; \
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
	forge test --match-path "test/mainnet-debug/sovryn-exit-fee/**" \
		$(if $(PROBE_MATCH),--match-test $(PROBE_MATCH),) \
		--fork-url $$RSK_MAINNET_RPC_URL $(PROBE_VERBOSITY) -j 1

# R51 Dex quote-vs-floor table (excluded from check/fork/CI). Prices every shipped path against the live
# pools at FORK_BLOCK_DEX_QUOTE and compares each row with the oracle-derived governance floor.
probe-dex-quote-floor:
	@echo "Probing live Dex pool quotes against the oracle floor at block $(FORK_BLOCK_DEX_QUOTE)..."
	@set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$$RSK_MAINNET_RPC_URL" ]; then \
		echo "error: RSK_MAINNET_RPC_URL is not set. Add it to .env or export it."; \
		exit 1; \
	fi; \
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
	forge test --match-path "test/mainnet-debug/dex-quote-floor/**" \
		--fork-url $$RSK_MAINNET_RPC_URL --fork-block-number $(FORK_BLOCK_DEX_QUOTE) $(PROBE_VERBOSITY) -j 1

# DexSwaps specific tests (DcaDappTest requires SWAP_TYPE and LENDING_PROTOCOL)
dex:
	@echo "Executing DexSwaps tests with $(LENDING_PROTOCOL) and $(STABLECOIN_TYPE)..."
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=$(LENDING_PROTOCOL) EXPECTED_LENDING_PROTOCOL=$(LENDING_PROTOCOL) STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
dex-none:
	@echo "Executing DexSwaps tests with idle (none) and $(STABLECOIN_TYPE)..."
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=none EXPECTED_LENDING_PROTOCOL=none STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
dex-tropykus:
	@echo "Executing DexSwaps Tropykus tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
dex-sovryn:
	@echo "Executing DexSwaps Sovryn tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
dex-layerbank:
	@echo "Executing DexSwaps LayerBank tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)

# Stateful invariant suite (test/ai-generated/fuzz). Not part of TEST_CMD: 64 runs × 512
# depth is ~32k calls and would multiply every unit lane. ComparePurchaseMethods stays excluded.
invariants:
	@echo "Executing invariant tests with LENDING_PROTOCOL=$(LENDING_PROTOCOL)..."
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=$(LENDING_PROTOCOL) EXPECTED_LENDING_PROTOCOL=$(LENDING_PROTOCOL) STABLECOIN_TYPE=$(STABLECOIN_TYPE) forge test --match-contract InvariantTest -j 1
invariants-sovryn:
	$(MAKE) invariants LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn

coverage:
	@echo "Calculating coverage excluding invariant tests..."
	forge coverage --no-match-test invariant

# Help target
help:
	@echo "Available targets:"
	@echo "  make check                     # Build + moc-* + dex-none/sovryn/layerbank + invariants-sovryn"
	@echo "  make ci                        # Build + required CI lanes (dex-none and dex-layerbank each on USDRIF and USDT0)"
	@echo "  make check-deploy              # Same lanes as check, compiled via_ir=true (R60) — slow; run before deploying"
	@echo "  make patch-deps                # Apply vendored Uniswap pragma compatibility patch"
	@echo "  make slither                   # Run slither (must be installed)"
	@echo "  make test SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC"
	@echo ""
	@echo "  make moc                       # MocSwaps local tests (LENDING_PROTOCOL from env, default tropykus)"
	@echo "  make moc-none                  # MocSwaps + idle handler (index 0)"
	@echo "  make moc-layerbank             # MocSwaps + LayerBank (index 1)"
	@echo "  make moc-tropykus              # MocSwaps + Tropykus (legacy mocks; not in the production map)"
	@echo "  make moc-sovryn                # MocSwaps + Sovryn (index 2)"
	@echo "  make dex                       # DexSwaps local tests (LENDING_PROTOCOL from env, default tropykus)"
	@echo "  make dex-none                  # DexSwaps + idle handler (index 0; USDRIF or USDT0)"
	@echo "  make dex-tropykus              # DexSwaps + Tropykus"
	@echo "  make dex-sovryn                # DexSwaps + Sovryn"
	@echo "  make dex-layerbank             # DexSwaps + LayerBank (USDRIF or USDT0)"
	@echo "  make invariants                # Stateful InvariantTest (LENDING_PROTOCOL from env, default tropykus)"
	@echo "  make invariants-sovryn         # InvariantTest + Sovryn (CI lane)"
	@echo ""
	@echo "  make fork                      # Fork tests (reads RSK_MAINNET_RPC_URL from env/.env); tropykus pins block $(FORK_BLOCK_TROPYKUS)"
	@echo "  make fork-none                 # Idle (none) fork tests (chain tip; use SWAP_TYPE=dexSwaps STABLECOIN_TYPE=USDRIF for idle+DEX)"
	@echo "  make fork-tropykus             # Tropykus fork tests (pinned: kDOC mint paused 2026-04-27)"
	@echo "  make fork-sovryn               # Sovryn fork tests (chain tip)"
	@echo "  make fork-layerbank            # LayerBank fork tests (chain tip; default mocSwaps)"
	@echo "  make fork-dex-path             # R52 Dex path allowlist on LayerBank and idle USDRIF Uniswap forks"
	@echo "  make probe-sovryn-exit-fee     # Live iSUSD burn: is SIP-0094's 0.1% fee charging?"
	@echo "  make probe-dex-quote-floor     # R51: live Dex pool quotes vs the oracle floor, at a pinned block"
	@echo ""
	@echo "Environment variables:"
	@echo "  SWAP_TYPE: mocSwaps (default) or dexSwaps"
	@echo "  LENDING_PROTOCOL: tropykus (default, legacy), none, layerbank, or sovryn"
	@echo "  STABLECOIN_TYPE: DOC (default), USDRIF, or USDT0"
	@echo ""
	@echo "Example:"
	@echo "  STABLECOIN_TYPE=USDRIF make dex-tropykus"
	@echo ""
	@echo "  make help                      # Show this help message"
