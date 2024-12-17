#[test_only]
module futarchy::proposal_tests {
    use std::vector;
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::clock::{Self, Clock};
    use sui::balance;
    use sui::transfer;
    use sui::object::{Self, ID};
    use futarchy::proposal::{Self, Proposal};
    use futarchy::market_state::{Self, AdminCap, TokenManagerCap};
    use futarchy::token_escrow::{Self, TokenEscrow};
    use futarchy::conditional_token::{Self as token, ConditionalToken, Supply};
    use std::debug;

    const ADMIN: address = @0xcafe;
    const USER: address = @0xdead;
    const DAO: address = @0xda0;
    
    const MIN_ASSET_LIQUIDITY: u64 = 1_000_000;
    const MIN_STABLE_LIQUIDITY: u64 = 1_000_000;
    const STARTING_TIMESTAMP: u64 = 1_000_000_000;
    const BASIS_POINTS: u64 = 10000;
    const TWAP_START_DELAY: u64 = 100;
    const TWAP_STEP_MAX: u64 = 10000;


    // State constants
    const STATE_REVIEW: u8 = 0;
    const STATE_TRADING: u8 = 1;
    const STATE_SETTLEMENT: u8 = 2;
    const STATE_FINALIZED: u8 = 3;
    const REVIEW_PERIOD_MS: u64 = 2_000_000;  // 2 seconds
    const TRADING_PERIOD_MS: u64 = 2_000_00; // 1 second

    fun setup_test_proposal(scenario: &mut Scenario, clock: &Clock) {
        let asset_balance = balance::create_for_testing<u64>(MIN_ASSET_LIQUIDITY);
        let stable_balance = balance::create_for_testing<u64>(MIN_STABLE_LIQUIDITY);
        let dao_id = object::id_from_address(DAO);
        
        let mut outcome_messages = vector::empty();
        vector::push_back(&mut outcome_messages, b"Outcome 0");
        vector::push_back(&mut outcome_messages, b"Outcome 1");
        
        let proposal = proposal::create(
            dao_id,
            2,
            asset_balance,
            stable_balance,
            b"Test Proposal",
            b"Test Metadata",
            outcome_messages,
            BASIS_POINTS,
            TWAP_START_DELAY,
            TWAP_STEP_MAX,
            clock,
            ctx(scenario)
        );

        transfer::public_share_object(proposal);
    }


    #[test]
    fun test_create_proposal() {
        let mut scenario = test::begin(ADMIN);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);
        
        next_tx(&mut scenario, ADMIN); 
        {
            setup_test_proposal(&mut scenario, &clock);
        };

        next_tx(&mut scenario, ADMIN);
        {
            let proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);

            assert!(proposal::state(&proposal) == STATE_REVIEW, 0);
            assert!(proposal::outcome_count(&proposal) == 2, 1);
            assert!(proposal::proposer(&proposal) == ADMIN, 2);
            assert!(vector::length(proposal::get_description(&proposal)) > 0, 3);
            assert!(vector::length(proposal::get_metadata(&proposal)) > 0, 4);
            assert!(proposal::created_at(&proposal) == STARTING_TIMESTAMP, 5);

            let (asset_bal, stable_bal) = token_escrow::get_balances(&escrow);
            assert!(asset_bal == MIN_ASSET_LIQUIDITY, 7);
            assert!(stable_bal == MIN_STABLE_LIQUIDITY, 8);

            test::return_shared(proposal);
            test::return_shared(escrow);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_basic_state_transition() {
        let mut scenario = test::begin(ADMIN);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

        // Create proposal
        next_tx(&mut scenario, ADMIN);
        {
            let asset_balance = balance::create_for_testing<u64>(MIN_ASSET_LIQUIDITY);
            let stable_balance = balance::create_for_testing<u64>(MIN_STABLE_LIQUIDITY);
            let dao_id = object::id_from_address(DAO);
            
            let mut outcome_messages = vector::empty();
            vector::push_back(&mut outcome_messages, b"Outcome 0");
            vector::push_back(&mut outcome_messages, b"Outcome 1");
            
            let proposal = proposal::create(
                dao_id,
                2,
                asset_balance,
                stable_balance,
                b"Test Proposal",
                b"Test Metadata",
                outcome_messages,
                BASIS_POINTS,
                TWAP_START_DELAY,
                TWAP_STEP_MAX,
                &clock,
                ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
        };

        // Advance clock and transition to trading
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + 2_000_100);
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);

            proposal::try_advance_state(
                &mut proposal,
                market_state,
                &admin_cap,
                &clock,
                ctx(&mut scenario)
            );

            assert!(proposal::state(&proposal) == 1, 0); // STATE_TRADING

