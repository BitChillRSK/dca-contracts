# Variables
SWAP_TYPE ?= mocSwaps
LENDING_PROTOCOL ?= tropykus
STABLECOIN_TYPE ?= DOC
TEST_CMD := forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods -j 1
# Exclude ai-generated tests on fork: they use mocks and vm.prank with raw addresses, causing RPC 429 and revert-depth failures
FORK_TEST_CMD := $(TEST_CMD) --no-match-path "test/ai-generated/**"

# Targets
.PHONY: all test moc dex help

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

# MocSwaps specific tests
moc:
	@echo "Executing MocSwaps tests with $(LENDING_PROTOCOL) and $(STABLECOIN_TYPE)..."
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=$(LENDING_PROTOCOL) STABLECOIN_TYPE=DOC $(TEST_CMD)
moc-tropykus:
	@echo "Executing MocSwaps Tropykus tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)
moc-sovryn:
	@echo "Executing MocSwaps Sovryn tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)

fork:
	@echo "Executing fork tests with $(LENDING_PROTOCOL) and $(STABLECOIN_TYPE)..."
	STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(FORK_TEST_CMD) --fork-url $(RSK_MAINNET_RPC_URL)
fork-tropykus:
	@echo "Executing Tropykus fork tests with $(STABLECOIN_TYPE)..."
	LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(FORK_TEST_CMD) --fork-url $(RSK_MAINNET_RPC_URL)
fork-sovryn:
	@echo "Executing Sovryn fork tests with $(STABLECOIN_TYPE)..."
	LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(FORK_TEST_CMD) --fork-url $(RSK_MAINNET_RPC_URL)

# DexSwaps specific tests
dex:
	@echo "Executing DexSwaps tests with $(STABLECOIN_TYPE)..."
	SWAP_TYPE=dexSwaps STABLECOIN_TYPE=$(STABLECOIN_TYPE) $(TEST_CMD)

coverage:
	@echo "Calculating coverage excluding invariant tests..."
	forge coverage --no-match-test invariant

# Help target
help:
	@echo "Available targets:"
	@echo "  make test SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC  # Run tests with specified parameters"
	@echo ""
	@echo "  make moc                       # Directly run MocSwaps local tests"
	@echo "  make moc-tropykus              # Run MocSwaps Tropykus local tests"
	@echo "  make moc-sovryn                # Run MocSwaps Sovryn local tests"
	@echo "  make dex                       # Directly run DexSwaps local tests"
	@echo ""
	@echo "  make fork                      # Run fork tests"
	@echo "  make fork-tropykus             # Run Tropykus fork tests"
	@echo "  make fork-sovryn               # Run Sovryn fork tests"
	@echo ""
	@echo "Environment variables:"
	@echo "  SWAP_TYPE: mocSwaps (default) or dexSwaps"
	@echo "  LENDING_PROTOCOL: tropykus (default) or sovryn"
	@echo "  STABLECOIN_TYPE: DOC (default) or USDRIF"
	@echo ""
	@echo "Example:"
	@echo "  STABLECOIN_TYPE=USDRIF make moc-tropykus  # Run MocSwaps Tropykus tests with USDRIF"
	@echo ""
	@echo "  make help                      # Show this help message"
