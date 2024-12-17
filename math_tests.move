#[test_only]
module futarchy::math_tests {
    use futarchy::math::{Self};

    #[test]
    public fun test_mul_div() {
        // Basic cases
        assert!(math::mul_div(500, 2000, 1000) == 1000, 0);
        assert!(math::mul_div(100, 100, 100) == 100, 1);
        assert!(math::mul_div(0, 1000, 1) == 0, 2);
        
        // Edge cases
        assert!(math::mul_div(1, 1, 1) == 1, 3);
        assert!(math::mul_div(0, 0, 1) == 0, 4);
        
        // Large numbers (but not overflowing)
        assert!(math::mul_div(1000000000, 2000000000, 1000000000) == 2000000000, 5);
        
        // Division resulting in decimal (should truncate)
        assert!(math::mul_div(10, 10, 3) == 33, 6); // 100/3 = 33.333...
        assert!(math::mul_div(7, 7, 2) == 24, 7); // 49/2 = 24.5
    }

    #[test]
    public fun test_mul_div_up() {
        // Basic cases
        assert!(math::mul_div_up(500, 2000, 1000) == 1000, 0);
        assert!(math::mul_div_up(100, 100, 100) == 100, 1);
        assert!(math::mul_div_up(0, 1000, 1) == 0, 2);
        
        // Cases requiring rounding up
        assert!(math::mul_div_up(5, 2, 3) == 4, 3); // 10/3 ≈ 3.33... -> 4
        assert!(math::mul_div_up(7, 7, 2) == 25, 4); // 49/2 = 24.5 -> 25
        assert!(math::mul_div_up(10, 10, 3) == 34, 5); // 100/3 = 33.333... -> 34
        
        // Edge cases
        assert!(math::mul_div_up(1, 1, 1) == 1, 6);
        assert!(math::mul_div_up(0, 0, 1) == 0, 7);
        
        // Cases that divide evenly (shouldn't round up)
        assert!(math::mul_div_up(5, 2, 2) == 5, 8);
        assert!(math::mul_div_up(100, 100, 10) == 1000, 9);
        
        // Large numbers (but not overflowing)
        assert!(math::mul_div_up(1000000000, 2000000000, 1000000000) == 2000000000, 10);
    }

#[test]
    public fun test_sqrt() {
        // Zero case
        assert!(math::sqrt(0) == 0, 0);
        
        // Small numbers
        assert!(math::sqrt(1) == 1, 1);
        assert!(math::sqrt(2) == 1, 2);
        assert!(math::sqrt(3) == 1, 3);
        
        // Perfect squares
        assert!(math::sqrt(4) == 2, 4);
        assert!(math::sqrt(9) == 3, 5);
        assert!(math::sqrt(16) == 4, 6);
        assert!(math::sqrt(25) == 5, 7);
        assert!(math::sqrt(100) == 10, 8);
        
        // Non-perfect squares (should return floor of sqrt)
        assert!(math::sqrt(8) == 2, 9);    // sqrt(8) ≈ 2.828
        assert!(math::sqrt(15) == 3, 10);  // sqrt(15) ≈ 3.873
        assert!(math::sqrt(99) == 9, 11);  // sqrt(99) ≈ 9.949
        
        // Large number
        assert!(math::sqrt(1000000) == 1000, 12); // Perfect square
        assert!(math::sqrt(1000001) == 1000, 13); // Just over perfect square
    }

    #[test]
    public fun test_min() {
        assert!(math::min(0, 0) == 0, 0);
        assert!(math::min(1, 0) == 0, 1);
        assert!(math::min(0, 1) == 0, 2);
        assert!(math::min(5, 5) == 5, 3);
        assert!(math::min(18446744073709551615, 1) == 1, 4); // max u64 vs 1
        assert!(math::min(1000, 999) == 999, 5);
    }

    #[test]
    public fun test_max() {
        assert!(math::max(0, 0) == 0, 0);
        assert!(math::max(1, 0) == 1, 1);
        assert!(math::max(0, 1) == 1, 2);
        assert!(math::max(5, 5) == 5, 3);
        assert!(math::max(18446744073709551615, 1) == 18446744073709551615, 4); // max u64 vs 1
        assert!(math::max(1000, 999) == 1000, 5);
    }

    #[test]
    #[expected_failure(abort_code = math::EDivideByZero)]
    public fun test_mul_div_div_by_zero() {
        math::mul_div(100, 100, 0);
    }

    #[test]
    #[expected_failure(abort_code = math::EDivideByZero)]
    public fun test_mul_div_up_div_by_zero() {
        math::mul_div_up(100, 100, 0);
    }

    #[test]
    #[expected_failure(abort_code = math::EOverflow)]
    public fun test_mul_div_overflow() {
        math::mul_div(18446744073709551615, 18446744073709551615, 1);
    }

    #[test]
    #[expected_failure(abort_code = math::EOverflow)]
    public fun test_mul_div_up_overflow() {
        math::mul_div_up(18446744073709551615, 18446744073709551615, 1);
    }
}