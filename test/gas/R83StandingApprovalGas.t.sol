// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IdleErc20HandlerDex} from "src/idle/IdleErc20HandlerDex.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IUniswapV3SwapRouter} from "src/interfaces/IUniswapV3SwapRouter.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {handlerBatchBuyOne} from "test/utils/BatchBuyOne.sol";
import "test/Constants.sol";

/**
 * @title R83StandingApprovalGas
 * @notice Pins that neither the lending deposit nor the Dex purchase writes an allowance slot any more,
 *         and records the Foundry cost of the round trip they no longer pay.
 * @dev Reproduce on both profiles:
 *
 *          forge test --match-path test/gas/R83StandingApprovalGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R83StandingApprovalGas.t.sol -vv
 *
 *      The write counts are the durable evidence; the gas figures are same-build Cancun regression pins.
 *      Each deposit arm is measured in its own transaction, so neither pays the other's cold access —
 *      see the note on the standing-approval test. Default profile: 139,362 pre-R83 against 115,882
 *      standing, **−23,480**. Deploy profile: 136,381 against 113,501, **−22,880**. Recovering a
 *      cleared allowance costs 3,934 / 3,645 for one spender, once per clearing rather than per deposit.
 *
 *      A `gasleft()` delta is execution before refunds, so that is what Cancun charges up front, and
 *      roughly 19,900 of it comes back as a refund there — which is why the removed round trip never
 *      registered as an Ethereum problem. Rootstock refunds less and charges more for the same two
 *      writes: `SET` 20,000 + `CLEAR` 5,000 − `REFUND` 15,000 = 10,000 net, plus a flat 700 for the
 *      `approve` call, against a standing approval's zero writes on a token that preserves `max`
 *      (USDRIF) or one `RESET` of 5,000 on a token that decrements it (DOC and USDT0). Which token does
 *      which is a live fact, measured by
 *      `test/mainnet-debug/standing-approvals/StandingApprovalProbe.t.sol`, not an assumption.
 */
