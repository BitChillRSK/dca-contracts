// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Handlers} from "./handlers/Handlers.sol";

/// @dev `cool(address)` is a forge cheatcode the vendored forge-std `Vm` interface does not declare yet.
interface CoolVm {
    function cool(address target) external;
}

/// @notice Contract to be used for quick testing with Foundry
contract FoundryTester is Test, Handlers {
    modifier asActor() override {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    function setUp() public {
        setup();
    }

    // forge test --match-test test_sequence -vvv
    function test_sequence() public {
        // Add here call sequence to Handler's functions to reproduce failing property
    }

    /// @dev Harness smoke check: every route can create, buy, claim and exit.
    function test_harnessFlow() public {
        for (uint256 r; r < 5; r++) {
            dcaManager_createDcaSchedule_clamped(r, 1_000 ether, 100 ether, 1);
        }
        assertEq(trackedSchedules.length, 5);
        env_skipDays(1, 0);
        dcaManager_activateProtectedPurchaseWindow_clamped(0);
        for (uint256 r; r < 5; r++) {
            dcaManager_batchBuyRbtc_clamped(r, 0, type(uint256).max);
        }
        dcaManager_batchBuyRbtcAcrossHandlers_clamped(type(uint256).max, 0); // nothing due again today
        env_skipDays(1, 3600);
        dcaManager_batchBuyRbtcAcrossHandlers_clamped(type(uint256).max, 0);
        uint256 ethBefore = actor.balance;
        dcaManager_withdrawAllAccumulatedRbtc_clamped(0);
        assertGt(actor.balance, ethBefore);
        dcaManager_withdrawAllAccumulatedRbtc_asCollector(0, 0);
        env_bumpLayerBankIndex(false, 200);
        env_moveSovrynPrice(300, true);
        env_skipDays(5, 0);
        dcaManager_withdrawTokenAndInterest_clamped(2, 1 ether);
        dcaManager_withdrawAllAccumulatedInterest_clamped(0);
        for (uint256 i; i < 5; i++) {
            dcaManager_withdrawToken_full(i);
        }
        dcaManager_deleteDcaSchedule_clamped(0);
        assertEq(trackedSchedules.length, 4);
    }

    /// @dev Every global property holds on the fresh deployment and after the smoke sequence.
    function test_globalsHold() public {
        _checkGlobals();
        test_harnessFlow();
        _checkGlobals();
    }

    function _checkGlobals() internal {
        property_rbtcSolvency();
        property_rbtcBooksExact();
        property_rbtcAssetSplit();
        property_idleCashCoversPrincipal();
        property_idleCashExact();
        property_lendingNoRawStablecoin();
        property_virtualSharesBacked();
        property_virtualSharesExact();
        property_accruedInterestIdentity();
        property_principalBackedNoLoss();
        property_scheduleCounts();
        property_nativeConservation();
        property_stablecoinConservation();
        property_marketValueCoversUserValues();
        property_sharePreviewPositive();
        property_retiredIdsStayDead();
        property_oneBuyPerDay();
        property_windowFreeze();
        property_routesFixed();
        property_anchorOnGrid();
        property_scheduleDomains();
        property_activePathAllowlisted();
        property_settingsDomains();
        property_principalHasSharesNoLoss();
        property_windowBounded();
        property_canActivateSync();
        property_privilegedHoldNothing();
        property_previewsNeverRevert();
        property_depositPauseOnlyAssigned();
    }

    /// @dev Smoke check for the specific-property wiring: every handler added or rewired by 7B runs once on
    ///      a populated state without reverting, the funnels' success paths are reached, and the globals still hold.
    function test_specificHandlersSmoke() public {
        for (uint256 a; a < 3; a++) {
            setCurrentActor(a);
            for (uint256 r; r < 5; r++) {
                dcaManager_createDcaSchedule_clamped(r, 2_000 ether, 100 ether, 1);
            }
        }
        assertEq(trackedSchedules.length, 15);
        setCurrentActor(0);
        env_skipDays(1, 0);

        // Batches through the funnels, then claims.
        dcaManager_batchBuyRbtc_clamped(0, 0, 0);
        dcaManager_batchBuyRbtcAcrossHandlers_clamped(type(uint256).max, 0);
        dcaManager_withdrawAllAccumulatedRbtc_clamped(0);
        dcaManager_withdrawAllAccumulatedRbtc_asCollector(1, 0);
        env_skipDays(2, 100);

        // Environment and admin wrappers.
        env_bumpLayerBankIndex(false, 150);
        env_bumpLayerBankIndex(true, 150);
        env_moveSovrynPrice(500, true);
        env_setDexPrice(48_000);
        env_setOraclePrice(false, 49_000);
        env_setSovrynExitFee(0);
        env_donateStablecoin(1, 1 ether);
        env_donateETH(0, 1 ether);
        env_donateIntermediateToRouter(1 ether);
        env_skipBlocks(1);
        dcaManager_secondary(0, 15, 0);
        dcaManager_secondary(1, 1, 0);
        dcaManager_secondary(2, 25 ether, 0);
        operationsAdmin_secondary(2, 0, true);
        operationsAdmin_secondary(2, 0, false);
        operationsAdmin_secondary(1, 1, false);
        operationsAdmin_secondary(0, 1, false);
        for (uint8 sel; sel < 9; sel++) {
            layerBankHandlerDex_secondary(sel, 1, sel % 2, 0, 0);
        }
        layerBankHandlerDex_secondary(8, 1, 1, 0, 0); // allow path 1 on the LB Dex handler
        layerBankHandlerDex_secondary(7, 1, 1, 0, 0); // switch to it as the owner
        for (uint8 w; w < 3; w++) {
            operationsAdmin_remapAttempt(w, 1, 2);
        }

        // Round trips.
        uint256 tracked = trackedSchedules.length;
        roundTrip_depositWithdraw(1, 10 ether, 2, false);
        roundTrip_depositWithdraw(2, 10 ether, 1, true);
        roundTrip_depositWithdraw(0, 10 ether, 3, false);
        roundTrip_createDelete(1, 500 ether, 50 ether, 1);
        roundTrip_createDelete(3, 500 ether, 50 ether, 1);
        roundTrip_interestTwice(0);
        assertEq(trackedSchedules.length, tracked);

        // Probes and attacks.
        probe_feeCurve(0, 300 ether, 1_000 ether);
        probe_feeCurve(4, 1 ether, 7 ether);
        probe_buyOne(4);
        adv_cleanBatchLiveness(4, 0, 0);
        adv_cleanBatchLiveness(1, 0, 0);
        for (uint8 w; w < 4; w++) {
            adv_impersonateSwapper(w, 1, 0, 0, 0);
        }
        for (uint8 w; w < 7; w++) {
            adv_callHandlerDirectly(w, 1, 2, 1 ether);
        }
        for (uint8 w; w < 9; w++) {
            adv_mutateForeignSchedule(w, 3, 30 ether);
        }
        for (uint8 w; w < 17; w++) {
            adv_nonOwnerSetter(w, 2, w, w);
        }
        adv_createLiveness(2, 300 ether, 30 ether, 2);
        adv_depositLiveness(1, 5 ether);
        adv_topUpLiveness(1, 1);
        adv_withdrawLiveness(0, 1 ether, false);
        adv_withdrawLiveness(3, 0, true);
        adv_principalAndInterestLiveness(1, 1 ether);
        adv_interestLiveness(0);
        for (uint8 m; m < 6; m++) {
            adv_claimLiveness(2, 0, m);
        }
        adv_claimLiveness(3, 0, 0);
        adv_deleteLiveness(4);

        // Finding 1: two-call plan / execute, then the single-call scenario.
        env_skipDays(3, 0);
        adv_planProtectedBatch(1, 0, 0);
        adv_executeProtectedBatchWithQuote();
        env_skipBlocks(6);
        env_skipDays(3, 0);
        adv_protectedBatchScenario(2, 0, 0, 3 << 8, 50 ether, true, true);
        env_skipBlocks(6);

        // Activation and window-gated paths.
        dcaManager_activateProtectedPurchaseWindow_clamped(0);
        dcaManager_withdrawToken_clamped(0, 1 ether); // guarded: must revert UserMutationsLocked inside the window
        dcaManager_depositToken_clamped(0, 1 ether); // unguarded: allowed inside the window
        probe_buyOne(0);
        env_skipBlocks(6);

        // Rewired edit / funding wrappers, including a top-up that funds another purchase.
        setCurrentActor(2);
        dcaManager_updatePurchaseAmount_clamped(0, 120 ether);
        dcaManager_updatePurchasePeriod_clamped(1, 3);
        dcaManager_setSchedulePaused_clamped(2, true);
        dcaManager_setSchedulePaused_clamped(2, true);
        dcaManager_setSchedulePaused_clamped(2, false);
        dcaManager_depositToken_dust(3, 7);
        dcaManager_withdrawToken_full(4);
        uint256 before = trackedSchedules.length;
        dcaManager_createDcaSchedule_clamped(1, 150 ether, 100 ether, 1); // LayerBank DOC, balance % amount = 50
        assertEq(trackedSchedules.length, before + 1);
        for (uint256 i; i < 4; i++) {
            env_bumpLayerBankIndex(false, 200);
        }
        uint256 topUpSeed = _ownedIndexOf(actors[2], trackedSchedules[trackedSchedules.length - 1].scheduleId);
        adv_topUpLiveness(topUpSeed, 50 ether);
        dcaManager_topUpFromInterest_clamped(topUpSeed, 1);
        env_skipDays(5, 0);
        dcaManager_batchBuyRbtc_allRows(1);
        dcaManager_batchBuyRbtc_zeroMinOut(2, 0);

        setCurrentActor(1);
        adv_fullExitAndReenter(3, 400 ether);
        _checkGlobals();
    }

    /// @dev Regression for a harness false positive found by Medusa: on Sovryn below par the floored mint
    ///      leaves the new position worth d - 1, so the delete is clamped and keeps one share worth 0 wei.
    ///      SP-23 / SP-21 now check the share count only for unclamped trips; the value check still applies.
    function test_roundTripSovrynBelowPar() public {
        env_moveSovrynPrice(1_929, false); // 1.0137 -> ~0.818
        roundTrip_createDelete(2, 63_687_275_611_708_319_395_910, 25 ether, 1);
        roundTrip_depositWithdraw(0, 1, 0, false); // no schedule yet: returns early
        dcaManager_createDcaSchedule_clamped(2, 1_000 ether, 100 ether, 1);
        roundTrip_depositWithdraw(0, 63_687_275_611_708_319_395_910, 0, false);
        _checkGlobals();
    }

    /// @dev `_pickOwnedSchedule` seed that selects `owner`'s schedule `id`.
    function _ownedIndexOf(address owner, uint64 id) internal view returns (uint256 seed) {
        for (uint256 i; i < trackedSchedules.length; i++) {
            if (trackedSchedules[i].owner != owner) continue;
            if (trackedSchedules[i].scheduleId == id) return seed;
            seed++;
        }
    }

    /// @dev Gas guard (Medusa transactionGasLimit = 12.5M) for the heaviest wrappers with every actor at the
    ///      cap. Each one runs as an external self-call (fresh memory, as in a Medusa transaction) after every
    ///      touched account is cooled, so cold SLOAD/SSTORE pricing applies as it would in its own transaction.
    function test_specificHandlersGasNearCap() public {
        for (uint256 a; a < 3; a++) {
            setCurrentActor(a);
            for (uint256 i; i < 20; i++) {
                this.dcaManager_createDcaSchedule_clamped(i % 5, 1_000 ether, 100 ether, 1);
            }
        }
        assertGe(trackedSchedules.length, 54);
        setCurrentActor(0);
        env_skipDays(1, 0);
        _measured(
            abi.encodeCall(this.dcaManager_batchBuyRbtcAcrossHandlers_clamped, (type(uint256).max, 0)), "across batch"
        );
        env_skipDays(1, 0);
        _measured(
            abi.encodeCall(this.adv_protectedBatchScenario, (1, 0, 0, 0, 50 ether, true, true)),
            "protected batch scenario"
        );
        env_skipBlocks(6);
        _measured(abi.encodeCall(this.dcaManager_activateProtectedPurchaseWindow_clamped, (1)), "activation");
        env_skipBlocks(6);
        _measured(abi.encodeCall(this.env_skipDays, (2, 0)), "env skip");
        _measured(
            abi.encodeCall(this.dcaManager_withdrawTokenAndInterest_clamped, (1, 1 ether)), "withdrawTokenAndInterest"
        );
        _measured(abi.encodeCall(this.dcaManager_createDcaSchedule_clamped, (1, 1_000 ether, 100 ether, 1)), "create");
        _measured(abi.encodeCall(this.dcaManager_batchBuyRbtc_allRows, (2)), "batch all rows");
        _measured(abi.encodeCall(this.adv_fullExitAndReenter, (1, 400 ether)), "full exit");
        _checkGlobals();
    }

    function _measured(bytes memory data, string memory what) internal {
        _coolAll();
        uint256 g = gasleft();
        (bool ok,) = address(this).call(data);
        uint256 used = g - gasleft();
        assertTrue(ok, what);
        console.log(what, used);
        assertLt(used + 21_000, 12_500_000, what);
    }

    function _coolAll() internal {
        CoolVm c = CoolVm(address(vm));
        c.cool(address(this));
        c.cool(address(dcaManager));
        c.cool(address(operationsAdmin));
        c.cool(address(doc));
        c.cool(address(usdrif));
        c.cool(address(usdt0));
        c.cool(address(wrbtc));
        c.cool(address(mocProxy));
        c.cool(address(swapRouter));
        c.cool(address(mocOracle));
        c.cool(address(mocOracleAlt));
        c.cool(address(sovrynIToken));
        c.cool(address(layerBankATokenDoc));
        c.cool(address(layerBankPoolDoc));
        c.cool(address(layerBankATokenUsdrif));
        c.cool(address(layerBankPoolUsdrif));
        for (uint256 k; k < routes.length; k++) {
            c.cool(routes[k].handler);
        }
        for (uint256 a; a < actors.length; a++) {
            c.cool(actors[a]);
        }
        c.cool(feeCollector);
    }

    // ── Violation Repros (auto-generated by Step 11) ──────────────────
    // Each test_repro_* function below replays a shrunk fuzzer call
    // sequence that violated a property. Run all with:
    //   forge test --match-contract FoundryTester -vvv

    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;

    /// @dev Medusa ran both shrunk sequences at block 25, timestamp 25, with no delay between calls.
    function _toMedusaStart() internal {
        vm.roll(25);
        vm.warp(25);
    }

    function _assertPanicked(bytes memory err) internal {
        assertEq(bytes4(err), PANIC_SELECTOR, "expected an assertion panic");
        uint256 code;
        assembly {
            code := mload(add(err, 36))
        }
        assertEq(code, 0x01, "expected panic code 0x01 (assertion failed)");
    }

    /// @dev SP-64 (EXPLORATORY), Finding 1 / "deposits in the protected window" lead. Alice re-enters LayerBank
    ///      with purchaseAmount == deposit; the half-up mint leaves her row clamped (all shares) at planning.
    ///      Inside the window an unguarded `depositToken` un-clamps it, so the batch burns one share more
    ///      than planned (45339366870081688524800 vs 45339366870081688524799).
    function test_repro_adv_protectedBatchScenario() public {
        _toMedusaStart();
        adv_fullExitAndReenter(
            21024335355776915299101188012106854391436269275498184707108144420689833445126,
            177684100258073654261007264031024834504374210172652464502406003705877663695
        );
        try this._repro_helper1() {
            revert("assertion should have fired");
        } catch (bytes memory err) {
            _assertPanicked(err);
        }
    }

    function _repro_helper1() external {
        adv_protectedBatchScenario(
            1975002696069456087214340238281671596821,
            421249970143250876261811275459913810280165123251885570202849875862,
            2204170690891626633309222478778813937632695548626627593618633,
            6739986666787659948716747286684485514180790527444378453215531223095,
            1606938044071917663131576722572516091220514129647059794356917,
            false,
            true
        );
    }

    /// @dev GL-15 (EXPLORATORY). The owner sets DOC's minimum purchase amount to 1 wei; at iToken price
    ///      1.0137e18 a 1-wei Sovryn deposit previews zero shares. Governance-only configuration.
    function test_repro_property_sharePreviewPositive() public {
        _toMedusaStart();
        dcaManager_secondary(
            20,
            400123900000000000000000000,
            42396913941755556936654186938328322142679471649784381576262641083582743421624
        );
        try this._repro_helper2() {
            revert("assertion should have fired");
        } catch (bytes memory err) {
            _assertPanicked(err);
        }
    }

    function _repro_helper2() external {
        property_sharePreviewPositive();
    }
}
