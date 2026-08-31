// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployBase} from "../../../script/DeployBase.s.sol";
import {DeployMocSwaps} from "../../../script/DeployMocSwaps.s.sol";
import {DeployDexSwaps} from "../../../script/DeployDexSwaps.s.sol";
import {DeployIdleHandler} from "../../../script/DeployIdleHandler.s.sol";
import {DeployLayerBankHandler} from "../../../script/DeployLayerBankHandler.s.sol";
import {DeployUsdrifHandler} from "../../../script/DeployUsdrifHandler.s.sol";
import {DeployMocAndUniswap} from "../../../script/DeployMocAndUniswap.s.sol";
import {UsdrifHelperConfig} from "../../../script/UsdrifHelperConfig.s.sol";
import {OperationsAdmin} from "../../../src/OperationsAdmin.sol";
import {DcaManager} from "../../../src/DcaManager.sol";
import {IOperationsAdmin} from "../../../src/interfaces/IOperationsAdmin.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";
import {IPurchaseUniswap} from "../../../src/interfaces/IPurchaseUniswap.sol";
import {BitChillOwnable} from "../../../src/BitChillOwnable.sol";
import {BaseDeploymentTest} from "./BaseDeploymentTest.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../../Constants.sol";

contract DeployBaseHarness is DeployBase {
    constructor(Environment env, address intendedOwner) {
        environment = env;
        adminAddresses[env] = intendedOwner;
    }

    function assertBroadcast(address broadcaster) external view {
        _assertLiveBroadcastSender(broadcaster);
    }

    function propose(address governed) external {
        _proposeFinalOwner(governed);
    }
}

contract DeployMocSwapsHarness is DeployMocSwaps {
    constructor(Environment env, address intendedOwner, address feeCollector) {
        environment = env;
        adminAddresses[env] = intendedOwner;
        feeCollectorAddresses[env] = feeCollector;
    }
}

contract DeployDexSwapsHarness is DeployDexSwaps {
    constructor(Environment env, address intendedOwner, address feeCollector) {
        environment = env;
        adminAddresses[env] = intendedOwner;
        feeCollectorAddresses[env] = feeCollector;
    }
}

contract DeployMocAndUniswapHarness is DeployMocAndUniswap {
    constructor(Environment env) {
        environment = env;
    }
}

