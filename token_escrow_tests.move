#[test_only]
module futarchy::token_escrow_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self, Clock};
    use sui::balance;
    use sui::coin;
    use sui::transfer;
    use std::vector;
    use std::debug;
    use futarchy::token_escrow::{Self as escrow, TokenEscrow};
    use futarchy::market_state::{Self, MarketState, TokenManagerCap};
    use futarchy::conditional_token::{Self as token, ConditionalToken};

    // Test assets
    public struct ASSET has drop {}
    public struct STABLE has drop {}

    // Test constants
    const ADMIN: address = @0xAD;
    const USER: address = @0xB0B;
    const AMOUNT: u64 = 1000;
    const OUTCOMES: u64 = 2; // Binary market for simplicity

    #[test]
    fun test_escrow_initialization() {
        let mut scenario = ts::begin(ADMIN);
        
        // Setup initial state
        ts::next_tx(&mut scenario, ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut market_state = market_state::create_for_testing(OUTCOMES, ctx);
            
            // Create new escrow
            let escrow = escrow::new<ASSET, STABLE>(
                market_state, // Move market_state into escrow
                ctx
            );

            // Verify initial balances are zero
            let (asset_balance, stable_balance) = escrow::get_balances(&escrow);
            assert!(asset_balance == 0, 0);
            assert!(stable_balance == 0, 0);

            // Share escrow which contains the market_state
            transfer::public_share_object(escrow);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_register_supplies() {
        let mut scenario = ts::begin(ADMIN);
        
        // Setup market state and clock
        ts::next_tx(&mut scenario, ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut market_state = market_state::create_for_testing(OUTCOMES, ctx);
            let token_cap = market_state::create_token_manager_cap_for_testing(&market_state, ctx);
            let clock = clock::create_for_testing(ctx);
            
            // Create escrow with market_state
            let mut escrow = escrow::new<ASSET, STABLE>(
                market_state,
                ctx
            );

            // Register supplies for both outcomes
            let mut i = 0;
            while (i < OUTCOMES) {
                let asset_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    0, // asset type
                    (i as u8),
                    ctx
                );
                let stable_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    1, // stable type
                    (i as u8),
                    ctx
                );
                
                escrow::register_supplies(
                    &mut escrow,
                    &token_cap,
                    i,
                    asset_supply,
                    stable_supply
                );
                i = i + 1;
            };

            // Share/transfer objects
            clock::share_for_testing(clock);
            transfer::public_transfer(token_cap, ADMIN);
            transfer::public_share_object(escrow);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_create_and_redeem_complete_set() {
        let mut scenario = ts::begin(ADMIN);
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut market_state = market_state::create_for_testing(OUTCOMES, ctx);
            let token_cap = market_state::create_token_manager_cap_for_testing(&market_state, ctx);
            let clock = clock::create_for_testing(ctx);
            
            market_state::init_trading_for_testing(&mut market_state);
            
            let escrow = escrow::new<ASSET, STABLE>(
                market_state,
                ctx
            );

            clock::share_for_testing(clock);
            transfer::public_transfer(token_cap, ADMIN);
            transfer::public_share_object(escrow);
        };
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut escrow = ts::take_shared<TokenEscrow<ASSET, STABLE>>(&scenario);
            let token_cap = ts::take_from_sender<TokenManagerCap>(&scenario);
            let clock = ts::take_shared<Clock>(&scenario);
            let ctx = ts::ctx(&mut scenario);

            let mut i = 0;
            while (i < OUTCOMES) {
                let asset_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    0,
                    (i as u8),
                    ctx
                );
                let stable_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    1,
                    (i as u8),
                    ctx
                );
                
                escrow::register_supplies(
                    &mut escrow,
                    &token_cap,
                    i,
                    asset_supply,
                    stable_supply
                );
                i = i + 1;
            };

            escrow::deposit_asset(
                &mut escrow,
                balance::create_for_testing<ASSET>(AMOUNT)
            );
            
            escrow::create_asset_tokens(
                &mut escrow,
                &token_cap,
                AMOUNT / OUTCOMES,
                USER,
                &clock,
                ctx
            );

            ts::return_shared(clock);
            ts::return_to_sender(&scenario, token_cap);
            ts::return_shared(escrow);
        };

       // User redeems complete set
        ts::next_tx(&mut scenario, USER);
        {
            let mut escrow = ts::take_shared<TokenEscrow<ASSET, STABLE>>(&scenario);
            let clock = ts::take_shared<Clock>(&scenario);
            
            // Debug print before redemption
            debug::print(&b"Escrow balance before redemption:");
            let (asset_balance, _) = escrow::get_balances(&escrow);
            debug::print(&asset_balance);
            
            // Collect tokens for complete set
            let mut tokens = vector::empty<ConditionalToken>();
            let mut i = 0;
            while (i < OUTCOMES) {
                let token = ts::take_from_sender<ConditionalToken>(&scenario);
                vector::push_back(&mut tokens, token);
                i = i + 1;
            };

            // Redeem complete set - now includes clock parameter
            let redeemed = escrow::redeem_complete_set_asset(
                &mut escrow,
                tokens,
                &clock,
                ts::ctx(&mut scenario)
            );

            assert!(balance::value(&redeemed) == AMOUNT / OUTCOMES, 0);
            
            // Convert balance to coin and transfer to user
            let coin = coin::from_balance(redeemed, ts::ctx(&mut scenario));
            transfer::public_transfer(coin, USER);

            // Debug print after redemption
            debug::print(&b"Escrow balance after redemption:");
            let (asset_balance, _) = escrow::get_balances(&escrow);
            debug::print(&asset_balance);

            ts::return_shared(clock);
            ts::return_shared(escrow);
        };
        
        ts::end(scenario);
    }


    #[test]
    fun test_winning_token_redemption() {
        let mut scenario = ts::begin(ADMIN);
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut market_state = market_state::create_for_testing(OUTCOMES, ctx);
            let token_cap = market_state::create_token_manager_cap_for_testing(&market_state, ctx);
            let clock = clock::create_for_testing(ctx);
            
            let mut escrow = escrow::new<ASSET, STABLE>(market_state, ctx);
            
            debug::print(&b"Registering supplies for outcomes:");
            
            let mut i = 0;
            while (i < OUTCOMES) {
                let asset_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    0,  // asset type
                    (i as u8),
                    ctx
                );
                let stable_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    1,  // stable type
                    (i as u8),
                    ctx
                );
                
                escrow::register_supplies(&mut escrow, &token_cap, i, asset_supply, stable_supply);
                debug::print(&i);
                i = i + 1;
            };
            
            market_state::init_trading_for_testing(escrow::get_market_state_mut(&mut escrow));
            
            // Deposit enough for all outcomes
            escrow::deposit_asset(&mut escrow, balance::create_for_testing<ASSET>(AMOUNT * OUTCOMES));
            
            debug::print(&b"Creating tokens for amount:");
            debug::print(&AMOUNT);
            
            // Create tokens - this will create tokens for both outcomes
            escrow::create_asset_tokens(
                &mut escrow,
                &token_cap,
                AMOUNT,
                USER,
                &clock,
                ctx
            );
            
            // Finalize the market - this sets winning outcome to 0
            market_state::finalize_for_testing(escrow::get_market_state_mut(&mut escrow));
            
            debug::print(&b"Market finalized. Winning outcome:");
            debug::print(&market_state::winning_outcome(escrow::get_market_state(&escrow)));
            
            clock::share_for_testing(clock);
            transfer::public_transfer(token_cap, ADMIN);
            transfer::public_share_object(escrow);
        };
        
        ts::next_tx(&mut scenario, USER);
        {
            let mut escrow = ts::take_shared<TokenEscrow<ASSET, STABLE>>(&scenario);
            let clock = ts::take_shared<Clock>(&scenario);
            
            // Take both tokens
            let losing_token = ts::take_from_sender<ConditionalToken>(&scenario);
            let winning_token = ts::take_from_sender<ConditionalToken>(&scenario);
            
            debug::print(&b"Losing token outcome:");
            debug::print(&token::outcome(&losing_token));
            debug::print(&b"Winning token outcome:");
            debug::print(&token::outcome(&winning_token));
            debug::print(&b"Market winning outcome:");
            debug::print(&market_state::winning_outcome(escrow::get_market_state(&escrow)));
            
            // Use the winning token - now includes clock parameter
            let redeemed = escrow::redeem_winning_tokens_asset(
                &mut escrow,
                winning_token,
                &clock,
                ts::ctx(&mut scenario)
            );
            
            assert!(balance::value(&redeemed) == AMOUNT, 0);
            
            let coin = coin::from_balance(redeemed, ts::ctx(&mut scenario));
            transfer::public_transfer(coin, USER);
            
            // Return the unused losing token
            transfer::public_transfer(losing_token, USER);
            
            ts::return_shared(clock);
            ts::return_shared(escrow);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_stable_token_operations() {
        let mut scenario = ts::begin(ADMIN);
        
        // Setup market and initial state
        ts::next_tx(&mut scenario, ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut market_state = market_state::create_for_testing(OUTCOMES, ctx);
            let token_cap = market_state::create_token_manager_cap_for_testing(&market_state, ctx);
            let clock = clock::create_for_testing(ctx);
            
            let mut escrow = escrow::new<ASSET, STABLE>(market_state, ctx);
            
            // Register supplies for each outcome
            let mut i = 0;
            while (i < OUTCOMES) {
                let asset_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    0,
                    (i as u8),
                    ctx
                );
                let stable_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    1,
                    (i as u8),
                    ctx
                );
                
                escrow::register_supplies(&mut escrow, &token_cap, i, asset_supply, stable_supply);
                i = i + 1;
            };
            
            market_state::init_trading_for_testing(escrow::get_market_state_mut(&mut escrow));
            
            debug::print(&b"Initial deposit amount:");
            debug::print(&(AMOUNT * OUTCOMES));
            
            escrow::deposit_stable(&mut escrow, balance::create_for_testing<STABLE>(AMOUNT * OUTCOMES));
            
            let (_, balance_after_deposit) = escrow::get_balances(&escrow);
            debug::print(&b"Balance after deposit:");
            debug::print(&balance_after_deposit);
            
            escrow::create_stable_tokens(
                &mut escrow,
                &token_cap,
                AMOUNT,
                USER,
                &clock,
                ctx
            );
            
            let (_, balance_after_create) = escrow::get_balances(&escrow);
            debug::print(&b"Balance after creating tokens:");
            debug::print(&balance_after_create);
            
            clock::share_for_testing(clock);
            transfer::public_transfer(token_cap, ADMIN);
            transfer::public_share_object(escrow);
        };
        
        // Verify stable token creation
        ts::next_tx(&mut scenario, USER);
        {
            let escrow = ts::take_shared<TokenEscrow<ASSET, STABLE>>(&scenario);
            let (_, stable_balance) = escrow::get_balances(&escrow);
            debug::print(&b"Final stable balance:");
            debug::print(&stable_balance);
            debug::print(&b"Expected balance:");
            debug::print(&(AMOUNT * (OUTCOMES - 1)));
            
            // When tokens are created, the balance is moved to outcome-specific balance
            // So main balance should be 0 since all balance is in outcome balances
            assert!(stable_balance == 0, 0);
            ts::return_shared(escrow);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EWRONG_OUTCOME)] 
    fun test_redeem_wrong_outcome() {
        let mut scenario = ts::begin(ADMIN);
        
        // Setup
        ts::next_tx(&mut scenario, ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut market_state = market_state::create_for_testing(OUTCOMES, ctx);
            let token_cap = market_state::create_token_manager_cap_for_testing(&market_state, ctx);
            let clock = clock::create_for_testing(ctx);
            let mut escrow = escrow::new<ASSET, STABLE>(market_state, ctx);
            
            // Register supplies
            let mut i = 0;
            while (i < OUTCOMES) {
                let asset_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    0,
                    (i as u8),
                    ctx
                );
                let stable_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    1,
                    (i as u8),
                    ctx
                );
                escrow::register_supplies(&mut escrow, &token_cap, i, asset_supply, stable_supply);
                i = i + 1;
            };
            
            // Initialize trading and deposit enough for token creation
            market_state::init_trading_for_testing(escrow::get_market_state_mut(&mut escrow));
            let init_balance = balance::create_for_testing<ASSET>(AMOUNT * OUTCOMES);
            escrow::deposit_asset(&mut escrow, init_balance);
            
            // Create tokens for each outcome
            escrow::create_asset_tokens(
                &mut escrow,
                &token_cap,
                AMOUNT,
                USER,
                &clock,
                ctx
            );
            
            // Finalize with outcome 0 as winner
            market_state::finalize_for_testing(escrow::get_market_state_mut(&mut escrow));
            
            transfer::public_share_object(escrow);
            transfer::public_transfer(token_cap, ADMIN);
            clock::share_for_testing(clock);
        };
        
        // Try to redeem losing token
        ts::next_tx(&mut scenario, USER);
        {
            let mut escrow = ts::take_shared<TokenEscrow<ASSET, STABLE>>(&scenario);
            let clock = ts::take_shared<Clock>(&scenario);
            
            let losing_token = ts::take_from_address<ConditionalToken>(&scenario, USER);
            let winning_token = ts::take_from_address<ConditionalToken>(&scenario, USER);
            
            // This should fail with EWRONG_OUTCOME - now includes clock parameter
            let redeemed = escrow::redeem_winning_tokens_asset(
                &mut escrow,
                losing_token,
                &clock,
                ts::ctx(&mut scenario)
            );
            balance::destroy_for_testing(redeemed);
            
            transfer::public_transfer(winning_token, USER);
            ts::return_shared(clock);
            ts::return_shared(escrow);
        };
        
        ts::end(scenario);
    }

    
    #[test]
    fun test_create_stable_tokens_entry() {
        let mut scenario = ts::begin(ADMIN);
            
        ts::next_tx(&mut scenario, ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut market_state = market_state::create_for_testing(OUTCOMES, ctx);
            let token_cap = market_state::create_token_manager_cap_for_testing(&market_state, ctx);
            let clock = clock::create_for_testing(ctx);
            
            let mut escrow = escrow::new<ASSET, STABLE>(market_state, ctx);
            
            let mut i = 0;
            while (i < OUTCOMES) {
                let asset_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    0,
                    (i as u8),
                    ctx
                );
                let stable_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    1,
                    (i as u8),
                    ctx
                );
                
                escrow::register_supplies(&mut escrow, &token_cap, i, asset_supply, stable_supply);
                i = i + 1;
            };
            
            market_state::init_trading_for_testing(escrow::get_market_state_mut(&mut escrow));
            escrow::deposit_stable(&mut escrow, balance::create_for_testing<STABLE>(AMOUNT * 2));
            
            clock::share_for_testing(clock);
            transfer::public_transfer(token_cap, ADMIN);
            transfer::public_share_object(escrow);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut escrow = ts::take_shared<TokenEscrow<ASSET, STABLE>>(&scenario);
            let token_cap = ts::take_from_address<TokenManagerCap>(&scenario, ADMIN);
            let clock = ts::take_shared<Clock>(&scenario);
            let ctx = ts::ctx(&mut scenario);
            
            escrow::create_stable_tokens_entry(
                &mut escrow,
                &token_cap,
                AMOUNT,
                &clock,
                ctx
            );

            ts::return_shared(clock);
            ts::return_to_address(ADMIN, token_cap);
            ts::return_shared(escrow);
        };

        // Verify ADMIN received the tokens for both outcomes
        ts::next_tx(&mut scenario, ADMIN);
        {
            // Take and verify token for outcome 0
            let token0 = ts::take_from_address<ConditionalToken>(&scenario, ADMIN);
            assert!(token::value(&token0) == AMOUNT, 0);
            assert!(token::asset_type(&token0) == 1, 2);  // 1 is stable type
            
            // Take and verify token for outcome 1
            let token1 = ts::take_from_address<ConditionalToken>(&scenario, ADMIN);
            assert!(token::value(&token1) == AMOUNT, 3);
            assert!(token::asset_type(&token1) == 1, 4);  // 1 is stable type
            
            // Verify we got tokens for different outcomes
            assert!(token::outcome(&token0) != token::outcome(&token1), 5);
            assert!(
                (token::outcome(&token0) == 0 && token::outcome(&token1) == 1) ||
                (token::outcome(&token0) == 1 && token::outcome(&token1) == 0),
                6
            );

            // Return tokens to ADMIN
            transfer::public_transfer(token0, ADMIN);
            transfer::public_transfer(token1, ADMIN);
        };
            
        ts::end(scenario);
    }

    #[test]
    fun test_redeem_winning_tokens_stable_entry() {
        let mut scenario = ts::begin(ADMIN);
        
        // Setup initial state
        ts::next_tx(&mut scenario, ADMIN);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut market_state = market_state::create_for_testing(OUTCOMES, ctx);
            let token_cap = market_state::create_token_manager_cap_for_testing(&market_state, ctx);
            let clock = clock::create_for_testing(ctx);
            
            let mut escrow = escrow::new<ASSET, STABLE>(market_state, ctx);
            
            debug::print(&b"Setting up test with OUTCOMES:");
            debug::print(&OUTCOMES);
            
            // Register supplies for outcomes
            let mut i = 0;
            while (i < OUTCOMES) {
                let asset_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    0,
                    (i as u8),
                    ctx
                );
                let stable_supply = token::new_supply(
                    escrow::get_market_state(&escrow),
                    &token_cap,
                    1,
                    (i as u8),
                    ctx
                );
                
                escrow::register_supplies(&mut escrow, &token_cap, i, asset_supply, stable_supply);
                debug::print(&b"Registered supplies for outcome:");
                debug::print(&i);
                i = i + 1;
            };
            
            // Initialize trading
            market_state::init_trading_for_testing(escrow::get_market_state_mut(&mut escrow));
            debug::print(&b"Trading initialized");
            
            // Deposit enough stable coins for the entire test
            // We need AMOUNT * OUTCOMES since we're creating tokens for each outcome
            escrow::deposit_stable(
                &mut escrow,
                balance::create_for_testing<STABLE>(AMOUNT * OUTCOMES)
            );
            
            let (_, stable_balance) = escrow::get_balances(&escrow);
            debug::print(&b"Stable balance after deposit:");
            debug::print(&stable_balance);
            
            // Create tokens for both outcomes
            escrow::create_stable_tokens(
                &mut escrow,
                &token_cap,
                AMOUNT,
                USER,
                &clock,
                ctx
            );
            
            let (_, stable_balance_after) = escrow::get_balances(&escrow);
            debug::print(&b"Stable balance after token creation:");
            debug::print(&stable_balance_after);
            
            // Finalize market with outcome 0 as winner
            market_state::finalize_for_testing(escrow::get_market_state_mut(&mut escrow));
            debug::print(&b"Market finalized with winning outcome:");
            debug::print(&market_state::winning_outcome(escrow::get_market_state(&escrow)));
            
            // Share/transfer objects
            clock::share_for_testing(clock);
            transfer::public_transfer(token_cap, ADMIN);
            transfer::public_share_object(escrow);
        };

        // User redeems winning token
        ts::next_tx(&mut scenario, USER);
        {
            let mut escrow = ts::take_shared<TokenEscrow<ASSET, STABLE>>(&scenario);
            let clock = ts::take_shared<Clock>(&scenario);
            
            let winner = market_state::winning_outcome(escrow::get_market_state(&escrow));
            debug::print(&b"Redeeming token for winning outcome:");
            debug::print(&winner);
            
            // Take both tokens and print their details
            let token1 = ts::take_from_address<ConditionalToken>(&scenario, USER);
            let token2 = ts::take_from_address<ConditionalToken>(&scenario, USER);
            
            debug::print(&b"Token 1 outcome and value:");
            debug::print(&token::outcome(&token1));
            debug::print(&token::value(&token1));
            
            debug::print(&b"Token 2 outcome and value:");
            debug::print(&token::outcome(&token2));
            debug::print(&token::value(&token2));
            
            // Use the winning token for redemption
            if (token::outcome(&token1) == (winner as u8)) {
                debug::print(&b"Using token1 for redemption");
                escrow::redeem_winning_tokens_stable_entry(
                    &mut escrow,
                    token1,
                    &clock,
                    ts::ctx(&mut scenario)
                );
                transfer::public_transfer(token2, USER);
            } else {
                debug::print(&b"Using token2 for redemption");
                escrow::redeem_winning_tokens_stable_entry(
                    &mut escrow,
                    token2,
                    &clock,
                    ts::ctx(&mut scenario)
                );
                transfer::public_transfer(token1, USER);
            };
            
            let (_, final_stable_balance) = escrow::get_balances(&escrow);
            debug::print(&b"Final stable balance in escrow:");
            debug::print(&final_stable_balance);
            
            ts::return_shared(clock);
            ts::return_shared(escrow);
        };

        // Verify redemption result
        ts::next_tx(&mut scenario, USER);
        {
            let coin_store = ts::take_from_address<escrow::CoinStore<STABLE>>(&scenario, USER);
            let store_value = escrow::value(&coin_store);
            debug::print(&b"Final coin store value:");
            debug::print(&store_value);
            assert!(store_value == AMOUNT, 0);
            let balance = escrow::withdraw(coin_store);
            balance::destroy_for_testing(balance);
        };
        
        ts::end(scenario);
    }
}