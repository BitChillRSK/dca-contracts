// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3SwapRouter} from "src/interfaces/IUniswapV3SwapRouter.sol";
import "../../Constants.sol";

interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function liquidity() external view returns (uint128);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IUniswapV3FactoryLike {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @dev The rest of SwapRouter02's surface, which `IUniswapV3SwapRouter` deliberately omits because
///      `PurchaseUniswap` never calls it. Declared here only so the probe can try to abuse it.
interface ISwapRouter02Extras {
    function factory() external view returns (address);
    function pull(address token, uint256 value) external payable;
    function sweepToken(address token, uint256 amountMinimum) external payable;
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface ILoanTokenLike {
    function mint(address receiver, uint256 depositAmount) external returns (uint256);
}

interface IAavePoolLike {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
    function getConfiguration(address asset) external view returns (uint256);
}

interface ISovrynFlashBorrowLike {
    function flashBorrowToken(
        uint256 borrowAmount,
        address borrower,
        address target,
        string calldata signature,
        bytes calldata data
    ) external payable;
}

/**
 * @title StandingApprovalProbe
 * @notice R83 evidence: what a standing `type(uint256).max` allowance to each live spender actually
 *         exposes, and whether the shipped stablecoins decrement such an allowance when it is spent.
 * @dev Run with `make probe-standing-approvals`. Excluded from `check` / `fork` / CI like every other
 *      `test/mainnet-debug/` probe: it asserts facts about live third-party code, not about `src/`.
 *
 *      Two questions, because R83's product gate turns on both:
 *
 *      1. **Cost.** A token that leaves a `max` allowance untouched makes every later spend a zero-write
 *         path; one that decrements turns each spend into a `RESET`. That decides whether the standing
 *         approval saves ~10,400 or ~5,400 Rootstock gas per use.
 *      2. **Exposure.** A standing allowance is only as safe as the set of callers who can make the
 *         spender pull on it. Each probe below tries to spend a victim's standing allowance from an
 *         address that is not the victim, through every entry point the live spender exposes.
 */
contract StandingApprovalProbe is Test {
    /*//////////////////////////////////////////////////////////////
                          LIVE ROOTSTOCK MAINNET
    //////////////////////////////////////////////////////////////*/
    address internal constant SWAP_ROUTER_02 = 0x0B14ff67f0014046b4b99057Aec4509640b3947A;
    address internal constant WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;

    address internal constant DOC = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
    address internal constant USDRIF = 0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    /// @dev The USDRIF path's first hop, 6-decimal `USDT` (see `DexQuoteFloorProbe`).
    address internal constant USDT_USDRIF_HOP = 0xAf368c91793CB22739386DFCbBb2F1A9e4bCBeBf;
    uint24 internal constant USDRIF_HOP_FEE = 500;

    address internal constant USDT0_HOLDER = 0xaeF6fABf3b0C9e5F9d6D5170AfC703A633479Bbd;

    /// @dev The two production lending spenders: `SovrynErc20Handler._lendingSpender()` (iSUSD, whose
    ///      underlying is DOC) and `LayerBankErc20Handler._lendingSpender()` (the Aave-v3 Pool).
    address internal constant ISUSD = 0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1;
    address internal constant LAYERBANK_POOL = 0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9;
    address internal constant LAYERBANK_POOL_CONFIGURATOR = 0x72F712EFD09cc5683a07BE5dB7f3fd00Cc593922;
    /// @dev Aave's `ReserveConfigurationMap` bit for "flash loans enabled on this reserve".
    uint256 internal constant FLASH_LOAN_ENABLED_BIT = 80;

    address internal victim;
    address internal attacker;

    function setUp() public {
        if (WRBTC.code.length == 0) vm.skip(true); // not on a Rootstock fork
        victim = makeAddr("victimHandler");
        attacker = makeAddr("attacker");
        console2.log("block", block.number);
    }

    /*//////////////////////////////////////////////////////////////
                    1. DOES A MAX ALLOWANCE DECREMENT?
    //////////////////////////////////////////////////////////////*/

    function test_maxAllowanceDecrementPerStablecoin() public {
        // Asserted, not just logged: these three answers are what the per-use saving is derived from,
        // so a token that changes behaviour must fail here rather than quietly restate the arithmetic.
        _assertDecrement("DOC", DOC, DOC_HOLDER, 100e18, true);
        _assertDecrement("USDRIF", USDRIF, USDRIF_HOLDER, 100e18, false);
        _assertDecrement("USDT0", USDT0, USDT0_HOLDER, 100e6, true);
    }

    /// @dev Approves `max` from a fresh holder to a fresh spender, spends once, and checks the
    ///      allowance that survives. `spender` is an arbitrary address on purpose: the decrement is a
    ///      property of the token, not of who is approved.
    function _assertDecrement(
        string memory name,
        address token,
        address whale,
        uint256 amount,
        bool expectedToDecrement
    ) internal {
        address holder = makeAddr(string.concat(name, "Holder"));
        address spender = makeAddr(string.concat(name, "Spender"));

        vm.prank(whale);
        IERC20(token).transfer(holder, amount);

        vm.prank(holder);
        IERC20(token).approve(spender, type(uint256).max);

        uint256 before = IERC20(token).allowance(holder, spender);
        vm.prank(spender);
        IERC20(token).transferFrom(holder, spender, amount);
        uint256 remaining = IERC20(token).allowance(holder, spender);

        console2.log(name, "allowance before", before);
        console2.log(name, "allowance after ", remaining);
        console2.log(name, "decrements max? ", remaining != before);
        assertEq(before, type(uint256).max, "approval did not take");
        assertEq(remaining != before, expectedToDecrement, "this token changed how it treats a max allowance");
        if (expectedToDecrement) assertEq(remaining, before - amount, "decrement was not the spent amount");
    }

    /*//////////////////////////////////////////////////////////////
              2. WHO CAN SPEND A STANDING ALLOWANCE TO THE ROUTER
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Every entry point SwapRouter02 exposes that moves an ERC20, tried by an address that is not
     *      the approver. The router's two `transferFrom` sites are `PeripheryPayments.pay` (payer is the
     *      swap's `msg.sender`, or the router itself on later hops) and `PeripheryPaymentsExtended.pull`
     *      (`from` is hardcoded to `msg.sender`), so the claim under test is that no caller can name a
     *      third party as payer.
     */
    function test_routerStandingApprovalIsUnreachableByAThirdParty() public {
        uint256 funded = 100e18;
        vm.prank(USDRIF_HOLDER);
        IERC20(USDRIF).transfer(victim, funded);
        vm.prank(victim);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max);

        // a. `pull` names msg.sender as the payer, so it pulls from the attacker, who holds nothing.
        vm.prank(attacker);
        (bool pulled,) =
            SWAP_ROUTER_02.call(abi.encodeCall(ISwapRouter02Extras.pull, (USDRIF, funded)));
        assertFalse(pulled, "router.pull moved someone else's tokens");

        // b. `exactInput` builds its callback data itself; `payer` is always msg.sender.
        IUniswapV3SwapRouter.ExactInputParams memory params = IUniswapV3SwapRouter.ExactInputParams({
            path: abi.encodePacked(USDRIF, USDRIF_HOP_FEE, USDT_USDRIF_HOP),
            recipient: attacker,
            amountIn: funded,
            amountOutMinimum: 0
        });
        vm.prank(attacker);
        (bool swapped,) = SWAP_ROUTER_02.call(abi.encodeCall(IUniswapV3SwapRouter.exactInput, (params)));
        assertFalse(swapped, "router swapped someone else's tokens");

        // c. The callback does take a caller-supplied `payer`, but only a canonical pool may call it.
        bytes memory forgedData = abi.encode(
            abi.encodePacked(USDRIF, USDRIF_HOP_FEE, USDT_USDRIF_HOP), // SwapCallbackData.path
            victim // SwapCallbackData.payer
        );
        vm.prank(attacker);
        (bool calledBack,) = SWAP_ROUTER_02.call(
            abi.encodeCall(ISwapRouter02Extras.uniswapV3SwapCallback, (int256(funded), int256(-1), forgedData))
        );
        assertFalse(calledBack, "router honoured a forged callback");

        // d. The one caller the router would trust is a real pool — but a pool calls back whoever
        //    invoked `swap`, never the router, so an attacker-initiated swap can never reach (c).
        address pool = IUniswapV3FactoryLike(ISwapRouter02Extras(SWAP_ROUTER_02).factory()).getPool(
            USDRIF, USDT_USDRIF_HOP, USDRIF_HOP_FEE
        );
        assertTrue(pool != address(0), "USDRIF hop pool not found");
        PoolCallbackRelay relay = new PoolCallbackRelay(SWAP_ROUTER_02);
        vm.prank(USDRIF_HOLDER);
        IERC20(USDRIF).transfer(address(relay), 10e18); // the relay pays its own swap, so the frame commits
        vm.prank(attacker);
        relay.attempt(pool, USDRIF, USDT_USDRIF_HOP, USDRIF_HOP_FEE, victim, 1e18);
        assertTrue(relay.calledBackTheRelay(), "pool did not call back its own caller");
        assertFalse(relay.routerAcceptedRelayAsPool(), "router accepted a non-pool callback");

        assertEq(IERC20(USDRIF).balanceOf(victim), funded, "a standing router allowance was spendable");
        console2.log("router: standing allowance survived all four attempts");
    }

    /*//////////////////////////////////////////////////////////////
            3. WHO CAN SPEND A STANDING ALLOWANCE TO A LENDER
    //////////////////////////////////////////////////////////////*/

    function test_sovrynStandingApprovalIsUnreachableByAThirdParty() public {
        uint256 funded = 100e18;
        vm.prank(DOC_HOLDER);
        IERC20(DOC).transfer(victim, funded);
        vm.prank(victim);
        IERC20(DOC).approve(ISUSD, type(uint256).max);

        // `mint(receiver, depositAmount)` names the receiver of the iSUSD, never the payer of the DOC.
        vm.prank(attacker);
        (bool minted,) = ISUSD.call(abi.encodeCall(ILoanTokenLike.mint, (attacker, funded)));
        assertFalse(minted, "iSUSD minted against someone else's allowance");
        assertEq(IERC20(DOC).balanceOf(victim), funded, "a standing iSUSD allowance was spendable");
    }

    function test_layerBankStandingApprovalIsUnreachableByAThirdParty() public {
        uint256 funded = 100e18;
        vm.prank(USDRIF_HOLDER);
        IERC20(USDRIF).transfer(victim, funded);
        vm.prank(victim);
        IERC20(USDRIF).approve(LAYERBANK_POOL, type(uint256).max);

        // `supply(asset, amount, onBehalfOf, referral)` credits `onBehalfOf` but pulls from msg.sender.
        vm.prank(attacker);
        (bool supplied,) =
            LAYERBANK_POOL.call(abi.encodeCall(IAavePoolLike.supply, (USDRIF, funded, attacker, 0)));
        assertFalse(supplied, "LayerBank supplied against someone else's allowance");
        assertEq(IERC20(USDRIF).balanceOf(victim), funded, "a standing pool allowance was spendable");
    }

    /*//////////////////////////////////////////////////////////////
          4. THE ONE SPENDER PATH THAT DOES NAME A THIRD PARTY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice LayerBank's Pool repays a flash loan from the `receiverAddress` the **caller** names, not
     *         from the caller — the one spender entry point in this file that does not pull from
     *         `msg.sender` — and the reserve-level flag that would enable it is off for all three
     *         stablecoins.
     * @dev Aave's `flashLoan` / `flashLoanSimple` hand `amount` to `receiverAddress`, require its
     *      `executeOperation` to return true, and then `safeTransferFrom(receiverAddress, aToken,
     *      amount + premium)`. An address holding a standing allowance that answers that callback
     *      therefore loses the premium on every call, repeatable up to its balance, without ever having
     *      asked for a loan.
     *
     *      Two independent things keep that off a lending handler, and only the second is BitChill's:
     *
     *      1. LayerBank has the reserve flash-loan flag off for DOC, USDRIF and USDT0. That is their
     *         configuration, flippable by the same EOA that can upgrade the Pool, so it is asserted here
     *         to fail loudly rather than relied on.
     *      2. A lending handler declares no `executeOperation` and no `fallback`, so the callback into it
     *         reverts and takes the flash loan with it. That is the precondition the handler headers
     *         state, and `StandingApprovalFallbackTest` asserts it against a real handler.
     */
    function test_layerBankFlashLoanFlag_isOffForEveryShippedStablecoin() public {
        assertFalse(_flashLoanEnabled(DOC), "LayerBank enabled DOC flash loans; re-check the precondition");
        assertFalse(_flashLoanEnabled(USDRIF), "LayerBank enabled USDRIF flash loans; re-check the precondition");
        assertFalse(_flashLoanEnabled(USDT0), "LayerBank enabled USDT0 flash loans; re-check the precondition");
        console2.log("LayerBank flash-loan premium if ever enabled (bps)", IAavePoolLike(LAYERBANK_POOL).FLASHLOAN_PREMIUM_TOTAL());
    }

    /**
     * @notice Sovryn's iSUSD can make itself call an arbitrary contract through `flashBorrowToken`, and
     *         that entry point is disabled today.
     * @dev bZx's loan tokens route a flash borrow through an arbitrary `target` call, which is the same
     *      shape as the LayerBank case: reachable only if the approver answers. It is inert right now —
     *      the logic proxy has no active target for the selector — but that is a Sovryn governance
     *      setting, not a property of the code, so this assertion is here to fail loudly if it changes.
     */
    function test_sovrynFlashBorrow_isDisabled() public {
        vm.prank(attacker);
        (bool ok, bytes memory reason) = ISUSD.call(
            abi.encodeCall(ISovrynFlashBorrowLike.flashBorrowToken, (1e18, attacker, attacker, "", ""))
        );
        assertFalse(ok, "Sovryn flash borrow is live again; re-examine the standing iSUSD approval");
        console2.log("Sovryn flashBorrowToken refusal", string(_revertReason(reason)));
    }

    function _flashLoanEnabled(address asset) private view returns (bool) {
        return (IAavePoolLike(LAYERBANK_POOL).getConfiguration(asset) >> FLASH_LOAN_ENABLED_BIT) & 1 == 1;
    }

    function _revertReason(bytes memory reason) private pure returns (bytes memory) {
        if (reason.length < 68) return bytes("(no reason string)");
        bytes memory trimmed = new bytes(reason.length - 68);
        for (uint256 i; i < trimmed.length; ++i) {
            trimmed[i] = reason[i + 68];
        }
        return trimmed;
    }
}

/**
 * @notice Stands in for an attacker contract that owns a Uniswap pool interaction and wants the router
 *         to pay for it out of somebody else's standing allowance.
 * @dev Records two facts: the pool called this relay back (not the router), and the router refused the
 *      relay's forwarded callback because the relay is not a pool address.
 */
contract PoolCallbackRelay {
    address private immutable i_router;

    bool public calledBackTheRelay;
    bool public routerAcceptedRelayAsPool;

    address private s_tokenIn;
    address private s_tokenOut;
    uint24 private s_fee;
    address private s_forgedPayer;

    constructor(address router) {
        i_router = router;
    }

    function attempt(address pool, address tokenIn, address tokenOut, uint24 fee, address forgedPayer, uint256 amountIn)
        external
    {
        s_tokenIn = tokenIn;
        s_tokenOut = tokenOut;
        s_fee = fee;
        s_forgedPayer = forgedPayer;

        bool zeroForOne = IUniswapV3PoolLike(pool).token0() == tokenIn;
        uint160 limit = zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341;
        IUniswapV3PoolLike(pool).swap(address(this), zeroForOne, int256(amountIn), limit, hex"01");
    }

    /// @dev The pool calls this, proving the callback target is the swap's caller and not the router.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        calledBackTheRelay = true;

        bytes memory forgedData = abi.encode(abi.encodePacked(s_tokenIn, s_fee, s_tokenOut), s_forgedPayer);
        (bool ok,) = i_router.call(
            abi.encodeCall(ISwapRouter02Extras.uniswapV3SwapCallback, (amount0Delta, amount1Delta, forgedData))
        );
        routerAcceptedRelayAsPool = ok;

        // Settle honestly out of the relay's own balance so this frame commits and the flags survive.
        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        IERC20(s_tokenIn).transfer(msg.sender, owed);
    }
}
