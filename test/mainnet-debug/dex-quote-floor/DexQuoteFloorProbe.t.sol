// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";

interface IV3SwapRouterLike {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title DexQuoteFloorProbe
 * @notice R51 relaunch evidence: for every shipped Dex path, what the live pool actually pays for the
 *         batch's post-BitChill-fee input, and how that compares with the oracle-derived governance floor.
 * @dev The shipped Dex set is LayerBank USDRIF and LayerBank USDT0. DOC is deliberately not in it — DOC buys
 *      rBTC through MoC redemption only — and its row below is kept as evidence about a legacy path that must
 *      never be deployed, not as a candidate awaiting calibration.
 * @dev Run with `make probe-dex-quote-floor`, which pins `FORK_BLOCK_DEX_QUOTE` so the table reproduces.
 *      This is the first single-block observation the R51 spec gates the contracts PR on. It is *not* the
 *      multi-block calibration that gates Dex relaunch: that extends this table across recent blocks and
 *      the supported batch-size envelope before governance picks a durable per-handler backstop.
 *
 *      There is no Uniswap Quoter deployment on Rootstock, so each row quotes by executing the swap through
 *      the live SwapRouter02 with `amountOutMinimum = 0` inside a frame that always reverts. The measured
 *      WRBTC delta comes back as revert data, so the pool is priced by a real swap of the real size and no
 *      row moves the pool for the next one.
 */
contract DexQuoteFloorProbe is Test {
    /*//////////////////////////////////////////////////////////////
                          LIVE ROOTSTOCK MAINNET
    //////////////////////////////////////////////////////////////*/
    address internal constant SWAP_ROUTER_02 = 0x0B14ff67f0014046b4b99057Aec4509640b3947A;
    address internal constant WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address internal constant MOC_ORACLE = 0xe2927A0620b82A66D67F678FC9b826B0E01B1bFD;

    address internal constant DOC = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
    address internal constant USDRIF = 0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant RUSDT = 0xef213441A85dF4d7ACbDaE0Cf78004e1E486bB96; // DOC hop
    /// @dev The deploy config calls this "rUSDT", but the address is 6-decimal `USDT`, a different token
    ///      from the 18-decimal `rUSDT` the DOC path hops through. Recorded here as deployed; renaming or
    ///      re-approving a path is R52's surface, not R51's.
    address internal constant USDT_USDRIF_HOP = 0xAf368c91793CB22739386DFCbBb2F1A9e4bCBeBf;

    /// @dev The deploy defaults R51 leaves untouched: 99.5% of the oracle-implied rBTC, $1 peg, 18-decimal oracle.
    uint256 internal constant AMOUNT_OUT_MINIMUM_PERCENT = 0.995 ether;
    uint256 internal constant ORACLE_DECIMALS = 18;
    /// @dev Production fee is a flat 1% (`MIN_FEE_RATE == MAX_FEE_RATE_PRODUCTION`).
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant BPS_DIVISOR = 10_000;

    SwapProbe internal probe;
    uint256 internal btcUsdPrice;

    function setUp() public {
        if (WRBTC.code.length == 0) vm.skip(true); // not on a Rootstock fork
        probe = new SwapProbe();

        (uint256 price, bool isValid,) = ICoinPairPrice(MOC_ORACLE).getPriceInfo();
        assertTrue(isValid, "MoC oracle price is not valid at this block");
        btcUsdPrice = price;

        console2.log("block", block.number);
        console2.log("timestamp", block.timestamp);
        console2.log("MoC BTC/USD (18dp)", btcUsdPrice);
    }

    /*//////////////////////////////////////////////////////////////
                             THE SHIPPED PATHS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev NOT a shipped route, and never to become one: **DOC buys rBTC only through MoC redemption.**
     *      DOC may appear in a Uniswap path solely as an intermediate hop, never as a Dex handler's input
     *      token. The DOC Dex handler is development-era legacy kept for tests, like Tropykus after R37.
     *      This row is measured to document what the abandoned path is actually worth — evidence for
     *      deleting it, not a route awaiting calibration. Path: DOC -0.05%-> rUSDT -0.05%-> WRBTC.
     */
    function test_quoteVsFloor_legacyDocDexPath_neverToBeDeployed() public {
        bytes memory path = abi.encodePacked(DOC, uint24(500), RUSDT, uint24(500), WRBTC);
        _table("LEGACY DOC dex path (never deployed; MoC is DOC's only venue)", DOC, 18, path, "DOC-500-rUSDT-500-WRBTC");
    }

    /// @dev LayerBank USDRIF: USDRIF -0.05%-> USDT -0.30%-> WRBTC. 0.35% in fee tiers.
    function test_quoteVsFloor_layerBankUsdrif() public {
        bytes memory path = abi.encodePacked(USDRIF, uint24(500), USDT_USDRIF_HOP, uint24(3000), WRBTC);
        _table("LayerBank USDRIF", USDRIF, 18, path, "USDRIF-500-USDT(6dp)-3000-WRBTC");
    }

    /// @dev LayerBank USDT0: direct USDT0 -0.30%-> WRBTC, 6 decimals in, 18-decimal WRBTC out.
    function test_quoteVsFloor_layerBankUsdt0() public {
        bytes memory path = abi.encodePacked(USDT0, uint24(3000), WRBTC);
        _table("LayerBank USDT0", USDT0, 6, path, "USDT0-3000-WRBTC");
    }

    /*//////////////////////////////////////////////////////////////
                                 THE TABLE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Three reproducible input points per route: the token's deployed minimum purchase and its fee
     *      lower and upper bounds, in the token's own units. Each row is one batch's aggregate gross spend.
     */
    function _table(
        string memory label,
        address tokenIn,
        uint8 tokenDecimals,
        bytes memory path,
        string memory pathLabel
    ) private {
        uint256 unit = 10 ** tokenDecimals;
        console2.log("=====================================================");
        console2.log(label);
        console2.log(pathLabel);

        _row(tokenIn, tokenDecimals, path, 25 * unit); // deployed minimum purchase
        _row(tokenIn, tokenDecimals, path, 1_000 * unit); // fee lower bound
        _row(tokenIn, tokenDecimals, path, 100_000 * unit); // fee upper bound
    }

    function _row(address tokenIn, uint8 tokenDecimals, bytes memory path, uint256 grossIn) private {
        uint256 netIn = grossIn - (grossIn * FEE_BPS / BPS_DIVISOR); // what the swap actually spends
        uint256 floor = _governanceFloor(netIn, tokenDecimals);

        console2.log("-- gross in (token units)", grossIn);
        console2.log("   post-fee in (token units)", netIn);
        console2.log("   oracle floor @99.5% (wrbtc wei)", floor);

        // A negative finding is valid PR evidence: it moves to the relaunch calibration, and the route
        // stays disabled rather than shipping with a floor widened to make it pass.
        (bool quoted, uint256 amountOut, uint256 amountInSpent) = _quote(tokenIn, path, netIn);
        if (!quoted) {
            console2.log("   pool quote: SWAP REVERTED");
            return;
        }
        if (amountInSpent < netIn) {
            console2.log("   PARTIAL FILL: pool ran out of liquidity");
            console2.log("   input actually spent (token units)", amountInSpent);
        }

        console2.log("   pool quote (wrbtc wei)", amountOut);
        if (amountOut >= floor) {
            console2.log("   clears the floor by (bps)", (amountOut - floor) * BPS_DIVISOR / floor);
        } else {
            console2.log("   BELOW the floor by (bps)", (floor - amountOut) * BPS_DIVISOR / floor);
        }
        // The tolerance the bot must leave under this quote to turn it into `minRbtcOut` and still clear the
        // floor: any tighter bound is inert, because the floor reverts first.
        if (amountOut > floor) {
            console2.log("   bot tolerance before the floor binds (bps)", (amountOut - floor) * BPS_DIVISOR / amountOut);
        } else {
            console2.log("   bot tolerance before the floor binds (bps)", uint256(0));
        }
    }

    /// @dev The R43 formula this PR does not change: net USD notional at the $1 peg, 99.5% of oracle rBTC.
    function _governanceFloor(uint256 netIn, uint8 tokenDecimals) private view returns (uint256) {
        uint256 stablecoinToUsdScale = 10 ** (ORACLE_DECIMALS - tokenDecimals);
        return (netIn * stablecoinToUsdScale * AMOUNT_OUT_MINIMUM_PERCENT) / btcUsdPrice;
    }

    /**
     * @dev Price the exact input against the live pools. The probe always reverts, so the swap prices the
     *      pool without moving it: `amountOut` comes back as 32 bytes of revert data, and anything else
     *      (an empty revert, a router error string) means the pool could not fill this size.
     */
    function _quote(address tokenIn, bytes memory path, uint256 amountIn)
        private
        returns (bool quoted, uint256 amountOut, uint256 amountInSpent)
    {
        deal(tokenIn, address(probe), amountIn);

        (bool ok, bytes memory returnData) = address(probe).call(
            abi.encodeCall(SwapProbe.quote, (tokenIn, path, amountIn))
        );
        assertFalse(ok, "the probe must always revert");
        if (returnData.length != 64) return (false, 0, 0);
        (amountOut, amountInSpent) = abi.decode(returnData, (uint256, uint256));
        return (true, amountOut, amountInSpent);
    }
}

/**
 * @notice Executes one swap and reverts with the measured WRBTC delta, so a quote leaves no state behind.
 */
contract SwapProbe {
    address internal constant SWAP_ROUTER_02 = 0x0B14ff67f0014046b4b99057Aec4509640b3947A;
    address internal constant WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;

    function quote(address tokenIn, bytes memory path, uint256 amountIn) external {
        IERC20(tokenIn).approve(SWAP_ROUTER_02, amountIn);

        uint256 wrbtcBefore = IERC20(WRBTC).balanceOf(address(this));
        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        IV3SwapRouterLike(SWAP_ROUTER_02).exactInput(
            IV3SwapRouterLike.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0
            })
        );
        uint256 amountOut = IERC20(WRBTC).balanceOf(address(this)) - wrbtcBefore;
        // A V3 swap that hits the tick price limit fills only part of the order and keeps the rest of the
        // input. Reporting the spend makes a starved pool distinguishable from a merely expensive one.
        uint256 amountInSpent = tokenInBefore - IERC20(tokenIn).balanceOf(address(this));

        bytes memory measured = abi.encode(amountOut, amountInSpent);
        assembly {
            revert(add(measured, 0x20), mload(measured))
        }
    }
}
