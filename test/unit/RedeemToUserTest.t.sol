// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";
import "../Constants.sol";

/**
 * @title RedeemToUserTest
 * @notice R97: a lending exit redeems straight to the user. The user's balance rises by exactly the
 *         cash the handler reports, and no stablecoin moves through the handler on the way.
 * @dev Runs on every lending lane, mock and fork, so the fork lanes exercise live iSUSD
 *      `burn(receiver, …)` and LayerBank `withdraw(…, to)`. Tropykus's `kToken.redeem` has no
 *      receiver and its test-only adapter forwards from the handler, so only the no-hop assertion
 *      skips that lane.
 */
contract RedeemToUserTest is DcaDappTest {
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant TOKEN_WITHDRAWN_TOPIC = keccak256("TokenHandler__TokenWithdrawn(address,address,uint256)");
    bytes32 private constant INTEREST_WITHDRAWN_TOPIC =
        keccak256("LendingHandler__InterestWithdrawn(address,address,uint256)");

    function testWithdrawTokenPaysTheUserStraightFromTheMarket() external onlyLendingLane {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));

        vm.recordLogs();
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 paid = _reportedAmount(logs, TOKEN_WITHDRAWN_TOPIC);
        assertGt(paid, 0);
        assertEq(stablecoin.balanceOf(USER) - userBefore, paid, "user gains exactly the reported cash");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerBefore, "handler balance untouched");
        _assertNoHandlerHop(logs);
    }

    function testWithdrawInterestPaysTheUserStraightFromTheMarket() external onlyLendingLane {
        updateExchangeRate(180 days);
        address[] memory tokens = new address[](1);
        uint256[] memory routeIndexes = new uint256[](1);
        tokens[0] = address(stablecoin);
        routeIndexes[0] = s_routeIndex;
        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));

        vm.recordLogs();
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 paid = _reportedAmount(logs, INTEREST_WITHDRAWN_TOPIC);
        assertGt(paid, 0);
        assertEq(stablecoin.balanceOf(USER) - userBefore, paid, "user gains exactly the reported interest");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerBefore, "handler balance untouched");
        _assertNoHandlerHop(logs);
    }

    function testWithdrawTokenAndInterestPaysBothLegsStraightToTheUser() external onlyLendingLane {
        updateExchangeRate(180 days);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));

        vm.recordLogs();
        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 principal = _reportedAmount(logs, TOKEN_WITHDRAWN_TOPIC);
        uint256 interest = _reportedAmount(logs, INTEREST_WITHDRAWN_TOPIC);
        assertGt(principal, 0);
        assertGt(interest, 0);
        assertEq(stablecoin.balanceOf(USER) - userBefore, principal + interest, "user gains both legs");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerBefore, "handler balance untouched");
        _assertNoHandlerHop(logs);
    }

    /// @dev The one event `topic` the handler emitted, decoded as its `uint256` amount.
    function _reportedAmount(Vm.Log[] memory logs, bytes32 topic) private returns (uint256 amount) {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(stablecoinHandler) && logs[i].topics[0] == topic) {
                amount = abi.decode(logs[i].data, (uint256));
                ++found;
            }
        }
        assertEq(found, 1, "exactly one payout event");
    }

    /// @dev No stablecoin `Transfer` names the handler as sender or recipient.
    function _assertNoHandlerHop(Vm.Log[] memory logs) private {
        if (isTropykus) return;
        address handler = address(stablecoinHandler);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stablecoin) || logs[i].topics[0] != TRANSFER_TOPIC) continue;
            address from = address(uint160(uint256(logs[i].topics[1])));
            address to = address(uint160(uint256(logs[i].topics[2])));
            assertTrue(from != handler && to != handler, "exit cash moved through the handler");
        }
    }
}
