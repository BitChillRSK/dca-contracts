//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {DcaManager} from "../../src/DcaManager.sol";
import {DcaManagerAccessControl} from "../../src/DcaManagerAccessControl.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IStablecoinHandler} from "../../test/interfaces/IStablecoinHandler.sol";
import {ICoinPairPrice} from "../../src/interfaces/ICoinPairPrice.sol";
import {TropykusDocHandlerMoc} from "../../src/TropykusDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "../../src/SovrynDocHandlerMoc.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {OperationsAdmin} from "../../src/OperationsAdmin.sol";
import {IOperationsAdmin} from "../../src/interfaces/IOperationsAdmin.sol";
import {MocHelperConfig} from "../../script/MocHelperConfig.s.sol";
import {DexHelperConfig} from "../../script/DexHelperConfig.s.sol";
import {DeployDexSwaps} from "../../script/DeployDexSwaps.s.sol";
import {DeployMocSwaps} from "../../script/DeployMocSwaps.s.sol";
import {MockStablecoin} from "../mocks/MockStablecoin.sol";
import {ILendingToken} from "../interfaces/ILendingToken.sol";
import {MockMocProxy} from "../mocks/MockMocProxy.sol";
import {IMocStateV1} from "../mocks/MocInterfaces.sol";
import {MockMocPriceProvider} from "../mocks/MockMocPriceProvider.sol";
import {GovernorMock} from "../mocks/MockMocGovernor.sol";
import {MockWrbtcToken} from "../mocks/MockWrbtcToken.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import "../../script/Constants.sol";
import "./TestsHelper.t.sol";
import {IkToken} from "../../src/interfaces/IkToken.sol";
import {IiSusdToken} from "../../src/interfaces/IiSusdToken.sol";
import {IPurchaseUniswap} from "../../src/interfaces/IPurchaseUniswap.sol";

