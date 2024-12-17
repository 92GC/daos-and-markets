#[test_only]
module futarchy::amm_tests {
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::clock::{Self, Clock};
    use sui::object::{Self, ID};
    use sui::tx_context::TxContext;
    use futarchy::amm::{Self, LiquidityPool, AMMConfig};
    use futarchy::market_state::{Self, MarketState, AdminCap, TokenManagerCap};
    use std::vector;
    use std::debug;

    // ======== Constants ========
    const ADMIN: address = @0xAD;
    const USER: address = @0xB0B;
    
    const INITIAL_ASSET: u64 = 1000000000; // 1000 units
    const INITIAL_STABLE: u64 = 1000000000; // 1000 units
    const SWAP_AMOUNT: u64 = 100000000; // 100 units (10% of pool)

    
    const BASIS_POINTS: u64 = 10000;
    const TWAP_START_DELAY: u64 = 2000;
    const TWAP_STEP_MAX: u64 = 1000;
    const OUTCOME_COUNT: u64 = 2;

    // ======== Test Setup Functions ========
    fun setup_test(): (Scenario, Clock) {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        (scenario, clock)
    }

    fun setup_market(scenario: &mut Scenario, clock: &mut Clock): (MarketState, AdminCap, TokenManagerCap) {
    let market_id = object::id_from_address(@0x1); // Using a dummy ID for testing
    let dao_id = object::id_from_address(@0x2); // Using a dummy ID for testing

        // Create outcome messages
        let mut outcome_messages = vector::empty<vector<u8>>();
        vector::push_back(&mut outcome_messages, b"Yes");
        vector::push_back(&mut outcome_messages, b"No");

        let (mut state, admin_cap, token_cap) = market_state::new(
            market_id,
            dao_id,
            OUTCOME_COUNT,
            ADMIN,
            outcome_messages,
            clock,
            ctx(scenario)
        );

        market_state::start_trading(
            &mut state, 
            &admin_cap,
            clock::timestamp_ms(clock),
            clock,
            ctx(scenario)
        );

        (state, admin_cap, token_cap)
    }

    fun setup_pool(
        scenario: &mut Scenario,
        state: &MarketState,
        cap: &TokenManagerCap,
        clock: &Clock,
    ): LiquidityPool {
        amm::new_pool(
            state,
            cap,
            0, // outcome_idx
            INITIAL_ASSET,
            INITIAL_STABLE,
            BASIS_POINTS,
            TWAP_START_DELAY,
            TWAP_STEP_MAX,
            clock::timestamp_ms(clock),
            ctx(scenario)
        )
    }

