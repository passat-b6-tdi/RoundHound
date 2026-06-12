// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BoundaryHandler} from "./handlers/BoundaryHandler.sol";
import {StockHandler} from "./handlers/StockHandler.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract InvariantsTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant EPS = 1e9;
    uint256 constant D_TOL = 1e12;

    BoundaryHandler internal handler;

    function setUp() public {
        bool buggy = vm.envOr("ROUNDHOUND_BUGGY", false);
        handler = new BoundaryHandler(
            new MockERC20("T0", "T0"),
            new MockERC20("T1", "T1"),
            buggy
        );

        bytes4[] memory sel = new bytes4[](1);
        sel[0] = BoundaryHandler.step.selector;
        targetSelector(
            StdInvariant.FuzzSelector({addr: address(handler), selectors: sel})
        );
        targetContract(address(handler));
    }

    function invariant_noFreeMoney() public view {
        assertLt(
            handler.ghost_maxRelExcessE18(),
            EPS,
            "actor extracted significant free money vs a correct pool"
        );
    }

    function invariant_invariantNonDecrease() public view {
        assertGe(
            handler.ghost_minDRatioE18(),
            WAD - D_TOL,
            "swap dropped D below the correct execution"
        );
    }

    function invariant_shareValueMonotone() public view {
        assertGe(
            handler.ghost_minShareRatioE18(),
            WAD - D_TOL,
            "BPT share value fell below the correct execution"
        );
    }

    function test_boundary_handler_finds_leak() public {
        BoundaryHandler h = _boundaryHandler(true);
        for (uint256 ti = 6; ti < 12; ti++) {
            h.step(0, ti, 0);
            for (uint256 dy = 0; dy < 5; dy++) {
                h.step(1, 0, dy);
            }
        }
        assertGt(
            h.ghost_maxRelExcessE18(),
            EPS,
            "boundary handler must detect significant free money"
        );
        assertLt(
            h.ghost_minDRatioE18(),
            WAD - D_TOL,
            "boundary handler must see D drop vs correct"
        );
        console2.log(
            "BOUNDARY: smallest reserve reached =",
            h.ghost_minScaleReached()
        );
        console2.log(
            "BOUNDARY: worst excess/reserve (1e18) =",
            h.ghost_maxRelExcessE18()
        );
        console2.log(
            "BOUNDARY: min D_underTest/D_ref (1e18) =",
            h.ghost_minDRatioE18()
        );
        console2.log(
            "BOUNDARY: total free token1 extracted =",
            h.ghost_excessProfit()
        );
    }

    function test_stock_handler_misses() public {
        StockHandler h = _stockHandler(true);
        uint256 s = 12345;
        for (uint256 i = 0; i < 400; i++) {
            s = uint256(keccak256(abi.encode(s)));
            h.step(s, s >> 7);
        }
        assertGt(h.ghost_extractions(), 0, "stock handler should extract");
        assertLt(
            h.ghost_maxRelExcessE18(),
            EPS,
            "stock handler misses (leak negligible vs liquidity)"
        );
        assertGe(
            h.ghost_minDRatioE18(),
            WAD - D_TOL,
            "stock D ratio stays 1.0"
        );
        console2.log("STOCK: extractions =", h.ghost_extractions());
        console2.log(
            "STOCK: smallest reserve reached =",
            h.ghost_minScaleReached()
        );
        console2.log(
            "STOCK: worst excess/reserve (1e18) =",
            h.ghost_maxRelExcessE18(),
            "< EPS => MISSED"
        );
    }

    function test_roundhound_exact_catches_what_stock_missed() public {
        StockHandler h = _stockHandler(true);
        uint256 s = 999;
        for (uint256 i = 0; i < 120; i++) {
            s = uint256(keccak256(abi.encode(s)));
            h.step(s, s >> 7);
        }
        assertLt(
            h.ghost_maxRelExcessE18(),
            EPS,
            "economic check stays below tolerance (the miss)"
        );
        assertGt(
            h.ghost_maxUndercharge(),
            0,
            "exact check flags the 1wei undercharge"
        );
        console2.log(
            "ROUNDHOUND exact: max input undercharge (wei) at highliq =",
            h.ghost_maxUndercharge()
        );
    }

    function test_fixed_pool_survives_boundary() public {
        BoundaryHandler h = _boundaryHandler(false);
        for (uint256 ti = 6; ti < 12; ti++) {
            h.step(0, ti, 0);
            for (uint256 dy = 0; dy < 5; dy++) {
                h.step(1, 0, dy);
            }
        }
        assertEq(
            h.ghost_maxRelExcessE18(),
            0,
            "fixed pool yields no-free-money"
        );
        assertEq(h.ghost_maxUndercharge(), 0, "fixed pool never undercharges");
        assertEq(
            h.ghost_minDRatioE18(),
            WAD,
            "fixed pool D ratio stays exactly 1"
        );
    }

    function test_replay_counterexample() public {
        BoundaryHandler h = _boundaryHandler(true);
        console2.log(
            "===counterexample decoded: deflate liquidity, then extract (vulnerable pool)==="
        );
        console2.log(
            "pool starts healthy; token1 reserve =",
            h.pool().rawBalances(1)
        );

        while (h.pool().rawBalances(1) > 16) {
            h.step(0, 9, 0);
            console2.log(
                "  DEFLATE (proportional exit) > token1 reserve =",
                h.pool().rawBalances(1)
            );
        }

        for (uint256 k = 0; k < 12; k++) {
            uint256 reserve = h.pool().rawBalances(1);
            if (reserve <= 3) break;
            uint256 before = h.ghost_excessProfit();
            h.step(1, 0, 1);
            console2.log(
                " EXTRACT dy=2 at reserve",
                reserve,
                "> free token1 +=",
                h.ghost_excessProfit() - before
            );
        }

        console2.log("---");
        console2.log(
            "TOTAL free token1 a correct pool would NOT have given =",
            h.ghost_excessProfit()
        );
        console2.log(
            "worst single extraction, excess/reserve (1e18=100%) =",
            h.ghost_maxRelExcessE18()
        );
        assertGt(h.ghost_excessProfit(), 0, "replay must extract free money");
        assertGt(
            h.ghost_maxRelExcessE18(),
            EPS,
            "and it must be significant relative to liquidity"
        );
    }

    function _boundaryHandler(bool buggy) internal returns (BoundaryHandler) {
        return
            new BoundaryHandler(
                new MockERC20("T0", "T0"),
                new MockERC20("T1", "T1"),
                buggy
            );
    }

    function _stockHandler(bool buggy) internal returns (StockHandler) {
        return
            new StockHandler(
                new MockERC20("T0", "T0"),
                new MockERC20("T1", "T1"),
                buggy
            );
    }
}
