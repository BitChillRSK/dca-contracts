// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @notice Reproducible R114 purchase-cost measurements against local protocol mocks.
 * @dev Adapted from the independent review's measurement probe. Gas and access recording run in
 *      separate tests from identical post-setUp state. The recorder warms storage before reporting
 *      accesses, so gas measured with it active would be invalid. Run under the deploy profile.
 */
import {BaseDeploymentTest} from "test/unit/deployment/BaseDeploymentTest.t.sol";
import {DeployIdleHandler} from "script/DeployIdleHandler.s.sol";
import {DeployLayerBankHandler} from "script/DeployLayerBankHandler.s.sol";
import {LayerBankDocHandlerMoc} from "src/layerbank/LayerBankDocHandlerMoc.sol";
import {IOperationsAdmin} from "src/interfaces/IOperationsAdmin.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {toBatch} from "test/utils/BatchBuyOne.sol";
import "test/Constants.sol";

struct Tally {
    uint256 calls; // CALL / STATICCALL / DELEGATECALL / CALLCODE
    uint256 ext700; // EXTCODESIZE / EXTCODECOPY
    uint256 ext400; // BALANCE / EXTCODEHASH
    uint256 sloads;
    uint256 sstoreSet; // zero -> non-zero
    uint256 sstoreClear; // non-zero -> zero
    uint256 sstoreReset; // non-zero -> different non-zero
    uint256 sstoreSame; // value unchanged
    uint256 foundryAccessGas; // what Cancun charged for all of the above
}

abstract contract AccessPricer {
    address private constant VM_ADDR = address(uint160(uint256(keccak256("hevm cheat code"))));
    address private constant CONSOLE_ADDR = 0x000000000000000000636F6e736F6c652e6c6f67;

    mapping(bytes32 => bool) private s_warmSlot;
    mapping(bytes32 => bool) private s_hasOriginal;
    mapping(bytes32 => bytes32) private s_original;
    mapping(address => bool) private s_warmAccount;

    // Per-callee counters, to say where the extra work is.
    mapping(address => uint256) internal s_callsInto;
    mapping(address => uint256) internal s_sloadsIn;
    mapping(address => uint256) internal s_sstoresIn;

    function _prewarm(address account) internal {
        s_warmAccount[account] = true;
    }

    function _price(VmSafe.AccountAccess[] memory accesses) internal returns (Tally memory t) {
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.account == VM_ADDR || a.account == CONSOLE_ADDR) continue;
            VmSafe.AccountAccessKind kind = a.kind;
            if (
                kind == VmSafe.AccountAccessKind.Call || kind == VmSafe.AccountAccessKind.StaticCall
                    || kind == VmSafe.AccountAccessKind.DelegateCall || kind == VmSafe.AccountAccessKind.CallCode
            ) {
                ++t.calls;
                ++s_callsInto[a.account];
                t.foundryAccessGas += _touchAccount(a.account);
            } else if (kind == VmSafe.AccountAccessKind.Extcodesize || kind == VmSafe.AccountAccessKind.Extcodecopy) {
                ++t.ext700;
                t.foundryAccessGas += _touchAccount(a.account);
            } else if (kind == VmSafe.AccountAccessKind.Balance || kind == VmSafe.AccountAccessKind.Extcodehash) {
                ++t.ext400;
                t.foundryAccessGas += _touchAccount(a.account);
            } else if (kind != VmSafe.AccountAccessKind.Resume) {
                revert("unexpected access kind in a purchase");
            }

            for (uint256 j; j < a.storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory s = a.storageAccesses[j];
                require(!s.reverted, "reverted storage access in a successful purchase");
                bytes32 key = keccak256(abi.encode(s.account, s.slot));
                bool cold = !s_warmSlot[key];
                s_warmSlot[key] = true;
                if (!s_hasOriginal[key]) {
                    s_hasOriginal[key] = true;
                    s_original[key] = s.previousValue;
                }
                if (!s.isWrite) {
                    ++t.sloads;
                    ++s_sloadsIn[s.account];
                    t.foundryAccessGas += cold ? 2100 : 100;
                    continue;
                }
                ++s_sstoresIn[s.account];
                if (cold) t.foundryAccessGas += 2100;
                if (s.newValue == s.previousValue) {
                    ++t.sstoreSame;
                    t.foundryAccessGas += 100;
                    continue;
                }
                if (s.previousValue == bytes32(0)) ++t.sstoreSet;
                else if (s.newValue == bytes32(0)) ++t.sstoreClear;
                else ++t.sstoreReset;
                if (s.previousValue == s_original[key]) {
                    t.foundryAccessGas += s_original[key] == bytes32(0) ? 20000 : 2900;
                } else {
                    t.foundryAccessGas += 100;
                }
            }
        }
    }

    function _touchAccount(address account) private returns (uint256 gas) {
        gas = s_warmAccount[account] ? 100 : 2600;
        s_warmAccount[account] = true;
    }
}

