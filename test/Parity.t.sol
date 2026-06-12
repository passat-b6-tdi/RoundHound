// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VulnerableStablePool} from "../src/VulnerableStablePool.sol";
import {IERC20} from "../src/helpers/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ParityTest is Test {
    uint256 constant WAD = 1e18;
    MockERC20 t0;
    MockERC20 t1;

    function setUp() public {
        t0 = new MockERC20("T0", "T0");
        t1 = new MockERC20("T1", "T1");
    }

    function _deploy(bool buggy) internal returns (VulnerableStablePool p) {
        p = new VulnerableStablePool(
            IERC20(address(t0)),
            IERC20(address(t1)),
            WAD,
            (WAD * 12) / 10,
            200,
            buggy
        );
        t0.mint(address(this), 1e30);
        t1.mint(address(this), 1e30);
        t0.approve(address(p), type(uint256).max);
        t1.approve(address(p), type(uint256).max);
        p.seed(15, 15);
    }

    function test_parity_boundary_correct_charges_4() public {
        assertEq(
            _deploy(false).quoteGivenOut(0, 1, 3),
            4,
            "correct pool charges 4 (matches sim)"
        );
    }

    function test_parity_boundary_buggy_charges_3() public {
        assertEq(
            _deploy(true).quoteGivenOut(0, 1, 3),
            3,
            "buggy pool undercharges to 3 (matches sim)"
        );
    }

    function test_parity_high_liquidity_identical() public {
        VulnerableStablePool pc = new VulnerableStablePool(
            IERC20(address(t0)),
            IERC20(address(t1)),
            WAD,
            (WAD * 12) / 10,
            200,
            false
        );
        VulnerableStablePool pb = new VulnerableStablePool(
            IERC20(address(t0)),
            IERC20(address(t1)),
            WAD,
            (WAD * 12) / 10,
            200,
            true
        );
        t0.mint(address(this), 1e30);
        t1.mint(address(this), 1e30);
        t0.approve(address(pc), type(uint256).max);
        t1.approve(address(pc), type(uint256).max);
        t0.approve(address(pb), type(uint256).max);
        t1.approve(address(pb), type(uint256).max);
        pc.seed(1_000_000 * WAD, 1_000_000 * WAD);
        pb.seed(1_000_000 * WAD, 1_000_000 * WAD);
        assertEq(
            pc.quoteGivenOut(0, 1, 1000),
            1198,
            "correct highliq charge (sim)"
        );
        assertEq(
            pb.quoteGivenOut(0, 1, 1000),
            1198,
            "buggy highliq charge identical (bug dormant)"
        );
    }
}