    // ======== Basic Functionality Tests ========
    #[test]
    fun test_pool_creation() {
        let (mut scenario, mut clock) = setup_test();
        let (state, admin_cap, token_cap) = setup_market(&mut scenario, &mut clock);
        
        let pool = setup_pool(&mut scenario, &state, &token_cap, &clock);
        
        let (asset_reserve, stable_reserve) = amm::get_reserves(&pool);
        assert!(asset_reserve == INITIAL_ASSET, 0);
        assert!(stable_reserve == INITIAL_STABLE, 0);
        
        // Verify initial price
        let initial_price = amm::get_current_price(&pool);
        assert!(initial_price == BASIS_POINTS, 1); // Price should be 1.0 initially
        
        amm::destroy_for_testing(pool);
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_swap_asset_to_stable() {
        let (mut scenario, mut clock) = setup_test();
        let (state, admin_cap, token_cap) = setup_market(&mut scenario, &mut clock);
        
        let mut pool = setup_pool(&mut scenario, &state, &token_cap, &clock);
        
        let initial_price = amm::get_current_price(&pool);
        
        let _ = amm::swap_asset_to_stable(
            &mut pool,
            &state,
            &token_cap,
            SWAP_AMOUNT,
            0,
            &clock,
            ctx(&mut scenario)
        );
        
        let new_price = amm::get_current_price(&pool);
        debug::print(&b"Price comparison:");
        debug::print(&initial_price);
        debug::print(&new_price);
        
        assert!(new_price < initial_price, 2);
        
        amm::destroy_for_testing(pool);
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }


    #[test]
    fun test_swap_stable_to_asset() {
        let (mut scenario, mut clock) = setup_test();
        let (state, admin_cap, token_cap) = setup_market(&mut scenario, &mut clock);
        
        let mut pool = setup_pool(&mut scenario, &state, &token_cap, &clock);
        
        let initial_price = amm::get_current_price(&pool);
        
        let amount_out = amm::swap_stable_to_asset(
            &mut pool,
            &state,
            &token_cap,
            SWAP_AMOUNT,
            0,
            &clock,
            ctx(&mut scenario)
        );
        
        let (asset_reserve, stable_reserve) = amm::get_reserves(&pool);
        assert!(stable_reserve == INITIAL_STABLE + SWAP_AMOUNT, 0);
        assert!(asset_reserve == INITIAL_ASSET - amount_out, 1);
        
        let new_price = amm::get_current_price(&pool);
        debug::print(&b"Swap stable_to_asset:");
        debug::print(&b"Initial price:");
        debug::print(&initial_price);
        debug::print(&b"New price:");
        debug::print(&new_price);
        
        // When we buy assets with stable tokens:
        // - asset_reserve decreases
        // - stable_reserve increases
        // - price (asset/stable) should decrease
        assert!(new_price > initial_price, 2);
        
        amm::destroy_for_testing(pool);
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }




    // ======== Liquidity Tests ========
    #[test]
    fun test_add_remove_liquidity() {
        let (mut scenario, mut clock) = setup_test();
        let (state, admin_cap, token_cap) = setup_market(&mut scenario, &mut clock);
        
        let mut pool = setup_pool(&mut scenario, &state, &token_cap, &clock);
        
        // Add liquidity
        let (asset_added, stable_added) = amm::add_liquidity(
            &mut pool,
            &state,
            &token_cap,
            SWAP_AMOUNT,
            SWAP_AMOUNT,
            &clock,
            ctx(&mut scenario)
        );
        
        let (asset_reserve, stable_reserve) = amm::get_reserves(&pool);
        assert!(asset_reserve == INITIAL_ASSET + asset_added, 0);
        assert!(stable_reserve == INITIAL_STABLE + stable_added, 1);
        
        // Remove liquidity
        let (asset_removed, stable_removed) = amm::remove_liquidity(
            &mut pool,
            &state,
            &token_cap,
            1000, // 10% removal
            0,
            0,
            &clock,
            ctx(&mut scenario)
        );
        
        let (final_asset, final_stable) = amm::get_reserves(&pool);
        assert!(final_asset == asset_reserve - asset_removed, 2);
        assert!(final_stable == stable_reserve - stable_removed, 3);
        
        amm::destroy_for_testing(pool);
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // ======== Oracle Tests ========
    #[test]
    fun test_oracle_price_updates() {
        let (mut scenario, mut clock) = setup_test();
        let (state, admin_cap, token_cap) = setup_market(&mut scenario, &mut clock);
        
        let mut pool = setup_pool(&mut scenario, &state, &token_cap, &clock);
        
        // Initial price check
        let initial_price = amm::get_current_price(&pool);
        debug::print(&b"Initial price check:");
        debug::print(&initial_price);
        
        // Perform swap
        clock::set_for_testing(&mut clock, 2000); 
        let _ = amm::swap_asset_to_stable(
            &mut pool,
            &state,
            &token_cap,
            SWAP_AMOUNT,
            0,
            &clock,
            ctx(&mut scenario)
        );
        
        // Check new price
        let new_price = amm::get_current_price(&pool);
        debug::print(&b"New price check:");
        debug::print(&new_price);
        
        assert!(new_price < initial_price, 1);
        
        amm::destroy_for_testing(pool);
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }


    // ======== Price Impact Tests ========
    #[test]
    #[expected_failure(abort_code = 8)] // EPRICE_IMPACT_TOO_HIGH
    fun test_price_impact_limit() {
        let (mut scenario, mut clock) = setup_test();
        let (state, admin_cap, token_cap) = setup_market(&mut scenario, &mut clock);
        
        let mut pool = setup_pool(&mut scenario, &state, &token_cap, &clock);
        
        // Should fail due to price impact too high
        let _ = amm::swap_asset_to_stable(
            &mut pool,
            &state,
            &token_cap,
            INITIAL_ASSET,  // Try to swap entire pool
            0,
            &clock,
            ctx(&mut scenario)
        );
        
        amm::destroy_for_testing(pool);
        market_state::destroy_for_testing(state, admin_cap, token_cap);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
}