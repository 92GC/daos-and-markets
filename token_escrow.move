module futarchy::token_escrow {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use std::vector;
    use futarchy::conditional_token::{Self as token, ConditionalToken, Supply};
    use futarchy::market_state::{Self, MarketState, TokenManagerCap};
    use std::debug;
    use sui::coin::{Self, Coin};
    use sui::event;

    // constants
    const TOKEN_TYPE_STABLE: u8 = 0;
    const TOKEN_TYPE_ASSET: u8 = 1;
    

    // Error constants
    const EINCORRECT_SEQUENCE: u64 = 0;
    const EMISMATCHED_AMOUNTS: u64 = 1;
    const EWRONG_MARKET: u64 = 2;
    const EWRONG_TOKEN_TYPE: u64 = 3;
    const ESUPPLIES_NOT_INITIALIZED: u64 = 4;
    const EOUTCOME_OUT_OF_BOUNDS: u64 = 5;
    const EWRONG_OUTCOME: u64 = 6;

    /// Escrow that manages token balances and supplies for N outcomes
    public struct TokenEscrow<phantom AssetType, phantom StableType> has key, store {
        id: UID,
        market_state: MarketState,
        // Main balances
        asset_balance: Balance<AssetType>,
        stable_balance: Balance<StableType>,
        // Per-outcome balances
        outcome_asset_balances: vector<Balance<AssetType>>,
        outcome_stable_balances: vector<Balance<StableType>>,
        // Token supplies
        outcome_asset_supplies: vector<Supply>,
        outcome_stable_supplies: vector<Supply>
    }

    public struct CoinStore<phantom T> has key {
        id: UID,
        balance: Balance<T>
    }

    // =========== Events ===========

    // === Creation and Initialization ===

    public fun new<AssetType, StableType>(
        market_state: MarketState,
        ctx: &mut TxContext
    ): TokenEscrow<AssetType, StableType> {
        let outcome_count = market_state::outcome_count(&market_state);
        
        let mut escrow = TokenEscrow {
            id: object::new(ctx),
            market_state,
            asset_balance: balance::zero(),
            stable_balance: balance::zero(),
            outcome_asset_balances: vector::empty(),
            outcome_stable_balances: vector::empty(),
            outcome_asset_supplies: vector::empty(),
            outcome_stable_supplies: vector::empty()
        };

        // Initialize outcome balance vectors
        let mut i = 0;
        while (i < outcome_count) {
            vector::push_back(&mut escrow.outcome_asset_balances, balance::zero());
            vector::push_back(&mut escrow.outcome_stable_balances, balance::zero());
            i = i + 1;
        };

        escrow
    }

    public fun register_supplies<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        cap: &TokenManagerCap,
        outcome_idx: u64,
        asset_supply: Supply,
        stable_supply: Supply
    ) {
        let outcome_count = market_state::outcome_count(&escrow.market_state);
        assert!(outcome_idx < outcome_count, EOUTCOME_OUT_OF_BOUNDS);
        assert!(vector::length(&escrow.outcome_asset_supplies) == outcome_idx, EINCORRECT_SEQUENCE);
        
        market_state::assert_token_manager(&escrow.market_state, cap);
        
        vector::push_back(&mut escrow.outcome_asset_supplies, asset_supply);
        vector::push_back(&mut escrow.outcome_stable_supplies, stable_supply);
    }

    // === Token Operations ===

    public fun redeem_complete_set_asset<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        mut tokens: vector<ConditionalToken>,
        clock: &Clock,  // Added parameter
        ctx: &mut TxContext
    ) : Balance<AssetType> {
        market_state::assert_not_finalized(&escrow.market_state);
        assert_supplies_initialized(escrow);
        
        let outcome_count = market_state::outcome_count(&escrow.market_state);
        assert!(vector::length(&tokens) == outcome_count, EINCORRECT_SEQUENCE);
        
        // Get amount from first token
        let first_token = vector::borrow(&tokens, 0);
        let amount = token::value(first_token);
        assert!(token::market_id(first_token) == market_state::market_id(&escrow.market_state), EWRONG_MARKET);
        assert!(token::asset_type(first_token) == 0, EWRONG_TOKEN_TYPE);
        
        // Verify all tokens match
        let mut i = 0;
        while (i < outcome_count) {
            let token = vector::borrow(&tokens, i);
            assert!(token::value(token) == amount, EMISMATCHED_AMOUNTS);
            assert!(token::market_id(token) == market_state::market_id(&escrow.market_state), EWRONG_MARKET);
            assert!(token::asset_type(token) == 0, EWRONG_TOKEN_TYPE);
            i = i + 1;
        };
        
        // Burn tokens and collect balances from each outcome
        i = 0;
        while (i < outcome_count) {
            let token = vector::remove(&mut tokens, 0);
            let outcome = token::outcome(&token);
            let supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, (outcome as u64));
            token::burn_complete_set(&escrow.market_state, supply, token, clock, ctx);  // Added clock and ctx
            
            // Return the balance from the outcome balance to the main balance
            let outcome_balance = vector::borrow_mut(&mut escrow.outcome_asset_balances, (outcome as u64));
            balance::join(&mut escrow.asset_balance, balance::split(outcome_balance, amount));
            
            i = i + 1;
        };
        vector::destroy_empty(tokens);

        // Now split from the main balance which has been replenished
        balance::split(&mut escrow.asset_balance, amount)
    }

    public entry fun redeem_complete_set_asset_entry<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        tokens: vector<ConditionalToken>,
        clock: &Clock,  // Added parameter
        ctx: &mut TxContext
    ) {
        let balance = redeem_complete_set_asset(escrow, tokens, clock, ctx);
        let sender = tx_context::sender(ctx);
        let coin_store = CoinStore {
            id: object::new(ctx),
            balance
        };
        transfer::transfer(coin_store, sender);
    }

    public fun redeem_winning_tokens_asset<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token: ConditionalToken,
        clock: &Clock,  // Added parameter
        ctx: &mut TxContext
    ) : Balance<AssetType> {
        market_state::assert_market_finalized(&escrow.market_state);
        let winner = market_state::winning_outcome(&escrow.market_state);
        
        let winner_u8 = (winner as u8);
        assert!(token::outcome(&token) == winner_u8, EWRONG_OUTCOME);
        assert!(token::market_id(&token) == market_state::market_id(&escrow.market_state), EWRONG_MARKET);
        assert!(token::asset_type(&token) == 0, EWRONG_TOKEN_TYPE); // 0 for asset type
        
        let amount = token::value(&token);
        let winning_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, winner);
        token::burn(&escrow.market_state, winning_supply, token, clock, ctx);  // Added clock and ctx
        
        // Return the balance from outcome balance to main balance first
        let outcome_balance = vector::borrow_mut(&mut escrow.outcome_asset_balances, winner);
        balance::join(&mut escrow.asset_balance, balance::split(outcome_balance, amount));
        
        // Then split from main balance
        balance::split(&mut escrow.asset_balance, amount)
    }


    public entry fun redeem_winning_tokens_asset_entry<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token: ConditionalToken,
        clock: &Clock,  // Added parameter
        ctx: &mut TxContext
    ) {
        let balance = redeem_winning_tokens_asset(escrow, token, clock, ctx);
        let sender = tx_context::sender(ctx);
        let coin_store = CoinStore {
            id: object::new(ctx),
            balance
        };
        transfer::transfer(coin_store, sender);
    }

    public fun redeem_winning_tokens_stable<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token: ConditionalToken,
        clock: &Clock,  // Added parameter
        ctx: &mut TxContext
    ) : Balance<StableType> {
        market_state::assert_market_finalized(&escrow.market_state);
        let winner = market_state::winning_outcome(&escrow.market_state);
        
        let winner_u8 = (winner as u8);
        assert!(token::outcome(&token) == winner_u8, EWRONG_OUTCOME);
        assert!(token::market_id(&token) == market_state::market_id(&escrow.market_state), EWRONG_MARKET);
        assert!(token::asset_type(&token) == 1, EWRONG_TOKEN_TYPE);
        
        let amount = token::value(&token);
        let winning_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, winner);
        token::burn(&escrow.market_state, winning_supply, token, clock, ctx);  // Added clock and ctx
        
        // First move balance from outcome balance to main balance
        let outcome_balance = vector::borrow_mut(&mut escrow.outcome_stable_balances, winner);
        balance::join(&mut escrow.stable_balance, balance::split(outcome_balance, amount));
        
        // Then split from main balance
        balance::split(&mut escrow.stable_balance, amount)
    }

    public entry fun redeem_winning_tokens_stable_entry<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token: ConditionalToken,
        clock: &Clock,  // Added parameter
        ctx: &mut TxContext
    ) {
        let balance = redeem_winning_tokens_stable(escrow, token, clock, ctx);
        let sender = tx_context::sender(ctx);
        let coin_store = CoinStore {
            id: object::new(ctx),
            balance
        };
        transfer::transfer(coin_store, sender);
    }

    // === Balance Management ===

    public fun deposit_asset<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        deposit: Balance<AssetType>
    ) {
        balance::join(&mut escrow.asset_balance, deposit);
    }

    public entry fun deposit_asset_entry<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        coin: Coin<AssetType>,
        ctx: &mut TxContext
    ) {
        let balance = coin::into_balance(coin);
        deposit_asset(escrow, balance);
    }

    public fun deposit_stable<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        deposit: Balance<StableType>
    ) {
        balance::join(&mut escrow.stable_balance, deposit);
    }

    public entry fun deposit_stable_entry<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        coin: Coin<StableType>,
        ctx: &mut TxContext
    ) {
        let balance = coin::into_balance(coin);
        deposit_stable(escrow, balance);
    }

    // === Token Creation ===

    public fun create_asset_tokens<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        amount: u64,
        recipient: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let outcome_count = market_state::outcome_count(&escrow.market_state);
        assert_supplies_initialized(escrow);
        market_state::assert_trading_active(&escrow.market_state);
        
        let mut i = 0;
        while (i < outcome_count) {
            let outcome_balance = vector::borrow_mut(&mut escrow.outcome_asset_balances, i);
            balance::join(outcome_balance, balance::split(&mut escrow.asset_balance, amount));
            
            let supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, i);
            token::mint(&escrow.market_state, token_cap, supply, amount, recipient, clock, ctx);

            i = i + 1;
        }
    }

    public entry fun create_asset_tokens_entry<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        create_asset_tokens(escrow, token_cap, amount, sender, clock, ctx);
    }


    public fun create_stable_tokens<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        amount: u64,
        recipient: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let outcome_count = market_state::outcome_count(&escrow.market_state);
        assert_supplies_initialized(escrow);
        market_state::assert_trading_active(&escrow.market_state);
        
        let mut i = 0;
        while (i < outcome_count) {
            let outcome_balance = vector::borrow_mut(&mut escrow.outcome_stable_balances, i);
            balance::join(outcome_balance, balance::split(&mut escrow.stable_balance, amount));
            
            let supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, i);
            token::mint(&escrow.market_state, token_cap, supply, amount, recipient, clock, ctx);

            i = i + 1;
        }
    }

    public entry fun create_stable_tokens_entry<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        create_stable_tokens(escrow, token_cap, amount, sender, clock, ctx);
    }


    // Atomic function to handle the entire asset->stable swap token operation
    public fun swap_asset_to_stable_tokens<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        token_in: ConditionalToken,
        outcome_idx: u64,
        amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify trading is active and outcome bounds
        let market_state = &escrow.market_state;
        market_state::assert_trading_active(market_state);
        assert!(outcome_idx < market_state::outcome_count(market_state), EOUTCOME_OUT_OF_BOUNDS);
        
        // Verify input token
        let market_id = market_state::market_id(market_state);
        assert!(token::market_id(&token_in) == market_id, EWRONG_MARKET);
        assert!(token::outcome(&token_in) == (outcome_idx as u8), EWRONG_OUTCOME);
        assert!(token::asset_type(&token_in) == 0, EWRONG_TOKEN_TYPE); // 0 for asset type
        
        // Get amount before burning
        let amount_in = token::value(&token_in);
        
        // First burn the input token
        // Burn tokens with updated parameters
        let asset_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, outcome_idx);
        token::burn_complete_set(&escrow.market_state, asset_supply, token_in, clock, ctx);

        
        // Move balances between outcome pools
        let outcome_asset_balance = vector::borrow_mut(&mut escrow.outcome_asset_balances, outcome_idx);
        balance::join(&mut escrow.asset_balance, balance::split(outcome_asset_balance, amount_in));

        let outcome_stable_balance = vector::borrow_mut(&mut escrow.outcome_stable_balances, outcome_idx);
        balance::join(outcome_stable_balance, balance::split(&mut escrow.stable_balance, amount_out));
        
        // Then mint new stable tokens directly to sender
        let stable_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, outcome_idx);
        token::mint(
            market_state,
            token_cap,
            stable_supply,
            amount_out,
            tx_context::sender(ctx),
            clock,
            ctx
        );
    }

    public fun swap_stable_to_asset_tokens<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        token_in: ConditionalToken,
        outcome_idx: u64,
        amount_out: u64,
        clock: &Clock,  // Added parameter
        ctx: &mut TxContext
    ) {
        // Verify trading is active and outcome bounds
        let market_state = &escrow.market_state;
        market_state::assert_trading_active(market_state);
        assert!(outcome_idx < market_state::outcome_count(market_state), EOUTCOME_OUT_OF_BOUNDS);
        
        // Verify input token
        let market_id = market_state::market_id(market_state);
        assert!(token::market_id(&token_in) == market_id, EWRONG_MARKET);
        assert!(token::outcome(&token_in) == (outcome_idx as u8), EWRONG_OUTCOME);
        assert!(token::asset_type(&token_in) == 1, EWRONG_TOKEN_TYPE); // 1 for stable type
        
        // Get token amount before burning
        let amount_in = token::value(&token_in);
        
        // Burn tokens with updated parameters
        let stable_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, outcome_idx);
        token::burn_complete_set(&escrow.market_state, stable_supply, token_in, clock, ctx);
        
        
        // Move balances between outcome pools
        let outcome_stable_balance = vector::borrow_mut(&mut escrow.outcome_stable_balances, outcome_idx);
        balance::join(&mut escrow.stable_balance, balance::split(outcome_stable_balance, amount_in));

        let outcome_asset_balance = vector::borrow_mut(&mut escrow.outcome_asset_balances, outcome_idx);
        balance::join(outcome_asset_balance, balance::split(&mut escrow.asset_balance, amount_out));
        
        // Then mint new asset tokens directly to sender
        let asset_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, outcome_idx);
        token::mint(
            market_state,
            token_cap,
            asset_supply,
            amount_out,
            tx_context::sender(ctx),
            clock,
            ctx
        );
    }

    public fun add_liquidity_tokens<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        market_state: &MarketState,
        token_cap: &TokenManagerCap,
        asset_tokens: ConditionalToken,
        stable_tokens: ConditionalToken,
        outcome_idx: u64,
        asset_used: u64,
        stable_used: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // ... token verification code ...

        // Get amounts from tokens before burning
        let asset_amount = token::value(&asset_tokens);
        let stable_amount = token::value(&stable_tokens);

        let asset_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, outcome_idx);
        token::burn_complete_set(&escrow.market_state, asset_supply, asset_tokens, clock, ctx);
        
        let stable_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, outcome_idx);
        token::burn_complete_set(&escrow.market_state, stable_supply, stable_tokens, clock, ctx);


        // Move balances back to main pools
        let outcome_asset_balance = vector::borrow_mut(&mut escrow.outcome_asset_balances, outcome_idx);
        balance::join(&mut escrow.asset_balance, balance::split(outcome_asset_balance, asset_amount));

        let outcome_stable_balance = vector::borrow_mut(&mut escrow.outcome_stable_balances, outcome_idx);
        balance::join(&mut escrow.stable_balance, balance::split(outcome_stable_balance, stable_amount));
    }

    public fun handle_add_liquidity_tokens<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        outcome_idx: u64,
        asset_tokens: ConditionalToken,
        stable_tokens: ConditionalToken,
        clock: &Clock,  // Added parameter
        ctx: &mut TxContext
    ) {
        // Get market info first
        let market_id = market_state::market_id(&escrow.market_state);
        
        // Verify tokens
        assert!(token::market_id(&asset_tokens) == market_id, EWRONG_MARKET);
        assert!(token::market_id(&stable_tokens) == market_id, EWRONG_MARKET);
        assert!(token::outcome(&asset_tokens) == (outcome_idx as u8), EWRONG_OUTCOME);
        assert!(token::outcome(&stable_tokens) == (outcome_idx as u8), EWRONG_OUTCOME);
        assert!(token::asset_type(&asset_tokens) == 0, EWRONG_TOKEN_TYPE);
        assert!(token::asset_type(&stable_tokens) == 1, EWRONG_TOKEN_TYPE);

        // Now handle burning tokens with updated parameters
        let asset_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, outcome_idx);
        token::burn_complete_set(&escrow.market_state, asset_supply, asset_tokens, clock, ctx);
        
        let stable_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, outcome_idx);
        token::burn_complete_set(&escrow.market_state, stable_supply, stable_tokens, clock, ctx);
    }

    public fun handle_remove_liquidity_tokens<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        outcome_idx: u64,
        asset_amount: u64,
        stable_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        
        // Move balances from main pools to outcome pools first
        let outcome_asset_balance = vector::borrow_mut(&mut escrow.outcome_asset_balances, outcome_idx);
        balance::join(outcome_asset_balance, balance::split(&mut escrow.asset_balance, asset_amount));

        let outcome_stable_balance = vector::borrow_mut(&mut escrow.outcome_stable_balances, outcome_idx);
        balance::join(outcome_stable_balance, balance::split(&mut escrow.stable_balance, stable_amount));
        
        // Then mint tokens
        let asset_supply = vector::borrow_mut(&mut escrow.outcome_asset_supplies, outcome_idx);
        token::mint(&escrow.market_state, token_cap, asset_supply, asset_amount, sender, clock, ctx);
        
        let stable_supply = vector::borrow_mut(&mut escrow.outcome_stable_supplies, outcome_idx);
        token::mint(&escrow.market_state, token_cap, stable_supply, stable_amount, sender, clock, ctx);
    }
    // === Internal Helpers ===

    fun assert_supplies_initialized<AssetType, StableType>(
        escrow: &TokenEscrow<AssetType, StableType>
    ) {
        let outcome_count = market_state::outcome_count(&escrow.market_state);
        assert!(
            vector::length(&escrow.outcome_asset_supplies) == outcome_count &&
            vector::length(&escrow.outcome_stable_supplies) == outcome_count,
            ESUPPLIES_NOT_INITIALIZED
        );
    }

    // === Getters ===

    public fun get_balances<AssetType, StableType>(
        escrow: &TokenEscrow<AssetType, StableType>
    ): (u64, u64) {
        (
            balance::value(&escrow.asset_balance),
            balance::value(&escrow.stable_balance)
        )
    }

    public fun get_market_state<AssetType, StableType>(
        escrow: &TokenEscrow<AssetType, StableType>
    ): &MarketState {
        &escrow.market_state
    }

    public fun get_market_state_mut<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>
    ): &mut MarketState {
        &mut escrow.market_state
    }

    public fun get_stable_supply<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        outcome_idx: u64,
    ): &mut Supply {
        vector::borrow_mut(&mut escrow.outcome_stable_supplies, outcome_idx)
    }

    public fun get_asset_supply<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        outcome_idx: u64,
    ): &mut Supply {
        vector::borrow_mut(&mut escrow.outcome_asset_supplies, outcome_idx)
    }

    public fun withdraw<T>(store: CoinStore<T>): Balance<T> {
        let CoinStore { id, balance } = store;
        object::delete(id);
        balance
    }

    public fun value<T>(store: &CoinStore<T>): u64 {
        balance::value(&store.balance)
    }

    public entry fun withdraw_to_coin<T>(
        store: CoinStore<T>,
        ctx: &mut TxContext
    ) {
        let CoinStore { id, balance } = store;
        object::delete(id);
        let coin = coin::from_balance(balance, ctx);
        transfer::public_transfer(coin, tx_context::sender(ctx))
    }
}