// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMocProxy} from "src/interfaces/IMocProxy.sol";
import {DOC_HOLDER} from "../../Constants.sol";

/**
 * @title MocRedeemFreeDocProbe
 * @notice R71 evidence: live MoC `redeemFreeDoc` alone redeems DOC for rBTC. No prior
 *         `redeemDocRequest` is required for free DOC. BitChill purchases therefore drop the
 *         settlement-queue hop.
 * @dev Excluded from `make check` / `make fork-*` / CI (`test/mainnet-debug/`).
 *      Run: `make probe-moc-redeem-free-doc` (needs `RSK_MAINNET_RPC_URL`).
 *      MoC rejects high tx gas prices; pin under its live `maxGasPrice()`
 *      (30_300_000 wei = 0.0303 gwei on 2026-09-07; RSK network price was 0.026 gwei).
 */
contract MocRedeemFreeDocProbe is Test {
    address constant DOC = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
    address constant MOC_PROXY = 0xf773B590aF754D597770937Fa8ea7AbDf2668370;
    uint256 constant REDEEM_AMOUNT = 10 ether;
    /// @dev RSK gas prices are ~1000x below Ethereum norms and MoC caps them; Anvil fork defaults
    ///      can exceed the cap. 20_000_000 wei is 0.02 gwei, under the 0.0303 gwei observed on
    ///      2026-09-07. Re-read `maxGasPrice()` on the MoC proxy if this ever reverts.
    uint256 constant MOC_SAFE_TX_GAS_PRICE = 20_000_000; // 0.02 gwei

    function test_redeemFreeDocAlonePaysRbtcWithoutPriorRequest() external {
        vm.txGasPrice(MOC_SAFE_TX_GAS_PRICE);

        uint256 docBefore = IERC20(DOC).balanceOf(DOC_HOLDER);
        require(docBefore >= REDEEM_AMOUNT, "DOC_HOLDER needs DOC on this tip");

        uint256 rbtcBefore = DOC_HOLDER.balance;

        vm.startPrank(DOC_HOLDER);
        IERC20(DOC).approve(MOC_PROXY, REDEEM_AMOUNT);
        // No redeemDocRequest — free DOC redeems immediately.
        IMocProxy(MOC_PROXY).redeemFreeDoc(REDEEM_AMOUNT);
        vm.stopPrank();

        uint256 docSpent = docBefore - IERC20(DOC).balanceOf(DOC_HOLDER);
        uint256 rbtcReceived = DOC_HOLDER.balance - rbtcBefore;

        console2.log("block", block.number);
        console2.log("txGasPrice", tx.gasprice);
        console2.log("DOC spent", docSpent);
        console2.log("rBTC received", rbtcReceived);

        assertEq(docSpent, REDEEM_AMOUNT, "DOC not pulled for free redeem");
        assertGt(rbtcReceived, 0, "redeemFreeDoc alone must pay rBTC");
    }

    function test_redeemDocRequestDoesNotPayImmediateRbtc() external {
        vm.txGasPrice(MOC_SAFE_TX_GAS_PRICE);

        uint256 docBefore = IERC20(DOC).balanceOf(DOC_HOLDER);
        require(docBefore >= REDEEM_AMOUNT, "DOC_HOLDER needs DOC on this tip");

        uint256 rbtcBefore = DOC_HOLDER.balance;

        vm.startPrank(DOC_HOLDER);
        // Settlement-queue path: may enqueue or no-op depending on MoC state; it must not
        // be required before redeemFreeDoc, and it must not itself pay immediate rBTC here.
        try IMocProxy(MOC_PROXY).redeemDocRequest(REDEEM_AMOUNT) {
            console2.log("redeemDocRequest: succeeded (queue path)");
        } catch (bytes memory reason) {
            console2.log("redeemDocRequest: reverted (acceptable for this probe)");
            console2.logBytes(reason);
        }
        vm.stopPrank();

        uint256 rbtcDelta = DOC_HOLDER.balance - rbtcBefore;
        uint256 docDelta = docBefore - IERC20(DOC).balanceOf(DOC_HOLDER);

        console2.log("block", block.number);
        console2.log("DOC delta after request", docDelta);
        console2.log("rBTC delta after request", rbtcDelta);

        assertEq(rbtcDelta, 0, "redeemDocRequest must not pay immediate rBTC");
    }
}
