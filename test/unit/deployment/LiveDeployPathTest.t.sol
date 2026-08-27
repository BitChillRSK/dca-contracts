// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployBase} from "../../../script/DeployBase.s.sol";
import {DeployMocSwaps} from "../../../script/DeployMocSwaps.s.sol";
import {DeployDexSwaps} from "../../../script/DeployDexSwaps.s.sol";
import {DeployIdleHandler} from "../../../script/DeployIdleHandler.s.sol";
import {OperationsAdmin} from "../../../src/OperationsAdmin.sol";
import {DcaManager} from "../../../src/DcaManager.sol";
import {IOperationsAdmin} from "../../../src/interfaces/IOperationsAdmin.sol";
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

contract LiveDeployPathTest is Test {
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
        }
        assertEq(
            uint256(operationsAdmin.getRouteClass(TROPYKUS_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending)
        );
        assertEq(uint256(operationsAdmin.getRouteClass(SOVRYN_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));
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

    function _skipIfDexLiveUnsupported() internal {
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        bytes32 protocolHash = keccak256(abi.encodePacked(lendingProtocol));
        if (
            protocolHash == keccak256(abi.encodePacked(NONE_STRING))
                || protocolHash == keccak256(abi.encodePacked(LAYERBANK_STRING))
        ) {
            vm.skip(true);
        }
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DEFAULT_STABLECOIN);
        if (
            protocolHash == keccak256(abi.encodePacked(SOVRYN_STRING))
                && keccak256(abi.encodePacked(coinType)) == keccak256(abi.encodePacked("USDRIF"))
        ) {
            vm.skip(true);
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
}