contract DcaDappTest is Test {
    DcaManager dcaManager;
    MockMocProxy mocProxy;
    IStablecoinHandler stablecoinHandler;
    OperationsAdmin operationsAdmin;
    MockStablecoin stablecoin;
    ILendingToken lendingToken;
    MockWrbtcToken wrBtcToken;
    FeeCalculator feeCalculator;
    
    // Helper configs from deployment
    MocHelperConfig mocHelperConfig;
    DexHelperConfig dexHelperConfig;

    // Stablecoin configuration
    string stablecoinType;

    address USER = makeAddr(USER_STRING);
    address OWNER = makeAddr(OWNER_STRING);
    address ADMIN = makeAddr(ADMIN_STRING);
    address SWAPPER = makeAddr(SWAPPER_STRING);
    address FEE_COLLECTOR = makeAddr(FEE_COLLECTOR_STRING);
    uint256 constant STARTING_RBTC_USER_BALANCE = 10 ether; // 10 rBTC
    // uint256 constant RBTC_TO_MINT_DOC = 0.2 ether; // 0.2 BTC

    // Fixed constants for all stablecoin types
    uint256 constant USER_TOTAL_AMOUNT = 20000 ether;
    uint256 constant AMOUNT_TO_DEPOSIT = 2000 ether;
    uint256 constant AMOUNT_TO_SPEND = 200 ether;

    uint256 constant SCHEDULE_INDEX = 0;
    uint256 constant NUM_OF_SCHEDULES = 5;
    
    string swapType = vm.envString("SWAP_TYPE");
    bool isMocSwaps = keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("mocSwaps"));
    bool isDexSwaps = keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("dexSwaps"));
    string lendingProtocol = vm.envString("LENDING_PROTOCOL");
    address stablecoinHandlerAddress;
    uint256 s_lendingProtocolIndex;
    uint256 s_btcPrice;
    ICoinPairPrice mocOracle;
    address constant MOC_ORACLE_MAINNET = 0xe2927A0620b82A66D67F678FC9b826B0E01B1bFD;
    address constant MOC_ORACLE_TESTNET = 0xbffBD993FF1d229B0FfE55668F2009d20d4F7C5f;
    address constant MOC_STATEV1_MAINNET = 0xb9C42EFc8ec54490a37cA91c423F7285Fa01e257;
    address constant MOC_STATEV1_TESTNET = 0x0adb40132cB0ffcEf6ED81c26A1881e214100555;
    address constant MOC_IN_RATE_MAINNET = 0xc0f9B54c41E3d0587Ce0F7540738d8d649b0A3F3;
    address constant MOC_IN_RATE_TESTNET = 0x76790f846FAAf44cf1B2D717d0A6c5f6f5152B60;
    address DUMMY_COMMISSION_RECEIVER = makeAddr("Dummy commission receiver");

    //////////////////////
    // Events ////////////
    //////////////////////

    // DcaManager
    event DcaManager__TokenBalanceUpdated(address indexed token, bytes32 indexed scheduleId, uint256 indexed amount);
    event DcaManager__DcaScheduleCreated(
        address indexed user,
        address indexed token,
        bytes32 indexed scheduleId,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 lendingProtocolIndex
    );
    event DcaManager__DcaScheduleUpdated(
        address indexed user,
        address indexed token,
        bytes32 indexed scheduleId,
        uint256 updatedTokenBalance,
        uint256 updatedPurchaseAmount,
        uint256 updatedPurchasePeriod
    );
    event DcaManager__LastPurchaseTimestampUpdated(address indexed token, bytes32 indexed scheduleId, uint256 indexed timestamp);

    // TokenHandler
    event TokenHandler__TokenDeposited(address indexed token, address indexed user, uint256 indexed amount);
    event TokenHandler__TokenWithdrawn(address indexed token, address indexed user, uint256 indexed amount);
    
    // TokenLending
    event TokenLending__UnderlyingRedeemed(
        address indexed user, uint256 indexed underlyingAmountRedeemed, uint256 indexed lendingTokenAmountRepayed
    );

    // IPurchaseRbtc
    event PurchaseRbtc__RbtcBought(
        address indexed user,
        address indexed tokenSpent,
        uint256 rBtcBought,
        bytes32 indexed scheduleId,
        uint256 amountSpent
    );
    event PurchaseRbtc__SuccessfulRbtcBatchPurchase(
        address indexed token, uint256 indexed totalPurchasedRbtc, uint256 indexed totalStablecoinAmountSpent
    );

    // OperationsAdmin
    event OperationsAdmin__TokenHandlerUpdated(
        address indexed token, uint256 indexed lendinProtocolIndex, address indexed newHandler
    );

    //MockMocProxy
    event MockMocProxy__DocRedeemed(address indexed user, uint256 docAmount, uint256 btcAmount);

    //TokenLending
    event TokenLending__WithdrawalAmountAdjusted(
        address indexed user, uint256 indexed originalAmount, uint256 indexed adjustedAmount
    );
    event TokenLending__UnderlyingRedeemedBatch(uint256 indexed underlyingAmountRedeemed, uint256 indexed lendingTokenAmountRepayed);

    modifier onlyDexSwaps() {
        if (!isDexSwaps) {
            console2.log("Skipping test: only applicable for dexSwaps");
            return;
        }
        _;
    }

    modifier onlyMocSwaps() {
        if (!isMocSwaps) {
            console2.log("Skipping test: only applicable for mocSwaps");
            return;
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            UNIT TESTS SETUP
    //////////////////////////////////////////////////////////////*/
    function setUp() public virtual {
        // Initialize stablecoin type from environment or use default
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            stablecoinType = coinType;
        } catch {
            stablecoinType = DEFAULT_STABLECOIN;
        }
        
        bool isSovryn = keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING));
        bool isUSDRIF = keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("USDRIF"));
        
        // Skip test if Sovryn + USDRIF combination (not supported)
        if (isSovryn && isUSDRIF) {
            console2.log("Skipping test: USDRIF is not supported by Sovryn");
            vm.skip(true);
            return;
        }
        // Skip test if MoC Swaps + USDRIF combination (not supported)
        if (isMocSwaps && isUSDRIF) {
            console2.log("Skipping test: USDRIF is not supported by MoC Swaps");
            vm.skip(true);
            return;
        }
        // Skip test if Dex Swaps + DOC combination (not supported)
        if (isDexSwaps && !isUSDRIF) {
            console2.log("Skipping test: DOC is not supported by Dex Swaps");
            vm.skip(true);
            return;
        }
        
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            s_lendingProtocolIndex = TROPYKUS_INDEX;
        } else if (isSovryn) {
            s_lendingProtocolIndex = SOVRYN_INDEX;
        } else {
            revert("Lending protocol not allowed");
        }
        
        // Deal rBTC funds to user
        vm.deal(USER, STARTING_RBTC_USER_BALANCE);
        s_btcPrice = BTC_PRICE;

        if (isMocSwaps) {
            DeployMocSwaps deployContracts = new DeployMocSwaps();
            (operationsAdmin, stablecoinHandlerAddress, dcaManager, mocHelperConfig) = deployContracts.run();
            stablecoinHandler = IStablecoinHandler(stablecoinHandlerAddress);
            MocHelperConfig.NetworkConfig memory networkConfig = mocHelperConfig.getActiveNetworkConfig();

            address stablecoinAddress = mocHelperConfig.getStablecoinAddress();
            address mocProxyAddress = networkConfig.mocProxyAddress;

            stablecoin = MockStablecoin(stablecoinAddress);
            mocProxy = MockMocProxy(mocProxyAddress);

            // Give the MoC proxy contract allowance
            stablecoin.approve(mocProxyAddress, AMOUNT_TO_DEPOSIT);

            // Mint stablecoin for the user
            if (block.chainid == ANVIL_CHAIN_ID) {
                // Local tests
                // Deal rBTC funds to MoC contract
                vm.deal(mocProxyAddress, 1000 ether);

                // Give the MoC proxy contract allowance to move stablecoin from stablecoinHandler
                // This is necessary for local tests because of how the mock contract works, but not for the live contract
                vm.prank(address(stablecoinHandler));
                stablecoin.approve(mocProxyAddress, type(uint256).max);
                stablecoin.mint(USER, USER_TOTAL_AMOUNT);
            } else if (block.chainid == RSK_MAINNET_CHAIN_ID) {
                // Fork tests
                vm.store(
                    MOC_IN_RATE_MAINNET,
                    bytes32(uint256(214)),
                    bytes32(uint256(uint160(DUMMY_COMMISSION_RECEIVER)))
                );

                // Fork tests - use token holders instead of minting
                if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("DOC"))) {
                    // Set USER to DOC holder address
                    USER = DOC_HOLDER;
                } else if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("USDRIF"))) {
                    // Set USER to USDRIF holder address
                    USER = USDRIF_HOLDER;
                }
                
                // Get BTC price from oracle
                mocOracle = ICoinPairPrice(MOC_ORACLE_MAINNET);
                s_btcPrice = mocOracle.getPrice() / 1e18;
                _overrideMocPriceProvider(MOC_STATEV1_MAINNET);
            } else if (block.chainid == RSK_TESTNET_CHAIN_ID) {
                vm.store(
                    address(MOC_IN_RATE_TESTNET),
                    bytes32(uint256(214)),
                    bytes32(uint256(uint160(DUMMY_COMMISSION_RECEIVER)))
                );

                // Fork tests - use token holders instead of minting
                if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("DOC"))) {
                    // Set USER to DOC holder address
                    USER = DOC_HOLDER_TESTNET;
                } else if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("USDRIF"))) {
                    // Set USER to USDRIF holder address
                    USER = USDRIF_HOLDER;
                }

                mocOracle = ICoinPairPrice(MOC_ORACLE_TESTNET);
                s_btcPrice = mocOracle.getPrice() / 1e18;
                _overrideMocPriceProvider(MOC_STATEV1_TESTNET);
            }
        } else if (isDexSwaps) {
            DeployDexSwaps deployContracts = new DeployDexSwaps();
            (operationsAdmin, stablecoinHandlerAddress, dcaManager, dexHelperConfig) = deployContracts.run();
            stablecoinHandler = IStablecoinHandler(stablecoinHandlerAddress);
            
            address stablecoinAddress = dexHelperConfig.getStablecoinAddress();
            address wrBtcTokenAddress = dexHelperConfig.getActiveNetworkConfig().wrbtcTokenAddress;
            address swapRouter02Address = dexHelperConfig.getActiveNetworkConfig().swapRouter02Address;
            address mocProxyAddress = dexHelperConfig.getActiveNetworkConfig().mocProxyAddress;

            stablecoin = MockStablecoin(stablecoinAddress);
            wrBtcToken = MockWrbtcToken(wrBtcTokenAddress);
            mocProxy = MockMocProxy(mocProxyAddress);

            // Mint stablecoin for the user
            if (block.chainid == ANVIL_CHAIN_ID) {
                // Local tests
                stablecoin.mint(USER, USER_TOTAL_AMOUNT);
                // Deal 1000 rBTC to the mock SwapRouter02 contract, so that it can deposit rBTC on the mock WRBTC contract
                // to simulate that the StablecoinHandlerDex contract has received WRBTC after calling the `exactInput()` function
                vm.deal(swapRouter02Address, 1000 ether);
            } else if (block.chainid == RSK_MAINNET_CHAIN_ID) {
                vm.store(
                    address(MOC_IN_RATE_MAINNET),
                    bytes32(uint256(214)),
                    bytes32(uint256(uint160(DUMMY_COMMISSION_RECEIVER)))
                );
                // vm.prank(USER);
                // // Use the appropriate mint function based on token type
                // (bool success, ) = address(mocProxy).call{value: 0.21 ether}(
                //     abi.encodeWithSignature(string(abi.encodePacked(tokenConfig.mintFunctionName, "(uint256)")), RBTC_TO_MINT_DOC)
                // );
                // require(success, "Mint function call failed");
                
                // Fork tests - use token holders instead of minting
                if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("DOC"))) {
                    // Set USER to DOC holder address
                    USER = DOC_HOLDER;
                } else if (keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("USDRIF"))) {
                    // Set USER to USDRIF holder address
                    USER = USDRIF_HOLDER;
                }

                mocOracle = ICoinPairPrice(MOC_ORACLE_MAINNET);
                s_btcPrice = mocOracle.getPrice() / 1e18;
                _overrideMocPriceProvider(MOC_STATEV1_MAINNET);
            // } else if (block.chainid == RSK_TESTNET_CHAIN_ID) {
            // THERE ARE NO UNSIWAP CONTRACTS ON RSK TESTNET, SO THIS BRANCH CAN'T BE TESTED
            //     vm.store(
            //         address(MOC_IN_RATE_TESTNET),
            //         bytes32(uint256(214)),
            //         bytes32(uint256(uint160(DUMMY_COMMISSION_RECEIVER)))
            //     );
            //     vm.prank(USER);
            //     // Use the appropriate mint function based on token type
            //     (bool success, ) = address(mocProxy).call{value: 0.21 ether}(
            //         abi.encodeWithSignature(string(abi.encodePacked(tokenConfig.mintFunctionName, "(uint256)")), RBTC_TO_MINT_DOC)
            //     );
            //     require(success, "Mint function call failed");

            //     mocOracle = ICoinPairPrice(MOC_ORACLE_TESTNET);
            //     s_btcPrice = mocOracle.getPrice() / 1e18;
            // _overrideMocPriceProvider(MOC_STATEV1_TESTNET);
            }
        } else {
            revert("Invalid deploy environment");
        }

        // Set the lending token based on protocol and current stablecoin
        lendingToken = ILendingToken(getLendingTokenAddress(stablecoinType, s_lendingProtocolIndex));

        if (address(lendingToken) == address(0)) {
            // Skip this test instead of letting it fail
            vm.skip(true);
            return;
        }

        // FeeCalculator helper test contract
        feeCalculator = new FeeCalculator();

        // Set roles
        vm.prank(OWNER);
        operationsAdmin.setAdminRole(ADMIN);
        vm.startPrank(ADMIN);
        operationsAdmin.setSwapperRole(SWAPPER);
        // Add Troypkus and Sovryn as allowed lending protocols
        operationsAdmin.addOrUpdateLendingProtocol(TROPYKUS_STRING, 1);
        operationsAdmin.addOrUpdateLendingProtocol(SOVRYN_STRING, 2);
        vm.stopPrank();

        // Add tokenHandler
        vm.expectEmit(true, true, true, false);
        emit OperationsAdmin__TokenHandlerUpdated(address(stablecoin), s_lendingProtocolIndex, address(stablecoinHandler));
        vm.prank(ADMIN);
        operationsAdmin.assignOrUpdateTokenHandler(address(stablecoin), s_lendingProtocolIndex, address(stablecoinHandler));

        // The starting point of the tests is that the user has already deposited stablecoin (so withdrawals can also be tested without much hassle)
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      UNIT TESTS COMMON FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositStablecoin() internal returns (uint256, uint256) {
        vm.startPrank(USER);
        uint256 userBalanceBeforeDeposit = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        bytes32 scheduleId = keccak256(
            abi.encodePacked(USER, address(stablecoin), block.timestamp, dcaManager.getMyDcaSchedules(address(stablecoin)).length - 1)
        );
        vm.expectEmit(true, true, true, false);
        emit TokenHandler__TokenDeposited(address(stablecoin), USER, AMOUNT_TO_DEPOSIT);
        vm.expectEmit(true, true, true, false);
        emit DcaManager__TokenBalanceUpdated(address(stablecoin), scheduleId, 2 * AMOUNT_TO_DEPOSIT); // 2 *, since a previous deposit is made in the setup
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_DEPOSIT);
        uint256 userBalanceAfterDeposit = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        vm.stopPrank();
        return (userBalanceAfterDeposit, userBalanceBeforeDeposit);
    }

    function withdrawStablecoin() internal {
        vm.startPrank(USER);
        vm.expectEmit(true, true, false, false); // Amounts may not match to the last wei, so third parameter is false
        emit TokenHandler__TokenWithdrawn(address(stablecoin), USER, AMOUNT_TO_DEPOSIT);
        bytes32 scheduleId = dcaManager.getMyScheduleId(address(stablecoin), SCHEDULE_INDEX);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_DEPOSIT);
        uint256 remainingAmount = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        assertEq(remainingAmount, 0);
        vm.stopPrank();
    }

    function createSeveralDcaSchedules() internal {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        uint256 stablecoinToDeposit = AMOUNT_TO_DEPOSIT / NUM_OF_SCHEDULES;
        uint256 purchaseAmount = AMOUNT_TO_SPEND / NUM_OF_SCHEDULES;
        // Delete the schedule created in setUp to have all five schedules with the same amounts
        bytes32 scheduleId = keccak256(
            abi.encodePacked(USER, address(stablecoin), block.timestamp, dcaManager.getMyDcaSchedules(address(stablecoin)).length - 1)
        );
        dcaManager.deleteDcaSchedule(address(stablecoin), 0, scheduleId);
        for (uint256 i = 0; i < NUM_OF_SCHEDULES; ++i) {
            uint256 scheduleIndex = SCHEDULE_INDEX + i;
            uint256 purchasePeriod = MIN_PURCHASE_PERIOD + i * 5 days;
            uint256 userBalanceBeforeDeposit;
            if (dcaManager.getMyDcaSchedules(address(stablecoin)).length > scheduleIndex) {
                userBalanceBeforeDeposit = dcaManager.getMyScheduleTokenBalance(address(stablecoin), scheduleIndex);
            } else {
                userBalanceBeforeDeposit = 0;
            }
            scheduleId = keccak256(
                abi.encodePacked(USER, address(stablecoin), block.timestamp, dcaManager.getMyDcaSchedules(address(stablecoin)).length)
            );
            vm.expectEmit(true, true, true, true);
            emit DcaManager__DcaScheduleCreated(
                USER, address(stablecoin), scheduleId, stablecoinToDeposit, purchaseAmount, purchasePeriod, s_lendingProtocolIndex
            );
            dcaManager.createDcaSchedule(
                address(stablecoin), stablecoinToDeposit, purchaseAmount, purchasePeriod, s_lendingProtocolIndex
            );
            uint256 userBalanceAfterDeposit = dcaManager.getMyScheduleTokenBalance(address(stablecoin), scheduleIndex);
            assertEq(stablecoinToDeposit, userBalanceAfterDeposit - userBalanceBeforeDeposit);
            assertEq(purchaseAmount, dcaManager.getMySchedulePurchaseAmount(address(stablecoin), scheduleIndex));
            assertEq(purchasePeriod, dcaManager.getMySchedulePurchasePeriod(address(stablecoin), scheduleIndex));
        }
        vm.stopPrank();
    }

    function makeSinglePurchase() internal {
        vm.startPrank(USER);
        uint256 stablecoinBalanceBeforePurchase = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        uint256 rbtcBalanceBeforePurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance();
        IDcaManager.DcaDetails[] memory dcaDetails = dcaManager.getMyDcaSchedules(address(stablecoin));
        vm.stopPrank();

        uint256 fee = feeCalculator.calculateFee(AMOUNT_TO_SPEND);
        uint256 netPurchaseAmount = AMOUNT_TO_SPEND - fee;

        vm.expectEmit(true, true, true, true);
        uint256 lastPurchaseTimestamp = dcaDetails[SCHEDULE_INDEX].lastPurchaseTimestamp == 0 ? block.timestamp : dcaDetails[SCHEDULE_INDEX].lastPurchaseTimestamp + dcaDetails[SCHEDULE_INDEX].purchasePeriod;
        emit DcaManager__LastPurchaseTimestampUpdated(address(stablecoin), dcaDetails[SCHEDULE_INDEX].scheduleId, lastPurchaseTimestamp);
        vm.expectEmit(true, false, false, false);
        emit TokenLending__UnderlyingRedeemed(USER, 0, 0);
        if (block.chainid == ANVIL_CHAIN_ID && isMocSwaps) {
            vm.expectEmit(true, true, true, true);
        } else {
            vm.expectEmit(true, true, true, false); // Amounts may not match to the last wei on fork tests
        }
        emit PurchaseRbtc__RbtcBought(
            USER,
            address(stablecoin),
            netPurchaseAmount / s_btcPrice,
            dcaDetails[SCHEDULE_INDEX].scheduleId,
            netPurchaseAmount
        );
        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), SCHEDULE_INDEX, dcaDetails[SCHEDULE_INDEX].scheduleId);

        vm.startPrank(USER);
        uint256 stablecoinBalanceAfterPurchase = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        uint256 rbtcBalanceAfterPurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance();
        vm.stopPrank();

        // Check that stablecoin was subtracted and rBTC was added to user's balances
        assertEq(stablecoinBalanceBeforePurchase - stablecoinBalanceAfterPurchase, AMOUNT_TO_SPEND);

        // if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("mocSwaps"))) {
        //     assertEq(rbtcBalanceAfterPurchase - rbtcBalanceBeforePurchase, netPurchaseAmount / s_btcPrice);
        // } else if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("dexSwaps"))) {
        assertApproxEqRel( // The mock contract that simulates swapping on Uniswap allows for some slippage
            rbtcBalanceAfterPurchase - rbtcBalanceBeforePurchase,
            netPurchaseAmount / s_btcPrice,
            MAX_SLIPPAGE_PERCENT // Allow a maximum difference of 0.5% (on fork tests we saw this was necessary for both MoC and Uniswap swaps)
        );
        // }
    }

    function makeSeveralPurchasesWithSeveralSchedules() internal returns (uint256 totalStablecoinSpent) {
        // createSeveralDcaSchedules();

        uint8 numOfPurchases = 5;
        uint256 totalStablecoinRedeemed;

        for (uint8 i; i < NUM_OF_SCHEDULES; ++i) {
            uint256 scheduleIndex = i;
            vm.startPrank(USER);
            uint256 schedulePurchaseAmount = dcaManager.getMySchedulePurchaseAmount(address(stablecoin), scheduleIndex);
            uint256 schedulePurchasePeriod = dcaManager.getMySchedulePurchasePeriod(address(stablecoin), scheduleIndex);
            vm.stopPrank();
            uint256 fee = feeCalculator.calculateFee(schedulePurchaseAmount);
            uint256 netPurchaseAmount = schedulePurchaseAmount - fee;

            for (uint8 j; j < numOfPurchases; ++j) {
                vm.startPrank(USER);
                uint256 stablecoinBalanceBeforePurchase = dcaManager.getMyScheduleTokenBalance(address(stablecoin), scheduleIndex);
                uint256 rbtcBalanceBeforePurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance();
                bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), scheduleIndex);
                vm.stopPrank();
                
                vm.prank(SWAPPER);
                dcaManager.buyRbtc(USER, address(stablecoin), scheduleIndex, scheduleId);
                
                vm.startPrank(USER);
                uint256 stablecoinBalanceAfterPurchase = dcaManager.getMyScheduleTokenBalance(address(stablecoin), scheduleIndex);
                uint256 RbtcBalanceAfterPurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance();
                vm.stopPrank();
                
                // Check that stablecoin was subtracted and rBTC was added to user's balances
                assertEq(stablecoinBalanceBeforePurchase - stablecoinBalanceAfterPurchase, schedulePurchaseAmount);
                assertApproxEqRel(
                    RbtcBalanceAfterPurchase - rbtcBalanceBeforePurchase,
                    netPurchaseAmount / s_btcPrice,
                    MAX_SLIPPAGE_PERCENT // Allow a maximum difference of 0.75% (on fork tests we saw this was necessary for both MoC and Uniswap swaps)
                );

                totalStablecoinSpent += netPurchaseAmount;
                totalStablecoinRedeemed += schedulePurchaseAmount;

                // Advance time so the next purchase can be made (purchase period check)
                updateExchangeRate(schedulePurchasePeriod);
            }
        }
        
        vm.prank(USER);
        assertApproxEqRel(
            IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(),
            totalStablecoinSpent / s_btcPrice,
            MAX_SLIPPAGE_PERCENT // Allow a maximum difference of 0.75% (on fork tests we saw this was necessary for both MoC and Uniswap swaps)
        );
        
        return totalStablecoinSpent;
    }

    function makeBatchPurchasesOneUser() internal {
        uint256 prevStablecoinHandlerBalance;

        if (isMocSwaps) {
            prevStablecoinHandlerBalance = address(stablecoinHandler).balance;
        } else if (isDexSwaps) {
            prevStablecoinHandlerBalance = wrBtcToken.balanceOf(address(stablecoinHandler));
        }

        vm.prank(USER);
        uint256 userAccumulatedRbtcPrev = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance();
        address[] memory users = new address[](NUM_OF_SCHEDULES);
        uint256[] memory scheduleIndexes = new uint256[](NUM_OF_SCHEDULES);
        uint256[] memory purchaseAmounts = new uint256[](NUM_OF_SCHEDULES);
        uint256[] memory purchasePeriods = new uint256[](NUM_OF_SCHEDULES);
        bytes32[] memory scheduleIds = new bytes32[](NUM_OF_SCHEDULES);

        uint256 totalNetPurchaseAmount;
        uint256 totalFee;
        // Create the arrays for the batch purchase (in production, this is done in the back end)
        for (uint8 i; i < NUM_OF_SCHEDULES; ++i) {
            uint256 scheduleIndex = i;
            vm.startPrank(USER);
            uint256 schedulePurchaseAmount = dcaManager.getMySchedulePurchaseAmount(address(stablecoin), scheduleIndex);
            vm.stopPrank();
            uint256 fee = feeCalculator.calculateFee(schedulePurchaseAmount);
            totalNetPurchaseAmount += schedulePurchaseAmount - fee;
            totalFee += fee;
            users[i] = USER; // Same user for has 5 schedules due for a purchase in this scenario
            scheduleIndexes[i] = i;
            vm.startPrank(OWNER);
            purchaseAmounts[i] = dcaManager.getDcaSchedules(users[0], address(stablecoin))[i].purchaseAmount;
            purchasePeriods[i] = dcaManager.getDcaSchedules(users[0], address(stablecoin))[i].purchasePeriod;
            scheduleIds[i] = dcaManager.getDcaSchedules(users[0], address(stablecoin))[i].scheduleId;
            vm.stopPrank();
        }
        vm.expectEmit(true, false, false, false);
        emit TokenLending__UnderlyingRedeemedBatch(totalNetPurchaseAmount + totalFee, 0);

        for (uint8 i; i < NUM_OF_SCHEDULES; ++i) {
            vm.expectEmit(false, false, false, false);
            emit PurchaseRbtc__RbtcBought(USER, address(stablecoin), 0, scheduleIds[i], 0); // Never mind the actual values on this test
        }

        vm.expectEmit(true, false, false, false); // the amount of rBTC purchased won't match exactly neither the amount of stablecoin spent in the case of Sovryn due to rounding errors
        if (isMocSwaps) {
            emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(
                address(stablecoin), totalNetPurchaseAmount / s_btcPrice, totalNetPurchaseAmount
            );
        } else if (isDexSwaps) {
            emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(
                address(stablecoin), (totalNetPurchaseAmount * 995) / (1000 * s_btcPrice), totalNetPurchaseAmount
            );
        }

        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            users,
            address(stablecoin),
            scheduleIndexes,
            scheduleIds,
            purchaseAmounts,
            s_lendingProtocolIndex
        );

        uint256 postStablecoinHandlerBalance;

        if (isMocSwaps) {
            postStablecoinHandlerBalance = address(stablecoinHandler).balance;
        } else if (isDexSwaps) {
            postStablecoinHandlerBalance = wrBtcToken.balanceOf(address(stablecoinHandler));
        }

        assertApproxEqRel(
            postStablecoinHandlerBalance - prevStablecoinHandlerBalance,
            totalNetPurchaseAmount / s_btcPrice,
            MAX_SLIPPAGE_PERCENT // Allow a maximum difference of 0.5% (on fork tests we saw this was necessary for both MoC and Uniswap purchases)
        );

        vm.prank(USER);
        uint256 userAccumulatedRbtcPost = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance();

        assertApproxEqRel(
            userAccumulatedRbtcPost - userAccumulatedRbtcPrev,
            totalNetPurchaseAmount / s_btcPrice,
            MAX_SLIPPAGE_PERCENT // Allow a maximum difference of 0.5% (on fork tests we saw this was necessary for both MoC and Uniswap purchases)
        );

        vm.warp(block.timestamp + 5 weeks); // warp to a time far in the future so all schedules are long due for a new purchase
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            users,
            address(stablecoin),
            scheduleIndexes,
            scheduleIds,
            purchaseAmounts,
            s_lendingProtocolIndex
        );
        
        uint256 postStablecoinHandlerBalance2;

        if (isMocSwaps) {
            postStablecoinHandlerBalance2 = address(stablecoinHandler).balance;
        } else if (isDexSwaps) {
            postStablecoinHandlerBalance2 = wrBtcToken.balanceOf(address(stablecoinHandler));
        }

        assertApproxEqRel(
            postStablecoinHandlerBalance2 - postStablecoinHandlerBalance,
            totalNetPurchaseAmount / s_btcPrice,
            MAX_SLIPPAGE_PERCENT // Allow a maximum difference of 0.5% (on fork tests we saw this was necessary for both MoC and Uniswap purchases)
        );
    }

    function updateExchangeRate(uint256 secondsPassed) internal {
        vm.warp(block.timestamp + secondsPassed);

        if (s_lendingProtocolIndex == TROPYKUS_INDEX) {
            console2.log("Exchange rate before update:", lendingToken.exchangeRateStored());
            vm.roll(block.number + secondsPassed / 30); // Jump to secondsPassed seconds (30 seconds per block) into the future so that some interest has been generated.
            console2.log("Exchange rate after update:", lendingToken.exchangeRateCurrent()); // This is the one that should be used
        }
    }

    /// @dev Replace MoC and BTC price providers with a MockMocPriceProvider that never expires
    function _overrideMocPriceProvider(address mocStateV1Address) internal {
        console2.log("Current chainid:", block.chainid);
        // Only on forks where StateV1 exists (mainnet)
        if (block.chainid != RSK_MAINNET_CHAIN_ID && block.chainid != RSK_TESTNET_CHAIN_ID) return;
        IMocStateV1 mocStateV1 = IMocStateV1(mocStateV1Address);
        // 1) Replace governor with a permissive mock so we can set the price provider
        GovernorMock mockGovernor = new GovernorMock();
        bytes32 slotGovernor = bytes32(uint256(155));
        vm.store(MOC_STATEV1_MAINNET, slotGovernor, bytes32(uint256(uint160(address(mockGovernor)))));
        
        // 2) Read current provider price and clone it to the mock with the same price
        address btcPriceProviderAddr = mocStateV1.getBtcPriceProvider();
        MockMocPriceProvider btcPriceProvider = MockMocPriceProvider(btcPriceProviderAddr);
        (bytes32 price,) = btcPriceProvider.peek();
        MockMocPriceProvider mockMocBtcPriceProvider = new MockMocPriceProvider(uint256(price));
        
        // 2) Do the same for MoC price provider
        address mocPriceProviderAddr = mocStateV1.getMoCPriceProvider();
        MockMocPriceProvider mocPriceProvider = MockMocPriceProvider(mocPriceProviderAddr);
        (bytes32 mocPrice,) = mocPriceProvider.peek();
        MockMocPriceProvider mockMocMocPriceProvider = new MockMocPriceProvider(uint256(mocPrice));

        // 3) Set the BTC price provider to mocStateV1 with the same price that now never expires
        mocStateV1.setBtcPriceProvider(address(mockMocBtcPriceProvider));

        // 4) Set the MoC price provider to mocStateV1 with the same price that now never expires
        mocStateV1.setMoCPriceProvider(address(mockMocMocPriceProvider));

        // Make the mock oracle the one for Uniswap interactions as well
        if(isDexSwaps) {
            vm.prank(OWNER);
            IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(mockMocBtcPriceProvider));
        }
    }

    /*//////////////////////////////////////////////////////////////
                      HELPER FUNCTIONS FOR STABLECOINS
    //////////////////////////////////////////////////////////////*/

    // Helper function to get lending token address based on stablecoin type and lending protocol
    function getLendingTokenAddress(string memory _stablecoinType, uint256 lendingProtocolIndex) internal view returns (address) {
        bool isUSDRIF = keccak256(abi.encodePacked(_stablecoinType)) == keccak256(abi.encodePacked("USDRIF"));
        
        // Check if this stablecoin is supported by Sovryn
        if (lendingProtocolIndex == SOVRYN_INDEX && isUSDRIF) {
            revert("Lending token not available for the selected combination");
        }
        
        address lendingTokenAddress = address(0);
        
        // Try to get the lending token address from the helper configs
        if (isMocSwaps && address(mocHelperConfig) != address(0)) {
            MocHelperConfig.NetworkConfig memory networkConfig = mocHelperConfig.getActiveNetworkConfig();
            
            if (lendingProtocolIndex == TROPYKUS_INDEX) {
                lendingTokenAddress = networkConfig.kDocAddress;
            } else if (lendingProtocolIndex == SOVRYN_INDEX) {
                lendingTokenAddress = networkConfig.iSusdAddress;
            }
        } else if (isDexSwaps && address(dexHelperConfig) != address(0)) {
            if (lendingProtocolIndex == TROPYKUS_INDEX || lendingProtocolIndex == SOVRYN_INDEX) {
                lendingTokenAddress = dexHelperConfig.getLendingTokenAddress();
            }
        }
        
        // If we couldn't get the lending token address from the helper configs, try to get it from the handler
        if (lendingTokenAddress == address(0) && address(stablecoinHandler) != address(0)) {
            if (lendingProtocolIndex == TROPYKUS_INDEX) {
                try TropykusDocHandlerMoc(payable(address(stablecoinHandler))).i_kToken() returns (IkToken kToken) {
                    lendingTokenAddress = address(kToken);
                } catch {
                    revert("Failed to get Tropykus lending token from handler");
                }
            } else if (lendingProtocolIndex == SOVRYN_INDEX) {
                try SovrynDocHandlerMoc(payable(address(stablecoinHandler))).i_iSusdToken() returns (IiSusdToken iSusdToken) {
                    lendingTokenAddress = address(iSusdToken);
                } catch {
                    revert("Failed to get Sovryn lending token from handler");
                }
            }
        }
        
        // If we still couldn't get the lending token address, revert
        if (lendingTokenAddress == address(0)) {
            revert("Lending token not available for the selected combination");
        }
        
        return lendingTokenAddress;
    }
}