/*//////////////////////////////////////////////////////////////
        SELF-CHECK: the simulator against known arithmetic
//////////////////////////////////////////////////////////////*/

contract R114Micro {
    uint256 public a = 1;
    uint256 public b = 2;
    uint256 public c;

    function run() external returns (uint256 x) {
        x = a + b;
        c = x;
        a = 5;
    }
}

/// @dev Measures inside its own call frame, so both measurements start from identical memory.
contract R114MicroCaller {
    function go(R114Micro micro) external returns (uint256 gasUsed) {
        gasUsed = gasleft();
        micro.run();
        gasUsed -= gasleft();
    }
}

contract R114SelfCheckTest is Test, AccessPricer {
    R114Micro private s_micro;
    R114MicroCaller private s_caller;

    function setUp() public {
        s_micro = new R114Micro();
        s_caller = new R114MicroCaller();
        // Touch every slot here. If warmth leaked from setUp into the test, call one below would be warm.
        s_micro.run();
    }

    /// @dev No recording here: an active state-diff recorder pre-reads every slot it reports, which
    ///      warms the slot before the opcode runs and bills a cold read as a warm one.
    function test_selfCheck_measuredColdWarmDifference() public {
        R114MicroCaller caller = s_caller;
        R114Micro micro = s_micro;
        uint256 gasCold = caller.go(micro);
        uint256 gasWarm = caller.go(micro);
        console.log("SELFCHECK measured cold/warm:", gasCold, gasWarm);
        // Run 1: cold micro 2600, SLOAD a 2100, SLOAD b 2100, SSTORE c cold non-zero change 5000,
        // SSTORE a warm unchanged 100 = 11,900. Run 2: five warm touches = 500.
        assertEq(gasCold - gasWarm, 11_400, "a test starts cold and Cancun prices are as modelled");
    }

    function test_selfCheck_simulatedColdWarmDifference() public {
        _prewarm(address(this));
        // The outer call into the caller sits outside the measured region; it adds 100 to both runs.
        _prewarm(address(s_caller));
        Tally memory cold = _record();
        Tally memory warm = _record();
        console.log("SELFCHECK simulated cold/warm:", cold.foundryAccessGas, warm.foundryAccessGas);
        assertEq(cold.foundryAccessGas, 12_000, "cold run");
        assertEq(warm.foundryAccessGas, 600, "warm run");
        assertEq(cold.foundryAccessGas - warm.foundryAccessGas, 11_400, "matches the measured difference");
        assertEq(cold.calls, 2, "outer call plus the micro call");
        assertEq(cold.sloads, 2, "an SSTORE must not also be recorded as a read");
        assertEq(cold.sstoreReset, 1);
        assertEq(cold.sstoreSame, 1);
    }

    function _record() private returns (Tally memory t) {
        R114MicroCaller caller = s_caller;
        R114Micro micro = s_micro;
        vm.startStateDiffRecording();
        caller.go(micro);
        t = _price(vm.stopAndReturnStateDiff());
    }
}

/*//////////////////////////////////////////////////////////////
                    PURCHASE-PATH PROBES
//////////////////////////////////////////////////////////////*/

