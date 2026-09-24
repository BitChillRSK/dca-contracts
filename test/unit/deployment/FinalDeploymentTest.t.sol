// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployBase} from "../../../script/DeployBase.s.sol";
import {DeployFinal} from "../../../script/DeployFinal.s.sol";
import {OperationsAdmin} from "../../../src/OperationsAdmin.sol";
import {DcaManager} from "../../../src/DcaManager.sol";
import {IOperationsAdmin} from "../../../src/interfaces/IOperationsAdmin.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";
import {ITokenLending} from "../../../src/interfaces/ITokenLending.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BitChillOwnable} from "../../../src/BitChillOwnable.sol";
import {LayerBankDocHandlerMoc} from "../../../src/layerbank/LayerBankDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "../../../src/sovryn/SovrynDocHandlerMoc.sol";
import {LayerBankErc20HandlerDex} from "../../../src/layerbank/LayerBankErc20HandlerDex.sol";
import {DcaManagerAccessControl} from "../../../src/DcaManagerAccessControl.sol";
import {TokenHandler} from "../../../src/TokenHandler.sol";
import {PurchaseMoc} from "../../../src/PurchaseMoc.sol";
import {PurchaseUniswap} from "../../../src/PurchaseUniswap.sol";
import {LayerBankErc20Handler} from "../../../src/layerbank/LayerBankErc20Handler.sol";
import {MockStablecoin} from "../../mocks/MockStablecoin.sol";
import {MockIsusdToken} from "../../mocks/MockIsusdToken.sol";
import {MockMocProxy} from "../../mocks/MockMocProxy.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "../../mocks/MockLayerBank.sol";
import {MockWrbtcToken} from "../../mocks/MockWrbtcToken.sol";
import {MockSwapRouter02} from "../../mocks/MockSwapRouter02.sol";
import {MockMocOracle} from "../../mocks/MockMocOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../../Constants.sol";

contract DeployFinalHarness is DeployFinal {
    constructor(Environment env, address intendedOwner, address feeCollector) {
        environment = env;
        adminAddresses[env] = intendedOwner;
        feeCollectorAddresses[env] = feeCollector;
    }
}

/**
 * @notice Constructs the canonical seven-handler stack through `DeployFinal.deployStack`.
 * @dev Runs on every lane (no STABLECOIN_TYPE / LENDING_PROTOCOL skip): the final map is
 *      fixed. Harness forces a live-style environment so production fee rates and USDT0
 *      6-decimal bounds apply while Anvil supplies mocks.
 */
