// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockStablecoin} from "../test/mocks/MockStablecoin.sol";
import {MockKdocToken} from "../test/mocks/MockKdocToken.sol";
import {MockIsusdToken} from "../test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "../test/mocks/MockMocProxy.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "../test/mocks/MockLayerBank.sol";
import "./Constants.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";

contract MocHelperConfig is Script {

    struct NetworkConfig {
        // DOC token address (MoC is only for DOC)
        address docTokenAddress;
        
        // Share token addresses by protocol
        address kDocAddress;  // The share token for Tropykus (kDOC) — legacy tests only
        address iSusdAddress; // The share token for Sovryn (iSUSD)
        address layerbankATokenAddress; // LayerBank lRooDOC aToken; handler reads Pool from aToken.POOL()
        
        // MoC protocol
        address mocProxyAddress;
    }
    
    string stablecoinType;
    address mockShareTokenAddress;
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
        console.log("  docTokenAddress:", activeNetworkConfig.docTokenAddress);
        console.log("  kDocAddress:", activeNetworkConfig.kDocAddress);
        console.log("  iSusdAddress:", activeNetworkConfig.iSusdAddress);
        console.log("  layerbankATokenAddress:", activeNetworkConfig.layerbankATokenAddress);
    }

    function getRootstockTestnetConfig() public pure returns (NetworkConfig memory RootstockTestnetNetworkConfig) {
        RootstockTestnetNetworkConfig = NetworkConfig({
            docTokenAddress: 0xCB46c0ddc60D18eFEB0E586C17Af6ea36452Dae0, // DOC token on testnet
            kDocAddress: 0x71e6B108d823C2786f8EF63A3E0589576B4F3914, // kDOC proxy on testnet
            iSusdAddress: 0x74e00A8CeDdC752074aad367785bFae7034ed89f, // iSUSD proxy on testnet
            layerbankATokenAddress: address(0), // LayerBank DOC is mainnet-only
            mocProxyAddress: 0x2820f6d4D199B8D8838A4B26F9917754B86a0c1F // MOC proxy on testnet
        });
    }

    function getRootstockMainnetConfig() public pure returns (NetworkConfig memory RootstockMainnetNetworkConfig) {
        RootstockMainnetNetworkConfig = NetworkConfig({
            docTokenAddress: 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db, // DOC token on mainnet
            kDocAddress: 0x544Eb90e766B405134b3B3F62b6b4C23Fcd5fDa2, // kDOC proxy on mainnet
            iSusdAddress: 0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1, // iSUSD proxy on mainnet
            layerbankATokenAddress: 0x3F04280C66314b78E9712A41BF8C1A214460cAa2, // lRooDOC aToken
            mocProxyAddress: 0xf773B590aF754D597770937Fa8ea7AbDf2668370 // MOC proxy on mainnet
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory anvilNetworkConfig) {
        console.log("getOrCreateAnvilConfig called");
        
        if (activeNetworkConfig.docTokenAddress != address(0)) {
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
        address mockDocTokenAddress = address(mockDocToken);
        
        address mockLayerbankAToken;
        if (lendingProtocolIsTropykus) {
            MockKdocToken mockShareToken = new MockKdocToken(mockDocTokenAddress);
            mockShareTokenAddress = address(mockShareToken);
            console.log("Created MockKdocToken at:", mockShareTokenAddress);
            emit HelperConfig__CreatedMockShareToken(mockShareTokenAddress, TROPYKUS_STRING);
        } else if (lendingProtocolIsSovryn) {
            MockIsusdToken mockShareToken = new MockIsusdToken(mockDocTokenAddress);
            mockShareTokenAddress = address(mockShareToken);
            console.log("Created MockIsusdToken at:", mockShareTokenAddress);
            emit HelperConfig__CreatedMockShareToken(mockShareTokenAddress, SOVRYN_STRING);
        } else if (lendingProtocolIsLayerbank) {
            MockLayerBankAToken aToken = new MockLayerBankAToken(mockDocTokenAddress);
            MockLayerBankPool pool = new MockLayerBankPool(aToken);
            aToken.setPool(address(pool));
            mockLayerbankAToken = address(aToken);
            mockShareTokenAddress = mockLayerbankAToken;
            console.log("Created MockLayerBankAToken at:", mockLayerbankAToken);
            emit HelperConfig__CreatedMockShareToken(mockLayerbankAToken, LAYERBANK_STRING);
        } else if (lendingProtocolIsNone) {
            console.log("Idle lane: no lending share token");
        } else {
            revert("Invalid lending protocol");
        }
        
        MockMocProxy mockMocProxy = new MockMocProxy(mockDocTokenAddress);
        
        // Only stop the broadcast if we started it
        if (!isBroadcasting) {
            vm.stopBroadcast();
        }

        emit HelperConfig__CreatedMockStablecoin(mockDocTokenAddress);
        emit HelperConfig__CreatedMockMocProxy(address(mockMocProxy));
        
        address kDocAddress = lendingProtocolIsTropykus ? mockShareTokenAddress : address(0);
        address iSusdAddress = lendingProtocolIsSovryn ? mockShareTokenAddress : address(0);

        console.log("Creating NetworkConfig with:");
        console.log("  docTokenAddress:", mockDocTokenAddress);
        console.log("  kDocAddress:", kDocAddress);
        console.log("  iSusdAddress:", iSusdAddress);
        console.log("  layerbankATokenAddress:", mockLayerbankAToken);

        anvilNetworkConfig = NetworkConfig({
            docTokenAddress: mockDocTokenAddress,
            kDocAddress: kDocAddress,
            iSusdAddress: iSusdAddress,
            layerbankATokenAddress: mockLayerbankAToken,
            mocProxyAddress: address(mockMocProxy)
        });
    }

    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }
    
    function getStablecoinAddress() public view returns (address) {
        return activeNetworkConfig.docTokenAddress;
    }

    function getShareTokenAddress() public view returns (address) {
        // Read current lending protocol from environment
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        console.log("getShareTokenAddress - Current lending protocol:", lendingProtocol);
        
        // Read current stablecoin type from environment or use stored value
        string memory currentStablecoinType;
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            currentStablecoinType = coinType;
        } catch {
            currentStablecoinType = stablecoinType;
        }
        console.log("getShareTokenAddress - Current stablecoin type:", currentStablecoinType);
        
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
            console.log("getShareTokenAddress - Returning kDocAddress:", activeNetworkConfig.kDocAddress);
            return activeNetworkConfig.kDocAddress;
        }
        if (lendingProtocolIsSovryn) {
            if (isUSDRIF) {
                console.log("getShareTokenAddress - WARNING: USDRIF is not supported by Sovryn");
                return address(0);
            }
            console.log("getShareTokenAddress - Returning iSusdAddress:", activeNetworkConfig.iSusdAddress);
            return activeNetworkConfig.iSusdAddress;
        }
        if (lendingProtocolIsLayerbank) {
            console.log("getShareTokenAddress - Returning layerbankATokenAddress:", activeNetworkConfig.layerbankATokenAddress);
            return activeNetworkConfig.layerbankATokenAddress;
        }
        console.log("getShareTokenAddress - ERROR: Unsupported lending protocol");
        revert("Unsupported lending protocol");
    }
}
