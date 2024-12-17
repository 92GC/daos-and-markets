#[test_only]
module futarchy::dao_tests {
    use std::vector;
    use sui::object::{Self, ID};
    use sui::coin::{Self, Coin};
    use sui::test_scenario::{Self, Scenario};
    use sui::clock::{Self, Clock};
    use futarchy::dao::{Self, DAO, AdminCap};
    use futarchy::market_state::{Self};
    use futarchy::proposal::{Self, Proposal};
    use sui::transfer;
    use sui::tx_context;
    use std::option;
    use futarchy::token_escrow;
    use futarchy::oracle;

    // Test coins
    public struct ASSET has drop {}
    public struct STABLE has drop {}

    const TEST_LIQUIDITY_AMOUNT: u64 = 10_000_000;
    const DEFAULT_BASIS_POINTS: u64 = 10000;
    const DEFAULT_TWAP_START_DELAY: u64 = 60_000;
    const DEFAULT_TWAP_STEP_MAX: u64 = 300_000;

    // Test helper function to set up basic scenario
    fun setup_test(sender: address): (Clock, Scenario) {
        let mut scenario = test_scenario::begin(sender);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        (clock, scenario)
    }

    // Helper to create test coins
    fun mint_test_coins(amount: u64, ctx: &mut tx_context::TxContext): (Coin<ASSET>, Coin<STABLE>) {
        (
            coin::mint_for_testing<ASSET>(amount, ctx),
            coin::mint_for_testing<STABLE>(amount, ctx)
        )
    }

    // Helper to create default outcome messages
    fun create_default_outcome_messages(): vector<vector<u8>> {
        let mut messages = vector::empty();
        vector::push_back(&mut messages, b"Reject");
        vector::push_back(&mut messages, b"Accept");
        messages
    }

