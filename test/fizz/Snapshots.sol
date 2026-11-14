// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "./Base.sol";

/// @notice Used to take snapshots of the state before and after a function call
/// @dev Index conventions (fizz_data/property-plan.md §7):
///      A = `_accounts()` index 0..3 (3 = initial fee collector); K = `routes` index 0..4;
///      actor tables use 0..2; Dex tables use `dexHandlers` index 0..1; token index 0 = DOC, 1 = USDRIF.
///      No read here reverts: getters that can revert are wrapped and set a `*ReadFailed` / `*Missing` flag.
abstract contract Snapshots is Base {
    struct State {
        // Accounts
        uint256[4] native;
        uint256[4] doc;
        uint256[4] usdrif;
        uint256[5][4] claim; // claim[A][K]
        uint256[5][4] shares; // shares[A][K], 0 on idle routes
        uint256[5][4] rawAccRbtc; // raw `s_accumulatedRbtc` slot (H8), [A][K]
        uint256[5][3] interest; // interest[actor][K], 0 on idle routes
        bool interestReadFailed;
        uint256[5][3] principal; // principal[actor][K] = Σ tokenBalance of tracked schedules
        bool principalReadFailed;
        // Handlers, per route K
        uint256[5] handlerStable;
        uint256[5] handlerNative;
        uint256[5] handlerWrbtc;
        uint256[5] receipt;
        uint256[5] rate;
        IPurchaseFees.FeeSettings[5] feeSettings;
        address[5] feeCollector;
        bool[5] depositsPaused;
        address[5] handlerOf;
        // Dex handlers, per `dexHandlers` index
        bytes32[2] pathHash;
        bool[2][2] pathAllowed; // pathAllowed[dex][path]: path 0 direct, path 1 via USDT0
        uint256[2] percent;
        uint256[2] safety;
        address[2] oracle;
        bool[2] oracleValid;
        uint256[2] oraclePrice;
        // DcaManager / OperationsAdmin
        uint256 unlock;
        uint256 blockNumber;
        uint256 timestamp;
        uint256 nonce;
        uint256 minPeriod;
        uint256 maxSchedules;
        uint256[2] minAmount; // [token]
        bool[2] isSwapper; // [swapper]
        bytes32[2][3] idsHash; // idsHash[actor][token] = keccak256(abi.encode(ids))
        uint256[2][3] idsLen;
        // Venues
        uint256 routerUsdrif;
        uint256 sovrynExitFee;
        uint256 sovrynPrice;
        uint256[2] lbIndex; // [0] DOC market, [1] USDRIF market
        // Tracked schedules, snapshotBefore only (stateAfter leaves schedCount = 0)
        uint256 schedCount;
        address[64] schedToken;
        uint64[64] schedId;
        address[64] schedOwner;
        IDcaManager.DcaSchedule[64] sched;
        bool[64] schedMissing; // getDcaSchedule reverted
    }

    State internal stateBefore;
    State internal stateAfter;

    /// @notice One handler's slice of a batch call, captured before the call.
    struct BatchRows {
        uint256 routeK; // type(uint256).max if (token, routeIndex) is not a harness route
        address handler; // OperationsAdmin's handler for the pair (0 if unassigned)
        address token;
        uint256 routeIndex;
        uint256 minRbtcOut;
        uint64[] ids;
        address[] buyers; // pre[i].user
        uint256[] amounts; // pre[i].purchaseAmount
        IDcaManager.DcaSchedule[] pre;
        bool[] rowMissing; // getDcaSchedule reverted for that row
    }

    /// @notice Per-handler state captured before a batch call (indexed by route K).
    struct HandlerCtx {
        bool touched;
        uint256 rows; // rows routed to this handler across all batches of the call
        uint256 rate;
        uint256 exitFeeBps; // Sovryn only
        IPurchaseFees.FeeSettings feeSettings;
        address collector;
        uint256 rbtcAsset;
        uint256 receipt;
        bool oracleValid; // Dex only
        uint256 oraclePrice; // Dex only
        uint256 percent; // Dex only
    }

    struct BatchCtx {
        bool set;
        bool truncated; // more than MAX_CTX_BATCHES batches or MAX_CTX_ROWS rows in one: rows beyond were not captured
        BatchRows[] batches;
        HandlerCtx[5] perRoute;
        uint256 routerUsdrif;
        uint256 today;
        uint256 blockNumber;
        uint256 unlock;
        bool windowLive;
    }

    uint256 internal constant MAX_CTX_BATCHES = 8;
    uint256 internal constant MAX_CTX_ROWS = 32;

    BatchCtx internal batchCtx;

    // ――――――――――――――――――――――――― Snapshots ――――――――――――――――――――――――――

    function snapshotBefore() internal {
        _takeSnapshot(stateBefore, true);
    }

    function snapshotAfter() internal {
        _takeSnapshot(stateAfter, false);
    }

    function _takeSnapshot(State storage s, bool withSchedules) private {
        _snapAccounts(s);
        _snapHandlers(s);
        _snapDex(s);
        _snapManager(s);
        _snapIdLists(s);
        _snapVenues(s);
        _snapInterest(s);
        if (withSchedules) {
            _snapSchedules(s);
        } else {
            s.schedCount = 0;
            (uint256[5][3] memory L, bool failed) = _principalTable();
            _storePrincipal(s, L, failed);
        }
    }

    function _snapAccounts(State storage s) private {
        address[4] memory accts = _accounts();
        for (uint256 a; a < 4; a++) {
            s.native[a] = accts[a].balance;
            s.doc[a] = doc.balanceOf(accts[a]);
            s.usdrif[a] = usdrif.balanceOf(accts[a]);
            for (uint256 k; k < 5; k++) {
                address h = routes[k].handler;
                s.claim[a][k] = claim(accts[a], h);
                s.shares[a][k] = shares(accts[a], h);
                s.rawAccRbtc[a][k] = _rawAccRbtc(accts[a], h);
            }
        }
    }

    function _snapHandlers(State storage s) private {
        for (uint256 k; k < 5; k++) {
            Route storage r = routes[k];
            address h = r.handler;
            s.handlerStable[k] = MockStablecoin(r.token).balanceOf(h);
            s.handlerNative[k] = h.balance;
            s.handlerWrbtc[k] = wrbtc.balanceOf(h);
            s.receipt[k] = receipt(h);
            s.rate[k] = rate(h);
            s.feeSettings[k] = IPurchaseFees(h).getFeeSettings();
            s.feeCollector[k] = IPurchaseFees(h).getFeeCollector();
            s.depositsPaused[k] = operationsAdmin.areDepositsPaused(r.token, r.routeIndex);
            s.handlerOf[k] = operationsAdmin.getHandler(r.token, r.routeIndex);
        }
    }

    function _snapDex(State storage s) private {
        bytes32 path0 = keccak256(_dexPath(0));
        bytes32 path1 = keccak256(_dexPath(1));
        for (uint256 d; d < 2; d++) {
            IPurchaseUniswap u = IPurchaseUniswap(dexHandlers[d]);
            s.pathHash[d] = keccak256(u.getSwapPath());
            s.pathAllowed[d][0] = u.isPurchasePathAllowed(path0);
            s.pathAllowed[d][1] = u.isPurchasePathAllowed(path1);
            s.percent[d] = u.getAmountOutMinimumPercent();
            s.safety[d] = u.getAmountOutMinimumSafetyCheck();
            s.oracle[d] = address(u.getMocOracle());
            (s.oraclePrice[d], s.oracleValid[d]) = _oracleInfo(address(u));
        }
    }

    function _snapManager(State storage s) private {
        s.unlock = dcaManager.getUserMutationsAllowedFromBlock();
        s.blockNumber = block.number;
        s.timestamp = block.timestamp;
        s.nonce = dcaManager.getSchedulesCreatedCount();
        s.minPeriod = dcaManager.getMinPurchasePeriod();
        s.maxSchedules = dcaManager.getMaxSchedulesPerToken();
        s.minAmount[0] = dcaManager.getTokenMinPurchaseAmount(address(doc));
        s.minAmount[1] = dcaManager.getTokenMinPurchaseAmount(address(usdrif));
        s.isSwapper[0] = operationsAdmin.isSwapper(swappers[0]);
        s.isSwapper[1] = operationsAdmin.isSwapper(swappers[1]);
    }

    function _snapIdLists(State storage s) private {
        for (uint256 a; a < 3; a++) {
            for (uint256 t; t < 2; t++) {
                address token = t == 0 ? address(doc) : address(usdrif);
                try dcaManager.getDcaSchedules(actors[a], token) returns (
                    uint64[] memory ids, IDcaManager.DcaSchedule[] memory
                ) {
                    s.idsHash[a][t] = keccak256(abi.encode(ids));
                    s.idsLen[a][t] = ids.length;
                } catch {
                    s.idsHash[a][t] = bytes32(0);
                    s.idsLen[a][t] = type(uint256).max;
                }
            }
        }
    }

    function _snapVenues(State storage s) private {
        s.routerUsdrif = usdrif.balanceOf(address(swapRouter));
        s.sovrynExitFee = sovrynIToken.getExitFeeBps();
        s.sovrynPrice = sovrynIToken.tokenPrice();
        s.lbIndex[0] = layerBankATokenDoc.getNormalizedIncome();
        s.lbIndex[1] = layerBankATokenUsdrif.getNormalizedIncome();
    }

    function _snapInterest(State storage s) private {
        bool failed;
        for (uint256 a; a < 3; a++) {
            for (uint256 k; k < 5; k++) {
                (uint256 v, bool f) = _interest(actors[a], k);
                s.interest[a][k] = v;
                if (f) failed = true;
            }
        }
        s.interestReadFailed = failed;
    }

    /// @dev Copies up to 64 tracked schedules and, in the same pass, sums principal over ALL tracked ones.
    function _snapSchedules(State storage s) private {
        uint256[5][3] memory L;
        bool failed;
        uint256 len = trackedSchedules.length;
        s.schedCount = len < 64 ? len : 64;
        for (uint256 i; i < len; i++) {
            TrackedSchedule memory ts = trackedSchedules[i];
            bool missing;
            IDcaManager.DcaSchedule memory d;
            try dcaManager.getDcaSchedule(ts.token, ts.scheduleId) returns (IDcaManager.DcaSchedule memory got) {
                d = got;
            } catch {
                missing = true;
                failed = true;
            }
            if (!missing) {
                uint256 a = _actorIndex(ts.owner);
                uint256 k = _routeKOf(ts.token, ts.routeIndex);
                if (a < 3 && k < 5) L[a][k] += d.tokenBalance;
            }
            if (i < 64) {
                s.schedToken[i] = ts.token;
                s.schedId[i] = ts.scheduleId;
                s.schedOwner[i] = ts.owner;
                s.sched[i] = d;
                s.schedMissing[i] = missing;
            }
        }
        _storePrincipal(s, L, failed);
    }

    function _storePrincipal(State storage s, uint256[5][3] memory L, bool failed) private {
        for (uint256 a; a < 3; a++) {
            for (uint256 k; k < 5; k++) {
                s.principal[a][k] = L[a][k];
            }
        }
        s.principalReadFailed = failed;
    }

    /// @return Index of (token, id) in `stateBefore`'s schedule copy, or `type(uint256).max`.
    function _beforeSchedIndex(address token, uint64 id) internal view returns (uint256) {
        uint256 n = stateBefore.schedCount;
        for (uint256 i; i < n; i++) {
            if (stateBefore.schedId[i] == id && stateBefore.schedToken[i] == token) return i;
        }
        return type(uint256).max;
    }

    // ――――――――――――――――――――――――― Batch context ――――――――――――――――――――――――――

    /// @notice Pre-batch capture for the batch funnels (H2). Call right after `snapshotBefore()`;
    ///         a single `batchBuyRbtc` passes a one-element array.
    function _captureBatchCtx(IDcaManager.Batch[] memory batches) internal {
        BatchCtx storage c = batchCtx;
        delete c.batches;
        for (uint256 k; k < 5; k++) {
            delete c.perRoute[k];
        }
        c.set = true;
        c.truncated = batches.length > MAX_CTX_BATCHES;
        c.routerUsdrif = usdrif.balanceOf(address(swapRouter));
        c.today = _today();
        c.blockNumber = block.number;
        c.unlock = dcaManager.getUserMutationsAllowedFromBlock();
        c.windowLive = block.number < c.unlock;
        uint256 n = batches.length < MAX_CTX_BATCHES ? batches.length : MAX_CTX_BATCHES;
        for (uint256 b; b < n; b++) {
            _captureBatchRows(c, batches[b]);
        }
    }

    function _captureBatchRows(BatchCtx storage c, IDcaManager.Batch memory batch) private {
        BatchRows storage br = c.batches.push();
        br.token = batch.token;
        br.routeIndex = batch.routeIndex;
        br.minRbtcOut = batch.minRbtcOut;
        br.routeK = _routeKOf(batch.token, batch.routeIndex);
        br.handler = _handlerOrZero(batch.token, batch.routeIndex);
        uint256 rows = batch.scheduleIds.length;
        if (rows > MAX_CTX_ROWS) {
            rows = MAX_CTX_ROWS;
            c.truncated = true;
        }
        for (uint256 i; i < rows; i++) {
            uint64 id = batch.scheduleIds[i];
            br.ids.push(id);
            try dcaManager.getDcaSchedule(batch.token, id) returns (IDcaManager.DcaSchedule memory d) {
                br.pre.push(d);
                br.buyers.push(d.user);
                br.amounts.push(d.purchaseAmount);
                br.rowMissing.push(false);
            } catch {
                br.pre.push();
                br.buyers.push(address(0));
                br.amounts.push(0);
                br.rowMissing.push(true);
            }
        }
        if (br.routeK < 5) {
            HandlerCtx storage hc = c.perRoute[br.routeK];
            hc.rows += batch.scheduleIds.length;
            if (!hc.touched) _captureHandlerCtx(hc, routes[br.routeK].handler);
        }
    }

    function _captureHandlerCtx(HandlerCtx storage hc, address h) private {
        hc.touched = true;
        hc.rate = rate(h);
        hc.exitFeeBps = isSov(h) ? sovrynIToken.getExitFeeBps() : 0;
        hc.feeSettings = IPurchaseFees(h).getFeeSettings();
        hc.collector = IPurchaseFees(h).getFeeCollector();
        hc.rbtcAsset = rbtcAsset(h);
        hc.receipt = receipt(h);
        if (isDex(h)) {
            (hc.oraclePrice, hc.oracleValid) = _oracleInfo(h);
            hc.percent = IPurchaseUniswap(h).getAmountOutMinimumPercent();
        }
    }
}
