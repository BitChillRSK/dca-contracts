// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Actor} from "./Actor.sol";
import {Clamp} from "./utils/Clamp.sol";
import {DecimalPrinter} from "./utils/DecimalPrinter.sol";
import {Deployer} from "./utils/Deployer.sol";
import {vm} from "./utils/Hevm.sol";
import {Logger} from "./utils/Logger.sol";
import {Math} from "./utils/Math.sol";
import {StringUtils} from "./utils/StringUtils.sol";
import {EnumerableSet} from "./utils/EnumerableSet.sol";

import {DcaManager} from "src/DcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IOperationsAdmin} from "src/interfaces/IOperationsAdmin.sol";
import {ILendingHandler} from "src/interfaces/ILendingHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "src/interfaces/IUniswapV3SwapRouter.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {IdleHandlerDex} from "src/idle/IdleHandlerDex.sol";
import {LayerBankDocHandlerMoc} from "src/layerbank/LayerBankDocHandlerMoc.sol";
import {LayerBankHandlerDex} from "src/layerbank/LayerBankHandlerDex.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";

import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "test/mocks/MockLayerBank.sol";
import {FizzIToken} from "./mocks/FizzIToken.sol";
import {FizzFeeProbe} from "./mocks/FizzFeeProbe.sol";
import {ReentrantActor} from "./ReentrantActor.sol";