abstract contract R114PurchaseClampGasBase is BaseDeploymentTest, AccessPricer {
    address internal constant SWAPPER = address(0x3333);

    MockStablecoin internal docToken;
    MockMocProxy internal mocProxy;
    LayerBankDocHandlerMoc internal handler;

    uint256 internal constant PROBE_DEPOSIT = 1000 ether;
    uint256 internal constant PROBE_PURCHASE = 25 ether;

    uint64[] internal s_rows;
    uint256 internal s_buyerCount;

    function _label() internal pure virtual returns (string memory);
    function _numBuyers() internal pure virtual returns (uint256);
    /// @dev Schedules this buyer holds for the token on the measured route.
    function _held(uint256 buyer) internal pure virtual returns (uint256);
    /// @dev How many of those are rows of the measured batch.
    function _rowsOf(uint256 buyer) internal pure virtual returns (uint256);

    function _route() internal pure virtual returns (uint256) {
        return LAYERBANK_INDEX;
    }

    function _measuredHandler() internal view returns (address) {
        return _route() == LAYERBANK_INDEX ? address(handler) : docHandlerMoc;
    }

    function setUp() public virtual override {
        if (
            block.chainid != ANVIL_CHAIN_ID
                || keccak256(bytes(vm.envString("SWAP_TYPE"))) != keccak256(bytes("mocSwaps"))
                || keccak256(bytes(vm.envString("STABLECOIN_TYPE"))) != keccak256(bytes("DOC"))
        ) {
            vm.skip(true);
            return;
        }
        super.setUp();
        // Same wiring as LayerBankDcaManagerTest.setUp (not virtual, so repeated here).
        handler = LayerBankDocHandlerMoc(
            payable(new DeployLayerBankHandler()
                    .deployMocksAndHandler(
                        address(dcaManager),
                        helperConfig.getStablecoin(),
                        helperConfig.getActiveNetworkConfig().mocProxy,
                        makeAddr(FEE_COLLECTOR_STRING),
                        operationsAdmin.owner()
                    ))
        );
        docToken = MockStablecoin(helperConfig.getStablecoin());
        mocProxy = MockMocProxy(helperConfig.getActiveNetworkConfig().mocProxy);
        vm.startPrank(OWNER);
        if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        }
        operationsAdmin.addSwapper(SWAPPER);
        operationsAdmin.assignHandler(address(docToken), LAYERBANK_INDEX, address(handler));
        vm.stopPrank();
        vm.deal(address(mocProxy), 100 ether);
        vm.prank(address(handler));
        docToken.approve(address(mocProxy), type(uint256).max);

        if (_route() == IDLE_INDEX) {
            docHandlerMoc = new DeployIdleHandler()
                .deployIdleDocHandlerMoc(
                    DeployIdleHandler.DeployParams({
                    dcaManager: address(dcaManager),
                    stablecoin: address(docToken),
                    mocProxy: address(mocProxy),
                    feeCollector: makeAddr(FEE_COLLECTOR_STRING),
                    initialOwner: OWNER
                })
                );
        }
        address target = _measuredHandler();
        if (_route() != LAYERBANK_INDEX) {
            vm.prank(OWNER);
            operationsAdmin.assignHandler(address(docToken), IDLE_INDEX, target);
            vm.prank(target);
            docToken.approve(address(mocProxy), type(uint256).max);
        }
        s_buyerCount = _numBuyers();
        for (uint256 b; b < s_buyerCount; ++b) {
            address buyer = address(uint160(uint256(keccak256(abi.encode("r114.probe.buyer", b)))));
            docToken.mint(buyer, 100_000 ether);
            vm.startPrank(buyer);
            docToken.approve(target, type(uint256).max);
            for (uint256 k; k < _held(b); ++k) {
                dcaManager.createDcaSchedule(
                    address(docToken), PROBE_DEPOSIT, PROBE_PURCHASE, MIN_PURCHASE_PERIOD, _route()
                );
                if (k < _rowsOf(b)) s_rows.push(uint64(dcaManager.getSchedulesCreatedCount()));
            }
            vm.stopPrank();
        }
        // One purchase of every measured row first, so the measured tick is a steady-state one:
        // non-zero cadence anchor, live accumulated-rBTC slots, shares left over, interest accrued.
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(s_rows, address(docToken), _route()));
        vm.warp(block.timestamp + MIN_PURCHASE_PERIOD);
    }

    /// @dev Clean Foundry gas: nothing is recording, so cold reads are billed cold.
    function test_probe_gas() public {
        IDcaManager.Batch memory batch = toBatch(s_rows, address(docToken), _route());
        IDcaManager manager = IDcaManager(address(dcaManager));
        vm.prank(SWAPPER);
        uint256 gasUsed = gasleft();
        manager.batchBuyRbtc(batch);
        gasUsed -= gasleft();
        console.log(
            string.concat(
                "R114GAS|",
                _label(),
                "|rows=",
                vm.toString(s_rows.length),
                "|buyers=",
                vm.toString(s_buyerCount),
                "|foundryGas=",
                vm.toString(gasUsed)
            )
        );
    }

    /// @dev Same call from the same post-setUp state, recorded. Gas is not read here.
    function test_probe_accesses() public {
        IDcaManager.Batch memory batch = toBatch(s_rows, address(docToken), _route());
        IDcaManager manager = IDcaManager(address(dcaManager));
        _prewarm(address(this));
        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.prank(SWAPPER);
        manager.batchBuyRbtc(batch);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Tally memory t = _price(accesses);
        _report(t, logs.length);
    }

    function _report(Tally memory t, uint256 logCount) private view {
        address target = _measuredHandler();
        string memory line = string.concat(
            "R114ACC|",
            _label(),
            "|rows=",
            vm.toString(s_rows.length),
            "|buyers=",
            vm.toString(s_buyerCount),
            "|foundryAccessGas=",
            vm.toString(t.foundryAccessGas)
        );
        line = string.concat(
            line,
            "|calls=",
            vm.toString(t.calls),
            "|ext700=",
            vm.toString(t.ext700),
            "|ext400=",
            vm.toString(t.ext400),
            "|sloads=",
            vm.toString(t.sloads)
        );
        line = string.concat(
            line,
            "|sset=",
            vm.toString(t.sstoreSet),
            "|sclear=",
            vm.toString(t.sstoreClear),
            "|sreset=",
            vm.toString(t.sstoreReset),
            "|ssame=",
            vm.toString(t.sstoreSame),
            "|logs=",
            vm.toString(logCount)
        );
        line = string.concat(
            line,
            "|callsIntoManager=",
            vm.toString(s_callsInto[address(dcaManager)]),
            "|callsIntoAdmin=",
            vm.toString(s_callsInto[address(operationsAdmin)]),
            "|callsIntoHandler=",
            vm.toString(s_callsInto[target])
        );
        line = string.concat(
            line,
            "|sloadsManager=",
            vm.toString(s_sloadsIn[address(dcaManager)]),
            "|sloadsAdmin=",
            vm.toString(s_sloadsIn[address(operationsAdmin)]),
            "|sloadsHandler=",
            vm.toString(s_sloadsIn[target]),
            "|sstoresHandler=",
            vm.toString(s_sstoresIn[target])
        );
        console.log(line);
    }
}

