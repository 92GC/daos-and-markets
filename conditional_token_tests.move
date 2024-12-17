#[test_only]
module futarchy::conditional_token_tests {
    use sui::test_scenario;
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use sui::object::UID;
    use futarchy::conditional_token::{Self, Supply, ConditionalToken};
    use futarchy::market_state::{Self, MarketState, TokenManagerCap};

    // Test constants
    const ADMIN: address = @0xA;
    const USER1: address = @0xB;
    const USER2: address = @0xC;
    
    const ASSET_TYPE_ASSET: u8 = 0;
    const ASSET_TYPE_STABLE: u8 = 1;
    const OUTCOME_YES: u8 = 0;
    const OUTCOME_NO: u8 = 1;
    
    // Test helper struct
    public struct TestTradingCap has key, store {
        id: UID
    }

    // Helper function to initialize market
    fun init_market(ctx: &mut TxContext): (MarketState, TokenManagerCap) {
        let market_state = market_state::create_for_testing(2, ctx);
        let token_cap = market_state::create_token_manager_cap_for_testing(&market_state, ctx);
        (market_state, token_cap)
    }

    #[test]
    fun test_supply_creation() {
        let mut scenario = test_scenario::begin(ADMIN); // Add mut
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let (mut state, token_cap) = init_market(ctx); // Add mut
            
            transfer::public_share_object(state);
            transfer::public_transfer(token_cap, ADMIN);
        };
        
        // Test valid supply creation
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut state = test_scenario::take_shared<MarketState>(&scenario);
            let token_cap = test_scenario::take_from_sender<TokenManagerCap>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            let supply = conditional_token::new_supply(
                &state,
                &token_cap,
                ASSET_TYPE_ASSET,
                OUTCOME_YES,
                ctx
            );
            
            assert!(conditional_token::total_supply(&supply) == 0, 0);
            transfer::public_transfer(supply, ADMIN);
            
            test_scenario::return_shared(state);
            test_scenario::return_to_sender(&scenario, token_cap);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_mint_and_burn() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let (mut state, token_cap) = init_market(ctx);
            let mut clock = clock::create_for_testing(ctx);
            
            market_state::init_trading_for_testing(&mut state);
            clock::set_for_testing(&mut clock, 1000);
            
