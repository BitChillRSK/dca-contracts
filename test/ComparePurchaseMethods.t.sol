// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DeployMocAndUniswap} from "../script/DeployMocAndUniswap.s.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {IPurchaseRbtc} from "../src/interfaces/IPurchaseRbtc.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {MocHelperConfig} from "../script/MocHelperConfig.s.sol";
import {DexHelperConfig} from "../script/DexHelperConfig.s.sol";
import {MockStablecoin} from "../test/mocks/MockStablecoin.sol";
import {MockMocProxy} from "../test/mocks/MockMocProxy.sol";
import {MockWrbtcToken} from "../test/mocks/MockWrbtcToken.sol";
import {toBatch, packBatchRow} from "./utils/BatchBuyOne.sol";
import "./Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";


contract ComparePurchaseMethods is Test {
    // Constants for testing
    uint256 constant NUM_OF_USERS = 10; // Can be easily changed to test different scenarios
    uint256 constant SCALING_FACTOR = 100 ether; // Base purchase amount
    uint256 constant DEPOSIT_MULTIPLIER = 2; // Deposit is 2x the purchase amount
    
    address[] users;
    uint256[] docToSpendArray;
    uint256[] docToDepositArray;
    
    address SWAPPER = makeAddr(SWAPPER_STRING);
    address OWNER = makeAddr(OWNER_STRING);
    address ADMIN = makeAddr(ADMIN_STRING);
    address FEE_COLLECTOR = makeAddr(FEE_COLLECTOR_STRING);
    address DUMMY_COMMISSION_RECEIVER = makeAddr("Dummy commission receiver");
    
    uint256 constant SCHEDULE_INDEX = 0;
    uint256 constant RBTC_TO_MINT_DOC = 1 ether;

    // Mainnet addresses
    address constant MOC_ORACLE = 0xe2927A0620b82A66D67F678FC9b826B0E01B1bFD;
    address constant MOC_INRATE = 0xc0f9B54c41E3d0587Ce0F7540738d8d649b0A3F3;
    
    // Deployed contracts
    DeployMocAndUniswap.DeployedContracts deployedContracts;
    
    // Common contracts
    MockStablecoin stablecoin;
    
    // MoC-specific contracts
    MockMocProxy mocProxy;
    DcaManager dcaManMoc;
    address handlerMoc;
    
    // Uniswap-specific contracts
    MockWrbtcToken wrbtcToken;
    ICoinPairPrice priceOracle;
    DcaManager dcaManUni;
    address handlerUni;
    
    // Protocol settings
    uint256 routeIndex;
    uint256 btcPrice;
    string stablecoinType;

    function setUp() public {
        if (block.chainid != RSK_MAINNET_CHAIN_ID) {
            return;
        }
        console2.log("Setting up comparison test with %d users", NUM_OF_USERS);
        
        // Initialize arrays for users and amounts
        initializeArrays();
        
        // Set route index from the lending-protocol env lane
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            routeIndex = TROPYKUS_INDEX;
        } else if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING))) {
            routeIndex = SOVRYN_INDEX;
        } else {
            revert("Lending protocol not allowed");
        }

        // Get stablecoin type (or use default if not specified)
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            stablecoinType = coinType;
        } catch {
            stablecoinType = DOC_STRING;
        }
        
        // Deploy both implementations
        DeployMocAndUniswap deployer = new DeployMocAndUniswap();
        deployedContracts = deployer.run();
        
        // Store references
        dcaManMoc = deployedContracts.dcaManMoc;
        handlerMoc = deployedContracts.handlerMoc;
        dcaManUni = deployedContracts.dcaManUni;
        handlerUni = deployedContracts.handlerUni;
        
        // Get stablecoin and MoC proxy contracts
        MocHelperConfig.NetworkConfig memory mocConfig = deployedContracts.helpConfMoc.getActiveNetworkConfig();
        
        // Get the DOC token address
        address docTokenAddress = mocConfig.docTokenAddress;
        stablecoin = MockStablecoin(docTokenAddress);
        mocProxy = MockMocProxy(mocConfig.mocProxyAddress);
        
        // Get Uniswap-specific contracts
        DexHelperConfig.NetworkConfig memory uniConfig = deployedContracts.helpConfUni.getActiveNetworkConfig();
        wrbtcToken = MockWrbtcToken(uniConfig.wrbtcTokenAddress);
        priceOracle = ICoinPairPrice(MOC_ORACLE);
        
        // Set up the test environment
        setupEnvironment();
        
        console2.log("Comparison test setup complete");
    }
    
    function initializeArrays() private {
        // Create arrays for users and amounts based on NUM_OF_USERS
        users = new address[](NUM_OF_USERS);
        docToSpendArray = new uint256[](NUM_OF_USERS);
        docToDepositArray = new uint256[](NUM_OF_USERS);
        
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            // Generate user addresses with index
            users[i] = makeAddr(string(abi.encodePacked("User", _uintToString(i+1))));
            
            // Calculate purchase amount: scale by user index (starting from 1)
            docToSpendArray[i] = SCALING_FACTOR * (i+1);
            
            // Calculate deposit amount: 10x the purchase amount
            docToDepositArray[i] = docToSpendArray[i] * DEPOSIT_MULTIPLIER;
        }
    }
    
    function setupEnvironment() private {
        // Deal rBTC funds to each user for minting DOC
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            vm.deal(users[i], 10 ether);
        }
        
        // Fix the commission splitter address to avoid gas issues in Foundry
        vm.store(
            MOC_INRATE,
            bytes32(uint256(214)),
            bytes32(uint256(uint160(DUMMY_COMMISSION_RECEIVER)))
        );
        
        // Mint DOC by sending rBTC to MoC for each user
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            vm.prank(users[i]);
            mocProxy.mintDoc{value: RBTC_TO_MINT_DOC}(RBTC_TO_MINT_DOC * 95 / 100); // Account for commission
        }
        
        // Get BTC price from oracle for Uniswap implementation
        btcPrice = priceOracle.getPrice() / 1e18;
        console2.log("BTC price from mainnet oracle: %d USD", btcPrice);
        
        // Output DOC balances for verification
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            console2.log("User %s: DOC balance: %d; Purchase amount: %d DOC", 
                _uintToString(i+1), 
                stablecoin.balanceOf(users[i]) / 1e18, 
                docToSpendArray[i] / 1e18
            );
        }
        
        // Set up swappers and routes for both implementations
        vm.startPrank(OWNER);
        deployedContracts.adOpsMoc.addSwapper(SWAPPER);
        deployedContracts.adOpsUni.addSwapper(SWAPPER);
        deployedContracts.adOpsMoc.registerRoute(TROPYKUS_INDEX, true);
        deployedContracts.adOpsMoc.registerRoute(SOVRYN_INDEX, true);
        deployedContracts.adOpsUni.registerRoute(TROPYKUS_INDEX, true);
        deployedContracts.adOpsUni.registerRoute(SOVRYN_INDEX, true);
        deployedContracts.adOpsMoc.assignTokenHandler(address(stablecoin), routeIndex, handlerMoc);
        deployedContracts.adOpsUni.assignTokenHandler(address(stablecoin), routeIndex, handlerUni);
        vm.stopPrank();

        // Create initial DCA schedules for each user
        createInitialSchedules();
        
        console2.log("Environment setup complete");
    }
    
    function createInitialSchedules() private {
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            vm.startPrank(users[i]);
            
            // For MoC implementation
            stablecoin.approve(handlerMoc, docToDepositArray[i]);
            dcaManMoc.createDcaSchedule(
                address(stablecoin), docToDepositArray[i], docToSpendArray[i], MIN_PURCHASE_PERIOD, routeIndex
            );
            
            // For Uniswap implementation
            stablecoin.approve(handlerUni, docToDepositArray[i]);
            dcaManUni.createDcaSchedule(
                address(stablecoin), docToDepositArray[i], docToSpendArray[i], MIN_PURCHASE_PERIOD, routeIndex
            );
            
            vm.stopPrank();
        }
    }
    
    
    function testCompareBatchPurchases() public {
        if (block.chainid != RSK_MAINNET_CHAIN_ID) {
            return;
        }

        console2.log("\n=== TESTING BATCH PURCHASES ===");
        
        // Execute batch purchases for both MoC and Uniswap
        (uint256 mocBatchGas, uint256 mocBatchRbtc) = executeMocBatchPurchase();
        
        // Reset time for Uniswap batch purchase
        vm.warp(block.timestamp + MIN_PURCHASE_PERIOD);
        
        (uint256 uniBatchGas, uint256 uniBatchRbtc) = executeUniBatchPurchase();
        
        // Calculate and print the total DOC spent
        uint256 totalDocSpent = calculateTotalDocSpent();
        console2.log("\nTotal DOC spent per method:", totalDocSpent / 1e18);
        
        // Print rBTC comparison
        printRbtcComparison(mocBatchRbtc, uniBatchRbtc);

        // Print gas comparison
        printGasComparison(mocBatchGas, uniBatchGas);
        
        // Print batch-specific conclusion
        printBatchConclusion(mocBatchGas, uniBatchGas, mocBatchRbtc, uniBatchRbtc);
    }
    
    
    
    function runBatchTest() private returns (uint256, uint256, uint256, uint256) {
        // Similar to testCompareBatchPurchases but without the logging
        (uint256 mocGas, uint256 mocRbtc) = executeMocBatchPurchase();
        vm.warp(block.timestamp + MIN_PURCHASE_PERIOD);
        (uint256 uniGas, uint256 uniRbtc) = executeUniBatchPurchase();
        
        return (mocGas, uniGas, mocRbtc, uniRbtc);
    }
    
    // Helper function to print rBTC comparison
    function printRbtcComparison(uint256 mocRbtc, uint256 uniRbtc) private view {
        console2.log("MoC rBTC purchased: %s", _formatRbtc(mocRbtc));
        console2.log("Uniswap rBTC purchased: %s", _formatRbtc(uniRbtc));
        
        if(mocRbtc > uniRbtc) {
            uint256 diff = mocRbtc - uniRbtc;
            console2.log("MoC returns more rBTC by: %s rBTC (%s USD)", 
                _formatRbtc(diff), _formatUsd(diff, btcPrice));
        } else if(uniRbtc > mocRbtc) {
            uint256 diff = uniRbtc - mocRbtc;
            console2.log("Uniswap returns more rBTC by: %s rBTC (%s USD)", 
                _formatRbtc(diff), _formatUsd(diff, btcPrice));
        } else {
            console2.log("Both methods return the same amount of rBTC");
        }
    }
    
    
    // Helper function to print batch test conclusion
    function printBatchConclusion(
        uint256 mocGas, 
        uint256 uniGas, 
        uint256 mocRbtc, 
        uint256 uniRbtc
    ) private pure {
        console2.log("\nBatch Purchases Conclusion:");
        
        if (mocRbtc > uniRbtc) {
            console2.log("  - MoC provides better returns for users in batch purchases");
        } else if (uniRbtc > mocRbtc) {
            console2.log("  - Uniswap provides better returns for users in batch purchases");
        } else {
            console2.log("  - Both methods provide equal returns for users in batch purchases");
        }
        
        if (mocGas < uniGas) {
            console2.log("  - MoC is more gas-efficient for batch purchases");
        } else if (uniGas < mocGas) {
            console2.log("  - Uniswap is more gas-efficient for batch purchases");
        } else {
            console2.log("  - Both methods have equal gas efficiency for batch purchases");
        }
    }

    // Helper functions for formatting rBTC values with proper decimal places
    function _formatRbtc(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e18;
        uint256 fraction = amount % 1e18;
        return string(abi.encodePacked(_uintToString(whole), ".", _formatFractional(fraction)));
    }
    
    function _formatFractional(uint256 fraction) internal pure returns (string memory) {
        // Convert fraction to a string with leading zeros
        string memory fractionStr = _uintToString(fraction);
        uint256 numZeros = 18 - bytes(fractionStr).length;

        // Prepend leading zeros
        string memory leadingZeros = "";
        for (uint256 i = 0; i < numZeros; i++) {
            leadingZeros = string(abi.encodePacked(leadingZeros, "0"));
        }

        return string(abi.encodePacked(leadingZeros, fractionStr));
    }

    function _uintToString(uint256 num) internal pure returns (string memory) {
        if (num == 0) return "0";
        uint256 temp = num;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (num != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + num % 10));
            num /= 10;
        }
        return string(buffer);
    }

    // Helper function to format USD values with proper decimal places
    function _formatUsd(uint256 rbtcAmount, uint256 btcPriceInUsd) internal pure returns (string memory) {
        // Calculate USD with higher precision to avoid losing small values
        uint256 usdValueRaw = (rbtcAmount * btcPriceInUsd);
        
        // Format with 6 decimal places (division by 1e12 instead of 1e18)
        uint256 usdWhole = usdValueRaw / 1e18;
        uint256 usdFraction = (usdValueRaw % 1e18) / 1e12; // 6 decimal places
        
        // Convert to string with proper formatting
        string memory usdWholeStr = _uintToString(usdWhole);
        string memory usdFractionStr = _uintToString(usdFraction);
        
        // Add leading zeros to fraction if needed
        uint256 numZeros = 6 - bytes(usdFractionStr).length;
        string memory leadingZeros = "";
        for (uint256 i = 0; i < numZeros; i++) {
            leadingZeros = string(abi.encodePacked(leadingZeros, "0"));
        }
        
        return string(abi.encodePacked(usdWholeStr, ".", leadingZeros, usdFractionStr));
    }

    function _weiToSats(uint256 weiAmount) internal pure returns (uint256) {
        return weiAmount / 1e10;
    }

    // Helper to calculate total DOC spent
    function calculateTotalDocSpent() private view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            total += docToSpendArray[i];
        }
        return total;
    }
    
    
    function executeMocBatchPurchase() private returns (uint256, uint256) {
        // Get starting balances
        uint256[] memory startBalances = new uint256[](NUM_OF_USERS);
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            vm.startPrank(users[i]);
            startBalances[i] = IPurchaseRbtc(handlerMoc).getAccumulatedRbtcBalance(users[i]);
            vm.stopPrank();
        }
        
        // Prepare batch data: each row is packed against the schedule's own purchaseAmount, which is
        // docToSpendArray[i] since createInitialSchedules() created it with that amount.
        bytes32[] memory rows = new bytes32[](NUM_OF_USERS);

        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            uint64 scheduleId = scheduleIdAt(dcaManMoc, users[i], address(stablecoin), SCHEDULE_INDEX);
            rows[i] = packBatchRow(scheduleId, uint96(docToSpendArray[i]));
        }

        // Execute batch purchase
        uint256 gasStart = gasleft();
        vm.prank(SWAPPER);
        dcaManMoc.batchBuyRbtc(
            toBatch(rows, address(stablecoin), routeIndex)
        );
        uint256 gasUsed = gasStart - gasleft();
        uint256 gasCost = gasUsed * tx.gasprice;
        
        // Get ending balances and calculate rBTC gained
        uint256 totalRbtcPurchased = 0;
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            vm.startPrank(users[i]);
            uint256 endBalance = IPurchaseRbtc(handlerMoc).getAccumulatedRbtcBalance(users[i]);
            totalRbtcPurchased += (endBalance - startBalances[i]);
            vm.stopPrank();
        }
        
        // Print results
        console2.log("MoC Batch Purchase (%d users at once):", NUM_OF_USERS);
        console2.log("  Gas used:", gasUsed);
        console2.log("  Gas cost: %s rBTC (%d sats, %s USD)", _formatRbtc(gasCost), _weiToSats(gasCost), _formatUsd(gasCost, btcPrice));
        console2.log("  Total rBTC purchased: %s (%d sats)", _formatRbtc(totalRbtcPurchased), totalRbtcPurchased / 1e10);
        
        return (gasUsed, totalRbtcPurchased);
    }
    
    function executeUniBatchPurchase() private returns (uint256, uint256) {
        // Get starting balances
        uint256[] memory startBalances = new uint256[](NUM_OF_USERS);
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            vm.startPrank(users[i]);
            startBalances[i] = IPurchaseRbtc(handlerUni).getAccumulatedRbtcBalance(users[i]);
            vm.stopPrank();
        }
        
        // Prepare batch data: each row is packed against the schedule's own purchaseAmount, which is
        // docToSpendArray[i] since createInitialSchedules() created it with that amount.
        bytes32[] memory rows = new bytes32[](NUM_OF_USERS);

        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            uint64 scheduleId = scheduleIdAt(dcaManUni, users[i], address(stablecoin), SCHEDULE_INDEX);
            rows[i] = packBatchRow(scheduleId, uint96(docToSpendArray[i]));
        }

        // Execute batch purchase
        uint256 gasStart = gasleft();
        vm.prank(SWAPPER);
        dcaManUni.batchBuyRbtc(
            toBatch(rows, address(stablecoin), routeIndex)
        );
        uint256 gasUsed = gasStart - gasleft();
        uint256 gasCost = gasUsed * tx.gasprice;
        
        // Get ending balances and calculate rBTC gained
        uint256 totalRbtcPurchased = 0;
        for (uint256 i = 0; i < NUM_OF_USERS; i++) {
            vm.startPrank(users[i]);
            uint256 endBalance = IPurchaseRbtc(handlerUni).getAccumulatedRbtcBalance(users[i]);
            totalRbtcPurchased += (endBalance - startBalances[i]);
            vm.stopPrank();
        }
        
        // Print results
        console2.log("Uniswap Batch Purchase (%d users at once):", NUM_OF_USERS);
        console2.log("  Gas used:", gasUsed);
        console2.log("  Gas cost: %s rBTC (%d sats, %s USD)", _formatRbtc(gasCost), _weiToSats(gasCost), _formatUsd(gasCost, btcPrice));
        console2.log("  Total rBTC purchased: %s (%d sats)", _formatRbtc(totalRbtcPurchased), totalRbtcPurchased / 1e10);
        
        return (gasUsed, totalRbtcPurchased);
    }
    
    function printGasComparison(uint256 mocGasUsed, uint256 uniGasUsed) private view {
        console2.log("\nGas Comparison:");
        
        if (mocGasUsed > uniGasUsed) {
            uint256 diff = mocGasUsed - uniGasUsed;
            uint256 percentage = (diff * 10000) / mocGasUsed;
            console2.log("Uniswap uses less gas by %d.%d%", percentage / 100, percentage % 100);
        } else if (uniGasUsed > mocGasUsed) {
            uint256 diff = uniGasUsed - mocGasUsed;
            uint256 percentage = (diff * 10000) / uniGasUsed;
            console2.log("MoC uses less gas by %d.%d%", percentage / 100, percentage % 100);
        } else {
            console2.log("Both methods use the same amount of gas");
        }
        
        uint256 mocGasCostRbtc = mocGasUsed * tx.gasprice;
        uint256 uniGasCostRbtc = uniGasUsed * tx.gasprice;
        if (mocGasCostRbtc > uniGasCostRbtc) {
            console2.log("MoC is more gas-expensive by: %s rBTC (%d sats, %s USD)", 
                _formatRbtc(mocGasCostRbtc - uniGasCostRbtc), 
                _weiToSats(mocGasCostRbtc - uniGasCostRbtc), 
                _formatUsd(mocGasCostRbtc - uniGasCostRbtc, btcPrice));
        } else {
            console2.log("Uniswap is more gas-expensive by: %s rBTC (%d sats, %s USD)", 
                _formatRbtc(uniGasCostRbtc - mocGasCostRbtc), 
                _weiToSats(uniGasCostRbtc - mocGasCostRbtc), 
                _formatUsd(uniGasCostRbtc - mocGasCostRbtc, btcPrice));
        }
    }
} 