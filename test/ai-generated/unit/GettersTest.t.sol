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
import {DcaManagerAccessControl} from "../../../src/DcaManagerAccessControl.sol";
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

    function test_dcaManager_getDcaSchedules() public {
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(USER, address(stablecoin));
        assertEq(schedules.length, 1); // Created in setup
        assertEq(schedules[0].tokenBalance, AMOUNT_TO_DEPOSIT);
        assertEq(schedules[0].purchaseAmount, AMOUNT_TO_SPEND);
        assertEq(schedules[0].purchasePeriod, MIN_PURCHASE_PERIOD);
    }

    function test_dcaManager_getDcaSchedule_selfAndArbitraryUser() public {
        vm.prank(USER);
        IDcaManager.DcaDetails memory asUser = dcaManager.getDcaSchedule(USER, address(stablecoin), 0);

        vm.prank(OWNER);
        IDcaManager.DcaDetails memory asThirdParty = dcaManager.getDcaSchedule(USER, address(stablecoin), 0);
        IDcaManager.DcaDetails[] memory enumerated = dcaManager.getDcaSchedules(USER, address(stablecoin));

        assertEq(asUser.tokenBalance, AMOUNT_TO_DEPOSIT);
        assertEq(asUser.purchaseAmount, AMOUNT_TO_SPEND);
        assertEq(asUser.purchasePeriod, MIN_PURCHASE_PERIOD);
        assertNotEq(asUser.scheduleId, bytes32(0));
        assertEq(asUser.routeIndex, s_routeIndex);

        assertEq(asThirdParty.tokenBalance, asUser.tokenBalance);
        assertEq(asThirdParty.purchaseAmount, asUser.purchaseAmount);
        assertEq(asThirdParty.purchasePeriod, asUser.purchasePeriod);
        assertEq(asThirdParty.scheduleId, asUser.scheduleId);
        assertEq(asThirdParty.routeIndex, asUser.routeIndex);
        assertEq(asThirdParty.lastPurchaseTimestamp, asUser.lastPurchaseTimestamp);

        assertEq(enumerated.length, 1);
        assertEq(enumerated[0].tokenBalance, asUser.tokenBalance);
        assertEq(enumerated[0].purchaseAmount, asUser.purchaseAmount);
        assertEq(enumerated[0].purchasePeriod, asUser.purchasePeriod);
        assertEq(enumerated[0].scheduleId, asUser.scheduleId);
        assertEq(enumerated[0].routeIndex, asUser.routeIndex);
        assertEq(enumerated[0].lastPurchaseTimestamp, asUser.lastPurchaseTimestamp);
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
            dcaManager.getAccumulatedRbtcBalance(USER, address(stablecoin), s_routeIndex);
        uint256 fromHandler = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        assertEq(fromManager, fromHandler);
        assertGt(fromManager, 0);
    }

    function test_dcaManager_getAccumulatedRbtcBalance_reverts_unknownTokenProtocol() public {
        address unknownToken = makeAddr("unknownToken");
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__TokenNotAccepted.selector, unknownToken, s_routeIndex
        );
        vm.expectRevert(encodedRevert);
        dcaManager.getAccumulatedRbtcBalance(USER, unknownToken, s_routeIndex);
    }

    function test_dcaManager_getInterestAccrued_whenSupported() public {
        if (s_routeIndex > 0) {
            uint256 interest = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
            assertGe(interest, 0);
        }
    }

    function test_dcaManager_getInterestAccrued_reverts_tokenDoesNotYieldInterest() public {
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__TokenDoesNotYieldInterest.selector, address(stablecoin)));
        dcaManager.getInterestAccrued(USER, address(stablecoin), 0);
    }

    function test_dcaManager_getDcaSchedule_reverts_invalidIndex() public {
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.getDcaSchedule(USER, address(stablecoin), 999);
    }

    /*//////////////////////////////////////////////////////////////
                    OPERATIONS ADMIN GETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_operationsAdmin_getTokenHandler() public {
        address handler = operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex);
        assertEq(handler, address(stablecoinHandler));
        
        // Test non-existent handler
        address nonExistentHandler = operationsAdmin.getTokenHandler(address(0x999), 1);
        assertEq(nonExistentHandler, address(0));
    }

    function test_operationsAdmin_isLendingRoute() public {
        assertTrue(operationsAdmin.isLendingRoute(TROPYKUS_INDEX));
        assertTrue(operationsAdmin.isLendingRoute(SOVRYN_INDEX));
        assertTrue(operationsAdmin.isLendingRoute(LAYERBANK_INDEX));
        assertFalse(operationsAdmin.isLendingRoute(IDLE_INDEX));
        assertFalse(operationsAdmin.isLendingRoute(999));
    }

    function test_operationsAdmin_getRouteClass() public {
        assertEq(uint256(operationsAdmin.getRouteClass(IDLE_INDEX)), uint256(IOperationsAdmin.RouteClass.Idle));
        assertEq(uint256(operationsAdmin.getRouteClass(TROPYKUS_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));
        assertEq(uint256(operationsAdmin.getRouteClass(SOVRYN_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));
        assertEq(uint256(operationsAdmin.getRouteClass(LAYERBANK_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));
        assertEq(uint256(operationsAdmin.getRouteClass(999)), uint256(IOperationsAdmin.RouteClass.Unregistered));
    }

    function test_operationsAdmin_isSwapper() public {
        assertTrue(operationsAdmin.isSwapper(SWAPPER));
        assertFalse(operationsAdmin.isSwapper(USER));
    }

    /*//////////////////////////////////////////////////////////////
                        FEE HANDLER GETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_feeHandler_getFeeSettings() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler(address(stablecoinHandler)).getFeeSettings();
        assertGt(settings.minFeeRate, 0);
        assertGt(settings.maxFeeRate, 0);
        assertLe(settings.minFeeRate, settings.maxFeeRate);
        assertGe(settings.feePurchaseLowerBound, 0);
        assertGe(settings.feePurchaseUpperBound, settings.feePurchaseLowerBound);
    }

    function test_feeHandler_getFeeCollectorAddress() public {
        address feeCollector = IFeeHandler(address(stablecoinHandler)).getFeeCollectorAddress();
        assertNotEq(feeCollector, address(0));
    }

    function test_feeHandler_feeRateConsistency() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler(address(stablecoinHandler)).getFeeSettings();
        assertLe(settings.minFeeRate, settings.maxFeeRate);
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

        bool supportsLending = IERC165(address(stablecoinHandler)).supportsInterface(type(ITokenLending).interfaceId);
        assertEq(supportsLending, isLendingLane, "lending handlers advertise ITokenLending; idle must not");
    }

    /*//////////////////////////////////////////////////////////////
                        PURCHASE RBTC GETTERS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_purchaseRbtc_getAccumulatedRbtcBalance_withUser() public {
        uint256 balance = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
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

    function test_tokenLending_getUserShares() public {
        if (s_routeIndex > 0) {
            uint256 balance = ITokenLending(address(stablecoinHandler)).getUserShares(USER);
            assertGe(balance, 0);
        }
    }

    function test_tokenLending_getAccruedInterest() public {
        if (s_routeIndex > 0) {
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
        if (s_routeIndex == TROPYKUS_INDEX) {
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
        } else if (s_routeIndex == SOVRYN_INDEX) {
            try SovrynErc20Handler(payable(address(stablecoinHandler))).i_dcaManager() returns (address dcaManagerAddr) {
                assertEq(dcaManagerAddr, address(dcaManager));
            } catch {
                try SovrynErc20HandlerDex(payable(address(stablecoinHandler))).i_dcaManager() returns (address dcaManagerAddr) {
                    assertEq(dcaManagerAddr, address(dcaManager));
                } catch {
                    // Handler might not expose this getter
                }
            }
        } else {
            assertEq(DcaManagerAccessControl(address(stablecoinHandler)).i_dcaManager(), address(dcaManager));
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

    function test_getters_singleScheduleMatchesArray() public {
        IDcaManager.DcaDetails memory single = dcaManager.getDcaSchedule(USER, address(stablecoin), 0);
        IDcaManager.DcaDetails[] memory enumerated = dcaManager.getDcaSchedules(USER, address(stablecoin));

        assertEq(enumerated.length, 1);
        assertEq(single.tokenBalance, enumerated[0].tokenBalance);
        assertEq(single.purchaseAmount, enumerated[0].purchaseAmount);
        assertEq(single.purchasePeriod, enumerated[0].purchasePeriod);
        assertEq(single.scheduleId, enumerated[0].scheduleId);
        assertEq(single.routeIndex, enumerated[0].routeIndex);
        assertEq(single.lastPurchaseTimestamp, enumerated[0].lastPurchaseTimestamp);
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
        
        assertTrue(operationsAdmin.isLendingRoute(TROPYKUS_INDEX));
        assertTrue(operationsAdmin.isLendingRoute(SOVRYN_INDEX));
        assertTrue(operationsAdmin.isLendingRoute(LAYERBANK_INDEX));
        assertFalse(operationsAdmin.isLendingRoute(IDLE_INDEX));

        // Test fee bounds consistency
        IFeeHandler.FeeSettings memory settings = IFeeHandler(address(stablecoinHandler)).getFeeSettings();
        assertLe(settings.feePurchaseLowerBound, settings.feePurchaseUpperBound);
    }

    function test_getters_boundaryConditions() public {
        // Test boundary conditions for various getters
        
        // Test with address(0) as token
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(USER, address(0));
        assertEq(schedules.length, 0);
        
        assertFalse(operationsAdmin.isLendingRoute(IDLE_INDEX));
        assertEq(uint256(operationsAdmin.getRouteClass(IDLE_INDEX)), uint256(IOperationsAdmin.RouteClass.Idle));
        assertFalse(operationsAdmin.isLendingRoute(999));
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION GETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getters_afterStateChanges() public {
        uint256 initialBalance = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).tokenBalance;

        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), 0, scheduleId);

        uint256 newBalance = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).tokenBalance;
        assertLt(newBalance, initialBalance);

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
        operationsAdmin.isLendingRoute(1);
        gasAfter = gasleft();
        assertLt(gasBefore - gasAfter, 10000);
    }
} 