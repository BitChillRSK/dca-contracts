// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {PurchaseUniswap} from "../../src/PurchaseUniswap.sol";
import {FeeHandler} from "../../src/FeeHandler.sol";
import {DcaManagerAccessControl} from "../../src/DcaManagerAccessControl.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {IPurchaseUniswap} from "../../src/interfaces/IPurchaseUniswap.sol";
import {ICoinPairPrice} from "../../src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "../../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockMocOracle} from "../mocks/MockMocOracle.sol";
import {MockWrbtcToken} from "../mocks/MockWrbtcToken.sol";
import {MockStablecoinWithDecimals} from "../mocks/MockStablecoinWithDecimals.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {handlerBatchBuyOne, NO_MIN_RBTC_OUT_RATE} from "test/utils/BatchBuyOne.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../Constants.sol";

/**
 * @notice R43: `amountOutMinimum` must denominate the swap in the stablecoin's own units.
 * @dev The formula before R43 was `amount * percent / btcUsdPrice`, which only lines up when the
 *      stablecoin has the oracle's 18 decimals. USDT0 has 6, so the floor came out 1e12 times too
 *      small — a swap could return a millionth of the rBTC it owed and still clear it.
 */
contract PurchaseUniswapMinOutTest is Test {
    uint256 private constant PERCENT = DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT; // the live swap-time floor
    uint256 private constant SAFETY = DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK; // the wall under it
    uint256 private constant BTC_PRICE_18 = BTC_PRICE * 1e18; // what MockMocOracle publishes
    uint256 private constant USD_NOTIONAL = 25; // $25, the minimum purchase
    uint256 private constant BATCH_USD_NOTIONAL = 1000; // inside the fee bands the harness is built with
    address private constant BUYER = address(0xB0B);
    uint64 private constant SCHEDULE_ID = 1;

    MockWrbtcToken private wrBtcToken;
    MockFloorSwapRouter private swapRouter;
    MockMocOracle private mocOracle;

    function setUp() public {
        wrBtcToken = new MockWrbtcToken();
        swapRouter = new MockFloorSwapRouter(wrBtcToken);
        mocOracle = new MockMocOracle();
        vm.deal(address(swapRouter), 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          THE $1 PEG, IN UNITS
    //////////////////////////////////////////////////////////////*/

    function testMinOutIsTheSameRbtcForTheSameUsdWhateverTheDecimals() public {
        MinOutHarness eighteen = _deployHarness(18);
        MinOutHarness six = _deployHarness(6);

        uint256 expected = (USD_NOTIONAL * 1e18 * PERCENT) / BTC_PRICE_18;

        assertEq(eighteen.getAmountOutMinimum(USD_NOTIONAL * 1e18), expected, "18-decimal min-out");
        assertEq(six.getAmountOutMinimum(USD_NOTIONAL * 1e6), expected, "6-decimal min-out");
    }

    function testSixDecimalMinOutIsNotTheEighteenDecimalFormula() public {
        MinOutHarness six = _deployHarness(6);
        uint256 amountIn = USD_NOTIONAL * 1e6;

        uint256 preR43 = (amountIn * PERCENT) / BTC_PRICE_18; // the formula this PR replaces
        uint256 minOut = six.getAmountOutMinimum(amountIn);

        // 1e12 tighter, up to the rounding the old formula lost by dividing a 6-decimal amount by an 18-decimal price.
        assertApproxEqRel(preR43 * 1e12, minOut, 0.01e18, "6-decimal floor must be ~1e12 tighter");
        assertLt(preR43, minOut / 1e11, "the pre-R43 floor bound essentially nothing for a 6-decimal stablecoin");
    }

    function testMinOutMatchesTheOracleAtEveryStablecoinScale(uint8 tokenDecimals, uint256 usdNotional) public {
        tokenDecimals = uint8(bound(tokenDecimals, 0, 18));
        usdNotional = bound(usdNotional, 1, 1_000_000);

        MinOutHarness harness = _deployHarness(tokenDecimals);
        uint256 amountIn = usdNotional * (10 ** tokenDecimals);

        assertEq(
            harness.getAmountOutMinimum(amountIn),
            (usdNotional * 1e18 * PERCENT) / BTC_PRICE_18,
            "min-out must track the USD notional, not the token's units"
        );
    }

    function testMinOutTracksTheOraclePrice() public {
        MinOutHarness six = _deployHarness(6);
        uint256 amountIn = USD_NOTIONAL * 1e6;
        uint256 minOutAtFiftyThousand = six.getAmountOutMinimum(amountIn);

        mocOracle.setPrice(BTC_PRICE_18 * 2);

        assertEq(six.getAmountOutMinimum(amountIn), minOutAtFiftyThousand / 2, "twice the BTC price, half the rBTC");
    }

    function testMinOutRevertsOnAnInvalidPrice() public {
        MinOutHarness six = _deployHarness(6);
        mocOracle.setInvalidPrice();

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__OutdatedPrice.selector);
        six.getAmountOutMinimum(USD_NOTIONAL * 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                        THE FLOOR AT SWAP TIME
    //////////////////////////////////////////////////////////////*/

    function testSixDecimalSwapRejectsWhatThePreR43FloorWouldHaveAccepted() public {
        MinOutHarness six = _deployHarness(6);
        uint256 amountIn = USD_NOTIONAL * 1e6;
        six.mintStablecoin(amountIn);

        // A router paying the pre-R43 floor is paying a millionth of a millionth of the rBTC owed.
        swapRouter.setAmountOut((amountIn * PERCENT) / BTC_PRICE_18);
        vm.expectRevert(bytes("Too little received"));
        six.purchaseRbtc(amountIn, 0);

        // The fair amount at the oracle price still clears.
        uint256 fair = (USD_NOTIONAL * 1e18 * 1e18) / BTC_PRICE_18;
        swapRouter.setAmountOut(fair);
        assertEq(six.purchaseRbtc(amountIn, 0), fair, "credited amount is the measured WRBTC delta");
    }

    function testSwapCreditsTheMeasuredWrbtcDeltaNotTheFloor() public {
        MinOutHarness eighteen = _deployHarness(18);
        uint256 amountIn = USD_NOTIONAL * 1e18;
        eighteen.mintStablecoin(amountIn);

        uint256 generous = (USD_NOTIONAL * 1e18 * 1e18) / BTC_PRICE_18 * 2;
        swapRouter.setAmountOut(generous);

        assertEq(eighteen.purchaseRbtc(amountIn, 0), generous, "invariant 1: cash is the balance delta");
    }

    /*//////////////////////////////////////////////////////////////
                          UNSUPPORTED TOKENS
    //////////////////////////////////////////////////////////////*/

    function testDeployRevertsOnAStablecoinWithMoreThanEighteenDecimals() public {
        MockStablecoinWithDecimals stablecoin = new MockStablecoinWithDecimals(address(this), 19);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__UnsupportedStablecoinDecimals.selector, uint8(19))
        );
        _deployHarnessFor(stablecoin);
    }

    /*//////////////////////////////////////////////////////////////
    R51 / R66: THE CALLER MINIMUM AND THE GOVERNANCE FLOOR ARE INDEPENDENT
    //////////////////////////////////////////////////////////////*/

    /// @dev The router floor bites on its own: a payout under the oracle-derived minimum is rejected by the
    ///      swap itself, with the caller supplying no minimum at all.
    function testOracleFloorRevertsWithNoCallerMinimum() public {
        MinOutHarness harness = _deployHarness(18);
        uint256 gross = _fundedGross(harness, 18);
        uint256 net = gross - harness.calculateFee(gross);

        swapRouter.setAmountOut(harness.getAmountOutMinimum(net) - 1);

        vm.expectRevert(bytes("Too little received"));
        _buyOne(harness, gross, net, NO_MIN_RBTC_OUT_RATE);
    }

    /// @dev The caller minimum bites on its own: a payout the router floor accepts is still rejected when the
    ///      swapper asked for more than it delivered.
    function testCallerMinimumRevertsAnOutputTheOracleFloorAccepts() public {
        MinOutHarness harness = _deployHarness(18);
        uint256 gross = _fundedGross(harness, 18);
        uint256 net = gross - harness.calculateFee(gross);

        uint256 clearsTheFloor = harness.getAmountOutMinimum(net);
        swapRouter.setAmountOut(clearsTheFloor);

        vm.expectRevert(bytes("Too little received"));
        _buyOne(harness, gross, net, clearsTheFloor + 1);
    }

    /// @dev A caller minimum looser than the governance floor is inert: the swap that clears the floor also
    ///      clears it, and the handler credits the measured WRBTC delta as before.
    function testCallerMinimumBelowTheOracleFloorIsInert() public {
        MinOutHarness harness = _deployHarness(18);
        uint256 gross = _fundedGross(harness, 18);
        uint256 net = gross - harness.calculateFee(gross);

        uint256 floor = harness.getAmountOutMinimum(net);
        swapRouter.setAmountOut(floor);

        _buyOne(harness, gross, net, floor / 2);

        assertEq(harness.getAccumulatedRbtcBalance(BUYER), floor, "the measured delta is still what is credited");
    }

    /// @dev No caller value can loosen the governance floor. The interesting case is not `0` — which the
    ///      test above already covers — but a **nonzero** minimum the payout would satisfy: the swapper says
    ///      "this much is enough for me", the swap delivers exactly that, and the floor still rejects it.
    ///      A caller value is only ever an additional constraint; it can never authorize a worse trade.
    function testCallerMinimumCannotLoosenTheOracleFloor() public {
        MinOutHarness harness = _deployHarness(18);
        uint256 gross = _fundedGross(harness, 18);
        uint256 net = gross - harness.calculateFee(gross);

        uint256 belowTheFloor = harness.getAmountOutMinimum(net) - 1;
        swapRouter.setAmountOut(belowTheFloor);

        // The caller minimum is satisfied by this payout, and is the loosest nonzero value that still is.
        vm.expectRevert(bytes("Too little received"));
        _buyOne(harness, gross, net, belowTheFloor);

        // Even asking for a single wei is not a way under the floor.
        vm.expectRevert(bytes("Too little received"));
        _buyOne(harness, gross, net, 1);

        assertEq(harness.getAccumulatedRbtcBalance(BUYER), 0, "no caller value bought below the floor");
    }

    /// @dev The caller minimum resolves to WRBTC wei whatever the stablecoin's decimals: the same USD
    ///      notional bought at the same price takes the same 18-decimal minimum from a 6-decimal token as
    ///      from an 18-decimal one. R66 made the field a rate per raw stablecoin wei, so the two tokens
    ///      pass *different* rates here — `_buyOne` derives each from the same target rBTC — and the
    ///      requirement they resolve to must still be identical.
    function testCallerMinimumIsWrbtcWeiAtEveryStablecoinScale() public {
        MinOutHarness eighteen = _deployHarness(18);
        MinOutHarness six = _deployHarness(6);

        uint256 grossEighteen = _fundedGross(eighteen, 18);
        uint256 grossSix = _fundedGross(six, 6);
        uint256 netEighteen = grossEighteen - eighteen.calculateFee(grossEighteen);
        uint256 netSix = grossSix - six.calculateFee(grossSix);
        // Same USD notional, so the same net USD and the same oracle-derived floor in WRBTC wei.
        uint256 floor = eighteen.getAmountOutMinimum(netEighteen);
        assertEq(six.getAmountOutMinimum(netSix), floor, "same USD, same floor");

        swapRouter.setAmountOut(floor);
        _buyOne(eighteen, grossEighteen, netEighteen, floor);
        _buyOne(six, grossSix, netSix, floor);

        assertEq(eighteen.getAccumulatedRbtcBalance(BUYER), floor);
        assertEq(six.getAccumulatedRbtcBalance(BUYER), floor, "a 6-decimal input still takes an 18-decimal minimum");

        // A wei more than the 18-decimal payout is out of reach for both, so neither read its own token's units.
        six.mintStablecoin(grossSix); // the first batch spent what it was funded with
        swapRouter.setAmountOut(floor);
        vm.expectRevert(bytes("Too little received"));
        _buyOne(six, grossSix, netSix, floor + 1);
    }

    /// @dev The owner may retighten the live floor without touching the wall, and the swap follows it
    ///      immediately. This is the knob that exists so the wall never has to move.
    function testOwnerCanRetightenTheFloorAndTheSwapFollows() public {
        MinOutHarness harness = _deployHarness(18);
        uint256 gross = _fundedGross(harness, 18);
        uint256 net = gross - harness.calculateFee(gross);

        uint256 looseFloor = harness.getAmountOutMinimum(net);

        harness.setAmountOutMinimumPercent(0.99 ether);
        uint256 tightFloor = harness.getAmountOutMinimum(net);
        assertGt(tightFloor, looseFloor, "raising the percent raises the swap-time floor");

        // A payout the old floor accepted is now rejected, with no caller minimum involved.
        swapRouter.setAmountOut(tightFloor - 1);
        vm.expectRevert(bytes("Too little received"));
        _buyOne(harness, gross, net, NO_MIN_RBTC_OUT_RATE);

        assertEq(
            harness.getAmountOutMinimumSafetyCheck(), SAFETY, "retightening the floor must not move the wall"
        );
    }

    /// @dev The wall is what a compromised swapper cannot get under. Even after the owner widens the floor
    ///      as far as one transaction allows, the swap still cannot pay less than the safety check implies.
    function testTheWallBoundsHowFarOneOwnerTransactionCanWiden() public {
        MinOutHarness harness = _deployHarness(18);
        uint256 gross = _fundedGross(harness, 18);
        uint256 net = gross - harness.calculateFee(gross);

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        harness.setAmountOutMinimumPercent(SAFETY - 1);

        // The loosest reachable floor in one transaction is the wall itself.
        harness.setAmountOutMinimumPercent(SAFETY);
        uint256 wallFloor = harness.getAmountOutMinimum(net);

        swapRouter.setAmountOut(wallFloor - 1);
        vm.expectRevert(bytes("Too little received"));
        _buyOne(harness, gross, net, 1); // a compromised swapper asking for one wei

        swapRouter.setAmountOut(wallFloor);
        _buyOne(harness, gross, net, 1);
        assertEq(harness.getAccumulatedRbtcBalance(BUYER), wallFloor, "the wall is the worst reachable fill");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Fund the handler with a batch's gross spend: `FEE_PURCHASE_LOWER_BOUND` USD in the token's units,
    ///      which sits inside the fee bands the harness is built with.
    function _fundedGross(MinOutHarness harness, uint8 tokenDecimals) private returns (uint256 gross) {
        gross = BATCH_USD_NOTIONAL * (10 ** tokenDecimals);
        harness.mintStablecoin(gross);
    }

    /// @dev One-row batch through the real `PurchaseRbtc` pipeline, so the swap, the fee, and the caller
    ///      minimum are all exercised the way `DcaManager` drives them.
    /// @param net The net stablecoin this batch will spend after the fee, which is what R66's rate is
    ///        applied to. Passed in rather than read from the harness so this helper makes no external
    ///        call before the purchase: a `vm.expectRevert` armed by the caller must land on the batch.
    /// @param targetRbtc The absolute rBTC the caller wants this batch to buy at minimum. R66 made the
    ///        `Batch` field a *rate* (rBTC wei per raw stablecoin wei, 1e18-scaled) applied to `net`, so
    ///        this converts the figure each test reasons in — an amount of WRBTC — into the rate that
    ///        demands exactly it, rounded up so the contract's own round-up cannot land below it.
    ///        `NO_MIN_RBTC_OUT_RATE` (`0`) passes through as the disabled check.
    function _buyOne(MinOutHarness harness, uint256 gross, uint256 net, uint256 targetRbtc) private {
        uint256 rate =
            targetRbtc == 0 ? NO_MIN_RBTC_OUT_RATE : Math.mulDiv(targetRbtc, 1 ether, net, Math.Rounding.Ceil);
        handlerBatchBuyOne(IPurchaseRbtc(address(harness)), BUYER, SCHEDULE_ID, gross, rate);
    }

    function _deployHarness(uint8 tokenDecimals) private returns (MinOutHarness) {
        return _deployHarnessFor(new MockStablecoinWithDecimals(address(this), tokenDecimals));
    }

    function _deployHarnessFor(MockStablecoinWithDecimals stablecoin) private returns (MinOutHarness) {
        // No external call before the `new`, so `vm.expectRevert` in the >18-decimals test lands on the harness.
        address[] memory intermediateTokens = new address[](0);
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;

        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(wrBtcToken)),
            swapRouter02: ISwapRouter02(address(swapRouter)),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(mocOracle))
        });

        // Fee bounds are irrelevant here: the harness calls the swap directly, never the fee-charging batch.
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        return new MinOutHarness(stablecoin, feeSettings, uniswapSettings, PERCENT, SAFETY);
    }
}

