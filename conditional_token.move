module futarchy::conditional_token {
    use sui::{object::{Self, ID, UID}, tx_context::{Self, TxContext}, transfer, clock::{Self, Clock}};
    use sui::event;
    use futarchy::market_state::{Self, TokenManagerCap};

    /// Error codes
    const EINVALID_ASSET_TYPE: u64 = 0;
    const EINVALID_OUTCOME: u64 = 1;
    const EWRONG_MARKET: u64 = 3;
    const EWRONG_TOKEN_TYPE: u64 = 4;
    const EWRONG_OUTCOME: u64 = 5;
    const EZERO_AMOUNT: u64 = 6;
    const EINSUFFICIENT_BALANCE: u64 = 7;
    const EEMPTY_VECTOR: u64 = 8;


    /// Events
    public struct TokenMinted has copy, drop {
        id: ID,  // token ID
        market_id: ID,
        asset_type: u8,
        outcome: u8,
        amount: u64,
        recipient: address,
        timestamp: u64  // new field
    }

    public struct TokenBurned has copy, drop {
        id: ID,         // token ID being burned - new field
        market_id: ID,
        asset_type: u8,
        outcome: u8,
        amount: u64,
        sender: address, // new field
        timestamp: u64   // new field
    }

    // New events needed
    public struct TokenSplit has copy, drop {
        original_token_id: ID,
        new_token_id: ID,
        market_id: ID,
        asset_type: u8,
        outcome: u8,
        original_amount: u64,
        split_amount: u64,
        owner: address,
        timestamp: u64
    }

    public struct TokenMerge has copy, drop {
        token1_id: ID,
        token2_id: ID,
        result_token_id: ID,
        market_id: ID,
        asset_type: u8,
        outcome: u8,
        amount1: u64,
        amount2: u64,
        owner: address,
        timestamp: u64
    }

    public struct TokenTransferred has copy, drop {
        token_id: ID,
        market_id: ID,
        asset_type: u8,
        outcome: u8,
        amount: u64,
        from: address,
        to: address,
        timestamp: u64
    }

    public struct TokenMergeMany has copy, drop {
        base_token_id: ID,
        merged_token_ids: vector<ID>,
        market_id: ID,
        asset_type: u8,
        outcome: u8,
        base_amount: u64,
        merged_amount: u64,
        owner: address,
        timestamp: u64
    }

    // structs
    
    /// Supply tracking object for a specific conditional token type
    public struct Supply has key, store {
        id: UID,
        market_id: ID,
        asset_type: u8,
        outcome: u8,
        total_supply: u64
    }

    /// The conditional token itself
    public struct ConditionalToken has key, store {
        id: UID,
        market_id: ID,
        asset_type: u8,    // 0 for asset, 1 for stable
        outcome: u8,       // outcome index
        balance: u64
    }

    // ======== Supply Functions ========

    public fun new_supply(
        state: &market_state::MarketState,
        cap: &TokenManagerCap,
        asset_type: u8,
        outcome: u8,
        ctx: &mut TxContext
    ): Supply {
        // Verify authority and market state
        market_state::assert_token_manager(state, cap);
        market_state::validate_outcome(state, (outcome as u64));
        assert!(asset_type <= 1, EINVALID_ASSET_TYPE);
        
        Supply {
            id: object::new(ctx),
            market_id: market_state::market_id(state),
            asset_type,
            outcome,
            total_supply: 0
        }
    }

    public fun transfer(token: ConditionalToken, recipient: address, clock: &Clock, ctx: &mut TxContext) {
        let token_id = object::id(&token);
        let from = tx_context::sender(ctx);
        
        event::emit(TokenTransferred {
            token_id,
            market_id: token.market_id,
            asset_type: token.asset_type,
            outcome: token.outcome,
            amount: token.balance,
            from,
            to: recipient,
            timestamp: clock::timestamp_ms(clock)
        });
        
        transfer::transfer(token, recipient);
    }

    public fun update_supply(supply: &mut Supply, amount: u64, increase: bool) {
        assert!(amount > 0, EZERO_AMOUNT);
        if (increase) {
            supply.total_supply = supply.total_supply + amount;
        } else {
            assert!(supply.total_supply >= amount, EINSUFFICIENT_BALANCE);
            supply.total_supply = supply.total_supply - amount;
        };
    }

    // ======== Token Functions ========

    public fun mint(
        state: &market_state::MarketState,
        cap: &TokenManagerCap,
        supply: &mut Supply,
        amount: u64,
        recipient: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify market state and trading period
        market_state::assert_token_manager(state, cap);
        market_state::assert_trading_active(state);
        assert!(amount > 0, EZERO_AMOUNT);
        
        // Update supply
        update_supply(supply, amount, true);
        
        // Create and transfer new token
        let token = ConditionalToken {
            id: object::new(ctx),
            market_id: supply.market_id,
            asset_type: supply.asset_type,
            outcome: supply.outcome,
            balance: amount
        };
        
        // Emit event
        event::emit(TokenMinted {
            id: object::id(&token),
            market_id: supply.market_id,
            asset_type: supply.asset_type,
            outcome: supply.outcome,
            amount,
            recipient,
            timestamp: clock::timestamp_ms(clock)
        });
        
        transfer::transfer(token, recipient);
    }

    public fun split(
        token: &mut ConditionalToken,
        amount: u64,
        recipient: address,
        clock: &Clock,  // new parameter
        ctx: &mut TxContext
    ) {
        assert!(amount > 0, EZERO_AMOUNT);
        assert!(token.balance >= amount, EINSUFFICIENT_BALANCE);
        
        token.balance = token.balance - amount;
        
        let new_token = ConditionalToken {
            id: object::new(ctx),
            market_id: token.market_id,
            asset_type: token.asset_type,
            outcome: token.outcome,
            balance: amount
        };

        // Emit split event
        event::emit(TokenSplit {
            original_token_id: object::uid_to_inner(&token.id),
            new_token_id: object::id(&new_token),
            market_id: token.market_id,
            asset_type: token.asset_type,
            outcome: token.outcome,
            original_amount: token.balance,
            split_amount: amount,
            owner: recipient,
            timestamp: clock::timestamp_ms(clock)
        });
        
        transfer::transfer(new_token, recipient);
    }

    public entry fun split_entry(
        token: &mut ConditionalToken,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        split(token, amount, sender, clock, ctx);
    }

    public fun merge(token1: &mut ConditionalToken, token2: ConditionalToken, clock: &Clock, ctx: &TxContext) {
        assert!(token1.market_id == token2.market_id, EWRONG_MARKET);
        assert!(token1.asset_type == token2.asset_type, EWRONG_TOKEN_TYPE);
        assert!(token1.outcome == token2.outcome, EWRONG_OUTCOME);
        
        let amount2 = token2.balance;
        let token2_id = object::id(&token2);
        
        event::emit(TokenMerge {
            token1_id: object::uid_to_inner(&token1.id),
            token2_id: token2_id,
            result_token_id: object::uid_to_inner(&token1.id),
            market_id: token1.market_id,
            asset_type: token1.asset_type,
            outcome: token1.outcome,
            amount1: token1.balance,
            amount2: amount2,
            owner: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock)
        });

        let ConditionalToken {
            id,
            market_id: _,
            asset_type: _,
            outcome: _,
            balance
        } = token2;
        
        token1.balance = token1.balance + balance;
        object::delete(id);
    }

    public entry fun merge_entry(
        token1: &mut ConditionalToken,
        token2: ConditionalToken,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        merge(token1, token2, clock, ctx);
    }

    public fun merge_many(
        base_token: &mut ConditionalToken,
        mut tokens: vector<ConditionalToken>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let len = vector::length(&tokens);
        assert!(len > 0, EEMPTY_VECTOR);
        
        let mut i = 0;
        let mut total_merged_amount = 0;
        let mut token_ids = vector::empty();
        
        while (i < len) {
            let token = vector::remove(&mut tokens, 0);
            // Verify token matches 
            assert!(token.market_id == base_token.market_id, EWRONG_MARKET);
            assert!(token.asset_type == base_token.asset_type, EWRONG_TOKEN_TYPE);
            assert!(token.outcome == base_token.outcome, EWRONG_OUTCOME);
            
            vector::push_back(&mut token_ids, object::id(&token));
            total_merged_amount = total_merged_amount + token.balance;
            
            let ConditionalToken {
                id,
                market_id: _,
                asset_type: _,
                outcome: _,
                balance
            } = token;
            
            base_token.balance = base_token.balance + balance;
            object::delete(id);
            i = i + 1;
        };

        // Emit merge event with all token IDs
        event::emit(TokenMergeMany {
            base_token_id: object::uid_to_inner(&base_token.id),
            merged_token_ids: token_ids,
            market_id: base_token.market_id,
            asset_type: base_token.asset_type,
            outcome: base_token.outcome,
            base_amount: base_token.balance - total_merged_amount,
            merged_amount: total_merged_amount,
            owner: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock)
        });
        
        vector::destroy_empty(tokens);
    }

    public entry fun merge_many_entry(
        base_token: &mut ConditionalToken,
        tokens: vector<ConditionalToken>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        merge_many(base_token, tokens, clock, ctx);
    }

    public fun burn_complete_set(
        state: &market_state::MarketState,
        supply: &mut Supply,
        token: ConditionalToken,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // For complete sets, market should NOT be finalized
        market_state::assert_not_finalized(state);
        
        // Verify token matches supply
        assert!(token.market_id == supply.market_id, EWRONG_MARKET);
        assert!(token.asset_type == supply.asset_type, EWRONG_TOKEN_TYPE);
        assert!(token.outcome == supply.outcome, EWRONG_OUTCOME);
        
        let ConditionalToken {
            id,
            market_id,
            asset_type,
            outcome,
            balance
        } = token;
        
        // Update supply
        update_supply(supply, balance, false);
        
        // Emit event
        event::emit(TokenBurned {
            id: object::uid_to_inner(&id),  // Convert UID to ID
            market_id,
            asset_type,
            outcome,
            amount: balance,
            sender: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock)
        });
        
        // Clean up
        object::delete(id);
    }

    public fun burn(
        state: &market_state::MarketState,
        supply: &mut Supply,
        token: ConditionalToken,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Only allow burns after market is finalized
        market_state::assert_market_finalized(state);
        
        // Verify token matches supply
        assert!(token.market_id == supply.market_id, EWRONG_MARKET);
        assert!(token.asset_type == supply.asset_type, EWRONG_TOKEN_TYPE);
        assert!(token.outcome == supply.outcome, EWRONG_OUTCOME);
        
        let ConditionalToken {
            id,
            market_id,
            asset_type,
            outcome,
            balance
        } = token;
        
        // Update supply
        update_supply(supply, balance, false);
        
        // Emit event
        event::emit(TokenBurned {
            id: object::uid_to_inner(&id),  // Convert UID to ID
            market_id,
            asset_type,
            outcome,
            amount: balance,
            sender: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock)
        });
        
        // Clean up
        object::delete(id);
    }

    // ======== Getters ========

    public fun market_id(token: &ConditionalToken): ID {
        token.market_id
    }

    public fun asset_type(token: &ConditionalToken): u8 {
        token.asset_type
    }

    public fun outcome(token: &ConditionalToken): u8 {
        token.outcome
    }

    public fun value(token: &ConditionalToken): u64 {
        token.balance
    }

    public fun total_supply(supply: &Supply): u64 {
        supply.total_supply
    }
}