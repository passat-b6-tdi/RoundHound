// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHandler} from "./BaseHandler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice stock handler: large, realistic trades at human scale liquidity, never deflating to weiscale — the regime an out of box fuzzer explores, it misses the bug
contract StockHandler is BaseHandler {
    uint256 constant INIT = 1_000_000 ether;
    uint256 constant FLOOR = INIT / 1000; // stays human scale, never approaches the boundary

    constructor(
        MockERC20 _t0,
        MockERC20 _t1,
        bool buggy
    ) BaseHandler(_t0, _t1, buggy) {
        pool.seed(INIT, INIT);
    }

    function step(uint256 mode, uint256 amt) external {
        if (mode % 4 == 0) {
            uint256 cur = pool.rawBalances(1);
            if (cur > FLOOR) _deflate(amt % 5000); // shallow only
        } else {
            uint256 bal = pool.rawBalances(1);
            if (bal < 4) return;
            uint256 dy = bal / 4 + (amt % (bal / 4 + 1)); // large, realistic output size
            _extract(dy);
        }
    }
}
