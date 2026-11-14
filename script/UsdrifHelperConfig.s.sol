// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {MockStablecoin} from "../test/mocks/MockStablecoin.sol";
import {MockWrbtcToken} from "../test/mocks/MockWrbtcToken.sol";
import {MockSwapRouter02} from "../test/mocks/MockSwapRouter02.sol";
import {MockMocOracle} from "../test/mocks/MockMocOracle.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "../test/mocks/MockLayerBank.sol";
import "./Constants.sol";

contract UsdrifHelperConfig is Script {
    struct NetworkConfig {
        address usdrifToken;
        address usdt0Token;
        address layerbankUsdrifAToken;
        address layerbankUsdt0AToken;
        address wrbtc;
        address swapRouter;
        address[] swapIntermediateTokens;
        uint24[] swapPoolFeeRates;
        address mocOracle;
        address operationsAdmin;
        address dcaManager;
        uint256 amountOutMinimumPercent;
        uint256 amountOutMinimumSafetyCheck;
    }

    NetworkConfig internal activeNetworkConfig;

    // Event for mock creation tracking in tests
    event HelperConfig__CreatedMockToken(string tokenName, address tokenAddress);

    constructor() {
        if (block.chainid == RSK_MAINNET_CHAIN_ID) {
            activeNetworkConfig = getRootstockMainnetConfig();
        } else if (block.chainid == RSK_TESTNET_CHAIN_ID) {
            activeNetworkConfig = getRootstockTestnetConfig();
        } else {
            // For Anvil, we'll use a separate function that can take in parameters
            activeNetworkConfig = getOrCreateAnvilConfig(address(0), address(0));
        }
    }

    function getRootstockMainnetConfig() public pure returns (NetworkConfig memory config) {
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = USDT0_MAINNET; // USDRIF -0.05%-> USDT0 -0.30%-> WRBTC

        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 500;
        poolFeeRates[1] = 3000;

        config = NetworkConfig({
            usdrifToken: 0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37, // USDRIF on mainnet
            usdt0Token: USDT0_MAINNET,
            layerbankUsdrifAToken: LAYERBANK_USDRIF_ATOKEN,
            layerbankUsdt0AToken: LAYERBANK_USDT0_ATOKEN,
            wrbtc: 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d, // WRBTC on mainnet
            swapRouter: 0x0B14ff67f0014046b4b99057Aec4509640b3947A, // SwapRouter02 on mainnet
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: 0xe2927A0620b82A66D67F678FC9b826B0E01B1bFD, // MoC Oracle on mainnet
            operationsAdmin: 0x07623b4bfA188687B683CbF242C12A7d4bD7D355, // OperationsAdmin
            dcaManager: 0x6287F0Ef7dcb288603B484d666785c59f7F6aa70, // DcaManager
            amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK
        });
    }

    function getRootstockTestnetConfig() public pure returns (NetworkConfig memory config) {
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = 0x4d5A316d23EBe168D8f887b4447BF8DBfA4901cc; // rUSDT on testnet

        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 500;
        poolFeeRates[1] = 500;

        config = NetworkConfig({
            usdrifToken: 0x0000000000000000000000000000000000000000, // Replace with USDRIF on testnet
            usdt0Token: 0x5a2256DD0DfbC8cE121d923AC7D6E7A3fc7F9922, // USDT0 on testnet
            layerbankUsdrifAToken: address(0), // LayerBank USDRIF is mainnet-only
            layerbankUsdt0AToken: address(0), // LayerBank USDT0 is mainnet-only
            wrbtc: 0x69FE5cEC81D5eF92600c1A0dB1F11986AB3758Ab, // WRBTC on testnet
            swapRouter: 0x0000000000000000000000000000000000000000, // Replace if exists on testnet
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: 0x0000000000000000000000000000000000000000, // Replace with MoC Oracle on testnet
            operationsAdmin: 0x0000000000000000000000000000000000000000, // Placeholder for OperationsAdmin
            dcaManager: 0x0000000000000000000000000000000000000000, // Placeholder for DcaManager
            amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK
        });
    }

    function getOrCreateAnvilConfig(address operationsAdmin, address dcaManager)
        public
        returns (NetworkConfig memory config)
    {
        // Check if we already have a configuration
        if (activeNetworkConfig.wrbtc != address(0)) {
            // Update with provided addresses if not zero
            if (operationsAdmin != address(0)) {
                activeNetworkConfig.operationsAdmin = operationsAdmin;
            }
            if (dcaManager != address(0)) {
                activeNetworkConfig.dcaManager = dcaManager;
            }
            return activeNetworkConfig;
        }

        // Deploy mocks
        bool isBroadcasting;
        try vm.getNonce(msg.sender) returns (uint64) {
            isBroadcasting = true;
        } catch {
            isBroadcasting = false;
        }

        if (!isBroadcasting) {
            vm.startBroadcast();
        }

        // Deploy mock tokens
        MockStablecoin mockUsdrifToken = new MockStablecoin(msg.sender);
        emit HelperConfig__CreatedMockToken("USDRIF", address(mockUsdrifToken));

        MockLayerBankAToken mockAToken = new MockLayerBankAToken(address(mockUsdrifToken));
        MockLayerBankPool mockPool = new MockLayerBankPool(mockAToken);
        mockAToken.setPool(address(mockPool));
        emit HelperConfig__CreatedMockToken("lRooUSDRIF", address(mockAToken));

        MockWrbtcToken mockWrbtcToken = new MockWrbtcToken();
        emit HelperConfig__CreatedMockToken("WRBTC", address(mockWrbtcToken));

        MockSwapRouter02 mockSwapRouter = new MockSwapRouter02(mockWrbtcToken, BTC_PRICE);
        emit HelperConfig__CreatedMockToken("SwapRouter", address(mockSwapRouter));

        MockMocOracle mockMocOracle = new MockMocOracle();
        emit HelperConfig__CreatedMockToken("MocOracle", address(mockMocOracle));

        // The USDRIF route hops through this token, and the purchase reads its balance on the router to
        // prove no hop stopped short, so it has to be a real ERC20: `balanceOf` on a codeless address reverts.
        MockStablecoin mockIntermediateToken = new MockStablecoin(msg.sender);
        emit HelperConfig__CreatedMockToken("rUSDT", address(mockIntermediateToken));

        if (!isBroadcasting) {
            vm.stopBroadcast();
        }

        // Configure the rest
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = address(mockIntermediateToken);

        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 500;
        poolFeeRates[1] = 500;

        config = NetworkConfig({
            usdrifToken: address(mockUsdrifToken),
            usdt0Token: address(mockUsdrifToken), // Anvil reuses the 18-decimal mock; 6-decimal coverage is a dedicated test
            layerbankUsdrifAToken: address(mockAToken),
            layerbankUsdt0AToken: address(mockAToken),
            wrbtc: address(mockWrbtcToken),
            swapRouter: address(mockSwapRouter),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: address(mockMocOracle),
            operationsAdmin: operationsAdmin,
            dcaManager: dcaManager,
            amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK
        });

        // Save the config
        activeNetworkConfig = config;
    }

    function updateProtocolAddresses(address operationsAdmin, address dcaManager) external {
        activeNetworkConfig.operationsAdmin = operationsAdmin;
        activeNetworkConfig.dcaManager = dcaManager;
    }

    function getNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }

    function isUsdt0() public view returns (bool) {
        string memory coinType;
        try vm.envString("STABLECOIN_TYPE") returns (string memory envType) {
            coinType = envType;
        } catch {
            coinType = USDRIF_STRING;
        }
        return keccak256(abi.encodePacked(coinType)) == keccak256(abi.encodePacked(USDT0_STRING));
    }

    function getToken() public view returns (address) {
        return isUsdt0() ? activeNetworkConfig.usdt0Token : activeNetworkConfig.usdrifToken;
    }

    function getAToken() public view returns (address) {
        return isUsdt0() ? activeNetworkConfig.layerbankUsdt0AToken : activeNetworkConfig.layerbankUsdrifAToken;
    }
}
