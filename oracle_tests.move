#[test_only]
module futarchy::oracle_tests {
    use sui::clock;
    use sui::test_scenario::{Self as test, Scenario};
    use futarchy::oracle::{Self, Oracle};
    use std::debug;

    // ======== Test Constants ========
    const BASIS_POINTS: u64 = 10_000;
    const TWAP_STEP_MAX: u64 = 1_000; // 10% max change
    const TWAP_START_DELAY: u64 = 2_000;
    const MARKET_START_TIME: u64 = 1_000;
    const INIT_PRICE: u64 = 10_000;

    // ======== Helper Functions ========
    fun setup_test_oracle(): Oracle {
        oracle::new_oracle(
            INIT_PRICE,
            MARKET_START_TIME,
            BASIS_POINTS,
            TWAP_START_DELAY,
            TWAP_STEP_MAX
        )
    }

    fun setup_scenario_and_clock(): (Scenario, clock::Clock) {
        let mut scenario = test::begin(@0x1);
        test::next_tx(&mut scenario, @0x1);
        let clock = clock::create_for_testing(test::ctx(&mut scenario));
        (scenario, clock)
    }

    // ======== Test Cases ========
    #[test]
    fun test_new_oracle() {
        let mut scenario = test::begin(@0x1);
        test::next_tx(&mut scenario, @0x1);
        {
            let oracle = setup_test_oracle();
            assert!(oracle::get_last_price(&oracle) == INIT_PRICE, 0);
            assert!(oracle::get_last_timestamp(&oracle) == MARKET_START_TIME, 1);
            let (basis_points, twap_delay, step_max) = oracle::get_config(&oracle);
            assert!(basis_points == BASIS_POINTS, 2);
            assert!(step_max == TWAP_STEP_MAX, 3);
            assert!(twap_delay == TWAP_START_DELAY, 4);
            assert!(oracle::get_market_start_time(&oracle) == MARKET_START_TIME, 5);
            assert!(oracle::get_twap_initialization_price(&oracle) == INIT_PRICE, 6);
        };
        test::end(scenario);
    }

    #[test]
    fun test_update_config() {
        let mut scenario = test::begin(@0x1);
        test::next_tx(&mut scenario, @0x1);
        {
            let mut oracle = setup_test_oracle();
            oracle::update_config(
                &mut oracle,
                20_000,  // new basis points
                3_000,   // new twap start delay
                2_000,   // new step max
                2_000,   // new market start time
                12_000   // new initialization price
            );
            let (basis_points, twap_delay, step_max) = oracle::get_config(&oracle);
            assert!(basis_points == 20_000, 0);
            assert!(twap_delay == 3_000, 1);
            assert!(step_max == 2_000, 2);
            assert!(oracle::get_market_start_time(&oracle) == 2_000, 3);
            assert!(oracle::get_twap_initialization_price(&oracle) == 12_000, 4);
        };
        test::end(scenario);
    }

    #[test]
    fun test_write_observation() {
        let (scenario,mut  clock) = setup_scenario_and_clock();
        {
            let mut oracle = setup_test_oracle();
            
            // Write first observation after market start
            clock::set_for_testing(&mut clock, 2_000);
            oracle::write_observation(&mut oracle, 2_000, 15_000, 100);
            assert!(oracle::get_last_price(&oracle) == 11_000, 0); // Price should be capped at 10% increase
            assert!(oracle::get_last_timestamp(&oracle) == 2_000, 1);
            
            clock::destroy_for_testing(clock);
        };
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = futarchy::oracle::ETIMESTAMP_REGRESSION)]
    fun test_timestamp_regression() {
        let (scenario, clock) = setup_scenario_and_clock();
        {
            let mut oracle = setup_test_oracle();
            oracle::write_observation(&mut oracle, 4_000, 15_000, 100);
            oracle::write_observation(&mut oracle, 2_000, 16_000, 100); // Should fail
            clock::destroy_for_testing(clock);
        };
        test::end(scenario);
    }

    #[test]
    fun test_capped_price_changes() {
        let (scenario, clock) = setup_scenario_and_clock();
        {
            let mut oracle = setup_test_oracle();
            
            // Test price increase capping
            oracle::write_observation(&mut oracle, 2_000, 15_000, 100);
            assert!(oracle::get_last_price(&oracle) == 11_000, 0); // Should be capped at 10% increase
            
            // Test price decrease capping
            oracle::write_observation(&mut oracle, 3_000, 5_000, 100);
            assert!(oracle::get_last_price(&oracle) == 9_900, 1); // Should be capped at 10% decrease
            
            clock::destroy_for_testing(clock);
        };
        test::end(scenario);
    }

    #[test]
    fun test_twap_calculation() {
        let (scenario, mut clock) = setup_scenario_and_clock();
        {
            let mut oracle = setup_test_oracle();
            
            // Write first observation after market start
            clock::set_for_testing(&mut clock, MARKET_START_TIME + 3_000);
            oracle::write_observation(&mut oracle, MARKET_START_TIME + 3_000, 11_000, 100);
            
            // Write second observation
            clock::set_for_testing(&mut clock, MARKET_START_TIME + 63_000);
            oracle::write_observation(&mut oracle, MARKET_START_TIME + 63_000, 12_000, 100);
            
            // Get TWAP at specific time
            clock::set_for_testing(&mut clock, MARKET_START_TIME + 123_000);
            let twap = oracle::get_twap(&oracle, &clock);
            
            // Calculate expected TWAP:
            // Total accumulation: 1,380,000,000
            // Period: 123,000
            // Scaled by BASIS_POINTS (10,000)
            // TWAP = (1,380,000,000 * 10,000) / 123,000 ≈ 112,195,121
            assert!(twap == 112195121, 0);
            
            clock::destroy_for_testing(clock);
        };
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = futarchy::oracle::E_TWAP_NOT_FINISHED)]
    fun test_twap_before_delay() {
        let (scenario, mut clock) = setup_scenario_and_clock();
        {
            let mut oracle = setup_test_oracle();
            clock::set_for_testing(&mut clock, MARKET_START_TIME + 1_000); // Before start delay
            oracle::write_observation(&mut oracle, MARKET_START_TIME + 1_000, 11_000, 100);
            
            // Should fail as TWAP delay hasn't passed
            let _ = oracle::get_twap(&oracle, &clock);
            
            clock::destroy_for_testing(clock);
        };
        test::end(scenario);
    }

    #[test]
    fun test_cumulative_price_updates() {
        let (scenario,mut clock) = setup_scenario_and_clock();
        {
            let mut oracle = setup_test_oracle();
            
            // Write observation and check internal state
            clock::set_for_testing(&mut clock, MARKET_START_TIME + 60_000);
            oracle::write_observation(&mut oracle, MARKET_START_TIME + 60_000, 11_000, 100);
            let (price, timestamp, cumulative) = oracle::debug_get_state(&oracle);
            
            assert!(price == 11_000, 0);
            assert!(timestamp == MARKET_START_TIME + 60_000, 1);
            assert!(cumulative > 0, 2); // Cumulative price should be updated
            
            clock::destroy_for_testing(clock);
        };
        test::end(scenario);
    }
}