// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice twotoken StableSwap invariant math, ported 1:1 from sim/stableswap_sim.py
/// @dev operates on upscaled balances (1e18), `amp` is the raw amplification coefficient
library StableMath {
    uint256 internal constant N = 2;

    /// @notice invariant D for upscaled balances `xp` (Newton's method)
    function getD(
        uint256[] memory xp,
        uint256 amp
    ) internal pure returns (uint256) {
        uint256 S = xp[0] + xp[1];
        if (S == 0) return 0;

        uint256 D = S;
        uint256 Ann = amp * N;

        for (uint256 iter = 0; iter < 255; iter++) {
            // D_P = D*D/(x0*N)*D/(x1*N), accumulated product term
            uint256 D_P = D;
            D_P = (D_P * D) / (xp[0] * N);
            D_P = (D_P * D) / (xp[1] * N);

            uint256 Dprev = D;
            D = ((Ann * S + D_P * N) * D) / ((Ann - 1) * D + (N + 1) * D_P);

            if (D > Dprev) {
                if (D - Dprev <= 1) return D;
            } else {
                if (Dprev - D <= 1) return D;
            }
        }
        return D;
    }

    /// @notice new balance of token `j` given token `i` is set to `x`, holding D constant
    function getY(
        uint256 i,
        uint256 j,
        uint256 x,
        uint256[] memory xp,
        uint256 amp,
        uint256 D
    ) internal pure returns (uint256) {
        uint256 Ann = amp * N;
        uint256 c = D;
        uint256 S_ = 0;

        for (uint256 k = 0; k < N; k++) {
            uint256 _x;
            if (k == i) {
                _x = x;
            } else if (k == j) {
                continue;
            } else {
                _x = xp[k];
            }
            S_ += _x;
            c = (c * D) / (_x * N);
        }
        c = (c * D) / (Ann * N);
        uint256 b = S_ + D / Ann;

        uint256 y = D;
        for (uint256 iter = 0; iter < 255; iter++) {
            uint256 yprev = y;
            // denominator stays positive for converged stable balances
            y = (y * y + c) / (2 * y + b - D);

            if (y > yprev) {
                if (y - yprev <= 1) return y;
            } else {
                if (yprev - y <= 1) return y;
            }
        }
        return y;
    }
}
