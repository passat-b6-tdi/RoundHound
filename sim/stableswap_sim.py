# pure-python integer StableSwap model proving the Balancer v2 rounding-direction bug
# run: python3 stableswap_sim.py
#
# mirrors Solidity fixed-point (1e18), Curve get_D / get_y, and the EXACT_OUT swap path
#
# bug: in EXACT_OUT, the requested OUTPUT amount is upscaled with mulDown (floor) instead
# of mulUp (ceil)
# rounding must favor the protocol, mulDown favors the user
# negligible at high liquidity, catastrophic at boundary (wei-scale) balances — this is what made the
# real $128M Balancer v2 hack (Nov 3 2025) possible once composability deflated a pool

WAD = 10**18
N = 2


def mul_down(value, factor):
    return (value * factor) // WAD


def mul_up(value, factor):
    product = value * factor
    return 0 if product == 0 else (product - 1) // WAD + 1


def div_up(numerator, denominator):
    return 0 if numerator == 0 else (numerator * WAD - 1) // denominator + 1


def get_D(balances, amp):
    total = sum(balances)
    if total == 0:
        return 0
    invariant = total
    amp_n = amp * N
    for _ in range(255):
        d_product = invariant
        for balance in balances:
            d_product = d_product * invariant // (balance * N)
        prev_invariant = invariant
        invariant = (amp_n * total + d_product * N) * invariant // ((amp_n - 1) * invariant + (N + 1) * d_product)
        if abs(invariant - prev_invariant) <= 1:
            return invariant
    return invariant


def get_y(fixed_index, unknown_index, fixed_balance, balances, amp, invariant):
    amp_n = amp * N
    c_coeff = invariant
    sum_others = 0
    for k in range(N):
        if k == fixed_index:
            balance = fixed_balance
        elif k == unknown_index:
            continue
        else:
            balance = balances[k]
        sum_others += balance
        c_coeff = c_coeff * invariant // (balance * N)
    c_coeff = c_coeff * invariant // (amp_n * N)
    b_coeff = sum_others + invariant // amp_n
    new_balance = invariant
    for _ in range(255):
        prev_balance = new_balance
        new_balance = (new_balance * new_balance + c_coeff) // (2 * new_balance + b_coeff - invariant)
        if abs(new_balance - prev_balance) <= 1:
            return new_balance
    return new_balance


def exact_out_amount_in(raw_balances, rates, amp, index_in, index_out, amount_out, buggy):
    """take `amount_out` of token `index_out`, pay token `index_in`, returns the input amount"""
    balances = [mul_down(raw_balances[k], rates[k]) for k in range(N)]
    invariant = get_D(balances, amp)
    # vulnerable line: output upscaled with mul_down (favors the user) instead of mul_up
    amount_out_scaled = mul_down(amount_out, rates[index_out]) if buggy else mul_up(amount_out, rates[index_out])
    new_out_balance = balances[index_out] - amount_out_scaled
    new_in_balance = get_y(index_out, index_in, new_out_balance, balances, amp, invariant)
    amount_in_scaled = new_in_balance - balances[index_in]
    return div_up(amount_in_scaled, rates[index_in]) # downscale the input, rounding up (correct)


def pool_value_after(raw_balances, rates, amp, index_in, index_out, amount_out, amount_in):
    new_balances = list(raw_balances)
    new_balances[index_in] += amount_in
    new_balances[index_out] -= amount_out
    upscaled = [mul_down(new_balances[k], rates[k]) for k in range(N)]
    return get_D(upscaled, amp), new_balances


def run(label, raw_balances, rates, amp, amount_out):
    print(f"\n==={label}===")
    print(f"raw balances = {raw_balances}, rates = {rates}, amp = {amp}, amount_out = {amount_out}")
    upscaled = [mul_down(raw_balances[k], rates[k]) for k in range(N)]
    invariant_before = get_D(upscaled, amp)
    for buggy in (False, True):
        amount_in = exact_out_amount_in(raw_balances, rates, amp, 0, 1, amount_out, buggy)
        invariant_after, _ = pool_value_after(raw_balances, rates, amp, 0, 1, amount_out, amount_in)
        tag = "BUGGY (mulDown)" if buggy else "CORRECT (mulUp)"
        print(
            f" {tag:18} > attacker pays amount_in={amount_in:>4} "
            f"D_before={invariant_before} D_after={invariant_after} D_leak={invariant_before - invariant_after}"
        )


if __name__ == "__main__":
    rates = [WAD, WAD * 12 // 10]  # token1 rate = 1.2 so mul_down != mul_up
    amp = 200
    run("HIGH liq", [1_000_000 * WAD, 1_000_000 * WAD], rates, amp, amount_out=1000)
    run("LOW liq (boundary, =10 wei)", [15, 15], rates, amp, amount_out=3)
