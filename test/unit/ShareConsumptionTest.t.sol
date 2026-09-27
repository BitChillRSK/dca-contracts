// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {ILendingHandler} from "../../src/interfaces/ILendingHandler.sol";
import {LayerBankErc20Handler} from "../../src/layerbank/LayerBankErc20Handler.sol";
import "../Constants.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @title ShareConsumptionTest
 * @notice Every successful lending redeem must decrease the external receipt-share balance by
 *         exactly the virtual debit. Local mocks and live fork lanes share this assertion.
 */
contract ShareConsumptionTest is DcaDappTest {
    uint256 constant WITHDRAWAL_AMOUNT = AMOUNT_TO_DEPOSIT / 4;

    function setUp() public override {
        super.setUp();
    }

    modifier onlyLending() {
        if (s_routeIndex == IDLE_INDEX) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_withdraw_externalShareDeltaEqualsVirtualDebit() public onlyLending {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 bookBefore = ILendingHandler(address(stablecoinHandler)).getUserShares(USER);
        uint256 receiptBefore = _receiptShares();

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, WITHDRAWAL_AMOUNT);

        uint256 bookDebit = bookBefore - ILendingHandler(address(stablecoinHandler)).getUserShares(USER);
        uint256 receiptDebit = receiptBefore - _receiptShares();
        assertGt(bookDebit, 0);
        assertEq(bookDebit, receiptDebit);
    }

    function test_singleSchedulePurchase_externalShareDeltaEqualsVirtualDebit() public onlyLending {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 bookBefore = ILendingHandler(address(stablecoinHandler)).getUserShares(USER);
        uint256 receiptBefore = _receiptShares();

        buyRbtcOne(scheduleId);

        uint256 bookDebit = bookBefore - ILendingHandler(address(stablecoinHandler)).getUserShares(USER);
        uint256 receiptDebit = receiptBefore - _receiptShares();
        assertGt(bookDebit, 0);
        assertEq(bookDebit, receiptDebit);
    }

    function _receiptShares() private returns (uint256) {
        if (s_routeIndex == LAYERBANK_INDEX) {
            // DcaDappTest leaves `shareToken` unset for LayerBank (aToken is not IShareToken).
            return LayerBankErc20Handler(payable(address(stablecoinHandler))).i_aToken()
                .scaledBalanceOf(address(stablecoinHandler));
        }
        return shareToken.balanceOf(address(stablecoinHandler));
    }
}