/**
 * @notice Holds the purchase token in a base constructor, the way `TokenHandler` does for the real handlers,
 *         so `PurchaseUniswap`'s constructor can already read `_purchaseToken()`.
 */
abstract contract PurchaseTokenBase {
    MockStablecoinWithDecimals internal immutable i_token;

    constructor(MockStablecoinWithDecimals token) {
        i_token = token;
    }
}

contract MinOutHarness is PurchaseTokenBase, PurchaseUniswap {
    constructor(
        MockStablecoinWithDecimals token,
        IFeeHandler.FeeSettings memory feeSettings,
        UniswapSettings memory uniswapSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck
    )
        PurchaseTokenBase(token)
        FeeHandler(address(0xFEE), feeSettings, msg.sender)
        DcaManagerAccessControl(msg.sender)
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}

    function getAmountOutMinimum(uint256 stablecoinAmountToSpend) external view returns (uint256) {
        return _getAmountOutLowerBound(stablecoinAmountToSpend);
    }

    function calculateFee(uint256 grossAmount) external view returns (uint256) {
        return _calculateFee(grossAmount);
    }

    function purchaseRbtc(uint256 stablecoinAmountToSpend, uint256 minRbtcOutRate) external returns (uint256) {
        return _purchaseRbtc(stablecoinAmountToSpend, minRbtcOutRate);
    }

    function mintStablecoin(uint256 amount) external {
        i_token.mint(address(this), amount);
    }

    function _purchaseToken() internal view override returns (IERC20) {
        return IERC20(address(i_token));
    }

    function _retrieveStablecoin(address, uint256) internal pure override returns (uint256) {
        return 0;
    }

    /// @dev The stablecoin is minted straight to the harness, so a batch "retrieves" exactly what it asked for.
    function _batchRetrieveStablecoin(address[] memory, uint256[] memory, uint256 totalStablecoinToRetrieve)
        internal
        pure
        override
        returns (uint256)
    {
        return totalStablecoinToRetrieve;
    }
}

/**
 * @notice A router that pays a settable amount of WRBTC and enforces `amountOutMinimum`, so a test can ask
 *         whether a given payout clears the handler's floor. `MockSwapRouter02` prices its own output, which
 *         cannot express "pay what the pre-R43 formula would have allowed".
 */
contract MockFloorSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    MockWrbtcToken private immutable i_wrBtcToken;
    uint256 private s_amountOut;

    constructor(MockWrbtcToken wrBtcToken) {
        i_wrBtcToken = wrBtcToken;
    }

    function setAmountOut(uint256 amountOut) external {
        s_amountOut = amountOut;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        amountOut = s_amountOut;
        require(params.amountOutMinimum <= amountOut, "Too little received");

        address tokenIn = address(uint160(bytes20(params.path[:20])));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "transferFrom failed");

        i_wrBtcToken.deposit{value: amountOut}(msg.sender);
    }

    receive() external payable {}
}
