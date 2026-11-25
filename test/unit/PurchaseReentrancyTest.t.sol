// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {MockStablecoin} from "../mocks/MockStablecoin.sol";
import {MockMocProxy} from "../mocks/MockMocProxy.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import {MockWrbtcToken} from "../mocks/MockWrbtcToken.sol";
import {scheduleIdAt, scheduleAt} from "test/utils/ScheduleAt.sol";
import {toBatch} from "test/utils/BatchBuyOne.sol";
import "../Constants.sol";

/// @notice Calls `target` with `data` once, from the venue's `_beforePayout`: after the input is
///         pulled and before the output is paid, while the handler measures its output. Stands in
///         for a token in the swap path that calls out on transfer. A failed callback reverts the
///         swap with its data.
/// @dev Declared after the venue mock in each subclass, so its slots follow the mock's and the
///      subclass code can be etched onto a deployed mock.
abstract contract SwapCallback {
    address private s_callbackTarget;
    bytes private s_callbackData;

    function setSwapCallback(address target, bytes calldata data) external {
        s_callbackTarget = target;
        s_callbackData = data;
    }

    function _runSwapCallback() internal {
        address target = s_callbackTarget;
        if (target == address(0)) return;
        delete s_callbackTarget;
        (bool ok, bytes memory returnData) = target.call(s_callbackData);
        if (!ok) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}

contract CallbackMocProxy is MockMocProxy, SwapCallback {
    constructor() MockMocProxy(address(0)) {}

    function _beforePayout() internal override {
        _runSwapCallback();
    }
}

contract CallbackSwapRouter is MockSwapRouter02, SwapCallback {
    constructor() MockSwapRouter02(MockWrbtcToken(payable(address(0))), 1) {}

    function _beforePayout() internal override {
        _runSwapCallback();
    }
}

/// @notice Holds a schedule and its rBTC claim, and claims when the swap calls it back (the PoC's `Claimant`).
contract CallbackClaimant {
    IDcaManager private immutable i_dcaManager;
    address private immutable i_token;
    uint256 private immutable i_routeIndex;

    constructor(IDcaManager dcaManager, address token, uint256 routeIndex) {
        i_dcaManager = dcaManager;
        i_token = token;
        i_routeIndex = routeIndex;
    }

    function createSchedule(address handler, uint256 deposit, uint256 purchaseAmount, uint256 period) external {
        MockStablecoin(i_token).approve(handler, deposit);
        i_dcaManager.createDcaSchedule(i_token, deposit, purchaseAmount, period, i_routeIndex);
    }

    function claim() external {
        address[] memory tokens = new address[](1);
        tokens[0] = i_token;
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = i_routeIndex;
        i_dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
    }

    receive() external payable {}
}

/**
 * @notice R124 (Kann #18 I-09): both purchase entry points are non-reentrant.
 * @dev `setUp` etches the callback variant of the lane's venue mock onto its address, keeping its
 *      storage. On MoC lanes the handler measures native rBTC, on Dex lanes WRBTC. Fork lanes use
 *      the live venues and skip.
 */
contract PurchaseReentrancyTest is DcaDappTest {
    CallbackClaimant private s_claimant;
    uint64 private s_userScheduleId;
    uint64 private s_claimantScheduleId;

    modifier onlyLocalVenues() {
        if (block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public override {
        super.setUp();
        if (block.chainid != ANVIL_CHAIN_ID) return;

        address venue = _venue();
        vm.etch(venue, isMocSwaps ? address(new CallbackMocProxy()).code : address(new CallbackSwapRouter()).code);

        s_userScheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        s_claimant = new CallbackClaimant(dcaManager, address(stablecoin), s_routeIndex);
        stablecoin.mint(address(s_claimant), AMOUNT_TO_DEPOSIT);
        s_claimant.createSchedule(address(stablecoinHandler), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD);
        s_claimantScheduleId = scheduleIdAt(dcaManager, address(s_claimant), address(stablecoin), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             NESTED PURCHASE
    //////////////////////////////////////////////////////////////*/

    function testNestedSingleHandlerPurchaseInsideSingleHandlerPurchaseReverts() external onlyLocalVenues {
        _assertNestedPurchaseRefused(false, _singleHandlerCall(s_claimantScheduleId));
    }

    function testNestedAcrossHandlersPurchaseInsideSingleHandlerPurchaseReverts() external onlyLocalVenues {
        _assertNestedPurchaseRefused(false, _acrossHandlersCall(s_claimantScheduleId));
    }

    function testNestedSingleHandlerPurchaseInsideAcrossHandlersPurchaseReverts() external onlyLocalVenues {
        _assertNestedPurchaseRefused(true, _singleHandlerCall(s_claimantScheduleId));
    }

    function testNestedAcrossHandlersPurchaseInsideAcrossHandlersPurchaseReverts() external onlyLocalVenues {
        _assertNestedPurchaseRefused(true, _acrossHandlersCall(s_claimantScheduleId));
    }

    /*//////////////////////////////////////////////////////////////
                           MID-PURCHASE CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @dev The claimant's own claim, made while the handler measures its output, would shrink the
    ///      measured output. It reverts the purchase instead, through either entry point.
    function testClaimDuringSingleHandlerPurchaseReverts() external onlyLocalVenues {
        _assertMidPurchaseClaimRefused(false);
    }

    function testClaimDuringAcrossHandlersPurchaseReverts() external onlyLocalVenues {
        _assertMidPurchaseClaimRefused(true);
    }

    /*//////////////////////////////////////////////////////////////
                            ORDINARY PURCHASE
    //////////////////////////////////////////////////////////////*/

    /// @dev The guard is released after each call, so ordinary purchases through both entry points,
    ///      back to back in one transaction context, still succeed.
    function testOrdinaryPurchasesThroughBothEntryPointsSucceed() external onlyLocalVenues {
        vm.startPrank(SWAPPER);
        _callManager(_singleHandlerCall(s_userScheduleId));
        _callManager(_acrossHandlersCall(s_claimantScheduleId));
        vm.stopPrank();

        assertEq(_tokenBalance(USER, SCHEDULE_INDEX), AMOUNT_TO_DEPOSIT - AMOUNT_TO_SPEND);
        assertEq(_tokenBalance(address(s_claimant), 0), AMOUNT_TO_DEPOSIT - AMOUNT_TO_SPEND);
        assertGt(_claim(USER), 0, "single-handler purchase not credited");
        assertGt(_claim(address(s_claimant)), 0, "across-handlers purchase not credited");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The venue calls `nested` on the manager during the outer purchase of USER's schedule.
    function _assertNestedPurchaseRefused(bool outerAcross, bytes memory nested) private {
        address venue = _venue();
        vm.prank(OWNER);
        operationsAdmin.addSwapper(venue);
        SwapCallback(venue).setSwapCallback(address(dcaManager), nested);

        _assertOuterPurchaseRefused(outerAcross);
        assertEq(_tokenBalance(address(s_claimant), 0), AMOUNT_TO_DEPOSIT, "nested purchase debited");
        assertEq(_claim(address(s_claimant)), 0, "nested purchase credited");
    }

    function _assertMidPurchaseClaimRefused(bool outerAcross) private {
        vm.prank(SWAPPER);
        _callManager(_singleHandlerCall(s_claimantScheduleId));
        uint256 claim = _claim(address(s_claimant));
        assertGt(claim, 0, "claimant has no claim to withdraw");
        uint256 claimantRbtc = address(s_claimant).balance;

        SwapCallback(_venue()).setSwapCallback(address(s_claimant), abi.encodeCall(CallbackClaimant.claim, ()));
        _assertOuterPurchaseRefused(outerAcross);

        assertEq(_claim(address(s_claimant)), claim, "claim moved");
        assertEq(address(s_claimant).balance, claimantRbtc, "claim paid during the purchase");
    }

    /// @dev The outer purchase of USER's schedule reverts with the guard error and moves nothing.
    function _assertOuterPurchaseRefused(bool outerAcross) private {
        bytes memory outer = outerAcross ? _acrossHandlersCall(s_userScheduleId) : _singleHandlerCall(s_userScheduleId);
        vm.prank(SWAPPER);
        (bool ok, bytes memory reason) = address(dcaManager).call(outer);
        assertFalse(ok, "outer purchase succeeded");
        assertEq(bytes4(reason), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(_tokenBalance(USER, SCHEDULE_INDEX), AMOUNT_TO_DEPOSIT, "outer purchase debited");
        assertEq(_claim(USER), 0, "outer purchase credited");
    }

    function _singleHandlerCall(uint64 scheduleId) private view returns (bytes memory) {
        return abi.encodeCall(IDcaManager.batchBuyRbtc, (_batch(scheduleId)));
    }

    function _acrossHandlersCall(uint64 scheduleId) private view returns (bytes memory) {
        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](1);
        batches[0] = _batch(scheduleId);
        return abi.encodeCall(IDcaManager.batchBuyRbtcAcrossHandlers, (batches));
    }

    function _batch(uint64 scheduleId) private view returns (IDcaManager.Batch memory) {
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = scheduleId;
        return toBatch(scheduleIds, address(stablecoin), s_routeIndex);
    }

    function _callManager(bytes memory data) private {
        (bool ok, bytes memory reason) = address(dcaManager).call(data);
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _venue() private view returns (address) {
        return isMocSwaps ? address(mocProxy) : dexHelperConfig.getActiveNetworkConfig().swapRouter;
    }

    function _claim(address user) private view returns (uint256) {
        return IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(user);
    }

    function _tokenBalance(address user, uint256 index) private view returns (uint256) {
        return scheduleAt(dcaManager, user, address(stablecoin), index).tokenBalance;
    }
}
