module futarchy::math {
    const EOverflow: u64 = 0;
    const EDivideByZero: u64 = 1;

    /// Safely multiplies two u64 values and divides by a third, checking for overflow
    /// Returns (a * b) / c
    public fun mul_div(a: u64, b: u64, c: u64): u64 {
        assert!(c != 0, EDivideByZero);
        let a_128 = (a as u128);
        let b_128 = (b as u128);
        let c_128 = (c as u128);
        let result = (a_128 * b_128) / c_128;
        assert!(result <= 18446744073709551615, EOverflow); // Max u64
        (result as u64)
    }

    /// Safely multiplies two u64 values and divides by a third, rounding up
    /// Returns ceil((a * b) / c)
    public fun mul_div_up(a: u64, b: u64, c: u64): u64 {
        assert!(c != 0, EDivideByZero);
        let a_128 = (a as u128);
        let b_128 = (b as u128);
        let c_128 = (c as u128);
        let numerator = a_128 * b_128;
        let result = if (numerator == 0) {
            0
        } else {
            let division = numerator / c_128;
            if (numerator % c_128 == 0) {
                division
            } else {
                division + 1
            }
        };
        assert!(result <= 18446744073709551615, EOverflow); // Max u64
        (result as u64)
    }

    /// Returns minimum of two numbers
    public fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    /// Returns maximum of two numbers
    public fun max(a: u64, b: u64): u64 {
        if (a > b) a else b
    }

    /// Calculate square root using the Babylonian method
    public fun sqrt(y: u64): u64 {
        if (y == 0) return 0;
        if (y < 4) return 1;

        let mut z = y;
        let mut x = y / 2;
        
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        };
        
        z
    }
}