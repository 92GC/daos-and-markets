#[test_only]
module futarchy::market_state_tests {
    use sui::test_scenario::{Self as test, ctx};
    use sui::clock;
    use sui::object::{Self, ID};
    use std::vector;
    use futarchy::market_state::{Self, MarketState, AdminCap, TokenManagerCap};
    use futarchy::oracle::{Self, Oracle};

    const ADMIN: address = @0xAD;
    
    // Error constants
    const ETEST_FAILED: u64 = 1;

    fun setup_test(scenario: &mut test::Scenario): (MarketState, AdminCap, TokenManagerCap, clock::Clock, Oracle) {
        let test_ctx = test::ctx(scenario);
        let mut clock = clock::create_for_testing(test_ctx);
        
        // Create outcome messages
        let mut outcome_messages = vector::empty();
        vector::push_back(&mut outcome_messages, b"Outcome A");
        vector::push_back(&mut outcome_messages, b"Outcome B");
        
        let market_id = object::id_from_address(@0x123);
        let dao_id = object::id_from_address(@0x456);
        
        let start_time = 1000;
        clock::set_for_testing(&mut clock, start_time);
        
        // Create oracle with initial configuration
        let oracle = oracle::new_oracle(
            100, // Initial price
            start_time, // Market start time
            10000, // Basis points
            2000, // TWAP start delay
            1000  // TWAP step max
        );
        
        let (state, admin_cap, token_cap) = market_state::new(
            market_id,
            dao_id,
            2, // outcome_count
            ADMIN,
            outcome_messages,
            &clock,
            test_ctx
        );
        
        (state, admin_cap, token_cap, clock, oracle)
    }

    #[test]
    fun test_market_initialization() {
        let mut scenario = test::begin(ADMIN);
        let (state, admin_cap, token_cap, clock, oracle) = setup_test(&mut scenario);
        
        // Verify initial state
        assert!(!market_state::is_trading_active(&state), ETEST_FAILED);
        assert!(!market_state::is_finalized(&state), ETEST_FAILED);
        assert!(market_state::outcome_count(&state) == 2, ETEST_FAILED);
        assert!(market_state::admin(&state) == ADMIN, ETEST_FAILED);
        assert!(oracle::get_last_price(&oracle) == 100, ETEST_FAILED);
        
        // Verify outcome messages
        assert!(market_state::get_outcome_message(&state, 0) == b"Outcome A", ETEST_FAILED);
        assert!(market_state::get_outcome_message(&state, 1) == b"Outcome B", ETEST_FAILED);
        
        // Clean up
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_trading_lifecycle() {
        let mut scenario = test::begin(ADMIN);
        let (mut state, admin_cap, token_cap, mut clock, mut oracle) = setup_test(&mut scenario);

        // Begin and record prices
        clock::set_for_testing(&mut clock, 1000);
        market_state::start_trading(&mut state, &admin_cap, 3600000, &clock, test::ctx(&mut scenario));

        clock::set_for_testing(&mut clock, 5000);
        oracle::write_observation(&mut oracle, 5000, 100, 1000);
        
        clock::set_for_testing(&mut clock, 9000);
        oracle::write_observation(&mut oracle, 9000, 100, 1000); // Keep price at 100

        clock::set_for_testing(&mut clock, 13000);
        market_state::end_trading(&mut state, &admin_cap, &oracle, &clock, test::ctx(&mut scenario));
        
        market_state::finalize(&mut state, &admin_cap, 0, &clock, test::ctx(&mut scenario));
        
        assert!(!market_state::is_trading_active(&state), ETEST_FAILED);
        assert!(market_state::is_finalized(&state), ETEST_FAILED);
        assert!(market_state::winning_outcome(&state) == 0, ETEST_FAILED);

        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_update_twap_parameters() {
        let mut scenario = test::begin(ADMIN);
        let (mut state, admin_cap, token_cap, clock, _oracle) = setup_test(&mut scenario);
        
        // Update TWAP parameters
        market_state::update_twap_parameters(
            &mut state,
            &admin_cap,
            2000, // period
            1000  // max deviation (10%)
        );
        
        // Verify parameters
        let period = market_state::get_twap_parameters(&state);
        assert!(period == 2000, ETEST_FAILED);
        
        // Clean up
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_get_dao_and_market_ids() {
        let mut scenario = test::begin(ADMIN);
        let (state, admin_cap, token_cap, clock, _oracle) = setup_test(&mut scenario);
        
        let market_id = market_state::market_id(&state);
        let dao_id = market_state::dao_id(&state);
        
        assert!(market_id == object::id_from_address(@0x123), ETEST_FAILED);
        assert!(dao_id == object::id_from_address(@0x456), ETEST_FAILED);
        
        // Clean up
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_admin_transfer() {
        let mut scenario = test::begin(ADMIN);
        let (mut state, admin_cap, token_cap, clock, _oracle) = setup_test(&mut scenario);
        
        let new_admin = @0xB0B;
        market_state::transfer_admin(
            &mut state,
            &admin_cap,
            new_admin,
            test::ctx(&mut scenario)
        );
        
        assert!(market_state::admin(&state) == new_admin, ETEST_FAILED);
        
        // Clean up
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = market_state::ETRADING_ALREADY_ENDED)]
    fun test_cannot_start_trading_twice() {
        let mut scenario = test::begin(ADMIN);
        let (mut state, admin_cap, token_cap, mut clock, _oracle) = setup_test(&mut scenario);
        
        // Start trading first time
        clock::set_for_testing(&mut clock, 1000);
        market_state::start_trading(
            &mut state,
            &admin_cap,
            3600000,
            &clock,
            test::ctx(&mut scenario)
        );
        
        // Try to start trading again - should fail
        market_state::start_trading(
            &mut state,
            &admin_cap,
            3600000,
            &clock,
            test::ctx(&mut scenario)
        );
        
        // Clean up
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
}