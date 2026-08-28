// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockStablecoin} from "../test/mocks/MockStablecoin.sol";
import {MockKToken} from "../test/mocks/MockKToken.sol";
import {MockIsusdToken} from "../test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "../test/mocks/MockMocProxy.sol";
import {MockWrbtcToken} from "../test/mocks/MockWrbtcToken.sol";
import {MockSwapRouter02} from "../test/mocks/MockSwapRouter02.sol";
import {MockMocOracle} from "../test/mocks/MockMocOracle.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "../test/mocks/MockLayerBank.sol";
import "./Constants.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";

contract DexHelperConfig is Script {
    string lendingProtocol = vm.envString("LENDING_PROTOCOL");
    string stablecoinType;
    bool lendingProtocolIsTropykus =
        keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING));
    bool lendingProtocolIsSovryn = keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING));
    bool lendingProtocolIsLayerbank =
        keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(LAYERBANK_STRING));

    struct NetworkConfig {
        // Stablecoin address
        address stablecoinAddress;
        
        // Share token addresses by protocol
        address tropykusShareToken;  // The share token for Tropykus (e.g., kDOC, kUSDRIF)
        address sovrynShareToken;    // The share token for Sovryn (e.g., iSUSD)
        address layerbankAToken;     // LayerBank aToken; handler reads Pool from aToken.POOL()
        
        // Swap-related addresses
        address wrbtcTokenAddress;
        address swapRouter02Address; // @notice NOT DEPLOYED ON RSK TESTNET!!
        address[] swapIntermediateTokens;
        uint24[] swapPoolFeeRates;
        address mocOracleAddress;
        address mocProxyAddress; // @notice: needed only for fork testing, where we need to call MoC::mintDoc()
        // Swap settings
        uint256 amountOutMinimumPercent;
        uint256 amountOutMinimumSafetyCheck;
    }

    NetworkConfig internal activeNetworkConfig;

    event HelperConfig__CreatedMockStablecoin(address stablecoinAddress, string symbol);
    event HelperConfig__CreatedMockShareToken(address shareTokenAddress, string protocol);
    event HelperConfig__CreatedMockWrbtc(address wrbtcTokenAddress);
    event HelperConfig__CreatedMockSwapRouter02(address swapRouter02Address);
    event HelperConfig__CreatedMockMocOracle(address mocOracleAddress);
    event HelperConfig__CreatedMockMocProxy(address mocProxyAddress);

    constructor() {
        // Initialize stablecoin type from environment or use default
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            stablecoinType = coinType;
        } catch {
            stablecoinType = DEFAULT_STABLECOIN;
        }
        
        if (block.chainid == RSK_MAINNET_CHAIN_ID) {
            activeNetworkConfig = getRootstockMainnetConfig();
        } else if (block.chainid == RSK_TESTNET_CHAIN_ID) {
            activeNetworkConfig = getRootstockTestnetConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getRootstockTestnetConfig() public view returns (NetworkConfig memory RootstockTestnetNetworkConfig) {
        address[] memory intermediateTokens;
        uint24[] memory poolFeeRates;
        address stablecoinAddress;
        address tropykusShareToken;
        address sovrynShareToken;
        address layerbankAToken;
        
        // Configure based on stablecoin type. LayerBank USDRIF/USDT0 is mainnet-only.
        if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDT0_STRING))) {
            intermediateTokens = new address[](0);
            poolFeeRates = new uint24[](1);
            poolFeeRates[0] = 3000;
            stablecoinAddress = 0x5a2256DD0DfbC8cE121d923AC7D6E7A3fc7F9922; // USDT0 on testnet
            tropykusShareToken = address(0);
            sovrynShareToken = address(0);
            layerbankAToken = address(0);
        } else if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDRIF_STRING))) {
            intermediateTokens = new address[](1);
            poolFeeRates = new uint24[](2);
            intermediateTokens[0] = 0x19F64674D8A5B4E652319F5e239eFd3bc969A1fE; // Intermediate token for USDRIF on testnet
            poolFeeRates[0] = 500;
            poolFeeRates[1] = 3000;
            stablecoinAddress = 0x8C3Cc5c26dcd3CC4Fc4c887fFeFC39F22E1d0F09; // USDRIF token on testnet
            tropykusShareToken = 0x11Fd4DDe59b237f801EC12eD2fCb9b13371f1AaF; // kUSDRIF on testnet
            sovrynShareToken = address(0); // Sovryn doesn't support USDRIF
            layerbankAToken = address(0);
        } else {
            intermediateTokens = new address[](1);
            poolFeeRates = new uint24[](2);
            intermediateTokens[0] = 0x4d5A316d23EBe168D8f887b4447BF8DBfA4901cc; // Address of the rUSDT token in Rootstock testnet
            poolFeeRates[0] = 500;
            poolFeeRates[1] = 500;
            stablecoinAddress = 0xCB46c0ddc60D18eFEB0E586C17Af6ea36452Dae0; // DOC token on testnet
            tropykusShareToken = 0x71e6B108d823C2786f8EF63A3E0589576B4F3914; // kDOC proxy on testnet
            sovrynShareToken = 0x74e00A8CeDdC752074aad367785bFae7034ed89f; // iSUSD proxy on testnet
            layerbankAToken = address(0); // LayerBank DOC dex is out of scope
        }

        RootstockTestnetNetworkConfig = NetworkConfig({
            stablecoinAddress: stablecoinAddress,
            tropykusShareToken: tropykusShareToken,
            sovrynShareToken: sovrynShareToken,
            layerbankAToken: layerbankAToken,
            wrbtcTokenAddress: 0x69FE5cEC81D5eF92600c1A0dB1F11986AB3758Ab, // WRBTC token on testnet
            swapRouter02Address: 0x0000000000000000000000000000000000000000, // Uniswap's contracts are not deployed on RSK testnet
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracleAddress: 0x0000000000000000000000000000000000000000,
            mocProxyAddress: 0x2820f6d4D199B8D8838A4B26F9917754B86a0c1F,
            amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK
        });
    }

    function getRootstockMainnetConfig() public view returns (NetworkConfig memory RootstockMainnetNetworkConfig) {
        address[] memory intermediateTokens;
        uint24[] memory poolFeeRates;
        address stablecoinAddress;
        address tropykusShareToken;
        address sovrynShareToken;
        address layerbankAToken;
        
        // Configure based on stablecoin type. USDT0 swaps direct WRBTC at 0.3% (looked up 2026-08-28);
        // the 0.05% USDT0/WRBTC pool exists but is empty. Do not hop through rUSDT as if it were USDT0.
        if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDT0_STRING))) {
            intermediateTokens = new address[](0);
            poolFeeRates = new uint24[](1);
            poolFeeRates[0] = 3000;
            stablecoinAddress = USDT0_MAINNET;
            tropykusShareToken = address(0);
            sovrynShareToken = address(0);
            layerbankAToken = LAYERBANK_USDT0_ATOKEN;
        } else if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDRIF_STRING))) {
            intermediateTokens = new address[](1);
            poolFeeRates = new uint24[](2);
            intermediateTokens[0] = 0xAf368c91793CB22739386DFCbBb2F1A9e4bCBeBf; // rUSDT hop for USDRIF
            poolFeeRates[0] = 500;
            poolFeeRates[1] = 3000;
            stablecoinAddress = 0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37; // USDRIF token on mainnet
            tropykusShareToken = 0xDdf3CE45fcf080DF61ee61dac5Ddefef7ED4F46C; // kUSDRIF on mainnet (paused; kept until R37)
            sovrynShareToken = address(0); // Sovryn doesn't support USDRIF
            layerbankAToken = LAYERBANK_USDRIF_ATOKEN;
        } else {
            intermediateTokens = new address[](1);
            poolFeeRates = new uint24[](2);
            intermediateTokens[0] = 0xef213441A85dF4d7ACbDaE0Cf78004e1E486bB96; // Address of the rUSDT token in Rootstock mainnet
            poolFeeRates[0] = 500;
            poolFeeRates[1] = 500;
            stablecoinAddress = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db; // DOC token on mainnet
            tropykusShareToken = 0x544Eb90e766B405134b3B3F62b6b4C23Fcd5fDa2; // kDOC proxy on mainnet
            sovrynShareToken = 0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1; // iSUSD proxy on mainnet
            layerbankAToken = address(0); // LayerBank DOC dex is out of scope
        }

        RootstockMainnetNetworkConfig = NetworkConfig({
            stablecoinAddress: stablecoinAddress,
            tropykusShareToken: tropykusShareToken,
            sovrynShareToken: sovrynShareToken,
            layerbankAToken: layerbankAToken,
            wrbtcTokenAddress: 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d, // WRBTC token on mainnet
            swapRouter02Address: 0x0B14ff67f0014046b4b99057Aec4509640b3947A, 
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracleAddress: 0xe2927A0620b82A66D67F678FC9b826B0E01B1bFD,
            mocProxyAddress: 0xf773B590aF754D597770937Fa8ea7AbDf2668370,
            amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory anvilNetworkConfig) {
        if (activeNetworkConfig.stablecoinAddress != address(0)) {
            return activeNetworkConfig;
        }

        // Check if we're already in a broadcast context
        bool isBroadcasting;
        try vm.getNonce(msg.sender) returns (uint64) {
            // If this succeeds, we're already in a broadcast context
            isBroadcasting = true;
        } catch {
            // If it fails, we're not in a broadcast context
            isBroadcasting = false;
        }

        // Only start a broadcast if we're not already in one
        if (!isBroadcasting) {
            vm.startBroadcast();
        }

        // Create mock tokens based on the selected stablecoin type
        MockStablecoin mockStablecoin = new MockStablecoin(msg.sender);
        address mockStablecoinAddress = address(mockStablecoin);
        
        address mockShareTokenAddress;
        address mockLayerbankAToken;
        if (lendingProtocolIsTropykus) {
            MockKToken mockShareToken = new MockKToken(mockStablecoinAddress);
            mockShareTokenAddress = address(mockShareToken);
            emit HelperConfig__CreatedMockShareToken(mockShareTokenAddress, TROPYKUS_STRING);
        } else if (lendingProtocolIsSovryn) {
            MockIsusdToken mockShareToken = new MockIsusdToken(mockStablecoinAddress);
            mockShareTokenAddress = address(mockShareToken);
            emit HelperConfig__CreatedMockShareToken(mockShareTokenAddress, SOVRYN_STRING);
        } else if (lendingProtocolIsLayerbank) {
            MockLayerBankAToken aToken = new MockLayerBankAToken(mockStablecoinAddress);
            MockLayerBankPool pool = new MockLayerBankPool(aToken);
            aToken.setPool(address(pool));
            mockLayerbankAToken = address(aToken);
            mockShareTokenAddress = mockLayerbankAToken;
            emit HelperConfig__CreatedMockShareToken(mockLayerbankAToken, LAYERBANK_STRING);
        } else {
            revert("Invalid lending protocol");
        }

        MockWrbtcToken mockWrbtcToken = new MockWrbtcToken();
        MockSwapRouter02 mockSwapRouter02 = new MockSwapRouter02(mockWrbtcToken, BTC_PRICE);
        MockMocOracle mockMocOracle = new MockMocOracle();
        MockMocProxy mockMocProxy = new MockMocProxy(mockStablecoinAddress);
        
        // Only stop the broadcast if we started it
        if (!isBroadcasting) {
            vm.stopBroadcast();
        }

        emit HelperConfig__CreatedMockStablecoin(mockStablecoinAddress, stablecoinType);
        emit HelperConfig__CreatedMockWrbtc(address(mockWrbtcToken));
        emit HelperConfig__CreatedMockSwapRouter02(address(mockSwapRouter02));
        emit HelperConfig__CreatedMockMocOracle(address(mockMocOracle));
        emit HelperConfig__CreatedMockMocProxy(address(mockMocProxy));

        address[] memory intermediateTokens;
        uint24[] memory poolFeeRates;
        
        // Set different pool fees based on stablecoin type, even for mocks. USDT0 is a direct WRBTC hop.
        if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDT0_STRING))) {
            intermediateTokens = new address[](0);
            poolFeeRates = new uint24[](1);
            poolFeeRates[0] = 3000;
        } else if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDRIF_STRING))) {
            intermediateTokens = new address[](1);
            intermediateTokens[0] = makeAddr("rUSDT");
            poolFeeRates = new uint24[](2);
            poolFeeRates[0] = 500;
            poolFeeRates[1] = 3000;
        } else {
            intermediateTokens = new address[](1);
            intermediateTokens[0] = makeAddr("rUSDT");
            poolFeeRates = new uint24[](2);
            poolFeeRates[0] = 500;
            poolFeeRates[1] = 500;
        }

        anvilNetworkConfig = NetworkConfig({
            stablecoinAddress: mockStablecoinAddress,
            tropykusShareToken: lendingProtocolIsTropykus ? mockShareTokenAddress : address(0),
            sovrynShareToken: lendingProtocolIsSovryn ? mockShareTokenAddress : address(0),
            layerbankAToken: lendingProtocolIsLayerbank ? mockLayerbankAToken : address(0),
            wrbtcTokenAddress: address(mockWrbtcToken),
            swapRouter02Address: address(mockSwapRouter02),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracleAddress: address(mockMocOracle),
            mocProxyAddress: address(mockMocProxy),
            amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK
        });
    }

    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }

    function getStablecoinAddress() public view returns (address) {
        return activeNetworkConfig.stablecoinAddress;
    }

    function getShareTokenAddress() public view returns (address) {
        if (lendingProtocolIsTropykus) {
            return activeNetworkConfig.tropykusShareToken;
        } else if (lendingProtocolIsSovryn) {
            bool isUSDRIF = keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDRIF_STRING));
            bool isUSDT0 = keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDT0_STRING));
            if (isUSDRIF || isUSDT0) {
                console.log("Warning: Sovryn does not list this stablecoin");
                return address(0);
            }
            return activeNetworkConfig.sovrynShareToken;
        } else if (lendingProtocolIsLayerbank) {
            return activeNetworkConfig.layerbankAToken;
        }
        revert("Unsupported lending protocol");
    }
}