            test::return_to_address(ADMIN, admin_cap);
            test::return_shared(proposal);
            test::return_shared(escrow);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_state_transitions() {
        let mut scenario = test::begin(ADMIN);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

        next_tx(&mut scenario, ADMIN);
        {
            setup_test_proposal(&mut scenario, &clock);
        };

        // Test transition to TRADING
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 100);
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);
            
            proposal::try_advance_state(&mut proposal, market_state, &admin_cap, &clock, ctx(&mut scenario));
            assert!(proposal::state(&proposal) == STATE_TRADING, 0);

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        // Test transition to SETTLEMENT
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + TRADING_PERIOD_MS + 100);
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);

            proposal::try_advance_state(&mut proposal, market_state, &admin_cap, &clock, ctx(&mut scenario));
            assert!(proposal::state(&proposal) == STATE_SETTLEMENT, 1);

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        // Test finalization
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            
            proposal::finalize_entry(&mut proposal, &mut escrow, &admin_cap, &clock, ctx(&mut scenario));
            assert!(proposal::state(&proposal) == STATE_FINALIZED, 2);
            
            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_liquidity_operations() {
        let mut scenario = test::begin(ADMIN);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);
        
        debug::print(&b"Starting test setup");
        next_tx(&mut scenario, ADMIN);
        setup_test_proposal(&mut scenario, &clock);

        // Advance to trading state
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 100);
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);
            proposal::try_advance_state(&mut proposal, market_state, &admin_cap, &clock, ctx(&mut scenario));
            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        // Create tokens for USER
        next_tx(&mut scenario, USER);
        {
            let token_cap = test::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            
            debug::print(&b"Creating tokens");
            token_escrow::create_asset_tokens(&mut escrow, &token_cap, 500, USER, &clock, ctx(&mut scenario));
            token_escrow::create_stable_tokens(&mut escrow, &token_cap, 500, USER, &clock, ctx(&mut scenario));
            
            test::return_shared(escrow);
            test::return_to_address(ADMIN, token_cap);
        };

        // Add liquidity using the tokens
        next_tx(&mut scenario, USER);
        {
            let token_cap = test::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            
            let token1 = test::take_from_address<ConditionalToken>(&scenario, USER);
            let token2 = test::take_from_address<ConditionalToken>(&scenario, USER);
            let token3 = test::take_from_address<ConditionalToken>(&scenario, USER);
            let token4 = test::take_from_address<ConditionalToken>(&scenario, USER);

            debug::print(&b"Token details:");
            debug::print(&b"Token1 - outcome, type:");
            debug::print(&token::outcome(&token1));
            debug::print(&token::asset_type(&token1));
            debug::print(&b"Token2 - outcome, type:");
            debug::print(&token::outcome(&token2));
            debug::print(&token::asset_type(&token2));
            debug::print(&b"Token3 - outcome, type:");
            debug::print(&token::outcome(&token3));
            debug::print(&token::asset_type(&token3));
            debug::print(&b"Token4 - outcome, type:");
            debug::print(&token::outcome(&token4));
            debug::print(&token::asset_type(&token4));

            // Use outcome 0 tokens (Token4 is asset, Token2 is stable)
            let outcome_idx = 0;
            let asset_token = token4;
            let stable_token = token2;

            // Return unused tokens
            test::return_to_address(USER, token1);
            test::return_to_address(USER, token3);

            debug::print(&b"Using matched tokens for liquidity - asset token outcome, stable token outcome:");
            debug::print(&token::outcome(&asset_token));
            debug::print(&token::outcome(&stable_token));
            
            proposal::add_liquidity_entry(
                &mut proposal,
                &mut escrow,
                &token_cap,
                outcome_idx,
                asset_token,
                stable_token,
                &clock,
                ctx(&mut scenario)
            );

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, token_cap);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = futarchy::proposal::EINVALID_STATE)]
    fun test_swap_before_trading() {
        let mut scenario = test::begin(ADMIN);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

        next_tx(&mut scenario, ADMIN);
        {
            setup_test_proposal(&mut scenario, &clock);
        };

        next_tx(&mut scenario, ADMIN);
        {
            let token_cap = test::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state(&escrow);

            // Try to swap while still in REVIEW state - should fail
            proposal::swap_asset_to_stable(
                &mut proposal,
                market_state,
                &token_cap,
                0,  // outcome_idx
                1000,  // amount_in
                900,   // min_amount_out
                &clock,
                ctx(&mut scenario)
            );

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, token_cap);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_successful_swaps() {
        let mut scenario = test::begin(ADMIN);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

        next_tx(&mut scenario, ADMIN);  
        setup_test_proposal(&mut scenario, &clock);

        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 100);
        next_tx(&mut scenario, ADMIN); 
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario); 
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);
            proposal::try_advance_state(&mut proposal, market_state, &admin_cap, &clock, ctx(&mut scenario));
            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        next_tx(&mut scenario, USER); 
        {
            let token_cap = test::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            token_escrow::create_asset_tokens(&mut escrow, &token_cap, 100, USER, &clock, ctx(&mut scenario));
            test::return_shared(escrow);
            test::return_to_address(ADMIN, token_cap);
        };

        next_tx(&mut scenario, USER);
        {
            let token_cap = test::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let token = test::take_from_address<ConditionalToken>(&scenario, USER);
            
            proposal::swap_asset_to_stable_entry(
                &mut proposal,
                &mut escrow,
                &token_cap,
                1,  // Changed to 1 to match token outcome
                token,
                0,
                &clock,
                ctx(&mut scenario)
            );

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, token_cap);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
                        
    #[test]
    fun test_twap_price_tracking() {
        let mut scenario = test::begin(ADMIN);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

        next_tx(&mut scenario, ADMIN);
        {
            setup_test_proposal(&mut scenario, &clock);
        };

        // Advance to trading state
        let trading_time = STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 100;
        clock::set_for_testing(&mut clock, trading_time);
        
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);
            
            proposal::try_advance_state(&mut proposal, market_state, &admin_cap, &clock, ctx(&mut scenario));
            debug::print(&b"Current proposal state after advance:");
            debug::print(&proposal::state(&proposal));
            
            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        // Create tokens for USER
        next_tx(&mut scenario, USER);
        {
            let token_cap = test::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            
            token_escrow::create_stable_tokens(&mut escrow, &token_cap, 10000, USER, &clock, ctx(&mut scenario));
            
            test::return_shared(escrow);
            test::return_to_address(ADMIN, token_cap);
        };

        // Perform swaps to affect prices
        next_tx(&mut scenario, USER);
        {
            let token_cap = test::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            
            let token1 = test::take_from_address<ConditionalToken>(&scenario, USER);
            let token2 = test::take_from_address<ConditionalToken>(&scenario, USER);
            
            debug::print(&b"Token details before swap:");
            debug::print(&b"Token1 - outcome, type, value:");
            debug::print(&token::outcome(&token1));
            debug::print(&token::asset_type(&token1));
            debug::print(&token::value(&token1));

            let outcome_idx = (token::outcome(&token1) as u64);
            
            proposal::swap_stable_to_asset_entry(
                &mut proposal,
                &mut escrow,
                &token_cap,
                outcome_idx,
                token1,
                0,
                &clock,
                ctx(&mut scenario)
            );

            test::return_to_address(USER, token2);
            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, token_cap);
        };

        // Advance time to allow TWAP accumulation
        let settlement_time = STARTING_TIMESTAMP + REVIEW_PERIOD_MS + TRADING_PERIOD_MS + 100;
        clock::set_for_testing(&mut clock, settlement_time);
        
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);

            proposal::try_advance_state(&mut proposal, market_state, &admin_cap, &clock, ctx(&mut scenario));
            assert!(proposal::state(&proposal) == STATE_SETTLEMENT, 0);

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        // Finalize and validate TWAP prices
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            
            proposal::finalize_entry(&mut proposal, &mut escrow, &admin_cap, &clock, ctx(&mut scenario));
            
            let twap_prices = proposal::get_twap_prices(&proposal);
            let value0 = *vector::borrow(twap_prices, 0);
            let value1 = *vector::borrow(twap_prices, 1);
            debug::print(&value0);
            debug::print(&value1);
            assert!(vector::length(twap_prices) == 2, 0); // Two outcomes
            assert!(*vector::borrow(twap_prices, 0) == 98177355, 1); // First outcome TWAP
            assert!(*vector::borrow(twap_prices, 1) == 99420662, 2); // Second outcome TWAP

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_full_proposal_flow() {
        let mut scenario = test::begin(ADMIN);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP);

        // Setup initial balances
        let initial_asset_amount = 1_000_000;
        let initial_stable_amount = 1_000_000;

        debug::print(&b"Creating proposal with initial balances:");
        debug::print(&initial_asset_amount);
        debug::print(&initial_stable_amount);

        // Create proposal
        next_tx(&mut scenario, ADMIN);
        {
            let asset_balance = balance::create_for_testing<u64>(initial_asset_amount);
            let stable_balance = balance::create_for_testing<u64>(initial_stable_amount);
            let dao_id = object::id_from_address(DAO);
            
            let mut outcome_messages = vector::empty();
            vector::push_back(&mut outcome_messages, b"Outcome 0");
            vector::push_back(&mut outcome_messages, b"Outcome 1");
            
            let proposal = proposal::create(
                dao_id,
                2,
                asset_balance,
                stable_balance,
                b"Test Proposal",
                b"Test Metadata",
                outcome_messages,
                BASIS_POINTS,
                TWAP_START_DELAY,
                TWAP_STEP_MAX,
                &clock,
                ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
        };

        // Advance to trading state
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + 100);
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);
            
            proposal::try_advance_state(&mut proposal, market_state, &admin_cap, &clock, ctx(&mut scenario));
            assert!(proposal::state(&proposal) == STATE_TRADING, 0);
            
            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        // Create stable tokens for swap
        next_tx(&mut scenario, USER);
        {
            let token_cap = test::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            
            // Create smaller amount of stable tokens to avoid price impact
            let swap_amount = 10_000;
            token_escrow::create_stable_tokens(&mut escrow, &token_cap, swap_amount, USER, &clock, ctx(&mut scenario));
            debug::print(&b"Created stable tokens amount:");
            debug::print(&swap_amount);
            
            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, token_cap);
        };

        // Perform swap from stable to asset for outcome 1
        next_tx(&mut scenario, USER);
        {
            let token_cap = test::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let token = test::take_from_address<ConditionalToken>(&scenario, USER);
            
            debug::print(&b"Token details before swap:");
            debug::print(&b"Token value:");
            debug::print(&token::value(&token));
            debug::print(&b"Token outcome:");
            debug::print(&token::outcome(&token));
            debug::print(&b"Token type:");
            debug::print(&token::asset_type(&token));
            
            let outcome_idx = (token::outcome(&token) as u64);
            debug::print(&b"Using outcome_idx:");
            debug::print(&outcome_idx);
            
            proposal::swap_stable_to_asset_entry(
                &mut proposal,
                &mut escrow,
                &token_cap,
                outcome_idx,
                token,
                0,  // min_amount_out set to 0 to allow any price impact
                &clock,
                ctx(&mut scenario)
            );

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, token_cap);
        };

        // Advance to settlement
        clock::set_for_testing(&mut clock, STARTING_TIMESTAMP + REVIEW_PERIOD_MS + TRADING_PERIOD_MS + 100);
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let market_state = token_escrow::get_market_state_mut(&mut escrow);

            proposal::try_advance_state(&mut proposal, market_state, &admin_cap, &clock, ctx(&mut scenario));
            assert!(proposal::state(&proposal) == STATE_SETTLEMENT, 1);

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

        // Finalize proposal and wait one tx before redemption
        next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test::take_from_address<AdminCap>(&scenario, ADMIN);
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            
            proposal::finalize_entry(&mut proposal, &mut escrow, &admin_cap, &clock, ctx(&mut scenario));
            assert!(proposal::state(&proposal) == STATE_FINALIZED, 2);

            test::return_shared(proposal);
            test::return_shared(escrow);
            test::return_to_address(ADMIN, admin_cap);
        };

    // Try redeem tokens in next tx
        next_tx(&mut scenario, USER);
        {
            let mut proposal = test::take_shared<Proposal<u64, u64>>(&scenario);
            let mut escrow = test::take_shared<TokenEscrow<u64, u64>>(&scenario);
            let token = test::take_from_address<ConditionalToken>(&scenario, USER);
            
            let token_outcome = token::outcome(&token);
            let token_type = token::asset_type(&token);
            let token_value = token::value(&token);
            let winning_outcome = market_state::get_winning_outcome(token_escrow::get_market_state(&escrow));
            
            debug::print(&b"Token details for redemption:");
            debug::print(&b"Token outcome:");
            debug::print(&token_outcome);
            debug::print(&b"Token type:");
            debug::print(&token_type);
            debug::print(&b"Token value:");
            debug::print(&token_value);
            debug::print(&b"Winning outcome:");
            debug::print(&winning_outcome);
                
            if (token_outcome == (winning_outcome as u8)) {
                debug::print(&b"Redeeming winning token");
                
                // Redeem in a separate transaction to ensure proper object creation
                token_escrow::redeem_winning_tokens_asset_entry(
                    &mut escrow,
                    token,
                    &clock,      // Add clock parameter
                    ctx(&mut scenario)
                );

                test::return_shared(proposal);
                test::return_shared(escrow);
                
                next_tx(&mut scenario, USER); {
                    let coin_store = test::take_from_address<token_escrow::CoinStore<u64>>(&scenario, USER);
                    let redeemed_amount = token_escrow::value(&coin_store);
                    debug::print(&b"Redeemed amount:");
                    debug::print(&redeemed_amount);
                    
                    // Return or withdraw as needed
                    token_escrow::withdraw_to_coin(coin_store, ctx(&mut scenario));
                }
            } else {
                debug::print(&b"Token was not winning outcome, returning");
                test::return_to_address(USER, token);
                test::return_shared(proposal);
                test::return_shared(escrow);
            };
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
}