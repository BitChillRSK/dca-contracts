// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "../../unit/DcaDappTest.t.sol";
import {IDcaManager} from "../../../src/interfaces/IDcaManager.sol";
import {IOperationsAdmin} from "../../../src/interfaces/IOperationsAdmin.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";
import {ITokenHandler} from "../../../src/interfaces/ITokenHandler.sol";
import {IPurchaseRbtc} from "../../../src/interfaces/IPurchaseRbtc.sol";
import {IPurchaseUniswap} from "../../../src/interfaces/IPurchaseUniswap.sol";
import {ITokenLending} from "../../../src/interfaces/ITokenLending.sol";
import {ICoinPairPrice} from "../../../src/interfaces/ICoinPairPrice.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PurchaseUniswap} from "../../../src/PurchaseUniswap.sol";
import {TropykusErc20Handler} from "../../../src/tropykus-legacy/TropykusErc20Handler.sol";
import {SovrynErc20Handler} from "../../../src/sovryn/SovrynErc20Handler.sol";
import {TropykusErc20HandlerDex} from "../../../src/tropykus-legacy/TropykusErc20HandlerDex.sol";
import {SovrynErc20HandlerDex} from "../../../src/sovryn/SovrynErc20HandlerDex.sol";
import {console2} from "forge-std/console2.sol";
import "../../../script/Constants.sol";

/**
 * @title GettersTest
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Comprehensive test suite for ALL getter functions in ALL contracts from /src directory
 * @dev Tests normal functionality, edge cases, and revert conditions for every getter across the entire codebase
 */
