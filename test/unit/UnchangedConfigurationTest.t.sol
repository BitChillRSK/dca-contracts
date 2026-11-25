// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseFees} from "../../src/interfaces/IPurchaseFees.sol";
import {IPurchaseUniswap} from "../../src/interfaces/IPurchaseUniswap.sol";
import {MockMocOracle} from "../mocks/MockMocOracle.sol";
import "../Constants.sol";
import {ownableUnauthorized} from "../utils/OzRevert.sol";

/**
 * @notice R123 (Kann #12): the eight configuration setters refuse a write that changes nothing.
 * @dev Authorization and validation run first, so a caller who may not write, or a value that is
 *      invalid, still gets that error even when it equals the stored value. A real change still
 *      succeeds; the setters' own suites cover its event and effect.
 */
contract UnchangedConfigurationTest is DcaDappTest {
    /*//////////////////////////////////////////////////////////////
                               DCA MANAGER
    //////////////////////////////////////////////////////////////*/

    function testSetMinPurchasePeriodRejectsTheCurrentValue() external {
        uint256 current = dcaManager.getMinPurchasePeriod();
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__MinPurchasePeriodUnchanged.selector, current));
        vm.prank(OWNER);
        dcaManager.setMinPurchasePeriod(current);

        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        dcaManager.setMinPurchasePeriod(current);

        vm.prank(OWNER);
        dcaManager.setMinPurchasePeriod(current + 1 days);
        assertEq(dcaManager.getMinPurchasePeriod(), current + 1 days);
    }

    /// @dev A period that is not whole days still gets its validation error.
    function testSetMinPurchasePeriodStillRejectsPartialDays() external {
        uint256 notWholeDays = dcaManager.getMinPurchasePeriod() + 1;
        vm.expectRevert(IDcaManager.DcaManager__PurchasePeriodMustBeWholeDays.selector);
        vm.prank(OWNER);
        dcaManager.setMinPurchasePeriod(notWholeDays);
    }

    function testSetMaxSchedulesPerTokenRejectsTheCurrentValue() external {
        uint256 current = dcaManager.getMaxSchedulesPerToken();
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__MaxSchedulesPerTokenUnchanged.selector, current));
        vm.prank(OWNER);
        dcaManager.setMaxSchedulesPerToken(current);

        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        dcaManager.setMaxSchedulesPerToken(current);
    }

    function testSetTokenMinPurchaseAmountRejectsTheCurrentValue() external {
        address token = address(stablecoin);
        uint256 current = dcaManager.getTokenMinPurchaseAmount(token);
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenMinPurchaseAmountUnchanged.selector, token, current)
        );
        vm.prank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(token, current);

        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        dcaManager.setTokenMinPurchaseAmount(token, current);
    }

    /// @dev An unset token stores zero, and zero is refused as zero, not as unchanged.
    function testSetTokenMinPurchaseAmountRejectsZeroBeforeComparing() external {
        address unsetToken = makeAddr("unsetToken");
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__TokenMinPurchaseAmountMustBeGreaterThanZero.selector, unsetToken
            )
        );
        vm.prank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(unsetToken, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              PURCHASE FEES
    //////////////////////////////////////////////////////////////*/

    function testSetFeeCollectorRejectsTheCurrentCollector() external {
        IPurchaseFees fees = IPurchaseFees(address(stablecoinHandler));
        address current = fees.getFeeCollector();
        vm.expectRevert(abi.encodeWithSelector(IPurchaseFees.PurchaseFees__FeeCollectorUnchanged.selector, current));
        vm.prank(OWNER);
        fees.setFeeCollector(current);

        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        fees.setFeeCollector(current);

        address next = makeAddr("nextCollector");
        vm.prank(OWNER);
        fees.setFeeCollector(next);
        assertEq(fees.getFeeCollector(), next);
    }

    /// @dev A zero collector still gets its validation error.
    function testSetFeeCollectorStillRejectsZero() external {
        vm.expectRevert(IPurchaseFees.PurchaseFees__InvalidFeeCollector.selector);
        vm.prank(OWNER);
        IPurchaseFees(address(stablecoinHandler)).setFeeCollector(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            PURCHASE UNISWAP
    //////////////////////////////////////////////////////////////*/

    function testSetMocOracleRejectsTheCurrentOracle() external onlyDexSwaps {
        IPurchaseUniswap handler = IPurchaseUniswap(address(stablecoinHandler));
        address current = address(handler.getMocOracle());
        vm.expectRevert(abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__OracleUnchanged.selector, current));
        vm.prank(OWNER);
        handler.setMocOracle(current);

        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        handler.setMocOracle(current);

        address next = address(new MockMocOracle());
        vm.prank(OWNER);
        handler.setMocOracle(next);
        assertEq(address(handler.getMocOracle()), next);
    }

    function testSetAmountOutMinimumPercentRejectsTheCurrentValue() external onlyDexSwaps {
        IPurchaseUniswap handler = IPurchaseUniswap(address(stablecoinHandler));
        uint256 current = handler.getAmountOutMinimumPercent();
        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentUnchanged.selector, current)
        );
        vm.prank(OWNER);
        handler.setAmountOutMinimumPercent(current);

        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        handler.setAmountOutMinimumPercent(current);
    }

    function testSetAmountOutMinimumSafetyCheckRejectsTheCurrentValue() external onlyDexSwaps {
        IPurchaseUniswap handler = IPurchaseUniswap(address(stablecoinHandler));
        uint256 current = handler.getAmountOutMinimumSafetyCheck();
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumSafetyCheckUnchanged.selector, current
            )
        );
        vm.prank(OWNER);
        handler.setAmountOutMinimumSafetyCheck(current);

        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        handler.setAmountOutMinimumSafetyCheck(current);
    }

    /// @dev The owner and a swapper are both refused for the active path; a stranger is refused as
    ///      unauthorized. Switching away and back still works.
    function testSetPurchasePathRejectsTheActivePath() external onlyDexSwaps {
        IPurchaseUniswap handler = IPurchaseUniswap(address(stablecoinHandler));
        (address[] memory activeTokens, uint24[] memory activeFees) = _activePath();
        bytes32 activeHash = keccak256(handler.getSwapPath());
        bytes memory unchanged =
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__PurchasePathUnchanged.selector, activeHash);

        vm.expectRevert(unchanged);
        vm.prank(OWNER);
        handler.setPurchasePath(activeTokens, activeFees);

        vm.expectRevert(unchanged);
        vm.prank(SWAPPER);
        handler.setPurchasePath(activeTokens, activeFees);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__UnauthorizedPurchasePathSetter.selector, USER)
        );
        vm.prank(USER);
        handler.setPurchasePath(activeTokens, activeFees);

        address[] memory otherTokens = new address[](1);
        otherTokens[0] = makeAddr("intermediate");
        uint24[] memory otherFees = new uint24[](2);
        otherFees[0] = 100;
        otherFees[1] = 500;
        vm.startPrank(OWNER);
        handler.setPurchasePathAllowed(otherTokens, otherFees, true);
        handler.setPurchasePath(otherTokens, otherFees);
        assertNotEq(keccak256(handler.getSwapPath()), activeHash);
        handler.setPurchasePath(activeTokens, activeFees);
        vm.stopPrank();
        assertEq(keccak256(handler.getSwapPath()), activeHash);
    }

    /// @dev The allowlist check still runs first: a path that is not allowlisted reports that.
    function testSetPurchasePathChecksTheAllowlistFirst() external onlyDexSwaps {
        address[] memory tokens = new address[](1);
        tokens[0] = makeAddr("notAllowlisted");
        uint24[] memory fees = new uint24[](2);
        fees[0] = 100;
        fees[1] = 500;
        bytes32 pathHash = keccak256(abi.encodePacked(address(stablecoin), fees[0], tokens[0], fees[1], address(wrbtc)));
        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__PurchasePathNotAllowed.selector, pathHash)
        );
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(tokens, fees);
    }

    /// @dev Decodes the active path `stablecoin, fee, (token, fee)*, wrbtc` back into its arrays.
    function _activePath() private view returns (address[] memory tokens, uint24[] memory fees) {
        bytes memory path = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        uint256 hops = (path.length - 20) / 23;
        tokens = new address[](hops - 1);
        fees = new uint24[](hops);
        for (uint256 i; i < hops; ++i) {
            uint256 offset = 20 + i * 23;
            fees[i] = uint24(bytes3(_slice(path, offset, 3)));
            if (i + 1 < hops) tokens[i] = address(bytes20(_slice(path, offset + 3, 20)));
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 length) private pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = data[start + i];
        }
    }
}