    #[test]
    fun test_create_dao() {
        let admin = @0xA;
        let (clock, mut scenario) = setup_test(admin);
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (dao, cap) = dao::create<ASSET, STABLE>(100, 100, &clock, test_scenario::ctx(&mut scenario));
            
            // Verify initial state
            let (active, total, _) = dao::get_stats(&dao);
            assert!(active == 0, 0);
            assert!(total == 0, 1);
            
            // Verify minimum amounts
            let (min_asset, min_stable) = dao::get_min_amounts(&dao);
            assert!(min_asset == 100, 2);
            assert!(min_stable == 100, 3);
            
            // Verify default TWAP config
            let (period, max_deviation) = dao::get_twap_config(&dao);
            assert!(period == 3600000, 4); // 1 hour
            assert!(max_deviation == 2000, 5); // 20%

            // Verify default AMM config
            let (basis_points, twap_start_delay, twap_step_max) = dao::get_amm_config(&dao);
            assert!(basis_points == DEFAULT_BASIS_POINTS, 6);
            assert!(twap_start_delay == DEFAULT_TWAP_START_DELAY, 7);
            assert!(twap_step_max == DEFAULT_TWAP_STEP_MAX, 8);

            transfer::public_transfer(dao, admin);
            transfer::public_transfer(cap, admin);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_create_valid_proposal() {
        let admin = @0xA;
        let (clock, mut scenario) = setup_test(admin);
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (mut dao, cap) = dao::create<ASSET, STABLE>(100, 100, &clock, test_scenario::ctx(&mut scenario));
            
            let (asset_coin, stable_coin) = mint_test_coins(TEST_LIQUIDITY_AMOUNT, test_scenario::ctx(&mut scenario));
            let description = b"Test Proposal";
            let metadata = vector::empty();
            let outcome_messages = create_default_outcome_messages();
            
            dao::create_proposal<ASSET, STABLE>(
                &mut dao,
                2, // outcome count
                asset_coin,
                stable_coin,
                description,
                metadata,
                outcome_messages,
                DEFAULT_BASIS_POINTS,
                DEFAULT_TWAP_START_DELAY,
                DEFAULT_TWAP_STEP_MAX,
                &clock,
                test_scenario::ctx(&mut scenario)
            );

            let (active, total, _) = dao::get_stats(&dao);
            assert!(active == 1, 0);
            assert!(total == 1, 1);

            transfer::public_transfer(dao, admin);
            transfer::public_transfer(cap, admin);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = dao::EINVALID_MESSAGES)]
    fun test_create_proposal_invalid_messages() {
        let admin = @0xA;
        let (clock, mut scenario) = setup_test(admin);
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (mut dao, cap) = dao::create<ASSET, STABLE>(100, 100, &clock, test_scenario::ctx(&mut scenario));
            let (asset_coin, stable_coin) = mint_test_coins(TEST_LIQUIDITY_AMOUNT, test_scenario::ctx(&mut scenario));
            
            // Create invalid outcome messages (wrong count)
            let mut outcome_messages = vector::empty();
            vector::push_back(&mut outcome_messages, b"Reject");
            // Missing second message for outcome count 2
            
            dao::create_proposal<ASSET, STABLE>(
                &mut dao,
                2,
                asset_coin,
                stable_coin,
                b"Test Proposal",
                vector::empty(),
                outcome_messages,
                DEFAULT_BASIS_POINTS,
                DEFAULT_TWAP_START_DELAY,
                DEFAULT_TWAP_STEP_MAX,
                &clock,
                test_scenario::ctx(&mut scenario)
            );

            transfer::public_transfer(dao, admin);
            transfer::public_transfer(cap, admin);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_update_amm_config() {
        let admin = @0xA;
        let (clock, mut scenario) = setup_test(admin);
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (mut dao, cap) = dao::create<ASSET, STABLE>(100, 100, &clock, test_scenario::ctx(&mut scenario));
            
            let new_basis_points = 8500; // 85%
            let new_twap_start_delay = 120_000; // 2 minutes
            let new_twap_step_max = 600_000; // 10 minutes
            
            dao::update_amm_config(&mut dao, &cap, new_basis_points, new_twap_start_delay, new_twap_step_max);
            
            let (basis_points, twap_start_delay, twap_step_max) = dao::get_amm_config(&dao);
            assert!(basis_points == new_basis_points, 0);
            assert!(twap_start_delay == new_twap_start_delay, 1);
            assert!(twap_step_max == new_twap_step_max, 2);

            transfer::public_transfer(dao, admin);
            transfer::public_transfer(cap, admin);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = dao::EINVALID_DESCRIPTION_LENGTH)]
    fun test_create_proposal_empty_description() {
        let admin = @0xA;
        let (clock, mut scenario) = setup_test(admin);
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (mut dao, cap) = dao::create<ASSET, STABLE>(100, 100, &clock, test_scenario::ctx(&mut scenario));
            let (asset_coin, stable_coin) = mint_test_coins(TEST_LIQUIDITY_AMOUNT, test_scenario::ctx(&mut scenario));
            
            dao::create_proposal<ASSET, STABLE>(
                &mut dao,
                2,
                asset_coin,
                stable_coin,
                b"", // Empty description
                vector::empty(),
                create_default_outcome_messages(),
                DEFAULT_BASIS_POINTS,
                DEFAULT_TWAP_START_DELAY,
                DEFAULT_TWAP_STEP_MAX,
                &clock,
                test_scenario::ctx(&mut scenario)
            );

            transfer::public_transfer(dao, admin);
            transfer::public_transfer(cap, admin);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_query_functions() {
        let admin = @0xA;
        let (clock, mut scenario) = setup_test(admin);
        
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (mut dao, cap) = dao::create<ASSET, STABLE>(100, 100, &clock, test_scenario::ctx(&mut scenario));
            let (asset_coin, stable_coin) = mint_test_coins(TEST_LIQUIDITY_AMOUNT, test_scenario::ctx(&mut scenario));
            let description = b"Test Proposal";
            
            dao::create_proposal<ASSET, STABLE>(
                &mut dao,
                2,
                asset_coin,
                stable_coin,
                description,
                vector::empty(),
                create_default_outcome_messages(),
                DEFAULT_BASIS_POINTS,
                DEFAULT_TWAP_START_DELAY,
                DEFAULT_TWAP_STEP_MAX,
                &clock,
                test_scenario::ctx(&mut scenario)
            );

            test_scenario::next_tx(&mut scenario, admin);
            
            let mut proposal_id = test_scenario::most_recent_id_for_address<Proposal<ASSET, STABLE>>(admin);
            let proposal_id = option::extract(&mut proposal_id);
            
            let info = dao::get_proposal_info(&dao, proposal_id);
            assert!(dao::get_proposer(info) == admin, 0);
            assert!(dao::get_description(info) == &description, 1);
            assert!(!dao::is_executed(info), 2);
            assert!(option::is_none(&dao::get_execution_time(info)), 3);
            assert!(option::is_none(dao::get_result(info)), 4);

            transfer::public_transfer(dao, admin);
            transfer::public_transfer(cap, admin);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_sign_result_entry() {
        let admin = @0xA;
        let (clock, mut scenario) = setup_test(admin);
        
        // Create DAO and proposal 
        test_scenario::next_tx(&mut scenario, admin);
        {
            let (mut dao, cap) = dao::create<ASSET, STABLE>(100, 100, &clock, test_scenario::ctx(&mut scenario));
            let (asset_coin, stable_coin) = mint_test_coins(TEST_LIQUIDITY_AMOUNT, test_scenario::ctx(&mut scenario));
            
            dao::create_proposal<ASSET, STABLE>(
                &mut dao,
                2,
                asset_coin,
                stable_coin,
                b"Test Proposal",
                vector::empty(),
                create_default_outcome_messages(),
                DEFAULT_BASIS_POINTS,
                DEFAULT_TWAP_START_DELAY,
                DEFAULT_TWAP_STEP_MAX,
                &clock,
                test_scenario::ctx(&mut scenario)
            );

            transfer::public_transfer(dao, admin);
            transfer::public_transfer(cap, admin);
        };

        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut dao = test_scenario::take_from_sender<DAO>(&mut scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&mut scenario);
            let mut proposal_id = test_scenario::most_recent_id_for_address<Proposal<ASSET, STABLE>>(admin);
            let proposal_id = option::extract(&mut proposal_id);
            let mut proposal = test_scenario::take_from_sender<Proposal<ASSET, STABLE>>(&mut scenario);
            
            // Get escrow as shared object
            let escrow_id = proposal::escrow_id(&proposal);
            let mut escrow = test_scenario::take_shared<token_escrow::TokenEscrow<ASSET, STABLE>>(&mut scenario);
            
            // First set proposal state to Settlement (2)
            dao::test_set_proposal_state(&mut dao, proposal_id, 2);

            // We need to properly finalize the market through state transition
            let market_admin_cap = test_scenario::take_from_sender<market_state::AdminCap>(&mut scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);

            // Start trading first (needs to happen before we can finalize)
            market_state::start_trading(market_state, &market_admin_cap, 1000, &clock, test_scenario::ctx(&mut scenario)); 
            
            // Create a test oracle
            let test_oracle = oracle::test_oracle();
            
            // End trading and move to settlement
            market_state::end_trading(market_state, &market_admin_cap, &test_oracle, &clock, test_scenario::ctx(&mut scenario));
            
            // Now finalize with outcome 1 as winner 
            market_state::finalize(market_state, &market_admin_cap, 1, &clock, test_scenario::ctx(&mut scenario));
            
            // Now set proposal state to finalized (3)
            dao::test_set_proposal_state(&mut dao, proposal_id, 3);
            
            // Test signing result
            dao::sign_result_entry<ASSET, STABLE>(
                &mut dao,
                proposal_id,
                &mut escrow,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify result was signed
            let info = dao::get_proposal_info(&dao, proposal_id);
            assert!(dao::is_executed(info), 0);
            assert!(option::is_some(&dao::get_execution_time(info)), 1);
            assert!(option::is_some(dao::get_result(info)), 2);
            
            // Clean up
            test_scenario::return_shared(escrow);
            test_scenario::return_to_sender(&mut scenario, proposal);
            test_scenario::return_to_sender(&mut scenario, dao);
            test_scenario::return_to_sender(&mut scenario, admin_cap);
            test_scenario::return_to_sender(&mut scenario, market_admin_cap);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}