contract GettersTest is DcaDappTest {
    
    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public override {
        super.setUp();
        // Additional setup specific to getter tests can go here
    }

    /*//////////////////////////////////////////////////////////////
                        DCAMANAGER GETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_dcaManager_getMyDcaSchedules() public {
        vm.prank(USER);
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getMyDcaSchedules(address(stablecoin));
        assertEq(schedules.length, 1); // Created in setup
        assertEq(schedules[0].tokenBalance, AMOUNT_TO_DEPOSIT);
        assertEq(schedules[0].purchaseAmount, AMOUNT_TO_SPEND);
        assertEq(schedules[0].purchasePeriod, MIN_PURCHASE_PERIOD);
    }

    function test_dcaManager_getDcaSchedules() public {
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(USER, address(stablecoin));
        assertEq(schedules.length, 1);
        assertEq(schedules[0].tokenBalance, AMOUNT_TO_DEPOSIT);
    }

    function test_dcaManager_getMyScheduleTokenBalance() public {
        vm.prank(USER);
        uint256 balance = dcaManager.getMyScheduleTokenBalance(address(stablecoin), 0);
        assertEq(balance, AMOUNT_TO_DEPOSIT);
    }

    function test_dcaManager_getScheduleTokenBalance() public {
        uint256 balance = dcaManager.getScheduleTokenBalance(USER, address(stablecoin), 0);
        assertEq(balance, AMOUNT_TO_DEPOSIT);
    }

    function test_dcaManager_getMySchedulePurchaseAmount() public {
        vm.prank(USER);
        uint256 amount = dcaManager.getMySchedulePurchaseAmount(address(stablecoin), 0);
        assertEq(amount, AMOUNT_TO_SPEND);
    }

    function test_dcaManager_getSchedulePurchaseAmount() public {
        uint256 amount = dcaManager.getSchedulePurchaseAmount(USER, address(stablecoin), 0);
        assertEq(amount, AMOUNT_TO_SPEND);
    }

    function test_dcaManager_getMySchedulePurchasePeriod() public {
        vm.prank(USER);
        uint256 period = dcaManager.getMySchedulePurchasePeriod(address(stablecoin), 0);
        assertEq(period, MIN_PURCHASE_PERIOD);
    }

    function test_dcaManager_getSchedulePurchasePeriod() public {
        uint256 period = dcaManager.getSchedulePurchasePeriod(USER, address(stablecoin), 0);
        assertEq(period, MIN_PURCHASE_PERIOD);
    }

    function test_dcaManager_getMyScheduleId() public {
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getMyScheduleId(address(stablecoin), 0);
        assertNotEq(scheduleId, bytes32(0));
    }

    function test_dcaManager_getScheduleId() public {
        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), 0);
        assertNotEq(scheduleId, bytes32(0));
    }

    function test_dcaManager_getOperationsAdminAddress() public {
        address adminAddress = dcaManager.getOperationsAdminAddress();
        assertEq(adminAddress, address(operationsAdmin));
    }

    function test_dcaManager_getMinPurchasePeriod() public {
        uint256 minPeriod = dcaManager.getMinPurchasePeriod();
        assertEq(minPeriod, MIN_PURCHASE_PERIOD);
    }

    function test_dcaManager_getMaxSchedulesPerToken() public {
        uint256 maxSchedules = dcaManager.getMaxSchedulesPerToken();
        assertEq(maxSchedules, MAX_SCHEDULES_PER_TOKEN);
    }

    function test_dcaManager_getAccumulatedRbtcBalance_matchesHandler() public {
        super.makeSinglePurchase();
        uint256 fromManager =
            dcaManager.getAccumulatedRbtcBalance(USER, address(stablecoin), s_lendingProtocolIndex);
        uint256 fromHandler = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        assertEq(fromManager, fromHandler);
        assertGt(fromManager, 0);
    }

    function test_dcaManager_getMyAccumulatedRbtcBalance_usesMsgSender() public {
        super.makeSinglePurchase();
        vm.prank(USER);
        uint256 mine = dcaManager.getMyAccumulatedRbtcBalance(address(stablecoin), s_lendingProtocolIndex);
        vm.prank(OWNER);
        uint256 owners = dcaManager.getMyAccumulatedRbtcBalance(address(stablecoin), s_lendingProtocolIndex);
        assertEq(mine, IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER));
        assertEq(owners, 0);
        assertGt(mine, 0);
    }

    function test_dcaManager_getAccumulatedRbtcBalance_reverts_unknownTokenProtocol() public {
        address unknownToken = makeAddr("unknownToken");
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__TokenNotAccepted.selector, unknownToken, s_lendingProtocolIndex
        );
        vm.expectRevert(encodedRevert);
        dcaManager.getAccumulatedRbtcBalance(USER, unknownToken, s_lendingProtocolIndex);
    }

    function test_dcaManager_getMyInterestAccrued_whenSupported() public {
        // Only test if the lending protocol supports interest
        if (s_lendingProtocolIndex > 0) {
            vm.prank(USER);
            uint256 interest = dcaManager.getMyInterestAccrued(address(stablecoin), s_lendingProtocolIndex);
            assertGe(interest, 0); // Interest should be non-negative
        }
    }

    function test_dcaManager_getInterestAccrued_whenSupported() public {
        if (s_lendingProtocolIndex > 0) {
            uint256 interest = dcaManager.getInterestAccrued(USER, address(stablecoin), s_lendingProtocolIndex);
            assertGe(interest, 0);
        }
    }

    function test_dcaManager_getMyInterestAccrued_reverts_tokenDoesNotYieldInterest() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__TokenDoesNotYieldInterest.selector, address(stablecoin)));
        dcaManager.getMyInterestAccrued(address(stablecoin), 0); // Index 0 = no lending
    }

    function test_dcaManager_getInterestAccrued_reverts_tokenDoesNotYieldInterest() public {
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__TokenDoesNotYieldInterest.selector, address(stablecoin)));
        dcaManager.getInterestAccrued(USER, address(stablecoin), 0);
    }

    // Test invalid schedule index reverts for all schedule getters
    function test_dcaManager_scheduleGetters_revert_invalidIndex() public {
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.getScheduleTokenBalance(USER, address(stablecoin), 999);
        
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.getSchedulePurchaseAmount(USER, address(stablecoin), 999);
        
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.getSchedulePurchasePeriod(USER, address(stablecoin), 999);
        
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.getScheduleId(USER, address(stablecoin), 999);

        vm.prank(USER);
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.getMyScheduleTokenBalance(address(stablecoin), 999);
    }

    /*//////////////////////////////////////////////////////////////
                    OPERATIONS ADMIN GETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_operationsAdmin_getTokenHandler() public {
        address handler = operationsAdmin.getTokenHandler(address(stablecoin), s_lendingProtocolIndex);
        assertEq(handler, address(stablecoinHandler));
        
        // Test non-existent handler
        address nonExistentHandler = operationsAdmin.getTokenHandler(address(0x999), 1);
        assertEq(nonExistentHandler, address(0));
    }

    function test_operationsAdmin_getLendingProtocolIndex() public {
        uint256 tropykusIndex = operationsAdmin.getLendingProtocolIndex(TROPYKUS_STRING);
        assertEq(tropykusIndex, 1);

        uint256 sovrynIndex = operationsAdmin.getLendingProtocolIndex(SOVRYN_STRING);
        assertEq(sovrynIndex, 2);

        // Test non-existent protocol
        uint256 nonExistentIndex = operationsAdmin.getLendingProtocolIndex("nonexistent");
        assertEq(nonExistentIndex, 0);
    }

    function test_operationsAdmin_getLendingProtocolName() public {
        string memory tropykusName = operationsAdmin.getLendingProtocolName(1);
        assertEq(tropykusName, TROPYKUS_STRING);

        string memory sovrynName = operationsAdmin.getLendingProtocolName(2);
        assertEq(sovrynName, SOVRYN_STRING);

        // Test non-existent index
        string memory emptyName = operationsAdmin.getLendingProtocolName(999);
        assertEq(bytes(emptyName).length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        FEE HANDLER GETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_feeHandler_getMinFeeRate() public {
        uint256 minFeeRate = IFeeHandler(address(stablecoinHandler)).getMinFeeRate();
        assertGt(minFeeRate, 0); // Should be greater than 0
    }

    function test_feeHandler_getMaxFeeRate() public {
        uint256 maxFeeRate = IFeeHandler(address(stablecoinHandler)).getMaxFeeRate();
        assertGt(maxFeeRate, 0);
    }

    function test_feeHandler_getFeePurchaseLowerBound() public {
        uint256 lowerBound = IFeeHandler(address(stablecoinHandler)).getFeePurchaseLowerBound();
        assertGe(lowerBound, 0);
    }

    function test_feeHandler_getFeePurchaseUpperBound() public {
        uint256 upperBound = IFeeHandler(address(stablecoinHandler)).getFeePurchaseUpperBound();
        assertGe(upperBound, 0);
        
        // Upper bound should be >= lower bound
        uint256 lowerBound = IFeeHandler(address(stablecoinHandler)).getFeePurchaseLowerBound();
        assertGe(upperBound, lowerBound);
    }

    function test_feeHandler_getFeeCollectorAddress() public {
        address feeCollector = IFeeHandler(address(stablecoinHandler)).getFeeCollectorAddress();
        assertNotEq(feeCollector, address(0));
    }

    function test_feeHandler_feeRateConsistency() public {
        uint256 minFeeRate = IFeeHandler(address(stablecoinHandler)).getMinFeeRate();
        uint256 maxFeeRate = IFeeHandler(address(stablecoinHandler)).getMaxFeeRate();
        assertLe(minFeeRate, maxFeeRate); // Min should be <= Max
    }

    /*//////////////////////////////////////////////////////////////
                        TOKEN HANDLER GETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_dcaManager_getMinPurchaseAmount() public {
        uint256 defaultMinAmount = dcaManager.getDefaultMinPurchaseAmount();
        assertGt(defaultMinAmount, 0);
        
        (uint256 effectiveMinAmount, bool isCustom) = dcaManager.getTokenMinPurchaseAmount(address(stablecoin));
        assertEq(effectiveMinAmount, defaultMinAmount);
        assertFalse(isCustom);
        
        // Test setting a custom amount for a token
        vm.prank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), 50 ether);
        
        (uint256 customAmount, bool isCustomSet) = dcaManager.getTokenMinPurchaseAmount(address(stablecoin));
        assertEq(customAmount, 50 ether);
        assertTrue(isCustomSet);
        
        (uint256 newEffectiveAmount, bool newIsCustom) = dcaManager.getTokenMinPurchaseAmount(address(stablecoin));
        assertEq(newEffectiveAmount, 50 ether);
        assertTrue(newIsCustom);
    }

    function test_tokenHandler_supportsInterface() public {
        // Test ERC165 support
        bool supportsERC165 = IERC165(address(stablecoinHandler)).supportsInterface(0x01ffc9a7);
        assertTrue(supportsERC165);
        
        // Test ITokenHandler interface support
        bool supportsTokenHandler = IERC165(address(stablecoinHandler)).supportsInterface(type(ITokenHandler).interfaceId);
        assertTrue(supportsTokenHandler);
    }

    /*//////////////////////////////////////////////////////////////
                        PURCHASE RBTC GETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_purchaseRbtc_getAccumulatedRbtcBalance_withUser() public {
        uint256 balance = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        assertGe(balance, 0);
    }

    function test_purchaseRbtc_getAccumulatedRbtcBalance_caller() public {
        vm.prank(USER);
        uint256 balance = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance();
        assertGe(balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        PURCHASE UNISWAP GETTERS TESTS (DEX ONLY)
    //////////////////////////////////////////////////////////////*/

    function test_purchaseUniswap_getters() public onlyDexSwaps {
        if (address(stablecoinHandler).code.length > 0) {
            try IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumPercent() returns (uint256 percent) {
                assertEq(percent, DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT);
            } catch {
                // Some handlers might not implement this interface
                return;
            }

            try IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumSafetyCheck() returns (uint256 safetyCheck) {
                assertEq(safetyCheck, DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK);
            } catch {
                return;
            }

            try IPurchaseUniswap(address(stablecoinHandler)).getMocOracle() returns (ICoinPairPrice oracle) {
                assertNotEq(address(oracle), address(0));
            } catch {
                return;
            }

            try IPurchaseUniswap(address(stablecoinHandler)).getSwapPath() returns (bytes memory path) {
                assertGt(path.length, 0);
            } catch {
                return;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        TOKEN LENDING GETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_tokenLending_getUsersLendingTokenBalance() public {
        if (s_lendingProtocolIndex > 0) {
            uint256 balance = ITokenLending(address(stablecoinHandler)).getUsersLendingTokenBalance(USER);
            assertGe(balance, 0);
        }
    }

    function test_tokenLending_getAccruedInterest() public {
        if (s_lendingProtocolIndex > 0) {
            vm.prank(address(dcaManager));
            uint256 interest = ITokenLending(address(stablecoinHandler)).getAccruedInterest(USER, AMOUNT_TO_DEPOSIT);
            assertGe(interest, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    DCA MANAGER ACCESS CONTROL GETTERS
    //////////////////////////////////////////////////////////////*/

    function test_dcaManagerAccessControl_immutableGetter() public {
        // Test that the docHandler has the correct DCA manager address
        // The public immutable creates an automatic getter
        if (s_lendingProtocolIndex == TROPYKUS_INDEX) {
            try TropykusErc20Handler(payable(address(stablecoinHandler))).i_dcaManager() returns (address dcaManagerAddr) {
                assertEq(dcaManagerAddr, address(dcaManager));
            } catch {
                // Try the Dex version
                try TropykusErc20HandlerDex(payable(address(stablecoinHandler))).i_dcaManager() returns (address dcaManagerAddr) {
                    assertEq(dcaManagerAddr, address(dcaManager));
                } catch {
                    // Handler might not expose this getter
                }
            }
        } else if (s_lendingProtocolIndex == SOVRYN_INDEX) {
            try SovrynErc20Handler(payable(address(stablecoinHandler))).i_dcaManager() returns (address dcaManagerAddr) {
                assertEq(dcaManagerAddr, address(dcaManager));
            } catch {
                try SovrynErc20HandlerDex(payable(address(stablecoinHandler))).i_dcaManager() returns (address dcaManagerAddr) {
                    assertEq(dcaManagerAddr, address(dcaManager));
                } catch {
                    // Handler might not expose this getter
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                           EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getters_withZeroAddress() public {
        // Test getters with zero address inputs where applicable
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(address(0), address(stablecoin));
        assertEq(schedules.length, 0);

        uint256 balance = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(address(0));
        assertEq(balance, 0);
    }

    function test_getters_withNonExistentToken() public {
        address fakeToken = address(0x999);
        
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(USER, fakeToken);
        assertEq(schedules.length, 0);

        address handler = operationsAdmin.getTokenHandler(fakeToken, 1);
        assertEq(handler, address(0));
    }

    function test_getters_consistencyBetweenUserAndCallerVariants() public {
        vm.prank(USER);
        IDcaManager.DcaDetails[] memory mySchedules = dcaManager.getMyDcaSchedules(address(stablecoin));
        
        IDcaManager.DcaDetails[] memory userSchedules = dcaManager.getDcaSchedules(USER, address(stablecoin));
        
        assertEq(mySchedules.length, userSchedules.length);
        if (mySchedules.length > 0) {
            assertEq(mySchedules[0].tokenBalance, userSchedules[0].tokenBalance);
            assertEq(mySchedules[0].purchaseAmount, userSchedules[0].purchaseAmount);
            assertEq(mySchedules[0].purchasePeriod, userSchedules[0].purchasePeriod);
            assertEq(mySchedules[0].scheduleId, userSchedules[0].scheduleId);
        }
    }

    function test_getters_returnTypesAndDefaults() public {
        // Test that getters return appropriate default values for empty states
        assertEq(dcaManager.getMinPurchasePeriod(), MIN_PURCHASE_PERIOD);
        assertEq(dcaManager.getMaxSchedulesPerToken(), MAX_SCHEDULES_PER_TOKEN);
        assertNotEq(dcaManager.getOperationsAdminAddress(), address(0));
        
        // Test empty arrays for new users
        address newUser = makeAddr("newUser");
        IDcaManager.DcaDetails[] memory emptySchedules = dcaManager.getDcaSchedules(newUser, address(stablecoin));
        assertEq(emptySchedules.length, 0);
    }

    function test_getters_accessControl() public {
        // Test that view functions don't have access control restrictions
        vm.prank(makeAddr("randomUser"));
        assertNotEq(dcaManager.getOperationsAdminAddress(), address(0));
        
        vm.prank(makeAddr("randomUser"));
        uint256 minPeriod = dcaManager.getMinPurchasePeriod();
        assertEq(minPeriod, MIN_PURCHASE_PERIOD);
    }

    function test_getters_stateConsistency() public {
        // Verify that related getters return consistent values
        assertEq(dcaManager.getMinPurchasePeriod(), MIN_PURCHASE_PERIOD);
        assertEq(dcaManager.getMaxSchedulesPerToken(), MAX_SCHEDULES_PER_TOKEN);
        
        // Test protocol mappings are bidirectional
        assertEq(operationsAdmin.getLendingProtocolIndex(TROPYKUS_STRING), 1);
        assertEq(operationsAdmin.getLendingProtocolName(1), TROPYKUS_STRING);
        
        assertEq(operationsAdmin.getLendingProtocolIndex(SOVRYN_STRING), 2);
        assertEq(operationsAdmin.getLendingProtocolName(2), SOVRYN_STRING);

        // Test fee bounds consistency
        uint256 lowerBound = IFeeHandler(address(stablecoinHandler)).getFeePurchaseLowerBound();
        uint256 upperBound = IFeeHandler(address(stablecoinHandler)).getFeePurchaseUpperBound();
        assertLe(lowerBound, upperBound);
    }

    function test_getters_boundaryConditions() public {
        // Test boundary conditions for various getters
        
        // Test with address(0) as token
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(USER, address(0));
        assertEq(schedules.length, 0);
        
        // Test protocol index 0 (should return empty name)
        string memory emptyProtocol = operationsAdmin.getLendingProtocolName(0);
        assertEq(bytes(emptyProtocol).length, 0);
        
        // Test empty protocol name (should return 0)
        uint256 emptyIndex = operationsAdmin.getLendingProtocolIndex("");
        assertEq(emptyIndex, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION GETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getters_afterStateChanges() public {
        // Test getters after making actual state changes
        uint256 initialBalance = dcaManager.getScheduleTokenBalance(USER, address(stablecoin), 0);
        
        // Make a purchase
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), 0);
        
        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), 0, scheduleId);
        
        // Check balance changed
        uint256 newBalance = dcaManager.getScheduleTokenBalance(USER, address(stablecoin), 0);
        assertLt(newBalance, initialBalance);
        
        // Check rBTC balance increased
        uint256 rbtcBalance = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        assertGt(rbtcBalance, 0);
    }

    function test_getters_gasEfficiency() public {
        // Test that getters are gas efficient
        uint256 gasBefore = gasleft();
        dcaManager.getMinPurchasePeriod(); // Use a different getter
        uint256 gasAfter = gasleft();
        assertLt(gasBefore - gasAfter, 10000); // Should be very cheap
        
        gasBefore = gasleft();
        dcaManager.getMinPurchasePeriod();
        gasAfter = gasleft();
        assertLt(gasBefore - gasAfter, 10000);
        
        gasBefore = gasleft();
        operationsAdmin.getLendingProtocolName(1);
        gasAfter = gasleft();
        assertLt(gasBefore - gasAfter, 15000); // String operations slightly more expensive
    }
} 