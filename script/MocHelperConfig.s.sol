// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockStablecoin} from "../test/mocks/MockStablecoin.sol";
import {MockKdocToken} from "../test/mocks/MockKdocToken.sol";
import {MockIToken} from "../test/mocks/MockIToken.sol";
import {MockMocProxy} from "../test/mocks/MockMocProxy.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "../test/mocks/MockLayerBank.sol";
import "./Constants.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";

contract MocHelperConfig is Script {
    struct NetworkConfig {
        // DOC token address (MoC is only for DOC)
        address docToken;

        // Share token addresses by protocol
        address kDoc; // The share token for Tropykus (kDOC) — legacy tests only
        address iToken; // The share token for Sovryn (iSUSD)
        address layerbankAToken; // LayerBank lRooDOC aToken; handler reads Pool from aToken.POOL()

        // MoC protocol
        address mocProxy;
    }

    string stablecoinType;
    address mockShareToken;
    NetworkConfig public activeNetworkConfig;

    event HelperConfig__CreatedMockStablecoin(address docTokenAddress);
    event HelperConfig__CreatedMockMocProxy(address mocProxyAddress);
    event HelperConfig__CreatedMockShareToken(address shareTokenAddress, string protocol);

    constructor() {
        // Log environment variables
        console.log("MocHelperConfig constructor called");
        console.log("LENDING_PROTOCOL from env:", vm.envString("LENDING_PROTOCOL"));

        // Initialize stablecoin type from environment or use default
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            stablecoinType = coinType;
        } catch {
            stablecoinType = DOC_STRING;
        }

        console.log("Using stablecoin type:", stablecoinType);

        if (block.chainid == RSK_MAINNET_CHAIN_ID) {
            activeNetworkConfig = getRootstockMainnetConfig();
        } else if (block.chainid == RSK_TESTNET_CHAIN_ID) {
            activeNetworkConfig = getRootstockTestnetConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }

        // Log the resulting network configuration
        console.log("Network config created:");
        console.log("  docToken:", activeNetworkConfig.docToken);
        console.log("  kDoc:", activeNetworkConfig.kDoc);
        console.log("  iToken:", activeNetworkConfig.iToken);
        console.log("  layerbankAToken:", activeNetworkConfig.layerbankAToken);
    }

    function getRootstockTestnetConfig() public pure returns (NetworkConfig memory RootstockTestnetNetworkConfig) {
        RootstockTestnetNetworkConfig = NetworkConfig({
            docToken: 0xCB46c0ddc60D18eFEB0E586C17Af6ea36452Dae0, // DOC token on testnet
            kDoc: 0x71e6B108d823C2786f8EF63A3E0589576B4F3914, // kDOC proxy on testnet
            iToken: 0x74e00A8CeDdC752074aad367785bFae7034ed89f, // iSUSD proxy on testnet
            layerbankAToken: address(0), // LayerBank DOC is mainnet-only
            mocProxy: 0x2820f6d4D199B8D8838A4B26F9917754B86a0c1F // MOC proxy on testnet
        });
    }

    function getRootstockMainnetConfig() public pure returns (NetworkConfig memory RootstockMainnetNetworkConfig) {
        RootstockMainnetNetworkConfig = NetworkConfig({
            docToken: 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db, // DOC token on mainnet
            kDoc: 0x544Eb90e766B405134b3B3F62b6b4C23Fcd5fDa2, // kDOC proxy on mainnet
            iToken: 0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1, // iSUSD proxy on mainnet
            layerbankAToken: 0x3F04280C66314b78E9712A41BF8C1A214460cAa2, // lRooDOC aToken
            mocProxy: 0xf773B590aF754D597770937Fa8ea7AbDf2668370 // MOC proxy on mainnet
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory anvilNetworkConfig) {
        console.log("getOrCreateAnvilConfig called");

        if (activeNetworkConfig.docToken != address(0)) {
            console.log("Returning existing activeNetworkConfig");
            return activeNetworkConfig;
        }

        // Read the current lending protocol from environment
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        console.log("lendingProtocol:", lendingProtocol);

        bool lendingProtocolIsTropykus =
            keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING));
        bool lendingProtocolIsSovryn =
            keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING));
        bool lendingProtocolIsLayerbank =
            keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(LAYERBANK_STRING));
        bool lendingProtocolIsNone =
            keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(NONE_STRING));

        console.log("lendingProtocolIsTropykus:", lendingProtocolIsTropykus);
        console.log("lendingProtocolIsSovryn:", lendingProtocolIsSovryn);
        console.log("lendingProtocolIsLayerbank:", lendingProtocolIsLayerbank);
        console.log("lendingProtocolIsNone:", lendingProtocolIsNone);

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

        // Create mock DOC token
        MockStablecoin mockDocToken = new MockStablecoin(msg.sender);

        address mockLayerbankAToken;
        if (lendingProtocolIsTropykus) {
            MockKdocToken shareToken = new MockKdocToken(address(mockDocToken));
            mockShareToken = address(shareToken);
            console.log("Created MockKdocToken at:", mockShareToken);
            emit HelperConfig__CreatedMockShareToken(mockShareToken, TROPYKUS_STRING);
        } else if (lendingProtocolIsSovryn) {
            MockIToken shareToken = new MockIToken(address(mockDocToken));
            mockShareToken = address(shareToken);
            console.log("Created MockIToken at:", mockShareToken);
            emit HelperConfig__CreatedMockShareToken(mockShareToken, SOVRYN_STRING);
        } else if (lendingProtocolIsLayerbank) {
            MockLayerBankAToken aToken = new MockLayerBankAToken(address(mockDocToken));
            MockLayerBankPool pool = new MockLayerBankPool(aToken);
            aToken.setPool(address(pool));
            mockLayerbankAToken = address(aToken);
            mockShareToken = mockLayerbankAToken;
            console.log("Created MockLayerBankAToken at:", mockLayerbankAToken);
            emit HelperConfig__CreatedMockShareToken(mockLayerbankAToken, LAYERBANK_STRING);
        } else if (lendingProtocolIsNone) {
            console.log("Idle lane: no lending share token");
        } else {
            revert("Invalid lending protocol");
        }

        MockMocProxy mockMocProxy = new MockMocProxy(address(mockDocToken));

        // Only stop the broadcast if we started it
        if (!isBroadcasting) {
            vm.stopBroadcast();
        }

        emit HelperConfig__CreatedMockStablecoin(address(mockDocToken));
        emit HelperConfig__CreatedMockMocProxy(address(mockMocProxy));

        address kDoc = lendingProtocolIsTropykus ? mockShareToken : address(0);
        address iToken = lendingProtocolIsSovryn ? mockShareToken : address(0);

        console.log("Creating NetworkConfig with:");
        console.log("  docToken:", address(mockDocToken));
        console.log("  kDoc:", kDoc);
        console.log("  iToken:", iToken);
        console.log("  layerbankAToken:", mockLayerbankAToken);

        anvilNetworkConfig = NetworkConfig({
            docToken: address(mockDocToken),
            kDoc: kDoc,
            iToken: iToken,
            layerbankAToken: mockLayerbankAToken,
            mocProxy: address(mockMocProxy)
        });
    }

    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }

    function getStablecoin() public view returns (address) {
        return activeNetworkConfig.docToken;
    }

    function getShareToken() public view returns (address) {
        // Read current lending protocol from environment
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        console.log("getShareToken - Current lending protocol:", lendingProtocol);

        // Read current stablecoin type from environment or use stored value
        string memory currentStablecoinType;
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            currentStablecoinType = coinType;
        } catch {
            currentStablecoinType = stablecoinType;
        }
        console.log("getShareToken - Current stablecoin type:", currentStablecoinType);

        bool lendingProtocolIsTropykus =
            keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING));
        bool lendingProtocolIsSovryn =
            keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING));
        bool lendingProtocolIsLayerbank =
            keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(LAYERBANK_STRING));
        bool lendingProtocolIsNone =
            keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(NONE_STRING));
        bool isUSDRIF = keccak256(abi.encodePacked(currentStablecoinType)) == keccak256(abi.encodePacked("USDRIF"));

        if (lendingProtocolIsNone) {
            return address(0);
        }
        if (lendingProtocolIsTropykus) {
            console.log("getShareToken - Returning kDoc:", activeNetworkConfig.kDoc);
            return activeNetworkConfig.kDoc;
        }
        if (lendingProtocolIsSovryn) {
            if (isUSDRIF) {
                console.log("getShareToken - WARNING: USDRIF is not supported by Sovryn");
                return address(0);
            }
            console.log("getShareToken - Returning iToken:", activeNetworkConfig.iToken);
            return activeNetworkConfig.iToken;
        }
        if (lendingProtocolIsLayerbank) {
            console.log("getShareToken - Returning layerbankAToken:", activeNetworkConfig.layerbankAToken);
            return activeNetworkConfig.layerbankAToken;
        }
        console.log("getShareToken - ERROR: Unsupported lending protocol");
        revert("Unsupported lending protocol");
    }
}