contract R114ClampGasLendingTenRows is R114PurchaseClampGasBase {
    function _label() internal pure override returns (string memory) {
        return "lending/unique/k=1/N=10";
    }

    function _numBuyers() internal pure override returns (uint256) {
        return 10;
    }

    function _held(uint256) internal pure override returns (uint256) {
        return 1;
    }

    function _rowsOf(uint256) internal pure override returns (uint256) {
        return 1;
    }
}

contract R114ClampGasLendingTenHeldSchedules is R114PurchaseClampGasBase {
    function _label() internal pure override returns (string memory) {
        return "lending/unique/k=10/N=10";
    }

    function _numBuyers() internal pure override returns (uint256) {
        return 10;
    }

    function _held(uint256) internal pure override returns (uint256) {
        return 10;
    }

    function _rowsOf(uint256) internal pure override returns (uint256) {
        return 1;
    }
}

contract R114ClampGasIdleTenRows is R114PurchaseClampGasBase {
    function _label() internal pure override returns (string memory) {
        return "idle/unique/k=1/N=10";
    }

    function _route() internal pure override returns (uint256) {
        return IDLE_INDEX;
    }

    function _numBuyers() internal pure override returns (uint256) {
        return 10;
    }

    function _held(uint256) internal pure override returns (uint256) {
        return 1;
    }

    function _rowsOf(uint256) internal pure override returns (uint256) {
        return 1;
    }
}
