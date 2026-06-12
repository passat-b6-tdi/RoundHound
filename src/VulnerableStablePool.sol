// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPoint} from "./helpers/FixedPoint.sol";
import {StableMath} from "./helpers/StableMath.sol";
import {IERC20} from "./helpers/IERC20.sol";

/// @notice minimal two token StableSwap pool reproducing the Balancer v2 EXACT_OUT rounding direction bug
/// @dev `buggy` toggles the vulnerable line so one test suite covers before/after, @custom:invariant no-free-money: EXACT_OUT must never charge less than the protocol favoring (mulUp on output) result, layer 1 derives the required rounding direction from this tag
contract VulnerableStablePool {
    bool public immutable buggy;
    uint256 public immutable amp;

    IERC20 internal immutable token0;
    IERC20 internal immutable token1;
    uint256 internal immutable rate0;
    uint256 internal immutable rate1;
    address internal immutable deployer;

    uint256[2] public rawBalances;

    uint256 public constant TOTAL_SUPPLY = 1e18;

    constructor(
        IERC20 _t0,
        IERC20 _t1,
        uint256 _r0,
        uint256 _r1,
        uint256 _amp,
        bool _buggy
    ) {
        token0 = _t0;
        token1 = _t1;
        rate0 = _r0;
        rate1 = _r1;
        amp = _amp;
        buggy = _buggy;
        deployer = msg.sender;
    }

    function rates() public view returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = rate0;
        r[1] = rate1;
    }

    function tokens() public view returns (IERC20[] memory t) {
        t = new IERC20[](2);
        t[0] = token0;
        t[1] = token1;
    }

    /// @notice balances upscaled by rate (rounded down, as is standard for balances)
    function upscaledBalances() public view returns (uint256[] memory xp) {
        xp = new uint256[](2);
        xp[0] = FixedPoint.mulDown(rawBalances[0], rate0);
        xp[1] = FixedPoint.mulDown(rawBalances[1], rate1);
    }

    /// @notice invariant D for the live balances
    function currentD() public view returns (uint256) {
        return StableMath.getD(upscaledBalances(), amp);
    }

    /// @notice pool value backing one unit of BPT (D / supply)
    function shareValue() public view returns (uint256) {
        return FixedPoint.divDown(currentD(), TOTAL_SUPPLY);
    }

    /// @notice EXACT_OUT quote: input of `indexIn` required to take `amountOut` of `indexOut`
    function quoteGivenOut(
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountOut
    ) public view returns (uint256 amountIn) {
        return _quote(indexIn, indexOut, amountOut, buggy);
    }

    /// @notice identical to the correct quote but with the output ceil inlined (independent of `FixedPoint.mulUp`)
    function correctQuoteGivenOut(
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountOut
    ) public view returns (uint256 amountIn) {
        uint256[] memory r = rates();
        uint256 product = amountOut * r[indexOut];
        uint256 amountOutScaled = product == 0 ? 0 : ((product - 1) / 1e18) + 1; // inline ceil
        return _quoteFromScaledOutput(indexIn, indexOut, amountOutScaled, r);
    }

    function _quote(
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountOut,
        bool _buggy
    ) internal view returns (uint256 amountIn) {
        uint256[] memory r = rates();
        // bug: output upscaled with mulDown (favors user) instead of mulUp
        uint256 amountOutScaled = _buggy
            ? FixedPoint.mulDown(amountOut, r[indexOut])
            : FixedPoint.mulUp(amountOut, r[indexOut]);
        return _quoteFromScaledOutput(indexIn, indexOut, amountOutScaled, r);
    }

    function _quoteFromScaledOutput(
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountOutScaled,
        uint256[] memory r
    ) internal view returns (uint256 amountIn) {
        uint256[] memory xp = upscaledBalances();
        uint256 D = StableMath.getD(xp, amp);
        uint256 newOut = xp[indexOut] - amountOutScaled;
        uint256 newIn = StableMath.getY(indexOut, indexIn, newOut, xp, amp, D);
        uint256 amountInScaled = newIn - xp[indexIn];
        amountIn = FixedPoint.divUp(amountInScaled, r[indexIn]); // input downscaled up (correct)
    }

    /// @notice EXACT_OUT swap: pull `amountIn` of `indexIn`, send `amountOut` of `indexOut`
    function swapGivenOut(
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountOut
    ) external returns (uint256 amountIn) {
        amountIn = quoteGivenOut(indexIn, indexOut, amountOut);
        _settle(indexIn, indexOut, amountIn, amountOut);
    }

    /// @notice `swapGivenOut`, but priced by the self-contained correct oracle, used by the differential reference pool
    function swapGivenOutCorrect(
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountOut
    ) external returns (uint256 amountIn) {
        amountIn = correctQuoteGivenOut(indexIn, indexOut, amountOut);
        _settle(indexIn, indexOut, amountIn, amountOut);
    }

    function _settle(
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountIn,
        uint256 amountOut
    ) internal {
        require(indexIn < 2 && indexOut < 2 && indexIn != indexOut, "bad idx");
        require(amountOut <= rawBalances[indexOut], "insufficient out");
        IERC20[] memory t = tokens();
        require(
            t[indexIn].transferFrom(msg.sender, address(this), amountIn),
            "in xfer"
        );
        require(t[indexOut].transfer(msg.sender, amountOut), "out xfer");
        rawBalances[indexIn] += amountIn;
        rawBalances[indexOut] -= amountOut;
    }

    /// @notice proportional liquidity removal (withdraws `bps`/1e4 of both reserves), the deflation primitive the boundary fuzzer drives
    function exitProportional(uint256 bps) external {
        require(bps <= 1e4, "bps");
        uint256 out0 = (rawBalances[0] * bps) / 1e4;
        uint256 out1 = (rawBalances[1] * bps) / 1e4;
        rawBalances[0] -= out0;
        rawBalances[1] -= out1;
        require(token0.transfer(msg.sender, out0), "exit0");
        require(token1.transfer(msg.sender, out1), "exit1");
    }

    /// @notice snapshot the pool to balances (b0, b1), backed by real tokens, deployer only fixture, not pool logic
    function seed(uint256 b0, uint256 b1) external {
        require(msg.sender == deployer, "only deployer");
        _setTokenBalance(token0, b0);
        _setTokenBalance(token1, b1);
        rawBalances[0] = b0;
        rawBalances[1] = b1;
    }

    function _setTokenBalance(IERC20 token, uint256 target) internal {
        uint256 have = token.balanceOf(address(this));
        if (target > have) {
            require(
                token.transferFrom(msg.sender, address(this), target - have),
                "seed in"
            );
        } else if (have > target) {
            require(token.transfer(msg.sender, have - target), "seed out");
        }
    }
}
