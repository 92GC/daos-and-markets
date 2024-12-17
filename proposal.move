module futarchy::proposal {
    use sui::{object::{Self, ID, UID}, clock::{Self, Clock}, tx_context::{Self, TxContext}};
    use sui::transfer;
    use std::ascii::{String as AsciiString};
    use sui::balance::{Self, Balance};
    use std::vector;
    use std::option::{Self, Option};
    use futarchy::market_state::{Self, MarketState, AdminCap, TokenManagerCap};
    use futarchy::token_escrow::{Self, TokenEscrow};
    use futarchy::conditional_token::{Self as token, Supply, ConditionalToken};
    use futarchy::amm::{Self, LiquidityPool};
    use sui::event;
    use futarchy::oracle;
    use sui::dynamic_field;
    use std::type_name::{Self};
    
    // ====== Constants ======
    const REVIEW_PERIOD_MS: u64 = 100;  // 2 seconds
    const TRADING_PERIOD_MS: u64 = 100; // 2 second
    
    // Separate minimum liquidity requirements
    const MIN_ASSET_LIQUIDITY: u64 = 500;
    const MIN_STABLE_LIQUIDITY: u64 = 500;
    
    // ====== Error Codes ======
    const EINVALID_STATE: u64 = 0;
    const EINVALID_OUTCOME: u64 = 1;
    const EUNAUTHORIZED: u64 = 2;
    const EINVALID_TIME: u64 = 3;
    const EASSET_LIQUIDITY_TOO_LOW: u64 = 4;
    const ESTABLE_LIQUIDITY_TOO_LOW: u64 = 5;
    const EPOOL_NOT_FOUND: u64 = 6;
    const EINVALID_POOL_LENGTH: u64 = 7;
    const ETWAP_VALIDATION_FAILED: u64 = 8;
    const EWRONG_MARKET: u64 = 9;
    const EWRONG_OUTCOME: u64 = 10;
    const EWRONG_TOKEN_TYPE: u64 = 11;

    // ====== Events ======
    public struct ProposalCreated has copy, drop {
        proposal_id: ID,
        dao_id: ID,
        proposer: address,
        outcome_count: u64,
        outcome_messages: vector<vector<u8>>,
        created_at: u64,
        market_state_id: ID,
        escrow_id: ID,
        admin_cap: ID,
        token_cap: ID,
        asset_value: u64,
        stable_value: u64,
        basis_points: u64,
        asset_type: AsciiString,
        stable_type: AsciiString

    }

    public struct ProposalStateChanged has copy, drop {
        proposal_id: ID,
        old_state: u8,
        new_state: u8,
        timestamp: u64
    }

    public struct TWAPHistoryEvent has copy, drop {
        proposal_id: ID,
        outcome_idx: u64,
        twap_price: u64,
        timestamp: u64
    }

    // ====== States ======
    const STATE_REVIEW: u8 = 0;
    const STATE_TRADING: u8 = 1;
    const STATE_SETTLEMENT: u8 = 2;
    const STATE_FINALIZED: u8 = 3;

    /// Core proposal object that owns AMM pools
    public struct Proposal<phantom AssetType, phantom StableType> has key, store {
        id: UID,
        created_at: u64,
        state: u8,
        outcome_count: u64,
        dao_id: ID,
        proposer: address,
        supply_ids: vector<ID>,
        amm_pools: vector<LiquidityPool>,  // Now owns the pools directly
        escrow_id: ID,
        market_state_id: ID,
        description: vector<u8>,
        metadata: vector<u8>,
        outcome_messages: vector<vector<u8>>,
        twap_prices: vector<u64>,  // Historical TWAP prices
        last_twap_update: u64,      // Last TWAP update timestamp
    }

    // ====== Creation ======
    public fun create<AssetType, StableType>(
        dao_id: ID,
        outcome_count: u64,
        initial_asset: Balance<AssetType>,
        initial_stable: Balance<StableType>,
        description: vector<u8>,
        metadata: vector<u8>,
        outcome_messages: vector<vector<u8>>,
        basis_points: u64,
        twap_start_delay: u64,
        twap_step_max: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Proposal<AssetType, StableType> {
        assert!(outcome_count > 0, EINVALID_OUTCOME);
        let asset_value = balance::value(&initial_asset);
        let stable_value = balance::value(&initial_stable);
        
        assert!(asset_value >= MIN_ASSET_LIQUIDITY, EASSET_LIQUIDITY_TOO_LOW);
        assert!(stable_value >= MIN_STABLE_LIQUIDITY, ESTABLE_LIQUIDITY_TOO_LOW);
        assert!(vector::length(&outcome_messages) == outcome_count, EINVALID_OUTCOME);
        
        let sender = tx_context::sender(ctx);
        let id = object::new(ctx);
        let proposal_id = object::uid_to_inner(&id);
        
        // Create market state with correct parameters
        let (market_state, admin_cap, token_cap) = market_state::new(
            proposal_id,  // market_id
            dao_id,       // dao_id
            outcome_count,
            sender,       // admin
            outcome_messages,
            clock,
            ctx
        );
        let market_state_id = object::id(&market_state);
        
        // Create escrow with market state
        let mut escrow = token_escrow::new<AssetType, StableType>(
            market_state,
            ctx
        );
        
        // Deposit initial liquidity
        token_escrow::deposit_asset(&mut escrow, initial_asset);
        token_escrow::deposit_stable(&mut escrow, initial_stable);
        
        let escrow_id = object::id(&escrow);
        
        // Initialize supplies and AMM pools with received parameters
        let (supply_ids, amm_pools) = create_outcome_markets(
            &mut escrow,
            &token_cap,
            outcome_count,
            asset_value / outcome_count,
            stable_value / outcome_count,
            basis_points,           // Pass through from parameters
            twap_start_delay,      // Pass through from parameters
            twap_step_max,         // Pass through from parameters
            clock::timestamp_ms(clock), // Use current time
            sender,
            clock, 
            ctx
        );

        let proposal = Proposal {
            id,
            created_at: clock::timestamp_ms(clock),
            state: STATE_REVIEW,
            outcome_count,
            dao_id,
            proposer: sender,
            supply_ids,
            amm_pools,
            escrow_id,
            market_state_id,
            description,
            metadata,
            outcome_messages,
            twap_prices: vector::empty(),
            last_twap_update: clock::timestamp_ms(clock),
        };

        event::emit(ProposalCreated {
            proposal_id,
            dao_id,
            proposer: sender,
            outcome_count,
            outcome_messages,
            created_at: proposal.created_at,
            escrow_id: escrow_id,
            market_state_id: market_state_id,
            admin_cap: object::id(&admin_cap),
            token_cap: object::id(&token_cap),
            asset_value: asset_value,
            stable_value: stable_value,
            basis_points: basis_points,
            asset_type: type_name::into_string(type_name::get<AssetType>()),
            stable_type: type_name::into_string(type_name::get<StableType>())
        });

        // Share escrow object
        transfer::public_share_object(escrow);
        // Transfer capabilities
        transfer::public_transfer(admin_cap, sender);
        transfer::public_transfer(token_cap, sender);

        proposal
    }

    // ====== AMM Operations ======
    public fun swap_asset_to_stable<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        state: &MarketState,
        cap: &TokenManagerCap,
        outcome_idx: u64,
        amount_in: u64,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): u64 {
        assert!(outcome_idx < proposal.outcome_count, EINVALID_OUTCOME);
        assert!(proposal.state == STATE_TRADING, EINVALID_STATE);
        
        let pool = get_pool_mut(&mut proposal.amm_pools, (outcome_idx as u8));
        amm::swap_asset_to_stable(pool, state, cap, amount_in, min_amount_out, clock, ctx)
    }
    
    public entry fun swap_asset_to_stable_entry<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        outcome_idx: u64,
        token_to_swap: ConditionalToken,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let amount_in = token::value(&token_to_swap);
        
        // Calculate the swap amount using AMM
        let amount_out = swap_asset_to_stable(
            proposal,
            token_escrow::get_market_state(escrow),
            token_cap,
            outcome_idx,
            amount_in,
            min_amount_out,
            clock,
            ctx
        );
        
        // Handle token swap atomically in escrow - tokens will be minted directly to sender
        token_escrow::swap_asset_to_stable_tokens(
            escrow,
            token_cap,
            token_to_swap,
            outcome_idx,
            amount_out,
            clock,
            ctx
        );
    }

    public fun swap_stable_to_asset<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        state: &MarketState,
        cap: &TokenManagerCap,
        outcome_idx: u64,
        amount_in: u64,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): u64 {
        assert!(outcome_idx < proposal.outcome_count, EINVALID_OUTCOME);
        assert!(proposal.state == STATE_TRADING, EINVALID_STATE);
        
        let pool = get_pool_mut(&mut proposal.amm_pools, (outcome_idx as u8));
        amm::swap_stable_to_asset(pool, state, cap, amount_in, min_amount_out, clock, ctx)
    }

    public entry fun swap_stable_to_asset_entry<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        outcome_idx: u64,
        token_to_swap: ConditionalToken,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let amount_in = token::value(&token_to_swap);
        
        // Calculate the swap amount using AMM
        let amount_out = swap_stable_to_asset(
            proposal,
            token_escrow::get_market_state(escrow),
            token_cap,
            outcome_idx,
            amount_in, 
            min_amount_out,
            clock,
            ctx
        );
        
        // Handle token swap atomically in escrow - tokens will be minted directly to sender
        token_escrow::swap_stable_to_asset_tokens(
            escrow,
            token_cap,
            token_to_swap,
            outcome_idx,
            amount_out,
            clock,
            ctx
        );
    }

    public fun add_liquidity<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        state: &MarketState,
        cap: &TokenManagerCap,
        outcome_idx: u64,
        asset_amount: u64,
        stable_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (u64, u64) {
        assert!(outcome_idx < proposal.outcome_count, EINVALID_OUTCOME);
        assert!(proposal.state == STATE_TRADING, EINVALID_STATE);
        
        let pool = get_pool_mut(&mut proposal.amm_pools, (outcome_idx as u8));
        amm::add_liquidity(pool, state, cap, asset_amount, stable_amount, clock, ctx)
    }

    public fun remove_liquidity<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        state: &MarketState,
        cap: &TokenManagerCap,
        outcome_idx: u64,
        percentage: u64,
        min_asset_out: u64,
        min_stable_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (u64, u64) {
        assert!(outcome_idx < proposal.outcome_count, EINVALID_OUTCOME);
        assert!(proposal.state == STATE_FINALIZED, EINVALID_STATE);
        
        let pool = get_pool_mut(&mut proposal.amm_pools, (outcome_idx as u8));
        amm::remove_liquidity(pool, state, cap, percentage, min_asset_out, min_stable_out, clock, ctx)
    }

    public entry fun add_liquidity_entry<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        outcome_idx: u64,
        asset_tokens: ConditionalToken,
        stable_tokens: ConditionalToken,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let asset_amount = token::value(&asset_tokens);
        let stable_amount = token::value(&stable_tokens);
        let market_state = token_escrow::get_market_state(escrow);

        // Calculate AMM amounts
        let (asset_used, stable_used) = add_liquidity(
            proposal,
            market_state,
            token_cap,
            outcome_idx,
            asset_amount,
            stable_amount,
            clock,
            ctx
        );

        // Handle tokens separately - pass through actual amounts used
        token_escrow::handle_add_liquidity_tokens(
            escrow,
            token_cap,
            outcome_idx,
            asset_tokens,
            stable_tokens,
            clock,
            ctx
        );
    }

    public entry fun remove_liquidity_entry<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        outcome_idx: u64,
        percentage: u64,
        min_asset_out: u64,
        min_stable_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let market_state = token_escrow::get_market_state(escrow);

        // Calculate AMM amounts
        let (asset_out, stable_out) = remove_liquidity(
            proposal,
            market_state,
            token_cap,
            outcome_idx,
            percentage,
            min_asset_out,
            min_stable_out,
            clock,
            ctx
        );

        // Handle tokens separately
        token_escrow::handle_remove_liquidity_tokens(
            escrow,
            token_cap,
            outcome_idx,
            asset_out,
            stable_out,
            clock,
            ctx
        );
    }
    // ====== State Management ======
    public fun try_advance_state<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        state: &mut MarketState,
        admin_cap: &AdminCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let elapsed = current_time - proposal.created_at;
        let old_state = proposal.state;

        if (proposal.state == STATE_REVIEW && elapsed >= REVIEW_PERIOD_MS) {
            proposal.state = STATE_TRADING;
            market_state::start_trading(state, admin_cap, TRADING_PERIOD_MS, clock, ctx);
        } else if (proposal.state == STATE_TRADING && 
                elapsed >= (REVIEW_PERIOD_MS + TRADING_PERIOD_MS)) {
            proposal.state = STATE_SETTLEMENT;
            // Get oracle from first pool for validation
            let pool = vector::borrow(&proposal.amm_pools, 0);
            market_state::end_trading(state, admin_cap, amm::get_oracle(pool), clock, ctx);
        };

        // Emit state change event if state changed
        if (old_state != proposal.state) {
            event::emit(ProposalStateChanged {
                proposal_id: object::uid_to_inner(&proposal.id),
                old_state,
                new_state: proposal.state,
                timestamp: current_time
            });
        }
    }

    public entry fun try_advance_state_entry<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        escrow: &mut token_escrow::TokenEscrow<AssetType, StableType>,
        admin_cap: &AdminCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let market_state = token_escrow::get_market_state_mut(escrow);
        try_advance_state(
            proposal,
            market_state,
            admin_cap,
            clock,
            ctx
        );
    }

    public(package) fun finalize<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        state: &mut MarketState,
        admin_cap: &AdminCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(proposal.state == STATE_SETTLEMENT, EINVALID_STATE);
        
        // Validate TWAP for all pools before finalizing
        let mut i = 0;
        while (i < vector::length(&proposal.amm_pools)) {
            let pool = vector::borrow(&proposal.amm_pools, i);
            let oracle = amm::get_oracle(pool);
            let current_price = amm::get_current_price(pool);
            i = i + 1;
        };
        
        // Record final TWAP prices and find winner
        let timestamp = clock::timestamp_ms(clock);
        proposal.twap_prices = vector::empty();
        
        let mut i = 0;
        let twap_period = market_state::get_twap_parameters(state);
        let mut highest_twap = 0;
        let mut winning_outcome = 0;
        
        while (i < vector::length(&proposal.amm_pools)) {
            let pool = vector::borrow(&proposal.amm_pools, i);
            let twap = amm::get_twap(pool, twap_period, clock);
            vector::push_back(&mut proposal.twap_prices, twap);
            
            // Track highest TWAP
            if (twap > highest_twap) {
                highest_twap = twap;
                winning_outcome = i;
            };
            
            event::emit(TWAPHistoryEvent {
                proposal_id: object::uid_to_inner(&proposal.id),
                outcome_idx: i,
                twap_price: twap,
                timestamp
            });
            
            i = i + 1;
        };
        
        proposal.last_twap_update = timestamp;
        
        market_state::finalize(state, admin_cap, winning_outcome, clock, ctx);
        let old_state = proposal.state;
        proposal.state = STATE_FINALIZED;

        event::emit(ProposalStateChanged {
            proposal_id: object::uid_to_inner(&proposal.id),
            old_state,
            new_state: proposal.state,
            timestamp
        });
    }

    public entry fun finalize_entry<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>,
        escrow: &mut TokenEscrow<AssetType, StableType>,
        admin_cap: &AdminCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let market_state = token_escrow::get_market_state_mut(escrow);
        finalize(
            proposal,
            market_state,
            admin_cap,
            clock,
            ctx
        );
    }

    // ====== Internal Helpers ======
    fun get_pool_mut(pools: &mut vector<LiquidityPool>, outcome_idx: u8): &mut LiquidityPool {
        let mut i = 0;
        let len = vector::length(pools);
        while (i < len) {
            let pool = vector::borrow_mut(pools, i);
            if (amm::get_outcome_idx(pool) == outcome_idx) {
                return pool
            };
            i = i + 1;
        };
        abort EPOOL_NOT_FOUND
    }

    fun create_outcome_markets<AssetType, StableType>(
        escrow: &mut TokenEscrow<AssetType, StableType>,
        token_cap: &TokenManagerCap,
        outcome_count: u64,
        initial_asset: u64,
        initial_stable: u64,
        basis_points: u64,
        twap_start_delay: u64,
        twap_step_max: u64,
        creation_time: u64,
        recipient: address,
        clock: &Clock,
        ctx: &mut TxContext
    ): (vector<ID>, vector<LiquidityPool>) {
        let mut supply_ids = vector::empty();
        let mut amm_pools = vector::empty();
        
        let mut i = 0;
        while (i < outcome_count) {
            let market_state = token_escrow::get_market_state(escrow);
            
            let asset_supply = token::new_supply(
                market_state,
                token_cap,
                0,
                (i as u8),
                ctx
            );
            let stable_supply = token::new_supply(
                market_state,
                token_cap,
                1,
                (i as u8),
                ctx
            );
            
            let asset_supply_id = object::id(&asset_supply);
            let stable_supply_id = object::id(&stable_supply);
            
            vector::push_back(&mut supply_ids, asset_supply_id);
            vector::push_back(&mut supply_ids, stable_supply_id);
            
            token_escrow::register_supplies(
                escrow,
                token_cap,
                i,
                asset_supply,
                stable_supply
            );

            let market_state = token_escrow::get_market_state(escrow);
            let pool = amm::new_pool(
                market_state,
                token_cap,
                (i as u8),
                initial_asset,
                initial_stable,
                basis_points,
                twap_start_delay,
                twap_step_max,
                creation_time,
                ctx
            );
            
            vector::push_back(&mut amm_pools, pool);
            
            i = i + 1;
        };

        (supply_ids, amm_pools)
    }

    // ====== Query Functions ======
    public fun is_finalized<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): bool {
        proposal.state == STATE_FINALIZED
    }

    public fun get_twap_prices<AssetType, StableType>(
        proposal: &Proposal<AssetType, StableType>
    ): &vector<u64> {
        &proposal.twap_prices
    }

    public fun get_last_twap_update<AssetType, StableType>(
        proposal: &Proposal<AssetType, StableType>
    ): u64 {
        proposal.last_twap_update
    }

    // ====== Getters ======
    public fun state<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u8 {
        proposal.state
    }

    public fun escrow_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
        proposal.escrow_id
    }

    public fun market_state_id<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): ID {
        proposal.market_state_id
    }

    public entry fun get_market_state_id_entry<AssetType, StableType>(
        proposal: &Proposal<AssetType, StableType>,
        ctx: &mut TxContext
    ): ID {
        market_state_id(proposal)
    }

    public fun outcome_count<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
        proposal.outcome_count
    }

    public fun proposer<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): address {
        proposal.proposer
    }

    public fun created_at<AssetType, StableType>(proposal: &Proposal<AssetType, StableType>): u64 {
        proposal.created_at
    }

    public fun get_description<AssetType, StableType>(
        proposal: &Proposal<AssetType, StableType>
    ): &vector<u8> {
        &proposal.description
    }

    public fun get_metadata<AssetType, StableType>(
        proposal: &Proposal<AssetType, StableType>
    ): &vector<u8> {
        &proposal.metadata
    }

    public fun get_amm_pool_ids<AssetType, StableType>(
        proposal: &Proposal<AssetType, StableType>
    ): vector<ID> {
        let mut ids = vector::empty();
        let mut i = 0;
        let len = vector::length(&proposal.amm_pools);
        while (i < len) {
            let pool = vector::borrow(&proposal.amm_pools, i);
            vector::push_back(&mut ids, amm::get_id(pool));
            i = i + 1;
        };
        ids
    }

#[test_only]
    /// Gets a mutable reference to the token escrow of the proposal
    public fun test_get_token_escrow<AssetType, StableType>(
        proposal: &mut Proposal<AssetType, StableType>
    ): &mut token_escrow::TokenEscrow<AssetType, StableType> {
        let id = escrow_id(proposal);
        dynamic_field::borrow_mut(&mut proposal.id, id)
    }

    #[test_only] 
    /// Gets the market state through the token escrow
    public fun test_get_market_state<AssetType, StableType>(
        proposal: &Proposal<AssetType, StableType>
    ): &market_state::MarketState {
        let id = escrow_id(proposal);
        let escrow: &token_escrow::TokenEscrow<AssetType, StableType> = dynamic_field::borrow(
            &proposal.id,
            id
        );
        token_escrow::get_market_state<AssetType, StableType>(escrow)
    }
}