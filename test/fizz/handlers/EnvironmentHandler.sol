// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {Actor} from "../Actor.sol";

/// @notice Moves the external world the handlers depend on: venue prices, oracle state, lending rates,
///         stray donations, and the clock.
/// @dev Bounds keep each venue inside behaviour its real counterpart can show. LayerBank's liquidity index
///      only rises (Aave v3); a Sovryn iToken price can fall on realized loan losses; the Uniswap pool and
///      the MoC oracle move independently so the oracle floor can bind.
///      Every handler is wrapped in `snapshotBefore` / `snapshotAfter` and the environment class of
///      common checks (plan §8: SP-40, SP-44, SP-45, SP-46, SP-47, SP-66; donations run SP-04 instead of SP-66).
abstract contract EnvironmentHandler is Properties {
    uint256 internal constant MIN_BTC_PRICE_USD = 40_000;
    uint256 internal constant MAX_BTC_PRICE_USD = 60_000;

    /// @dev Pool price for the Uniswap mock (stablecoin units per rBTC, whole numbers).
    function env_setDexPrice(uint256 price) public {
        price = clampBetween(price, MIN_BTC_PRICE_USD, MAX_BTC_PRICE_USD);
        snapshotBefore();
        swapRouter.setFixedAmountOut(price);
        dexRouterPrice = price;
        _afterEnv();
    }

    function env_setOraclePrice(bool alt, uint256 price) public {
        price = clampBetween(price, MIN_BTC_PRICE_USD, MAX_BTC_PRICE_USD) * 1e18;
        snapshotBefore();
        (alt ? mocOracleAlt : mocOracle).setPrice(price);
        _afterEnv();
    }

    function env_setOracleValid(bool alt, bool valid) public {
        MockMocOracle oracle = alt ? mocOracleAlt : mocOracle;
        snapshotBefore();
        if (valid) oracle.setValidPrice();
        else oracle.setInvalidPrice();
        _afterEnv();
    }

    /// @dev Up to ±20% per call, kept within [0.5, 3] stablecoin per iToken, so loss paths
    ///      (rows clamped to zero share value, redeems paying nothing) are reachable in one sequence.
    function env_moveSovrynPrice(uint256 bps, bool up) public {
        bps = clampLte(bps, 2_000);
        uint256 price = sovrynIToken.tokenPrice();
        uint256 delta = price * bps / 10_000;
        uint256 next = up ? price + delta : price - delta;
        if (next < 0.5 ether || next > 3 ether) return;
        snapshotBefore();
        sovrynIToken.setTokenPrice(next);
        _ghostSovrynPriceMoved(price, next);
        _afterEnv();
    }

    function env_setSovrynExitFee(uint256 bps) public {
        snapshotBefore();
        sovrynIToken.setExitFeeBps(clampLte(bps, 100));
        _afterEnv();
    }

    /// @dev Raises one LayerBank market's normalized income by up to 2%. Freezes its time-based accrual
    ///      at the new value until the next bump, as the mock's override does.
    function env_bumpLayerBankIndex(bool usdrifMarket, uint256 bps) public {
        bps = clampLte(bps, 200);
        MockLayerBankAToken aToken = usdrifMarket ? layerBankATokenUsdrif : layerBankATokenDoc;
        snapshotBefore();
        uint256 index = aToken.getNormalizedIncome();
        aToken.setNormalizedIncome(index + index * bps / 10_000, true);
        _afterEnv();
    }

    /// @dev Stray stablecoin sent straight to a handler: credited to no one, must not change any book.
    function env_donateStablecoin(uint256 routeSeed, uint256 amount) public {
        Route memory r = _route(routeSeed);
        uint256 balance = MockStablecoin(r.token).balanceOf(actor);
        if (balance == 0) return;
        amount = clampBetween(amount, 1, balance);
        snapshotBefore();
        vm.prank(actor);
        MockStablecoin(r.token).transfer(r.handler, amount);
        snapshotAfter();
        _ghostDonateStable(r.handler, amount);
        _afterDonation();
    }

    /// @dev Stray native rBTC forced into a handler (bypassing `receive`).
    function env_donateETH(uint256 routeSeed, uint256 amount) public {
        if (actor.balance == 0) return;
        amount = clampBetween(amount, 1, actor.balance);
        address h = _route(routeSeed).handler;
        snapshotBefore();
        Actor(payable(actor)).forceSendETH(h, amount);
        snapshotAfter();
        _ghostDonateEth(h, amount);
        _afterDonation();
    }

    /// @dev H9: USDT0 minted straight to the shared router. Feeds SP-72 when a Dex handler uses path 1.
    function env_donateIntermediateToRouter(uint256 amount) public {
        amount = clampBetween(amount, 1, 1e24);
        snapshotBefore();
        usdt0.mint(address(swapRouter), amount);
        _afterEnv();
    }

    /// @dev Jump to a later UTC midnight plus an offset, so cadence boundaries are hit exactly.
    function env_skipDays(uint256 days_, uint256 secondsIntoDay) public {
        days_ = clampBetween(days_, 1, 30);
        secondsIntoDay = clampLt(secondsIntoDay, 1 days);
        uint256 target = block.timestamp - (block.timestamp % 1 days) + days_ * 1 days + secondsIntoDay;
        snapshotBefore();
        skipTime(target - block.timestamp);
        _afterEnv();
    }

    function env_skipBlocks(uint256 blocks) public {
        blocks = clampBetween(blocks, 1, 10);
        snapshotBefore();
        skipBlocks(blocks);
        _afterEnv();
    }

    // ―――――――――――――――――――――――― Helpers ―――――――――――――――――――――――――――

    function _afterEnv() internal {
        snapshotAfter();
        _postCommon(_newCtx(OP_ENV, address(0)));
    }

    function _afterDonation() internal {
        OpCtx memory ctx = _newCtx(OP_DONATION, actor);
        SchedPair[] memory sp = _schedPairs();
        property_donationMovesNoBook(sp);
        _postCommonWith(ctx, sp);
    }
}