contract FinalDeploymentTest is Test {
    address internal constant SAFE = address(0x5AFE);
    address internal swapper;

    MockStablecoin internal doc;
    MockStablecoin internal usdrif;
    MockStablecoin internal usdt0;
    MockMocProxy internal mocProxy;
    MockIsusdToken internal iSusd;
    MockLayerBankAToken internal docAToken;
    MockLayerBankAToken internal usdrifAToken;
    MockLayerBankAToken internal usdt0AToken;
    MockWrbtcToken internal wrbtc;
    MockSwapRouter02 internal router;
    MockMocOracle internal oracle;
    MockStablecoin internal intermediate;

    function setUp() public {
        vm.setEnv("REAL_DEPLOYMENT", "false");
        swapper = makeAddr("initialSwapper");

        doc = new MockStablecoin(address(this));
        usdrif = new MockStablecoin(address(this));
        usdt0 = new MockStablecoin(address(this));
        mocProxy = new MockMocProxy(address(doc));
        iSusd = new MockIsusdToken(address(doc));

        docAToken = new MockLayerBankAToken(address(doc));
        MockLayerBankPool docPool = new MockLayerBankPool(docAToken);
        docAToken.setPool(address(docPool));

        usdrifAToken = new MockLayerBankAToken(address(usdrif));
        MockLayerBankPool usdrifPool = new MockLayerBankPool(usdrifAToken);
        usdrifAToken.setPool(address(usdrifPool));

        usdt0AToken = new MockLayerBankAToken(address(usdt0));
        MockLayerBankPool usdt0Pool = new MockLayerBankPool(usdt0AToken);
        usdt0AToken.setPool(address(usdt0Pool));

        wrbtc = new MockWrbtcToken();
        router = new MockSwapRouter02(wrbtc, BTC_PRICE);
        oracle = new MockMocOracle();
        intermediate = new MockStablecoin(address(this));
    }

    function test_finalStack_mainnetStyle_sevenHandlersAndSafePending() public {
        DeployFinalHarness harness =
            new DeployFinalHarness(DeployBase.Environment.MAINNET, SAFE, address(this));
        DeployFinal.FinalStack memory stack = harness.deployStack(_mockConfig(address(this)));

        assertEq(stack.operationsAdmin.owner(), address(this));
        assertEq(stack.operationsAdmin.pendingOwner(), SAFE);
        assertEq(stack.dcaManager.owner(), address(this));
        assertEq(stack.dcaManager.pendingOwner(), SAFE);
        assertEq(address(stack.dcaManager.i_operationsAdmin()), address(stack.operationsAdmin));

        assertEq(uint256(stack.operationsAdmin.getRouteClass(IDLE_INDEX)), uint256(IOperationsAdmin.RouteClass.Idle));
        assertEq(
            uint256(stack.operationsAdmin.getRouteClass(LAYERBANK_INDEX)),
            uint256(IOperationsAdmin.RouteClass.Lending)
        );
        assertEq(
            uint256(stack.operationsAdmin.getRouteClass(SOVRYN_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending)
        );
        assertEq(
            uint256(stack.operationsAdmin.getRouteClass(TROPYKUS_INDEX)),
            uint256(IOperationsAdmin.RouteClass.Unregistered),
            "Tropykus must stay unregistered"
        );

        assertEq(stack.operationsAdmin.getTokenHandler(address(doc), IDLE_INDEX), stack.docIdle);
        assertEq(stack.operationsAdmin.getTokenHandler(address(doc), LAYERBANK_INDEX), stack.docLayerBank);
        assertEq(stack.operationsAdmin.getTokenHandler(address(doc), SOVRYN_INDEX), stack.docSovryn);
        assertEq(stack.operationsAdmin.getTokenHandler(address(usdrif), IDLE_INDEX), stack.usdrifIdle);
        assertEq(stack.operationsAdmin.getTokenHandler(address(usdrif), LAYERBANK_INDEX), stack.usdrifLayerBank);
        assertEq(stack.operationsAdmin.getTokenHandler(address(usdt0), IDLE_INDEX), stack.usdt0Idle);
        assertEq(stack.operationsAdmin.getTokenHandler(address(usdt0), LAYERBANK_INDEX), stack.usdt0LayerBank);
        assertEq(
            stack.operationsAdmin.getTokenHandler(address(doc), TROPYKUS_INDEX),
            address(0),
            "no DOC Tropykus handler"
        );
        assertEq(
            stack.operationsAdmin.getTokenHandler(address(usdrif), SOVRYN_INDEX),
            address(0),
            "no USDRIF Sovryn handler"
        );

        assertTrue(stack.operationsAdmin.isSwapper(swapper));
        assertFalse(stack.operationsAdmin.isSwapper(address(this)));

        assertEq(stack.dcaManager.getTokenMinPurchaseAmount(address(doc)), MIN_PURCHASE_AMOUNT);
        assertEq(stack.dcaManager.getTokenMinPurchaseAmount(address(usdrif)), MIN_PURCHASE_AMOUNT);
        assertEq(stack.dcaManager.getTokenMinPurchaseAmount(address(usdt0)), USDT0_MIN_PURCHASE_AMOUNT);
        assertEq(stack.dcaManager.getMinPurchasePeriod(), 7 days);
        assertEq(stack.dcaManager.getMaxSchedulesPerToken(), 10);

        _assertHandlerOwnerPending(stack.docIdle, SAFE);
        _assertHandlerOwnerPending(stack.docLayerBank, SAFE);
        _assertHandlerOwnerPending(stack.docSovryn, SAFE);
        _assertHandlerOwnerPending(stack.usdrifIdle, SAFE);
        _assertHandlerOwnerPending(stack.usdrifLayerBank, SAFE);
        _assertHandlerOwnerPending(stack.usdt0Idle, SAFE);
        _assertHandlerOwnerPending(stack.usdt0LayerBank, SAFE);

        _assertCommonHandlerWiring(stack.docIdle, address(stack.dcaManager), address(doc));
        _assertCommonHandlerWiring(stack.docLayerBank, address(stack.dcaManager), address(doc));
        _assertCommonHandlerWiring(stack.docSovryn, address(stack.dcaManager), address(doc));
        _assertCommonHandlerWiring(stack.usdrifIdle, address(stack.dcaManager), address(usdrif));
        _assertCommonHandlerWiring(stack.usdrifLayerBank, address(stack.dcaManager), address(usdrif));
        _assertCommonHandlerWiring(stack.usdt0Idle, address(stack.dcaManager), address(usdt0));
        _assertCommonHandlerWiring(stack.usdt0LayerBank, address(stack.dcaManager), address(usdt0));

        assertEq(address(LayerBankDocHandlerMoc(payable(stack.docLayerBank)).i_aToken()), address(docAToken));
        assertEq(address(SovrynDocHandlerMoc(payable(stack.docSovryn)).i_iSusdToken()), address(iSusd));
        assertEq(address(LayerBankErc20HandlerDex(payable(stack.usdrifLayerBank)).i_aToken()), address(usdrifAToken));
        assertEq(address(LayerBankErc20HandlerDex(payable(stack.usdt0LayerBank)).i_aToken()), address(usdt0AToken));

        assertEq(address(LayerBankErc20Handler(stack.docLayerBank).i_pool()), docAToken.POOL());
        assertEq(address(LayerBankErc20Handler(stack.usdrifLayerBank).i_pool()), usdrifAToken.POOL());
        assertEq(address(LayerBankErc20Handler(stack.usdt0LayerBank).i_pool()), usdt0AToken.POOL());

        _assertMocWiring(stack.docIdle);
        _assertMocWiring(stack.docLayerBank);
        _assertMocWiring(stack.docSovryn);

        _assertDexWiring(stack.usdrifIdle);
        _assertDexWiring(stack.usdrifLayerBank);
        _assertDexWiring(stack.usdt0Idle);
        _assertDexWiring(stack.usdt0LayerBank);

        IFeeHandler.FeeSettings memory usdt0Fees = IFeeHandler(stack.usdt0LayerBank).getFeeSettings();
        assertEq(usdt0Fees.feePurchaseLowerBound, USDT0_FEE_PURCHASE_LOWER_BOUND);
        assertEq(usdt0Fees.feePurchaseUpperBound, USDT0_FEE_PURCHASE_UPPER_BOUND);
        assertEq(usdt0Fees.maxFeeRate, MAX_FEE_RATE_PRODUCTION);

        IFeeHandler.FeeSettings memory docFees = IFeeHandler(stack.docIdle).getFeeSettings();
        assertEq(docFees.feePurchaseLowerBound, FEE_PURCHASE_LOWER_BOUND);
        assertEq(docFees.maxFeeRate, MAX_FEE_RATE_PRODUCTION);

        assertTrue(IERC165(stack.docLayerBank).supportsInterface(type(ITokenLending).interfaceId));
        assertTrue(IERC165(stack.docSovryn).supportsInterface(type(ITokenLending).interfaceId));
        assertTrue(IERC165(stack.usdrifLayerBank).supportsInterface(type(ITokenLending).interfaceId));
        assertFalse(IERC165(stack.docIdle).supportsInterface(type(ITokenLending).interfaceId));
        assertFalse(IERC165(stack.usdt0Idle).supportsInterface(type(ITokenLending).interfaceId));

        // Handler addresses must be unique because each may back only one token-route pair.
        address[7] memory handlers = [
            stack.docIdle,
            stack.docLayerBank,
            stack.docSovryn,
            stack.usdrifIdle,
            stack.usdrifLayerBank,
            stack.usdt0Idle,
            stack.usdt0LayerBank
        ];
        for (uint256 i = 0; i < handlers.length; i++) {
            for (uint256 j = i + 1; j < handlers.length; j++) {
                assertTrue(handlers[i] != handlers[j], "handler addresses must be unique");
            }
        }

        vm.prank(SAFE);
        stack.operationsAdmin.acceptOwnership();
        vm.prank(SAFE);
        stack.dcaManager.acceptOwnership();
        assertEq(stack.operationsAdmin.owner(), SAFE);
        assertEq(stack.dcaManager.owner(), SAFE);
    }

    /**
     * @notice Every production handler holds a standing allowance to its own spender, and to nobody else.
     * @dev The assertion that carries the ordering rule is `== max` to the real spender. A lending handler
     *      grants its approval in the protocol adapter's constructor because that is where the spender
     *      immutable is assigned; the same helper called from `LendingErc20Handler`'s constructor compiles
     *      and reads `address(0)`. With an OpenZeppelin token that reverts the deploy outright, so the
     *      companion `address(0)` assertion below is belt-and-braces for a token that would allow it.
     */
    function test_finalStack_standingSpenderApprovals() public {
        DeployFinalHarness harness =
            new DeployFinalHarness(DeployBase.Environment.MAINNET, SAFE, address(this));
        DeployFinal.FinalStack memory stack = harness.deployStack(_mockConfig(address(this)));

        // Lending spenders: LayerBank's Pool and Sovryn's iToken, one per lending leaf.
        _assertStandingApproval(stack.docLayerBank, doc, docAToken.POOL());
        _assertStandingApproval(stack.usdrifLayerBank, usdrif, usdrifAToken.POOL());
        _assertStandingApproval(stack.usdt0LayerBank, usdt0, usdt0AToken.POOL());
        _assertStandingApproval(stack.docSovryn, doc, address(iSusd));

        // The Uniswap router, on every Dex leaf, idle and lending alike.
        _assertStandingApproval(stack.usdrifIdle, usdrif, address(router));
        _assertStandingApproval(stack.usdt0Idle, usdt0, address(router));
        _assertStandingApproval(stack.usdrifLayerBank, usdrif, address(router));
        _assertStandingApproval(stack.usdt0LayerBank, usdt0, address(router));

        // A MoC leaf buys by redeeming its own DOC and never swaps, so it approves no router.
        assertEq(doc.allowance(stack.docSovryn, address(router)), 0, "MoC leaf approved the router");
        assertEq(doc.allowance(stack.docLayerBank, address(router)), 0, "MoC leaf approved the router");
        // The idle DOC leaf neither lends nor swaps, so it holds no standing allowance at all.
        assertEq(doc.allowance(stack.docIdle, address(mocProxy)), 0, "MoC redemption needs no allowance");
        assertEq(doc.allowance(stack.docIdle, address(router)), 0, "idle MoC leaf approved the router");
        assertEq(doc.allowance(stack.docIdle, address(0)), 0, "idle MoC leaf approved the zero address");
    }

    function test_finalStack_testnetStyle_keepsBroadcasterAsOwner() public {
        DeployFinalHarness harness =
            new DeployFinalHarness(DeployBase.Environment.TESTNET, address(this), address(this));
        DeployFinal.FinalStack memory stack = harness.deployStack(_mockConfig(address(this)));

        assertEq(stack.operationsAdmin.owner(), address(this));
        assertEq(stack.operationsAdmin.pendingOwner(), address(0));
        assertEq(stack.dcaManager.pendingOwner(), address(0));
        assertEq(BitChillOwnable(stack.docIdle).pendingOwner(), address(0));
        assertTrue(stack.operationsAdmin.isSwapper(swapper));
    }

    function test_run_revertsWhenNotLive() public {
        DeployFinalHarness harness =
            new DeployFinalHarness(DeployBase.Environment.LOCAL, address(this), address(this));
        vm.expectRevert(DeployFinal.DeployFinal__NotALivePath.selector);
        harness.run();
    }

    function test_deployStack_revertsOnZeroSwapper() public {
        DeployFinalHarness harness =
            new DeployFinalHarness(DeployBase.Environment.MAINNET, SAFE, address(this));
        DeployFinal.FinalNetworkConfig memory config = _mockConfig(address(this));
        config.initialSwapper = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployFinal.DeployFinal__ZeroAddress.selector, "initialSwapper"));
        harness.deployStack(config);
    }

    function test_deployStack_revertsOnMissingLayerBankAToken() public {
        DeployFinalHarness harness =
            new DeployFinalHarness(DeployBase.Environment.MAINNET, SAFE, address(this));
        DeployFinal.FinalNetworkConfig memory config = _mockConfig(address(this));
        config.docLayerBankAToken = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(DeployFinal.DeployFinal__IncompleteMap.selector, "docLayerBankAToken")
        );
        harness.deployStack(config);
    }

    function _assertHandlerOwnerPending(address handler, address pending) internal {
        assertEq(Ownable(handler).owner(), address(this));
        assertEq(BitChillOwnable(handler).pendingOwner(), pending);
    }

    function _assertCommonHandlerWiring(address handler, address manager, address stablecoin) internal {
        assertEq(DcaManagerAccessControl(handler).i_dcaManager(), manager);
        assertEq(address(TokenHandler(handler).i_stableToken()), stablecoin);
    }

    function _assertStandingApproval(address handler, MockStablecoin token, address spender) internal {
        assertEq(token.allowance(handler, spender), type(uint256).max, "spender is not standing-approved");
        assertEq(token.allowance(handler, address(0)), 0, "approval ran before the spender was assigned");
    }

    function _assertMocWiring(address handler) internal {
        assertEq(address(PurchaseMoc(payable(handler)).i_mocProxy()), address(mocProxy));
    }

    function _assertDexWiring(address handler) internal {
        PurchaseUniswap purchase = PurchaseUniswap(payable(handler));
        assertEq(address(purchase.i_wrBtcToken()), address(wrbtc));
        assertEq(address(purchase.i_swapRouter02()), address(router));
        assertEq(address(purchase.getMocOracle()), address(oracle));
        bytes memory path = purchase.getSwapPath();
        assertTrue(purchase.isPurchasePathAllowed(keccak256(path)));
    }

    function _mockConfig(address feeCollector) internal view returns (DeployFinal.FinalNetworkConfig memory config) {
        address[] memory usdrifIntermediate = new address[](1);
        usdrifIntermediate[0] = address(intermediate);
        uint24[] memory usdrifFees = new uint24[](2);
        usdrifFees[0] = 500;
        usdrifFees[1] = 3000;

        address[] memory usdt0Intermediate = new address[](0);
        uint24[] memory usdt0Fees = new uint24[](1);
        usdt0Fees[0] = 3000;

        config = DeployFinal.FinalNetworkConfig({
            doc: address(doc),
            mocProxy: address(mocProxy),
            docLayerBankAToken: address(docAToken),
            docSovrynShares: address(iSusd),
            usdrif: address(usdrif),
            usdrifLayerBankAToken: address(usdrifAToken),
            usdt0: address(usdt0),
            usdt0LayerBankAToken: address(usdt0AToken),
            wrbtc: address(wrbtc),
            swapRouter02: address(router),
            mocOracle: address(oracle),
            usdrifIntermediateTokens: usdrifIntermediate,
            usdrifPoolFeeRates: usdrifFees,
            usdt0IntermediateTokens: usdt0Intermediate,
            usdt0PoolFeeRates: usdt0Fees,
            amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            feeCollector: feeCollector,
            initialSwapper: swapper
        });
    }
}
