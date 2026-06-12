// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHandler} from "./BaseHandler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice boundary-biased handler: starts at healthy liquidity and lets the fuzzer deflate toward weiscale and extract, the fuzzer must discover "deflate deep, then extract"
contract BoundaryHandler is BaseHandler {
    uint256 constant INIT = 1_000_000 ether;

    // deflation targets biased toward weiscale, where the leak bites
    uint80[12] internal TARGETS = [
        1e24,
        1e20,
        1e15,
        1e9,
        1e6,
        1000,
        200,
        80,
        40,
        16,
        9,
        5
    ];

    constructor(
        MockERC20 _t0,
        MockERC20 _t1,
        bool buggy
    ) BaseHandler(_t0, _t1, buggy) {
        pool.seed(INIT, INIT);
    }

    function step(uint256 mode, uint256 target, uint256 amt) external {
        if (mode % 2 == 0) {
            _deflateTo(TARGETS[target % TARGETS.length]);
        } else {
            _extract(1 + (amt % 6));
        }
    }

    function _deflateTo(uint256 target) internal {
        uint256 r0 = pool.rawBalances(0);
        uint256 r1 = pool.rawBalances(1);
        uint256 cur = r0 < r1 ? r0 : r1;
        if (target >= cur || cur == 0) return;
        _deflate(((cur - target) * 1e4) / cur);
    }
}
