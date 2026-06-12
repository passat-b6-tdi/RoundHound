// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VulnerableStablePool} from "../../src/VulnerableStablePool.sol";
import {IERC20} from "../../src/helpers/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared invariant-fuzzing logic: owns the pool under test plus a rounding correct reference, and scores each extraction differentially against it
abstract contract BaseHandler {
    uint256 internal constant WAD = 1e18;

    VulnerableStablePool public pool; // under test (vulnerable or fixed)
    VulnerableStablePool public refPool; // always rounding correct
    MockERC20 internal t0;
    MockERC20 internal t1;

    uint256 public ghost_excessProfit; // cumulative free token1 vs the reference
    uint256 public ghost_maxRelExcessE18; // worst extraction's excess / reserve (1e18 == 100%)
    uint256 public ghost_minDRatioE18; // min D_underTest / D_reference over the run
    uint256 public ghost_minShareRatioE18; // min share_underTest / share_reference over the run
    uint256 public ghost_maxUndercharge; // worst per swap input undercharge vs the oracle
    uint256 public ghost_extractions;
    uint256 public ghost_minScaleReached = type(uint256).max;

    constructor(MockERC20 _t0, MockERC20 _t1, bool buggy) {
        t0 = _t0;
        t1 = _t1;
        pool = new VulnerableStablePool(
            IERC20(address(_t0)),
            IERC20(address(_t1)),
            WAD,
            (WAD * 12) / 10,
            200,
            buggy
        );
        refPool = new VulnerableStablePool(
            IERC20(address(_t0)),
            IERC20(address(_t1)),
            WAD,
            (WAD * 12) / 10,
            200,
            false
        );

        _t0.mint(address(this), 1e40);
        _t1.mint(address(this), 1e40);
        _t0.approve(address(pool), type(uint256).max);
        _t1.approve(address(pool), type(uint256).max);
        _t0.approve(address(refPool), type(uint256).max);
        _t1.approve(address(refPool), type(uint256).max);

        ghost_minDRatioE18 = WAD;
        ghost_minShareRatioE18 = WAD;
    }

    function _deflate(uint256 bps) internal {
        if (bps == 0) return;
        if (bps > 1e4) bps = 1e4;
        if (pool.rawBalances(0) < 2 || pool.rawBalances(1) < 2) return;
        pool.exitProportional(bps);
        uint256 m = pool.rawBalances(0) < pool.rawBalances(1)
            ? pool.rawBalances(0)
            : pool.rawBalances(1);
        if (m < ghost_minScaleReached) ghost_minScaleReached = m;
    }

    function _extract(uint256 dy) internal {
        uint256 s0 = pool.rawBalances(0);
        uint256 s1 = pool.rawBalances(1);
        if (dy == 0 || dy >= s1 || s0 <= 1) return;

        (int256 putNet, bool putOk) = _roundtripOn(pool, dy, true);
        if (!putOk) return;
        uint256 dPut = pool.currentD();
        uint256 sharePut = pool.shareValue();

        refPool.seed(s0, s1);
        (int256 refNet, bool refOk) = _roundtripOn(refPool, dy, false);
        if (!refOk) return;
        uint256 dRef = refPool.currentD();
        uint256 shareRef = refPool.shareValue();

        if (putNet > refNet) {
            uint256 ex = uint256(putNet - refNet);
            ghost_excessProfit += ex;
            uint256 relEx = (ex * WAD) / s1; // excess relative to liquidity, not volume
            if (relEx > ghost_maxRelExcessE18) ghost_maxRelExcessE18 = relEx;
        }
        ghost_extractions++;

        if (dRef > 0) {
            uint256 ratio = (dPut * WAD) / dRef;
            if (ratio < ghost_minDRatioE18) ghost_minDRatioE18 = ratio;
        }
        if (shareRef > 0) {
            uint256 sRatio = (sharePut * WAD) / shareRef;
            if (sRatio < ghost_minShareRatioE18) {
                ghost_minShareRatioE18 = sRatio;
            }
        }
    }

    function _roundtripOn(
        VulnerableStablePool p,
        uint256 dy,
        bool isPUT
    ) internal returns (int256 net1, bool ok) {
        if (dy >= p.rawBalances(1)) return (0, false);

        uint256 paid;
        if (isPUT) {
            paid = p.quoteGivenOut(0, 1, dy);
            uint256 required = p.correctQuoteGivenOut(0, 1, dy);
            if (required > paid && required - paid > ghost_maxUndercharge) {
                ghost_maxUndercharge = required - paid;
            }
        } else {
            paid = p.correctQuoteGivenOut(0, 1, dy);
        }
        if (paid == 0 || paid >= p.rawBalances(0)) return (0, false);

        if (isPUT) p.swapGivenOut(0, 1, dy);
        else p.swapGivenOutCorrect(0, 1, dy);

        uint256 back = isPUT
            ? p.quoteGivenOut(1, 0, paid)
            : p.correctQuoteGivenOut(1, 0, paid);
        if (back == 0 || back > p.rawBalances(1) + dy) {
            return (int256(dy), true); // leg2 not cleanly serviceable
        }

        if (isPUT) p.swapGivenOut(1, 0, paid);
        else p.swapGivenOutCorrect(1, 0, paid);
        net1 = int256(dy) - int256(back);
        ok = true;
    }
}