/// @notice Base contract with state variables and setup functions
/// @dev Deployment retains the audited test topology on one DcaManager / OperationsAdmin pair:
///      DOC  → route 0 IdleDocHandlerMoc, route 1 LayerBankDocHandlerMoc, route 2 SovrynDocHandlerMoc
///      USDRIF → route 0 IdleHandlerDex, route 1 LayerBankHandlerDex
///      External venues are the repo's own mocks (MoC proxy, SwapRouter02, WRBTC, MoC oracle, LayerBank)
///      plus `FizzIToken`, a Sovryn iToken whose price can fall. `SovrynHandlerDex` is not deployed
///      and `src/tropykus-legacy/` is out of scope. Sovryn is retained for regression coverage;
///      the canonical initial launch excludes it.
abstract contract Base is StringUtils, Clamp, Deployer, Math {
    using DecimalPrinter for uint256;

    string[] internal ACTOR_LABELS = ["Alice", "Bob", "Charlie"];
    uint256 internal constant BLOCK_INTERVAL = 12 seconds;
    uint256 internal constant INITIAL_ETH_BALANCE = 1_000 ether;
    uint256 internal constant INITIAL_TOKEN_BALANCE = 1_000_000 ether;

    // Protocol configuration (launch values from script/Constants.sol unless noted)
    uint256 internal constant IDLE_ROUTE = 0;
    uint256 internal constant LAYERBANK_ROUTE = 1;
    uint256 internal constant SOVRYN_ROUTE = 2;
    uint256 internal constant MIN_PURCHASE_AMOUNT = 25 ether;
    /// @dev Launch is 7 days; 1 day keeps more schedules due per campaign and still exercises the
    ///      whole-day grid. The secondary dispatcher can raise it.
    uint256 internal constant INITIAL_MIN_PURCHASE_PERIOD = 1 days;
    uint256 internal constant MAX_SCHEDULES_PER_TOKEN = 10;
    uint16 internal constant MIN_FEE_RATE = 20;
    uint16 internal constant MAX_FEE_RATE = 100;
    uint112 internal constant FEE_PURCHASE_LOWER_BOUND = 250 ether;
    uint256 internal constant AMOUNT_OUT_MINIMUM_PERCENT = 0.97 ether;
    uint256 internal constant AMOUNT_OUT_MINIMUM_SAFETY_CHECK = 0.95 ether;
    uint256 internal constant BTC_PRICE_USD = 50_000; // MockMocProxy and MockSwapRouter02 both price at this
    uint24 internal constant DEFAULT_POOL_FEE = 3000;
    uint24 internal constant ALT_POOL_FEE = 500;
    uint256 internal constant INITIAL_ITOKEN_PRICE = 1.0137 ether;
    uint256 internal constant VENUE_ETH_BALANCE = 1e27;

    // Fizz property bounds (fizz_data/property-plan.md §2)
    /// @dev Create paths return early at this many tracked schedules, so snapshots and global loops stay bounded.
    uint256 internal constant MAX_TRACKED = 64;
    /// @dev GL-16 re-checks only this many of the most recent deletions.
    uint256 internal constant DELETED_TAIL = 64;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WINDOW_BLOCKS = 5;
    /// @dev `s_accumulatedRbtc` slot per leaf (`forge inspect <leaf> storageLayout`): idle leaves 4,
    ///      lending leaves 5 (`s_shares` sits at 4). Same on the MoC and Dex variants.
    uint256 internal constant ACC_RBTC_SLOT_IDLE = 4;
    uint256 internal constant ACC_RBTC_SLOT_LENDING = 5;

    // ―――――――――――――――――――――――――― Ghosts ――――――――――――――――――――――――――

    /// @notice Planned protected batch (H3). 7B's `adv_planProtectedBatch` writes every field.
    struct Plan {
        bool live;
        uint256 routeK;
        uint64[] ids;
        address swapper;
        uint256 unlock;
        uint256 G;
        uint256 SR;
        uint256 cashIn;
        uint256 rate;
        uint256 exitFeeBps;
        uint256 dexPrice;
        uint256 oraclePrice;
        bool oracleValid;
        uint256 minOut;
        uint48[] anchors;
    }

    /// @dev Ghosts that only handler wiring can move are updated through the `_ghost*` hooks below.
    struct Ghosts {
        // Donations and dust (GL-02, GL-03, GL-05, GL-06, SP-05)
        mapping(address handler => uint256) stableDonated;
        mapping(address handler => uint256) ethDonated;
        mapping(address handler => uint256) rbtcDustBudget;
        mapping(address handler => bool) donatedSinceDeposit;
        // Rounding slack and loss flag (GL-10, GL-24, SP-09, SP-28)
        mapping(address account => mapping(address handler => uint256)) shareSlack;
        bool sovrynPriceEverFell;
        // Schedule lifecycle (GL-11, GL-16, SP-02), maintained by `_trackSchedule` / `_untrackSchedule`
        uint256 schedulesCreated;
        uint256 schedulesDeleted;
        uint64 maxIdSeen;
        uint64[] deletedIds;
        address[] deletedTokens;
        // Baselines fixed at the end of setup() (GL-12, GL-27)
        uint256 nativeTotal;
        mapping(address token => uint256) privBaseline;
        // Cadence (GL-17)
        mapping(address token => mapping(uint64 id => uint256)) buyDay;
        mapping(address token => mapping(uint64 id => uint256)) buysOnDay;
        mapping(address token => mapping(uint64 id => uint256)) editDay;
        mapping(address token => mapping(uint64 id => uint256)) editsOnDay;
        // Protected window (GL-18, SP-55). Mappings are keyed by epoch because they cannot be cleared.
        uint256 winEpoch;
        uint256 winUnlock;
        address[] winSnapToken;
        uint64[] winSnapId;
        IDcaManager.DcaSchedule[] winSnap;
        bool[] winEligible;
        mapping(uint256 epoch => mapping(address token => mapping(uint64 id => uint256))) winBatchDebit;
        mapping(uint256 epoch => mapping(address account => mapping(address handler => uint256))) winShareSnap;
        mapping(uint256 epoch => mapping(address account => mapping(address handler => uint256))) winShareBatchDebit;
        // Swapper allowlist (GL-25)
        bool allowlistEmpty;
        uint256 allowlistEmptySince;
        // Finding 1 plan (SP-64, SP-65)
        Plan plan;
    }

    Ghosts internal ghosts;

    // ―――――――――――――――――――――――――― Actors ――――――――――――――――――――――――――

    address[] internal actors;
    address internal actor;
    address internal admin;

    /// @dev Two allowlisted keepers so a revocation does not end every purchase path.
    address[] internal swappers;
    address internal swapper;

    /// @dev Initial fee collector on every handler. Rotations pick from this account and the actors.
    address internal feeCollector;

    modifier asActor() virtual {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier asAdmin() virtual {
        vm.startPrank(admin);
        _;
        vm.stopPrank();
    }

    modifier asSwapper() virtual {
        vm.startPrank(swapper);
        _;
        vm.stopPrank();
    }

    // ―――――――――――――――――――――――― Contracts ―――――――――――――――――――――――――

    DcaManager internal dcaManager;
    OperationsAdmin internal operationsAdmin;

    MockStablecoin internal doc;
    MockStablecoin internal usdrif;
    /// @dev Only ever an intermediate hop in the alternative Uniswap path.
    MockStablecoin internal usdt0;

    MockMocProxy internal mocProxy;
    MockWrbtcToken internal wrbtc;
    MockSwapRouter02 internal swapRouter;
    MockMocOracle internal mocOracle;
    /// @dev Second oracle for `setMocOracle` rotations.
    MockMocOracle internal mocOracleAlt;

    FizzIToken internal sovrynIToken;
    MockLayerBankAToken internal layerBankATokenDoc;
    MockLayerBankPool internal layerBankPoolDoc;
    MockLayerBankAToken internal layerBankATokenUsdrif;
    MockLayerBankPool internal layerBankPoolUsdrif;

    IdleDocHandlerMoc internal idleDocMoc;
    LayerBankDocHandlerMoc internal layerBankDocMoc;
    SovrynDocHandlerMoc internal sovrynDocMoc;
    IdleHandlerDex internal idleUsdrifDex;
    LayerBankHandlerDex internal layerBankUsdrifDex;

    /// @notice One assigned (token, route) pair and the facts handlers need to drive it.
    struct Route {
        address token;
        uint256 routeIndex;
        address handler;
        bool lending;
        bool dex;
    }

    Route[] internal routes;
    address[] internal dexHandlers;

    /// @dev MockSwapRouter02 has no price getter; EnvironmentHandler keeps this in step with it.
    uint256 internal dexRouterPrice;

    /// @dev `PurchaseFees` with its internal fee curve exposed (H4); owner is `admin`.
    FizzFeeProbe internal feeProbe;

    /// @notice A live schedule as the harness last saw it. Removed on delete.
    struct TrackedSchedule {
        address token;
        uint64 scheduleId;
        address owner;
        uint256 routeIndex;
    }

    TrackedSchedule[] internal trackedSchedules;

    // ―――――――――――――――――――――――――― Setup ―――――――――――――――――――――――――――

    function setup() internal {
        admin = address(this);
        vm.label(admin, "Admin");

        feeCollector = address(new Actor());
        vm.label(feeCollector, "FeeCollector");

        _deployCore();
        _deployVenues();
        _deployHandlers();
        _registerRoutes();

        setupActors();
        _setupSwappers();
        _setupFizzHarness();
    }

    /// @dev Property harness additions. Runs last so the baselines see the finished setup.
    function _setupFizzHarness() private {
        // The fixed-size snapshot tables assume this topology.
        require(actors.length == 3 && routes.length == 5 && dexHandlers.length == 2, "Fizz: topology changed");

        feeProbe = new FizzFeeProbe(
            feeCollector,
            IPurchaseFees.FeeSettings({
                minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
            }),
            admin
        );
        vm.label(address(feeProbe), "FizzFeeProbe");

        ghosts.nativeTotal = _nativeWorldTotal();
        ghosts.privBaseline[address(doc)] = doc.balanceOf(admin);
        ghosts.privBaseline[address(usdrif)] = usdrif.balanceOf(admin);
        ghosts.privBaseline[address(usdt0)] = usdt0.balanceOf(admin);
        ghosts.privBaseline[address(wrbtc)] = wrbtc.balanceOf(admin);
    }

    function _deployCore() private {
        operationsAdmin = new OperationsAdmin(admin);
        dcaManager =
            new DcaManager(address(operationsAdmin), INITIAL_MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, admin);

        doc = new MockStablecoin(admin);
        usdrif = new MockStablecoin(admin);
        usdt0 = new MockStablecoin(admin);
        vm.label(address(doc), "DOC");
        vm.label(address(usdrif), "USDRIF");
        vm.label(address(usdt0), "USDT0");

        dcaManager.setTokenMinPurchaseAmount(address(doc), MIN_PURCHASE_AMOUNT);
        dcaManager.setTokenMinPurchaseAmount(address(usdrif), MIN_PURCHASE_AMOUNT);
    }

    function _deployVenues() private {
        mocProxy = new MockMocProxy(address(doc));
        vm.deal(address(mocProxy), VENUE_ETH_BALANCE);

        wrbtc = new MockWrbtcToken();
        swapRouter = new MockSwapRouter02(wrbtc, BTC_PRICE_USD);
        dexRouterPrice = BTC_PRICE_USD;
        vm.deal(address(swapRouter), VENUE_ETH_BALANCE);
        mocOracle = new MockMocOracle();
        mocOracleAlt = new MockMocOracle();

        sovrynIToken = new FizzIToken(address(doc), INITIAL_ITOKEN_PRICE);

        layerBankATokenDoc = new MockLayerBankAToken(address(doc));
        layerBankPoolDoc = new MockLayerBankPool(layerBankATokenDoc);
        layerBankATokenDoc.setPool(address(layerBankPoolDoc));

        layerBankATokenUsdrif = new MockLayerBankAToken(address(usdrif));
        layerBankPoolUsdrif = new MockLayerBankPool(layerBankATokenUsdrif);
        layerBankATokenUsdrif.setPool(address(layerBankPoolUsdrif));
    }

    function _deployHandlers() private {
        IPurchaseFees.FeeSettings memory feeSettings = IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
        });

        idleDocMoc = new IdleDocHandlerMoc(
            address(dcaManager), address(doc), feeCollector, address(mocProxy), feeSettings, admin
        );
        layerBankDocMoc = new LayerBankDocHandlerMoc(
            address(dcaManager),
            address(doc),
            address(layerBankATokenDoc),
            feeCollector,
            address(mocProxy),
            feeSettings,
            admin
        );
        sovrynDocMoc = new SovrynDocHandlerMoc(
            address(dcaManager),
            address(doc),
            address(sovrynIToken),
            feeCollector,
            address(mocProxy),
            feeSettings,
            admin
        );

        // Local MockMocProxy pulls DOC with transferFrom; live MoC burns from the caller without an
        // allowance. Same fixture step as test/ai-generated/fuzz/LendingPurchaseConservationInvariant.t.sol.
        vm.prank(address(idleDocMoc));
        doc.approve(address(mocProxy), type(uint256).max);
        vm.prank(address(layerBankDocMoc));
        doc.approve(address(mocProxy), type(uint256).max);
        vm.prank(address(sovrynDocMoc));
        doc.approve(address(mocProxy), type(uint256).max);

        idleUsdrifDex = new IdleHandlerDex(
            address(dcaManager),
            address(usdrif),
            _uniswapSettings(),
            feeCollector,
            feeSettings,
            AMOUNT_OUT_MINIMUM_PERCENT,
            AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            admin
        );
        layerBankUsdrifDex = new LayerBankHandlerDex(
            address(dcaManager),
            address(usdrif),
            address(layerBankATokenUsdrif),
            _uniswapSettings(),
            feeCollector,
            feeSettings,
            AMOUNT_OUT_MINIMUM_PERCENT,
            AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            admin
        );
        dexHandlers.push(address(idleUsdrifDex));
        dexHandlers.push(address(layerBankUsdrifDex));

        vm.label(address(idleDocMoc), "IdleDocHandlerMoc");
        vm.label(address(layerBankDocMoc), "LayerBankDocHandlerMoc");
        vm.label(address(sovrynDocMoc), "SovrynDocHandlerMoc");
        vm.label(address(idleUsdrifDex), "IdleHandlerDex");
        vm.label(address(layerBankUsdrifDex), "LayerBankHandlerDex");
    }

    function _uniswapSettings() private view returns (IPurchaseUniswap.UniswapSettings memory settings) {
        uint24[] memory fees = new uint24[](2);
        fees[0] = ALT_POOL_FEE;
        fees[1] = DEFAULT_POOL_FEE;
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = address(usdt0);
        settings = IPurchaseUniswap.UniswapSettings({
            wrbtc: IWRBTC(address(wrbtc)),
            swapRouter: IUniswapV3SwapRouter(address(swapRouter)),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: fees,
            mocOracle: ICoinPairPrice(address(mocOracle))
        });
    }

    function _registerRoutes() private {
        operationsAdmin.registerRoute(LAYERBANK_ROUTE, true);
        operationsAdmin.registerRoute(SOVRYN_ROUTE, true);

        _assign(address(doc), IDLE_ROUTE, address(idleDocMoc), false, false);
        _assign(address(doc), LAYERBANK_ROUTE, address(layerBankDocMoc), true, false);
        _assign(address(doc), SOVRYN_ROUTE, address(sovrynDocMoc), true, false);
        _assign(address(usdrif), IDLE_ROUTE, address(idleUsdrifDex), false, true);
        _assign(address(usdrif), LAYERBANK_ROUTE, address(layerBankUsdrifDex), true, true);
    }

    function _assign(address token, uint256 routeIndex, address handler, bool lending, bool dex) private {
        operationsAdmin.assignHandler(token, routeIndex, handler);
        routes.push(Route({token: token, routeIndex: routeIndex, handler: handler, lending: lending, dex: dex}));
    }

    function setupActors() internal {
        for (uint256 i; i < ACTOR_LABELS.length; i++) {
            // actors[2] can re-enter on payment (H7); inert until armed, so it acts as a plain Actor.
            address _actor = i == 2
                ? address(new ReentrantActor{value: INITIAL_ETH_BALANCE}())
                : address(new Actor{value: INITIAL_ETH_BALANCE}());
            actors.push(_actor);
            if (ACTOR_LABELS.length > i) {
                vm.label(_actor, ACTOR_LABELS[i]);
            }
            doc.mint(_actor, INITIAL_TOKEN_BALANCE);
            usdrif.mint(_actor, INITIAL_TOKEN_BALANCE);
            // Deposits pull from the user into the handler, so each user approves every handler.
            for (uint256 r; r < routes.length; r++) {
                vm.prank(_actor);
                MockStablecoin(routes[r].token).approve(routes[r].handler, type(uint256).max);
            }
        }
        actor = actors[0];
    }

    function _setupSwappers() private {
        swappers.push(address(0x5A11));
        swappers.push(address(0x5A12));
        vm.label(swappers[0], "SwapperA");
        vm.label(swappers[1], "SwapperB");
        operationsAdmin.addSwapper(swappers[0]);
        operationsAdmin.addSwapper(swappers[1]);
        swapper = swappers[0];
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    // Maps an arbitrary address to an actor address
    function toActor(address addy) internal view returns (address) {
        return actors[uint256(uint160(addy)) % actors.length];
    }

    // Maps an arbitrary address to an actor address that is different from the current actor
    function toActorNotCurrent(address addy) internal view returns (address) {
        address _actor = actors[uint256(uint160(addy)) % actors.length];
        if (_actor == actor) {
            _actor = actors[(uint256(uint160(addy)) + 1) % actors.length];
        }
        return _actor;
    }

    function _route(uint256 seed) internal view returns (Route memory) {
        return routes[seed % routes.length];
    }

    function _routeOf(address token, uint256 routeIndex) internal view returns (Route memory r) {
        for (uint256 i; i < routes.length; i++) {
            if (routes[i].token == token && routes[i].routeIndex == routeIndex) return routes[i];
        }
    }

    /// @dev Call after every successful create (GL-11 counts it; SP-02 reads `ghosts.maxIdSeen` BEFORE this).
    function _trackSchedule(address token, uint64 scheduleId, address owner, uint256 routeIndex) internal {
        trackedSchedules.push(
            TrackedSchedule({token: token, scheduleId: scheduleId, owner: owner, routeIndex: routeIndex})
        );
        ghosts.schedulesCreated++;
        if (scheduleId > ghosts.maxIdSeen) ghosts.maxIdSeen = scheduleId;
    }

    /// @dev Call after every successful delete. Counts the deletion even when the key was not tracked,
    ///      so a delete of an untracked key surfaces in GL-11 instead of being absorbed.
    function _untrackSchedule(address token, uint64 scheduleId) internal {
        ghosts.schedulesDeleted++;
        ghosts.deletedIds.push(scheduleId);
        ghosts.deletedTokens.push(token);
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            if (trackedSchedules[i].token == token && trackedSchedules[i].scheduleId == scheduleId) {
                trackedSchedules[i] = trackedSchedules[len - 1];
                trackedSchedules.pop();
                return;
            }
        }
    }

    /// @dev Index of the `seed`-th tracked schedule owned by `owner`, or `type(uint256).max` if none.
    function _pickOwnedSchedule(address owner, uint256 seed) internal view returns (uint256) {
        uint256 len = trackedSchedules.length;
        uint256 owned;
        for (uint256 i; i < len; i++) {
            if (trackedSchedules[i].owner == owner) owned++;
        }
        if (owned == 0) return type(uint256).max;
        uint256 target = seed % owned;
        for (uint256 i; i < len; i++) {
            if (trackedSchedules[i].owner == owner) {
                if (target == 0) return i;
                target--;
            }
        }
        return type(uint256).max;
    }

    // Sums the native token balances of all actors
    function sumActorsBalances() internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            sumOfBalances += actors[i].balance;
        }
    }

    // Sums the ERC-20 token balances of all actors for a given token
    function sumActorsERC20Balances(address _token) internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            bytes memory data = abi.encodeWithSignature("balanceOf(address)", actors[i]);
            (bool success, bytes memory result) = _token.staticcall(data);
            require(success, "sumActorsERC20Balances: failed to get balance");
            sumOfBalances += abi.decode(result, (uint256));
        }
    }

    function skipBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_INTERVAL);
    }

    function skipTime(uint256 time) internal {
        uint256 blocks = (time + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + time);
    }

    // ――――――――――――――――――――――――― Fizz helpers ―――――――――――――――――――――――――
    // Shared by Snapshots, the global properties and the specific properties (fizz_data/property-plan.md §2).
    // None of them reverts on a reachable state: getters that can revert are wrapped and report a flag.

    /// @notice ACCOUNTS: the three actors and the initial fee collector (no duplicates).
    function _accounts() internal view returns (address[4] memory accts) {
        accts[0] = actors[0];
        accts[1] = actors[1];
        accts[2] = actors[2];
        accts[3] = feeCollector;
    }

    /// @return 0..2, or `type(uint256).max` if `who` is not an actor.
    function _actorIndex(address who) internal view returns (uint256) {
        for (uint256 i; i < actors.length; i++) {
            if (actors[i] == who) return i;
        }
        return type(uint256).max;
    }

    /// @return Index into `_accounts()` (0..3), or `type(uint256).max`.
    function _accountIndex(address who) internal view returns (uint256) {
        if (who == feeCollector) return 3;
        return _actorIndex(who);
    }

    /// @return Index into `routes` of the route served by `handler`, or `type(uint256).max`.
    function _routeK(address handler) internal view returns (uint256) {
        for (uint256 k; k < routes.length; k++) {
            if (routes[k].handler == handler) return k;
        }
        return type(uint256).max;
    }

    /// @return Index into `routes` of the (token, routeIndex) pair, or `type(uint256).max`.
    function _routeKOf(address token, uint256 routeIndex) internal view returns (uint256) {
        for (uint256 k; k < routes.length; k++) {
            if (routes[k].token == token && routes[k].routeIndex == routeIndex) return k;
        }
        return type(uint256).max;
    }

    /// @dev `operationsAdmin.getHandler` reverts on a routeIndex above uint32; raw batches can send one.
    function _handlerOrZero(address token, uint256 routeIndex) internal view returns (address handler) {
        try operationsAdmin.getHandler(token, routeIndex) returns (address h) {
            handler = h;
        } catch {}
    }

    function isLB(address h) internal view returns (bool) {
        return h == address(layerBankDocMoc) || h == address(layerBankUsdrifDex);
    }

    function isSov(address h) internal view returns (bool) {
        return h == address(sovrynDocMoc);
    }

    function isLendingHandler(address h) internal view returns (bool) {
        return isLB(h) || isSov(h);
    }

    function isDex(address h) internal view returns (bool) {
        return h == address(idleUsdrifDex) || h == address(layerBankUsdrifDex);
    }

    function _aTokenOf(address h) internal view returns (MockLayerBankAToken) {
        return h == address(layerBankDocMoc) ? layerBankATokenDoc : layerBankATokenUsdrif;
    }

    /// @notice Valuation rate the handler applies (its `_viewExchangeRate`): LayerBank normalized income,
    ///         Sovryn iToken price. 0 on idle handlers.
    function rate(address h) internal view returns (uint256) {
        if (isLB(h)) return _aTokenOf(h).getNormalizedIncome();
        if (isSov(h)) return sovrynIToken.tokenPrice();
        return 0;
    }

    /// @notice Rate denominator: 1e27 on LayerBank, 1e18 on Sovryn, 1 on idle handlers.
    function D(address h) internal view returns (uint256) {
        if (isLB(h)) return RAY;
        if (isSov(h)) return 1e18;
        return 1;
    }

    /// @notice Receipt shares the handler holds at its market (scaled aToken / iToken). 0 on idle handlers.
    function receipt(address h) internal view returns (uint256) {
        if (isLB(h)) return _aTokenOf(h).scaledBalanceOf(h);
        if (isSov(h)) return sovrynIToken.balanceOf(h);
        return 0;
    }

    /// @notice rBTC the handler holds for its book: WRBTC on Dex handlers, native on MoC handlers.
    function rbtcAsset(address h) internal view returns (uint256) {
        return isDex(h) ? wrbtc.balanceOf(h) : h.balance;
    }

    /// @notice Decoded claimable rBTC of `a` on `h`.
    function claim(address a, address h) internal view returns (uint256) {
        return IPurchaseRbtc(h).getAccumulatedRbtcBalance(a);
    }

    /// @notice Virtual shares of `a` on `h` (0 on idle handlers).
    function shares(address a, address h) internal view returns (uint256) {
        if (!isLendingHandler(h)) return 0;
        return ILendingHandler(h).getUserShares(a);
    }

    /// @notice Stablecoin value of `a`'s shares at the current rate (floor, as `_sharesToStablecoin`).
    function V(address a, address h) internal view returns (uint256) {
        if (!isLendingHandler(h)) return 0;
        return shares(a, h) * rate(h) / D(h);
    }

    /// @notice Gap one share-touching operation can open between nominal principal and share value.
    function slackOp(address h) internal view returns (uint256) {
        return rate(h) / D(h) + 2;
    }

    function ceilDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    /// @notice Fee on one purchase per docs/PURCHASE_FEES.md "Integer rounding" (one final floor).
    function specFee(uint256 x, IPurchaseFees.FeeSettings memory fs) internal pure returns (uint256) {
        uint256 m = fs.minFeeRate;
        uint256 M = fs.maxFeeRate;
        uint256 L = fs.feePurchaseLowerBound;
        if (x <= L || m >= M) return x * M / 10_000;
        return (m * x * x + (M - m) * L * (2 * x - L)) / (x * 10_000);
    }

    function _dayStart(uint256 ts) internal pure returns (uint256) {
        return ts - (ts % 1 days);
    }

    function _today() internal view returns (uint256) {
        return _dayStart(block.timestamp);
    }

    /// @notice AUDIT_GUIDE due rule: never bought, or today is on/after anchor + period.
    function _specDue(IDcaManager.DcaSchedule memory s) internal view returns (bool) {
        return s.cadenceAnchor == 0 || _today() >= uint256(s.cadenceAnchor) + s.purchasePeriod;
    }

    function _isTracked(address token, uint64 id) internal view returns (bool) {
        return _trackedIndex(token, id) != type(uint256).max;
    }

    /// @return The tracked owner of (token, id), or address(0) if it is not tracked.
    function _trackedOwner(address token, uint64 id) internal view returns (address) {
        uint256 i = _trackedIndex(token, id);
        return i == type(uint256).max ? address(0) : trackedSchedules[i].owner;
    }

    function _trackedIndex(address token, uint64 id) internal view returns (uint256) {
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            if (trackedSchedules[i].token == token && trackedSchedules[i].scheduleId == id) return i;
        }
        return type(uint256).max;
    }

    /// @notice One pass over `trackedSchedules`: L[actorIdx][routeK] = Σ tokenBalance of that actor's
    ///         tracked schedules on that route. `readFailed` is set if any `getDcaSchedule` reverted.
    function _principalTable() internal view returns (uint256[5][3] memory L, bool readFailed) {
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            TrackedSchedule storage s = trackedSchedules[i];
            uint256 a = _actorIndex(s.owner);
            uint256 k = _routeKOf(s.token, s.routeIndex);
            try dcaManager.getDcaSchedule(s.token, s.scheduleId) returns (IDcaManager.DcaSchedule memory d) {
                if (a < 3 && k < 5) L[a][k] += d.tokenBalance;
            } catch {
                readFailed = true;
            }
        }
    }

    /// @notice TB[routeK] = Σ tokenBalance of every tracked schedule on that route, whoever owns it.
    function _routePrincipal() internal view returns (uint256[5] memory TB, bool readFailed) {
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            TrackedSchedule storage s = trackedSchedules[i];
            uint256 k = _routeKOf(s.token, s.routeIndex);
            try dcaManager.getDcaSchedule(s.token, s.scheduleId) returns (IDcaManager.DcaSchedule memory d) {
                if (k < 5) TB[k] += d.tokenBalance;
            } catch {
                readFailed = true;
            }
        }
    }

    /// @notice `dcaManager.getAccruedInterest` for `a` on routes[k]; (0, false) on idle routes.
    function _interest(address a, uint256 k) internal view returns (uint256 value, bool failed) {
        Route storage r = routes[k];
        if (!r.lending) return (0, false);
        try dcaManager.getAccruedInterest(a, r.token, r.routeIndex) returns (uint256 v) {
            value = v;
        } catch {
            failed = true;
        }
    }

    /// @notice Raw `s_accumulatedRbtc[a]` slot of handler `h` (`claimable + 1` encoding; H8).
    function _rawAccRbtc(address a, address h) internal returns (uint256) {
        uint256 slot = isLendingHandler(h) ? ACC_RBTC_SLOT_LENDING : ACC_RBTC_SLOT_IDLE;
        return uint256(vm.load(h, keccak256(abi.encode(a, slot))));
    }

    /// @notice Active MoC oracle price and validity of Dex handler `h` ((0, false) if unreadable).
    function _oracleInfo(address h) internal view returns (uint256 price, bool valid) {
        try IPurchaseUniswap(h).getMocOracle() returns (ICoinPairPrice oracle) {
            if (address(oracle).code.length == 0) return (0, false);
            try oracle.getPriceInfo() returns (uint256 p, bool v, uint256) {
                (price, valid) = (p, v);
            } catch {}
        } catch {}
    }

    /// @notice The two canonical USDRIF paths the harness can set: 0 = direct pool, 1 = via USDT0.
    function _dexPath(uint256 which) internal view returns (bytes memory) {
        if (which == 0) return abi.encodePacked(address(usdrif), DEFAULT_POOL_FEE, address(wrbtc));
        return abi.encodePacked(address(usdrif), ALT_POOL_FEE, address(usdt0), DEFAULT_POOL_FEE, address(wrbtc));
    }

    /// @notice Native rBTC held by ACCOUNTS, the five handlers, the MoC proxy, the router and WRBTC (GL-12).
    function _nativeWorldTotal() internal view returns (uint256 total) {
        address[4] memory accts = _accounts();
        for (uint256 i; i < 4; i++) {
            total += accts[i].balance;
        }
        for (uint256 k; k < routes.length; k++) {
            total += routes[k].handler.balance;
        }
        total += address(mocProxy).balance + address(swapRouter).balance + address(wrbtc).balance;
    }

    function _windowEligible(IDcaManager.DcaSchedule memory d, address token) internal view returns (bool) {
        if (!_specDue(d) || d.paused || d.purchaseAmount > d.tokenBalance) return false;
        Route memory r = _routeOf(token, d.routeIndex);
        if (r.lending && V(d.user, r.handler) == 0) return false;
        return true;
    }

    // ――――――――――――――――――――――――― Ghost hooks ――――――――――――――――――――――――――
    // Handlers call these after the external call succeeds (fizz_data/property-plan.md §6 and §9).

    /// @dev env_donateStablecoin, after the transfer to handler `h`.
    function _ghostDonateStable(address h, uint256 amount) internal {
        ghosts.stableDonated[h] += amount;
        ghosts.donatedSinceDeposit[h] = true;
    }

    /// @dev env_donateETH, after the force-send to handler `h`.
    function _ghostDonateEth(address h, uint256 amount) internal {
        ghosts.ethDonated[h] += amount;
        ghosts.donatedSinceDeposit[h] = true;
    }

    /// @dev Every successful `sovrynIToken.setTokenPrice` (env_moveSovrynPrice, in-scenario price moves).
    function _ghostSovrynPriceMoved(uint256 oldPrice, uint256 newPrice) internal {
        if (newPrice < oldPrice) ghosts.sovrynPriceEverFell = true;
    }

    /// @dev After every successful addSwapper / revokeSwapper. Reads the live allowlist of the two keepers.
    function _ghostSwapperSetChanged() internal {
        bool anyAllowed;
        for (uint256 i; i < swappers.length; i++) {
            if (operationsAdmin.isSwapper(swappers[i])) anyAllowed = true;
        }
        if (anyAllowed) {
            ghosts.allowlistEmpty = false;
            ghosts.allowlistEmptySince = 0;
        } else if (!ghosts.allowlistEmpty) {
            ghosts.allowlistEmpty = true;
            ghosts.allowlistEmptySince = block.number;
        }
    }

    /// @dev `ops` share-touching operations of account `a` on lending handler `h` (see plan §6 for counts).
    function _ghostAddShareSlack(address a, address h, uint256 ops) internal {
        if (ops == 0 || !isLendingHandler(h)) return;
        ghosts.shareSlack[a][h] += ops * slackOp(h);
    }

    /// @dev Every successful batch / across call, once per handler, with the rows sent to that handler.
    function _ghostBatchRows(address h, uint256 rows) internal {
        ghosts.rbtcDustBudget[h] += rows;
    }

    /// @dev Every row bought by a successful batch.
    function _ghostBuy(address token, uint64 id) internal {
        uint256 today = _today();
        if (ghosts.buyDay[token][id] != today) {
            ghosts.buyDay[token][id] = today;
            ghosts.buysOnDay[token][id] = 0;
        }
        ghosts.buysOnDay[token][id]++;
    }

    /// @dev Every successful updatePurchasePeriod.
    function _ghostPeriodEdit(address token, uint64 id) internal {
        uint256 today = _today();
        if (ghosts.editDay[token][id] != today) {
            ghosts.editDay[token][id] = today;
            ghosts.editsOnDay[token][id] = 0;
        }
        ghosts.editsOnDay[token][id]++;
    }

    /// @dev Every successful activateProtectedPurchaseWindow: opens a new epoch and snapshots every tracked
    ///      schedule and every account's lending shares (GL-18, SP-55).
    function _ghostWindowActivated() internal {
        uint256 epoch = ++ghosts.winEpoch;
        ghosts.winUnlock = dcaManager.getUserMutationsAllowedFromBlock();
        // Overwrite in place and trim, instead of delete + push: rewriting live slots is far cheaper.
        uint256 n;
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            TrackedSchedule memory s = trackedSchedules[i];
            try dcaManager.getDcaSchedule(s.token, s.scheduleId) returns (IDcaManager.DcaSchedule memory d) {
                _storeWinSnap(n++, s.token, s.scheduleId, d, _windowEligible(d, s.token));
            } catch {}
        }
        while (ghosts.winSnap.length > n) {
            ghosts.winSnapToken.pop();
            ghosts.winSnapId.pop();
            ghosts.winSnap.pop();
            ghosts.winEligible.pop();
        }
        address[4] memory accts = _accounts();
        for (uint256 k; k < routes.length; k++) {
            if (!routes[k].lending) continue;
            address h = routes[k].handler;
            for (uint256 a; a < 4; a++) {
                ghosts.winShareSnap[epoch][accts[a]][h] = shares(accts[a], h);
            }
        }
    }

    function _storeWinSnap(uint256 i, address token, uint64 id, IDcaManager.DcaSchedule memory d, bool eligible)
        private
    {
        if (i < ghosts.winSnap.length) {
            ghosts.winSnapToken[i] = token;
            ghosts.winSnapId[i] = id;
            ghosts.winSnap[i] = d;
            ghosts.winEligible[i] = eligible;
        } else {
            ghosts.winSnapToken.push(token);
            ghosts.winSnapId.push(id);
            ghosts.winSnap.push(d);
            ghosts.winEligible.push(eligible);
        }
    }

    /// @dev Each row of a successful batch run while the window is live: `debit` = the row's pre-batch purchaseAmount.
    function _ghostWindowBatch(address token, uint64 id, uint256 debit) internal {
        ghosts.winBatchDebit[ghosts.winEpoch][token][id] += debit;
    }

    /// @dev Each buyer of a successful lending batch run while the window is live: `burn` = its share drop on `h`.
    function _ghostWindowShareBurn(address a, address h, uint256 burn) internal {
        ghosts.winShareBatchDebit[ghosts.winEpoch][a][h] += burn;
    }

    /// @dev After a successful lending create/deposit on `h`, once SP-05 has run.
    function _ghostLendingDeposit(address h) internal {
        ghosts.donatedSinceDeposit[h] = false;
    }
}