            transfer::public_share_object(state);
            clock::share_for_testing(clock);
            transfer::public_transfer(token_cap, ADMIN);
        };
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let state = test_scenario::take_shared<MarketState>(&scenario);
            let token_cap = test_scenario::take_from_sender<TokenManagerCap>(&scenario);
            let clock = test_scenario::take_shared<Clock>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            let mut supply = conditional_token::new_supply(
                &state,
                &token_cap,
                ASSET_TYPE_ASSET,
                OUTCOME_YES,
                ctx
            );
            
            conditional_token::mint(
                &state,
                &token_cap,
                &mut supply,
                100,
                USER1,
                &clock,
                ctx
            );
        
            assert!(conditional_token::total_supply(&supply) == 100, 2);
            transfer::public_transfer(supply, ADMIN);
            
            test_scenario::return_shared(state);
            test_scenario::return_shared(clock);
            test_scenario::return_to_sender(&scenario, token_cap);
        };
        
        // Burn tokens
        test_scenario::next_tx(&mut scenario, USER1);
        let token = test_scenario::take_from_sender<ConditionalToken>(&scenario);
        let mut state = test_scenario::take_shared<MarketState>(&scenario);
        let clock = test_scenario::take_shared<Clock>(&scenario);
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut supply = test_scenario::take_from_sender<Supply>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            market_state::finalize_for_testing(&mut state);
            
            conditional_token::burn(
                &state,
                &mut supply,
                token,
                &clock,
                ctx
            );
            assert!(conditional_token::total_supply(&supply) == 0, 3);
            
            test_scenario::return_to_sender(&scenario, supply);
        };
        
        test_scenario::return_shared(state);
        test_scenario::return_shared(clock);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_split_and_merge() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup initial state
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let (mut state, token_cap) = init_market(ctx);
            let mut clock = clock::create_for_testing(ctx);
            
            market_state::init_trading_for_testing(&mut state);
            clock::set_for_testing(&mut clock, 1000);
            
            transfer::public_share_object(state);
            clock::share_for_testing(clock);
            transfer::public_transfer(token_cap, ADMIN);
        };
        
        // Mint initial token
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut state = test_scenario::take_shared<MarketState>(&scenario);
            let token_cap = test_scenario::take_from_sender<TokenManagerCap>(&scenario);
            let clock = test_scenario::take_shared<Clock>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            let mut supply = conditional_token::new_supply(
                &state,
                &token_cap,
                ASSET_TYPE_ASSET,
                OUTCOME_YES,
                ctx
            );
            
            conditional_token::mint(
                &state,
                &token_cap,
                &mut supply,
                100,
                USER1,
                &clock,
                ctx
            );
            
            transfer::public_transfer(supply, ADMIN);
            
            test_scenario::return_shared(state);
            test_scenario::return_shared(clock);
            test_scenario::return_to_sender(&scenario, token_cap);
        };
        
        // Split token
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut token = test_scenario::take_from_sender<ConditionalToken>(&scenario);
            let clock = test_scenario::take_shared<Clock>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            conditional_token::split(
                &mut token,
                40,
                USER2,
                &clock,
                ctx
            );
            
            assert!(conditional_token::value(&token) == 60, 4);
            test_scenario::return_to_sender(&scenario, token);
            test_scenario::return_shared(clock);
        };
        
        // Merge tokens
        test_scenario::next_tx(&mut scenario, USER2);
        {
            let token2 = test_scenario::take_from_sender<ConditionalToken>(&scenario);
            let clock = test_scenario::take_shared<Clock>(&scenario);
            assert!(conditional_token::value(&token2) == 40, 5);
            
            test_scenario::next_tx(&mut scenario, USER1);
            let mut token1 = test_scenario::take_from_sender<ConditionalToken>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            conditional_token::merge(&mut token1, token2, &clock, ctx);
            assert!(conditional_token::value(&token1) == 100, 6);
            
            test_scenario::return_to_sender(&scenario, token1);
            test_scenario::return_shared(clock);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_merge_many() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup initial state
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let (mut state, token_cap) = init_market(ctx);
            let mut clock = clock::create_for_testing(ctx);
            
            market_state::init_trading_for_testing(&mut state);
            clock::set_for_testing(&mut clock, 1000);
            
            transfer::public_share_object(state);
            clock::share_for_testing(clock);
            transfer::public_transfer(token_cap, ADMIN);
        };
        
        // Mint multiple tokens to different users
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let state = test_scenario::take_shared<MarketState>(&scenario);
            let token_cap = test_scenario::take_from_sender<TokenManagerCap>(&scenario);
            let clock = test_scenario::take_shared<Clock>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            let mut supply = conditional_token::new_supply(
                &state,
                &token_cap,
                ASSET_TYPE_ASSET,
                OUTCOME_YES,
                ctx
            );
            
            // Mint base token for USER1
            conditional_token::mint(
                &state,
                &token_cap,
                &mut supply,
                50,
                USER1,
                &clock,
                ctx
            );
            
            // Mint tokens to be merged
            conditional_token::mint(
                &state,
                &token_cap,
                &mut supply,
                20,
                USER2,
                &clock,
                ctx
            );
            
            conditional_token::mint(
                &state,
                &token_cap,
                &mut supply,
                30,
                USER2,
                &clock,
                ctx
            );
            
            transfer::public_transfer(supply, ADMIN);
            
            test_scenario::return_shared(state);
            test_scenario::return_shared(clock);
            test_scenario::return_to_sender(&scenario, token_cap);
        };
        
        // Prepare tokens for merge
        test_scenario::next_tx(&mut scenario, USER2);
        {
            let token2 = test_scenario::take_from_sender<ConditionalToken>(&scenario);
            let token3 = test_scenario::take_from_sender<ConditionalToken>(&scenario);
            let clock = test_scenario::take_shared<Clock>(&scenario);
            
            test_scenario::next_tx(&mut scenario, USER1);
            let mut base_token = test_scenario::take_from_sender<ConditionalToken>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            
            // Create vector of tokens to merge
            let mut tokens_to_merge = vector::empty();
            vector::push_back(&mut tokens_to_merge, token2);
            vector::push_back(&mut tokens_to_merge, token3);
            
            // Verify initial values
            assert!(conditional_token::value(&base_token) == 50, 7);
            
            // Merge multiple tokens
            conditional_token::merge_many(
                &mut base_token,
                tokens_to_merge,
                &clock,
                ctx
            );
            
            // Verify final merged amount
            assert!(conditional_token::value(&base_token) == 100, 8);
            
            test_scenario::return_to_sender(&scenario, base_token);
            test_scenario::return_shared(clock);
        };
        
        test_scenario::end(scenario);
    }

}