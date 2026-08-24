# Variables
SWAP_TYPE ?= mocSwaps
LENDING_PROTOCOL ?= tropykus
STABLECOIN_TYPE ?= DOC
# Forge clap allows only one --no-match-path. Local/CI skip mainnet-debug; forks also skip ai-generated
# (mocks + vm.prank with raw addresses → RPC 429 and revert-depth failures).
TEST_CMD := forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods --no-match-path "test/mainnet-debug/**" -j 1
FORK_TEST_CMD := forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods --no-match-path "test/{mainnet-debug,ai-generated}/**" -j 1
# Rootstock mainnet 2026-04-05, comfortably before Tropykus paused kDOC mint. Measured by bisecting
# mint on a fork: block 8739512 (2026-04-16 16:20 UTC) still mints, 8740674 (2026-04-17 00:13 UTC)
# reverts with kToken error "C2". Do not raise this past 8739512.
FORK_BLOCK_TROPYKUS ?= 8700000
# Live SIP-0094 probe (`make probe-sovryn-exit-fee`). Override with PROBE_VERBOSITY=-vvvv
# or PROBE_MATCH=test_controllerFlagAndVault.
PROBE_VERBOSITY ?= -vv
PROBE_MATCH ?=

# Targets
.PHONY: all test moc dex help check ci build patch-deps slither moc-tropykus moc-sovryn dex-tropykus dex-sovryn fork fork-tropykus fork-sovryn probe-sovryn-exit-fee coverage

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
	$(MAKE) moc-tropykus
	$(MAKE) moc-sovryn
	STABLECOIN_TYPE=USDRIF $(MAKE) dex-sovryn

ci:
	FOUNDRY_PROFILE=ci $(MAKE) build
	FOUNDRY_PROFILE=ci $(MAKE) moc-sovryn
	FOUNDRY_PROFILE=ci STABLECOIN_TYPE=USDRIF $(MAKE) dex-sovryn

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
fork-sovryn:
	@echo "Executing Sovryn fork tests with SWAP_TYPE=$(SWAP_TYPE) $(STABLECOIN_TYPE)..."
	@set -a; [ -f .env ] && . ./.env; set +a; \
	if [ -z "$$RSK_MAINNET_RPC_URL" ]; then \
		echo "error: RSK_MAINNET_RPC_URL is not set. Add it to .env or export it."; \
		exit 1; \
	fi; \
	SWAP_TYPE=$(SWAP_TYPE) LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=$(STABLECOIN_TYPE) \
	$(FORK_TEST_CMD) --fork-url $$RSK_MAINNET_RPC_URL

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

# DexSwaps specific tests (DcaDappTest requires SWAP_TYPE and LENDING_PROTOCOL)
dex:
	@echo "Executing DexSwaps tests with $(LENDING_PROTOCOL) and $(STABLECOIN_TYPE)..."
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=$(LENDING_PROTOCOL) EXPECTED_LENDING_PROTOCOL=$(LENDING_PROTOCOL) STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
dex-tropykus:
	@echo "Executing DexSwaps Tropykus tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
dex-sovryn:
	@echo "Executing DexSwaps Sovryn tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=dexSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)

coverage:
	@echo "Calculating coverage excluding invariant tests..."
	forge coverage --no-match-test invariant

# Help target
help:
	@echo "Available targets:"
	@echo "  make check                     # Build + moc-tropykus + required CI lanes"
	@echo "  make ci                        # Build + required CI lanes"
	@echo "  make patch-deps                # Apply vendored Uniswap pragma compatibility patch"
	@echo "  make slither                   # Run slither (must be installed)"
	@echo "  make test SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC"
	@echo ""
	@echo "  make moc                       # MocSwaps local tests (LENDING_PROTOCOL from env, default tropykus)"
	@echo "  make moc-tropykus              # MocSwaps + Tropykus"
	@echo "  make moc-sovryn                # MocSwaps + Sovryn"
	@echo "  make dex                       # DexSwaps local tests (LENDING_PROTOCOL from env, default tropykus)"
	@echo "  make dex-tropykus              # DexSwaps + Tropykus"
	@echo "  make dex-sovryn                # DexSwaps + Sovryn"
	@echo ""
	@echo "  make fork                      # Fork tests (reads RSK_MAINNET_RPC_URL from env/.env); tropykus pins block $(FORK_BLOCK_TROPYKUS)"
	@echo "  make fork-tropykus             # Tropykus fork tests (pinned: kDOC mint paused 2026-04-27)"
	@echo "  make fork-sovryn               # Sovryn fork tests (chain tip)"
	@echo "  make probe-sovryn-exit-fee     # Live iSUSD burn: is SIP-0094's 0.1% fee charging?"
	@echo ""
	@echo "Environment variables:"
	@echo "  SWAP_TYPE: mocSwaps (default) or dexSwaps"
	@echo "  LENDING_PROTOCOL: tropykus (default) or sovryn"
	@echo "  STABLECOIN_TYPE: DOC (default) or USDRIF"
	@echo ""
	@echo "Example:"
	@echo "  STABLECOIN_TYPE=USDRIF make dex-tropykus"
	@echo ""
	@echo "  make help                      # Show this help message"