contract LiveDeployPathTest is Test {
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    address internal constant SAFE = address(0x5AFE);

    function setUp() public {
        vm.setEnv("REAL_DEPLOYMENT", "false");
    }

    function test_testnet_broadcastFromWrongAccountRevertsBeforeCreate() public {
        DeployBaseHarness harness = new DeployBaseHarness(DeployBase.Environment.TESTNET, TESTNET_OWNER);
        address other = makeAddr("other");
        vm.expectRevert(
            abi.encodeWithSelector(DeployBase.DeployBase__BroadcastMustBeTestnetOwner.selector, other, TESTNET_OWNER)
        );
        harness.assertBroadcast(other);
    }

    function test_mainnet_broadcastAsSafeRevertsBeforeCreate() public {
        DeployBaseHarness harness = new DeployBaseHarness(DeployBase.Environment.MAINNET, MAINNET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(DeployBase.DeployBase__DoNotBroadcastAsSafe.selector, MAINNET_OWNER));
        harness.assertBroadcast(MAINNET_OWNER);
    }

    function test_testnet_broadcastFromOwnerPasses() public {
        DeployBaseHarness harness = new DeployBaseHarness(DeployBase.Environment.TESTNET, TESTNET_OWNER);
        harness.assertBroadcast(TESTNET_OWNER);
    }

    function test_mainnet_broadcastFromEoaPasses() public {
        DeployBaseHarness harness = new DeployBaseHarness(DeployBase.Environment.MAINNET, MAINNET_OWNER);
        harness.assertBroadcast(makeAddr("deployer"));
    }

    function test_proposeFinalOwner_secondCallDoesNotReemit() public {
        DeployBaseHarness harness = new DeployBaseHarness(DeployBase.Environment.MAINNET, SAFE);
        OperationsAdmin admin = new OperationsAdmin(address(harness));

        vm.expectEmit(true, true, true, true, address(admin));
        emit OwnershipTransferStarted(address(harness), SAFE);
        harness.propose(address(admin));
        assertEq(admin.owner(), address(harness));
        assertEq(admin.pendingOwner(), SAFE);

        vm.recordLogs();
        harness.propose(address(admin));
        assertEq(vm.getRecordedLogs().length, 0, "identical pending owner must not re-emit");
        assertEq(admin.pendingOwner(), SAFE);
    }

    function test_compareHarness_revertsOnLive() public {
        DeployMocAndUniswapHarness harness = new DeployMocAndUniswapHarness(DeployBase.Environment.TESTNET);
        vm.expectRevert(DeployMocAndUniswap.DeployMocAndUniswap__NotALivePath.selector);
        harness.run();
        harness = new DeployMocAndUniswapHarness(DeployBase.Environment.MAINNET);
        vm.expectRevert(DeployMocAndUniswap.DeployMocAndUniswap__NotALivePath.selector);
        harness.run();
    }

    function test_mocLive_testnetStyle_registersRoutesAndKeepsOwner() public {
        _skipIfMocLiveUnsupported();
        DeployMocSwapsHarness harness =
            new DeployMocSwapsHarness(DeployBase.Environment.TESTNET, address(this), address(this));
        (OperationsAdmin operationsAdmin, address handler, DcaManager dcaManager,) = harness.run();

        assertEq(operationsAdmin.owner(), address(this));
        assertEq(operationsAdmin.pendingOwner(), address(0));
        assertEq(dcaManager.owner(), address(this));
        assertEq(dcaManager.pendingOwner(), address(0));
        assertEq(Ownable(handler).owner(), address(this));
        assertEq(BitChillOwnable(handler).pendingOwner(), address(0));

        assertEq(uint256(operationsAdmin.getRouteClass(IDLE_INDEX)), uint256(IOperationsAdmin.RouteClass.Idle));
        assertEq(uint256(operationsAdmin.getRouteClass(LAYERBANK_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));
        assertEq(uint256(operationsAdmin.getRouteClass(SOVRYN_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));
        assertNotEq(
            operationsAdmin.getTokenHandler(_docTokenFromHandler(handler), IDLE_INDEX),
            address(0),
            "live MoC path must assign the idle handler"
        );
    }

    function test_mocLive_mainnetStyle_proposesSafeAfterRegistering() public {
        _skipIfMocLiveUnsupported();
        DeployMocSwapsHarness harness = new DeployMocSwapsHarness(DeployBase.Environment.MAINNET, SAFE, address(this));
        (OperationsAdmin operationsAdmin, address handler, DcaManager dcaManager,) = harness.run();

        assertEq(operationsAdmin.owner(), address(this), "broadcaster remains owner until accept");
        assertEq(operationsAdmin.pendingOwner(), SAFE);
        assertEq(dcaManager.owner(), address(this));
        assertEq(dcaManager.pendingOwner(), SAFE);
        assertEq(Ownable(handler).owner(), address(this));
        assertEq(BitChillOwnable(handler).pendingOwner(), SAFE);
        assertEq(
            uint256(operationsAdmin.getRouteClass(LAYERBANK_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending)
        );
        assertEq(uint256(operationsAdmin.getRouteClass(SOVRYN_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));

        vm.prank(SAFE);
        operationsAdmin.acceptOwnership();
        assertEq(operationsAdmin.owner(), SAFE);
        assertEq(operationsAdmin.pendingOwner(), address(0));
    }

    function test_dexLive_mainnetStyle_registersRoutesThenProposes() public {
        _skipIfDexLiveUnsupported();
        DeployDexSwapsHarness harness = new DeployDexSwapsHarness(DeployBase.Environment.MAINNET, SAFE, address(this));
        (OperationsAdmin operationsAdmin, address handler, DcaManager dcaManager,) = harness.run();

        assertEq(operationsAdmin.owner(), address(this));
        assertEq(operationsAdmin.pendingOwner(), SAFE);
        assertEq(dcaManager.pendingOwner(), SAFE);
        if (handler != address(0)) {
            assertEq(BitChillOwnable(handler).pendingOwner(), SAFE);
            assertTrue(
                operationsAdmin.isPurchasePathAllowed(
                    handler, keccak256(IPurchaseUniswap(handler).getSwapPath())
                ),
                "constructor path must be allowlisted before assignment"
            );
        }
        assertEq(
            uint256(operationsAdmin.getRouteClass(TROPYKUS_INDEX)),
            uint256(IOperationsAdmin.RouteClass.Unregistered),
            "live dex path must not register the legacy Tropykus route"
        );
        assertEq(uint256(operationsAdmin.getRouteClass(SOVRYN_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DEFAULT_STABLECOIN);
        bytes32 coinHash = keccak256(abi.encodePacked(coinType));
        if (
            keccak256(abi.encodePacked(vm.envString("LENDING_PROTOCOL")))
                == keccak256(abi.encodePacked(LAYERBANK_STRING))
                && (
                    coinHash == keccak256(abi.encodePacked(USDRIF_STRING))
                        || coinHash == keccak256(abi.encodePacked(USDT0_STRING))
                )
        ) {
            assertEq(
                uint256(operationsAdmin.getRouteClass(LAYERBANK_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending)
            );
            assertNotEq(handler, address(0), "live dex path must deploy the LayerBank handler for this stable");
            assertTrue(
                operationsAdmin.isPurchasePathAllowed(
                    handler, keccak256(IPurchaseUniswap(handler).getSwapPath())
                ),
                "constructor path must be allowlisted before assignment"
            );
            vm.prank(SAFE);
            operationsAdmin.acceptOwnership();
            vm.prank(SAFE);
            dcaManager.acceptOwnership();
            vm.prank(SAFE);
            BitChillOwnable(handler).acceptOwnership();
            assertEq(operationsAdmin.owner(), SAFE);
            assertEq(dcaManager.owner(), SAFE);
            assertEq(Ownable(handler).owner(), SAFE);
            assertEq(operationsAdmin.owner(), Ownable(handler).owner());
            if (coinHash == keccak256(abi.encodePacked(USDT0_STRING))) {
                IFeeHandler.FeeSettings memory stored = IFeeHandler(handler).getFeeSettings();
                assertEq(stored.feePurchaseLowerBound, USDT0_FEE_PURCHASE_LOWER_BOUND);
                assertEq(stored.feePurchaseUpperBound, USDT0_FEE_PURCHASE_UPPER_BOUND);
                address token = _docTokenFromHandler(handler);
                (uint256 minPurchase, bool custom) = dcaManager.getTokenMinPurchaseAmount(token);
                assertTrue(custom, "DeployDexSwaps live USDT0 path must set the 6-decimal min");
                assertEq(minPurchase, USDT0_MIN_PURCHASE_AMOUNT);
            }
        }
    }

    function _skipIfMocLiveUnsupported() internal {
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DEFAULT_STABLECOIN);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked("DOC"))) {
            vm.skip(true);
            return;
        }
        if (keccak256(abi.encodePacked(vm.envString("LENDING_PROTOCOL"))) == keccak256(abi.encodePacked(TROPYKUS_STRING)))
        {
            vm.skip(true);
        }
    }

    /// @notice The live dex map is LayerBank + Sovryn. Tropykus must fail loudly, not deploy quietly.
    function test_dexLive_revertsForTropykus() public {
        if (keccak256(abi.encodePacked(vm.envString("LENDING_PROTOCOL")))
            != keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            vm.skip(true);
            return;
        }
        DeployDexSwapsHarness harness = new DeployDexSwapsHarness(DeployBase.Environment.MAINNET, SAFE, address(this));
        vm.expectRevert(bytes("Tropykus is not on the production dex map"));
        harness.run();
    }

    function _skipIfDexLiveUnsupported() internal {
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        bytes32 protocolHash = keccak256(abi.encodePacked(lendingProtocol));
        if (protocolHash == keccak256(abi.encodePacked(NONE_STRING))) {
            vm.skip(true);
            return;
        }
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DEFAULT_STABLECOIN);
        bytes32 coinHash = keccak256(abi.encodePacked(coinType));
        bool isUSDRIF = coinHash == keccak256(abi.encodePacked(USDRIF_STRING));
        bool isUSDT0 = coinHash == keccak256(abi.encodePacked(USDT0_STRING));
        bool isDOC = coinHash == keccak256(abi.encodePacked(DEFAULT_STABLECOIN));
        if (protocolHash == keccak256(abi.encodePacked(LAYERBANK_STRING)) && isDOC) {
            vm.skip(true); // LayerBank DOC dex is out of scope
            return;
        }
        if (
            protocolHash == keccak256(abi.encodePacked(SOVRYN_STRING))
                && (isUSDRIF || isUSDT0)
        ) {
            vm.skip(true);
            return;
        }
        if (protocolHash == keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            vm.skip(true); // Tropykus is off both live maps; the live dex branch reverts for it
        }
    }

    function _docTokenFromHandler(address handler) internal view returns (address) {
        // TokenHandler.i_stableToken is public immutable on every leaf.
        (bool ok, bytes memory data) = handler.staticcall(abi.encodeWithSignature("i_stableToken()"));
        require(ok && data.length >= 32, "handler has no i_stableToken");
        return abi.decode(data, (address));
    }
}

contract AddonPendingOwnerTest is BaseDeploymentTest {
    function test_idleAddOn_revertsWhenAdminOwnershipPending() public {
        vm.prank(OWNER);
        operationsAdmin.transferOwnership(makeAddr("incoming"));

        DeployIdleHandler idleDeployer = new DeployIdleHandler();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBase.DeployBase__OwnershipTransferPending.selector, makeAddr("incoming")
            )
        );
        idleDeployer.run(helperConfig, address(operationsAdmin), address(dcaManager));
    }

    function test_layerBankAddOn_revertsWhenAdminOwnershipPending() public {
        vm.prank(OWNER);
        operationsAdmin.transferOwnership(makeAddr("incoming"));

        DeployLayerBankHandler layerbankDeployer = new DeployLayerBankHandler();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBase.DeployBase__OwnershipTransferPending.selector, makeAddr("incoming")
            )
        );
        layerbankDeployer.run(helperConfig, address(operationsAdmin), address(dcaManager));
    }

    function test_usdrifAddOn_revertsWhenAdminOwnershipPending() public {
        vm.prank(OWNER);
        operationsAdmin.transferOwnership(makeAddr("incoming"));

        UsdrifHelperConfig usdrifHelperConfig = new UsdrifHelperConfig();
        usdrifHelperConfig.updateProtocolAddresses(address(operationsAdmin), address(dcaManager));
        DeployUsdrifHandler usdrifDeployer = new DeployUsdrifHandler();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployBase.DeployBase__OwnershipTransferPending.selector, makeAddr("incoming")
            )
        );
        usdrifDeployer.run(usdrifHelperConfig);
    }
}