contract R83StandingApprovalGasTest is Test {
    address private constant USER = address(0xB0B);
    address private constant FEE_COLLECTOR = address(0xFEE);
    uint256 private constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 private constant PURCHASE_AMOUNT = 100 ether;
    uint64 private constant SCHEDULE_ID = 1;

    MockStablecoin private s_stablecoin;
    MockIsusdToken private s_iSusd;
    MockMocProxy private s_mocProxy;
    SovrynDocHandlerMoc private s_lendingHandler;
    /// @dev The pre-R83 deposit shape, the arm the saving is measured against. It needs its own iToken:
    ///      sharing an allowance slot would let EIP-2200 net metering price its write at 100 gas.
    MockIsusdToken private s_preR83ISusd;
    PreR83SovrynDocHandlerMoc private s_preR83Handler;

    MockWrbtcToken private s_wrBtc;
    MockSwapRouter02 private s_router;
    MockMocOracle private s_oracle;
    IdleErc20HandlerDex private s_dexHandler;

    /// @dev Both handlers take this test contract as their DcaManager so the `onlyDcaManager` entry
    ///      points are callable directly and the measurement is of the handler, not of the manager.
    function setUp() public {
        s_stablecoin = new MockStablecoin(address(this));
        s_iSusd = new MockIsusdToken(address(s_stablecoin));
        s_mocProxy = new MockMocProxy(address(s_stablecoin));
        vm.deal(address(s_mocProxy), 100 ether);

        s_lendingHandler = new SovrynDocHandlerMoc(
            address(this),
            address(s_stablecoin),
            address(s_iSusd),
            FEE_COLLECTOR,
            address(s_mocProxy),
            _feeSettings(),
            address(this)
        );

        s_preR83ISusd = new MockIsusdToken(address(s_stablecoin));
        s_preR83Handler = new PreR83SovrynDocHandlerMoc(
            address(this),
            address(s_stablecoin),
            address(s_preR83ISusd),
            FEE_COLLECTOR,
            address(s_mocProxy),
            _feeSettings(),
            address(this)
        );
        // Undo the standing grant the leaf still makes in its constructor, so this arm starts from the
        // zero allowance the pre-R83 code left behind after every deposit.
        vm.prank(address(s_preR83Handler));
        s_stablecoin.approve(address(s_preR83ISusd), 0);

        s_wrBtc = new MockWrbtcToken();
        s_router = new MockSwapRouter02(s_wrBtc, BTC_PRICE);
        s_oracle = new MockMocOracle();
        vm.deal(address(s_router), 1000 ether);

        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        s_dexHandler = new IdleErc20HandlerDex(
            address(this),
            address(s_stablecoin),
            IPurchaseUniswap.UniswapSettings({
                wrBtcToken: IWRBTC(address(s_wrBtc)),
                swapRouter02: IUniswapV3SwapRouter(address(s_router)),
                swapIntermediateTokens: new address[](0),
                swapPoolFeeRates: poolFeeRates,
                mocOracle: ICoinPairPrice(address(s_oracle))
            }),
            FEE_COLLECTOR,
            _feeSettings(),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            address(this)
        );

        s_stablecoin.mint(USER, 100 * DEPOSIT_AMOUNT);
        s_stablecoin.mint(address(s_iSusd), 100 * DEPOSIT_AMOUNT);
        s_stablecoin.mint(address(s_preR83ISusd), 100 * DEPOSIT_AMOUNT);
        vm.startPrank(USER);
        s_stablecoin.approve(address(s_lendingHandler), type(uint256).max);
        s_stablecoin.approve(address(s_preR83Handler), type(uint256).max);
        s_stablecoin.approve(address(s_dexHandler), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice The lending deposit against the standing approval: no allowance slot is written.
     * @dev One arm per transaction, compared across the two. Both arms share the stablecoin contract and
     *      the depositor's balance slot, so in a combined test whichever ran first paid the cold access
     *      and the first dirty write for both, moving the delta by thousands of gas on call order alone.
     */
    function test_lendingDeposit_standingApproval_writesNoAllowanceSlot() public {
        bytes32 allowanceSlot = _allowanceSlot(address(s_lendingHandler), address(s_iSusd));
        (uint256 gasUsed, uint256 writes) = _measureDeposit(s_lendingHandler, allowanceSlot);

        console2.log("R83 lending deposit, standing approval (Foundry gas)", gasUsed);
        assertEq(writes, 0, "the deposit still writes the allowance slot");
        assertGt(s_lendingHandler.getUserShares(USER), 0);
    }

    /**
     * @notice The pre-R83 deposit shape: the allowance slot written twice, on every deposit, for good.
     * @dev The arm the saving is measured against, reconstructed in a subclass rather than quoted from
     *      an earlier branch, so it is re-derived on every run and cannot drift. It makes the same two
     *      writes and the same `approve` call as the code R83 replaced; only their order differs, which
     *      the Cancun schedule does not price.
     */
    function test_lendingDeposit_preR83Shape_writesTheAllowanceSlotTwice() public {
        bytes32 allowanceSlot = _allowanceSlot(address(s_preR83Handler), address(s_preR83ISusd));
        (uint256 gasUsed, uint256 writes) = _measureDeposit(s_preR83Handler, allowanceSlot);

        console2.log("R83 lending deposit, pre-R83 exact approval (Foundry gas)", gasUsed);
        assertEq(writes, 2, "the pre-R83 shape wrote the slot on the grant and again on the pull");
        assertEq(
            s_stablecoin.allowance(address(s_preR83Handler), address(s_preR83ISusd)),
            0,
            "the pull should have spent the exact approval back to zero"
        );
        assertGt(s_preR83Handler.getUserShares(USER), 0);
    }

    /**
     * @notice Restoring a cleared allowance writes the spender's slot once.
     * @dev Bounds what recovery costs and pins that it is off the deposit path: the arm above shows the
     *      deposit writing nothing, so a handler pays this at most once per clearing, not per deposit.
     */
    function test_restoreStandingApprovals_writesTheAllowanceSlotOnce() public {
        bytes32 allowanceSlot = _allowanceSlot(address(s_lendingHandler), address(s_iSusd));
        vm.prank(address(s_lendingHandler));
        s_stablecoin.approve(address(s_iSusd), 0);

        vm.startStateDiffRecording();
        uint256 gasBefore = gasleft();
        s_lendingHandler.restoreStandingApprovals();
        uint256 gasUsed = gasBefore - gasleft();
        uint256 writes = _slotWrites(vm.stopAndReturnStateDiff(), address(s_stablecoin), allowanceSlot);

        console2.log("R83 restoreStandingApprovals, one spender (Foundry gas)", gasUsed);
        assertEq(writes, 1, "the restore should write the slot once");
        assertEq(
            s_stablecoin.allowance(address(s_lendingHandler), address(s_iSusd)),
            type(uint256).max,
            "the restore should leave the standing allowance at max"
        );
    }

    /// @notice The Dex batch purchase neither reads nor writes the router allowance slot.
    function test_dexPurchase_writesNoAllowanceSlot() public {
        bytes32 allowanceSlot = _allowanceSlot(address(s_dexHandler), address(s_router));
        s_dexHandler.depositToken(USER, DEPOSIT_AMOUNT);

        vm.startStateDiffRecording();
        uint256 gasBefore = gasleft();
        handlerBatchBuyOne(IPurchaseRbtc(address(s_dexHandler)), USER, SCHEDULE_ID, PURCHASE_AMOUNT);
        uint256 purchaseGas = gasBefore - gasleft();
        uint256 writes = _slotWrites(vm.stopAndReturnStateDiff(), address(s_stablecoin), allowanceSlot);

        console2.log("R83 Dex batch purchase (Foundry gas)", purchaseGas);
        assertEq(writes, 0, "the purchase still writes the router allowance slot");
        assertEq(
            s_stablecoin.allowance(address(s_dexHandler), address(s_router)),
            type(uint256).max,
            "the standing approval should survive a purchase on a token that preserves it"
        );
        assertGt(s_dexHandler.getAccumulatedRbtcBalance(USER), 0);
    }

    function _measureDeposit(SovrynDocHandlerMoc handler, bytes32 allowanceSlot)
        private
        returns (uint256 gasUsed, uint256 writes)
    {
        vm.startStateDiffRecording();
        uint256 gasBefore = gasleft();
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        gasUsed = gasBefore - gasleft();
        writes = _slotWrites(vm.stopAndReturnStateDiff(), address(s_stablecoin), allowanceSlot);
    }

    /// @dev Found by writing the slot rather than by hardcoding an inherited layout offset.
    function _allowanceSlot(address owner, address spender) private returns (bytes32 slot) {
        uint256 snap = vm.snapshot();
        vm.startStateDiffRecording();
        vm.prank(owner);
        s_stablecoin.approve(spender, 12345);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        vm.revertTo(snap);

        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != address(s_stablecoin)) continue;
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                if (storageAccesses[j].isWrite) return storageAccesses[j].slot;
            }
        }
        revert("allowance slot not found");
    }

    function _slotWrites(Vm.AccountAccess[] memory accesses, address account, bytes32 slot)
        private
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != account) continue;
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                if (storageAccesses[j].isWrite && storageAccesses[j].slot == slot) ++count;
            }
        }
    }

    function _feeSettings() private pure returns (IFeeHandler.FeeSettings memory) {
        return IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
    }
}

/**
 * @title PreR83SovrynDocHandlerMoc
 * @notice The deposit shape R83 replaced, kept only so the gas test has a live baseline.
 * @dev Approves the exact deposit and lets the protocol pull spend it back to zero: one `SET` on the
 *      grant and one `CLEAR` on the pull, on every deposit. Never deployed.
 */
contract PreR83SovrynDocHandlerMoc is SovrynDocHandlerMoc {
    using SafeERC20 for IERC20;

    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address iSusdTokenAddress,
        address feeCollector,
        address mocProxyAddress,
        IFeeHandler.FeeSettings memory feeSettings,
        address initialOwner
    )
        SovrynDocHandlerMoc(
            dcaManagerAddress,
            docTokenAddress,
            iSusdTokenAddress,
            feeCollector,
            mocProxyAddress,
            feeSettings,
            initialOwner
        )
    {}

    function _depositToken(address user, uint256 depositAmount) internal override {
        i_stableToken.forceApprove(_lendingSpender(), depositAmount);
        super._depositToken(user, depositAmount);
    }
}
