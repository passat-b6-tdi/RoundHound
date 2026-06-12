// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VulnerableStablePool} from "../src/VulnerableStablePool.sol";
import {IERC20} from "../src/helpers/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract NaiveHighLiquidityTest is Test {
    uint256 constant WAD = 1e18;
    VulnerableStablePool pool;
    MockERC20 t0;
    MockERC20 t1;

    function setUp() public {
        t0 = new MockERC20("T0", "T0");
        t1 = new MockERC20("T1", "T1");
        pool = new VulnerableStablePool(
            IERC20(address(t0)),
            IERC20(address(t1)),
            WAD,
            (WAD * 12) / 10,
            200,
            false
        );
        t0.mint(address(this), 1e30);
        t1.mint(address(this), 1e30);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        pool.seed(1_000_000 * WAD, 1_000_000 * WAD);
    }

    function test_swap_charges_expected_amount() public view {
        assertEq(pool.quoteGivenOut(0, 1, 1000), 1198, "highliq swap charge");
    }

    function test_single_roundtrip_no_profit() public {
        uint256 dy = 500_000 * WAD;
        uint256 paid = pool.swapGivenOut(0, 1, dy);
        uint256 back = pool.swapGivenOut(1, 0, paid);
        assertApproxEqAbs(back, dy, 10, "roundtrip neutral at highliq");
    }
}
