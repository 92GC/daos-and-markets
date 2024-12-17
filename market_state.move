module futarchy::market_state {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use std::vector;
    use std::option::{Self, Option};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use futarchy::oracle::{Self, Oracle};
    use std::debug;

    // ======== Error Constants ========
    const EOUTCOME_OUT_OF_BOUNDS: u64 = 0;
    const EUNAUTHORIZED: u64 = 1;
    const EALREADY_FINALIZED: u64 = 2;
    const ETRADING_ALREADY_ENDED: u64 = 3;
    const ETRADING_NOT_ENDED: u64 = 4;
    const ENOT_FINALIZED: u64 = 5;
    const ETRADING_NOT_STARTED: u64 = 6;
    const EINVALID_TIMELINE: u64 = 7;
    const EMARKET_EXPIRED: u64 = 8;

    // ========== Constants ===========
    const ETWAP_PRICE_INVALID: u64 = 16;
    const ETWAP_DEVIATION_TOO_HIGH: u64 = 17;
    const DEFAULT_TWAP_PERIOD: u64 = 1000; // 1 second in milliseconds
    const BASIS_POINTS: u64 = 10000;

    // ======== Events ========
    public struct TradingStartedEvent has copy, drop {
        market_id: ID,
        start_time: u64,
        end_time: u64
    }

    public struct TradingEndedEvent has copy, drop {
        market_id: ID,
        timestamp_ms: u64
    }

    public struct MarketFinalizedEvent has copy, drop {
        market_id: ID,
        winning_outcome: u64,
        timestamp_ms: u64
    }

    public struct AdminTransferredEvent has copy, drop {
        market_id: ID,
        old_admin: address,
        new_admin: address
    }

    public struct TWAPValidationEvent has copy, drop {
        market_id: ID,
        twap_price: u64,
        spot_price: u64,
        deviation: u64,
        timestamp: u64
    }

    // ======== State Enums ========
    public struct MarketStatus has store, copy, drop {
        created: bool,
        trading_started: bool,
        trading_ended: bool,
        finalized: bool
    }

    // ======== Core State Struct ========
    public struct MarketState has key, store {
        id: UID,
        market_id: ID,
        dao_id: ID,
        outcome_count: u64,
        admin: address,
        outcome_messages: vector<vector<u8>>,
        status: MarketStatus,
        winning_outcome: Option<u64>,
        creation_time: u64,
        trading_start: u64,
        trading_end: Option<u64>,
        finalization_time: Option<u64>,  // add comma here
        twap_period: u64,
        last_twap_price: u64
    }


    // ======== Capability Types ========
    public struct AdminCap has key, store {
        id: UID,
        market_id: ID
    }

    public struct TokenManagerCap has key, store {
        id: UID,
        market_id: ID
    }

    // ======== Creation and Initialization ========
    public(package) fun new(
        market_id: ID,
        dao_id: ID,
        outcome_count: u64,
        admin: address,
        outcome_messages: vector<vector<u8>>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (MarketState, AdminCap, TokenManagerCap) {
        let timestamp = clock::timestamp_ms(clock);
        
        let state = MarketState {
            id: object::new(ctx),
            market_id,
            dao_id,
            outcome_count,
            admin,
            outcome_messages,
            status: MarketStatus {
                created: true,
                trading_started: false,
                trading_ended: false,
                finalized: false
            },
            winning_outcome: option::none(),
            creation_time: timestamp,
            trading_start: 0,
            trading_end: option::none(),
            finalization_time: option::none(),
            twap_period: DEFAULT_TWAP_PERIOD,
            last_twap_price: 0
        };

        let admin_cap = AdminCap {
            id: object::new(ctx),
            market_id
        };

        let token_cap = TokenManagerCap {
            id: object::new(ctx),
            market_id
        };

        (state, admin_cap, token_cap)
    }

    // ======== Trading State Management ========
    public fun start_trading(
        state: &mut MarketState,
        _cap: &AdminCap,
        duration_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(!state.status.trading_started, ETRADING_ALREADY_ENDED);
        
        let start_time = clock::timestamp_ms(clock);
        let end_time = start_time + duration_ms;
        
        state.status.trading_started = true;
        state.trading_start = start_time;
        state.trading_end = option::some(end_time);
        
        event::emit(TradingStartedEvent {
            market_id: state.market_id,
            start_time,
            end_time
        });
    }

    public fun assert_trading_active(state: &MarketState) {
        assert!(state.status.trading_started, ETRADING_NOT_STARTED);
        assert!(!state.status.trading_ended, ETRADING_ALREADY_ENDED);
    }

    public fun end_trading(
        state: &mut MarketState,
        cap: &AdminCap,
        oracle_data: &Oracle,  // Changed from pool to oracle_data
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert_admin(state, cap);
        assert!(state.status.trading_started, ETRADING_NOT_STARTED);
        assert!(!state.status.trading_ended, ETRADING_ALREADY_ENDED);
        
        // Get current price from oracle
        let current_price = oracle::get_last_price(oracle_data);
        
        let timestamp = clock::timestamp_ms(clock);
        state.status.trading_ended = true;
        
        event::emit(TradingEndedEvent {
            market_id: state.market_id,
            timestamp_ms: timestamp
        });
    }

    // ======== Market Finalization ========
    public fun finalize(
        state: &mut MarketState,
        _cap: &AdminCap,
        winner: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(state.status.trading_ended, ETRADING_NOT_ENDED);
        assert!(!state.status.finalized, EALREADY_FINALIZED);
        assert!(winner < state.outcome_count, EOUTCOME_OUT_OF_BOUNDS);
        
        let timestamp = clock::timestamp_ms(clock);
        state.status.finalized = true;
        state.winning_outcome = option::some(winner);
        state.finalization_time = option::some(timestamp);
        
        event::emit(MarketFinalizedEvent {
            market_id: state.market_id,
            winning_outcome: winner,
            timestamp_ms: timestamp
        });
    }

    // Add this to market_state.move
    public fun assert_market_finalized(state: &MarketState) {
        assert!(state.status.finalized, ENOT_FINALIZED);
    }

    // Add to market_state.move
    public fun assert_not_finalized(state: &MarketState) {
        assert!(!state.status.finalized, EALREADY_FINALIZED);
    }

    // ======== Trading Capability Management ========

    // ======== Admin Management ========
    public fun transfer_admin(
        state: &mut MarketState,
        cap: &AdminCap,
        new_admin: address,
        ctx: &TxContext
    ) {
        assert_admin(state, cap);
        let old_admin = state.admin;
        state.admin = new_admin;
        
        event::emit(AdminTransferredEvent {
            market_id: state.market_id,
            old_admin,
            new_admin
        });
    }

    // ======== Validation Functions ========
    public fun assert_admin(state: &MarketState, cap: &AdminCap) {
        assert!(cap.market_id == state.market_id, EUNAUTHORIZED);
    }

    public fun assert_token_manager(state: &MarketState, cap: &TokenManagerCap) {
        assert!(cap.market_id == state.market_id, EUNAUTHORIZED);
    }

    public fun validate_outcome(state: &MarketState, outcome: u64) {
        assert!(outcome < state.outcome_count, EOUTCOME_OUT_OF_BOUNDS);
    }

    public fun update_twap_parameters(
        state: &mut MarketState,
        cap: &AdminCap,
        new_period: u64,
        new_max_deviation: u64
    ) {
        assert_admin(state, cap);
        state.twap_period = new_period;
    }



    // ======== Getter Functions ========
    public fun get_twap_parameters(state: &MarketState): (u64) {
        state.twap_period
    }

    public fun get_last_twap_price(state: &MarketState): u64 {
        state.last_twap_price
    }
    public fun market_id(state: &MarketState): ID {
        state.market_id
    }

    public fun outcome_count(state: &MarketState): u64 {
        state.outcome_count
    }

    public fun admin(state: &MarketState): address {
        state.admin
    }

    public fun is_trading_active(state: &MarketState): bool {
        state.status.trading_started && !state.status.trading_ended
    }

    public fun is_finalized(state: &MarketState): bool {
        state.status.finalized
    }

    public fun winning_outcome(state: &MarketState): u64 {
        assert!(state.status.finalized, ENOT_FINALIZED);
        *option::borrow(&state.winning_outcome)
    }

    public fun trading_end_time(state: &MarketState): u64 {
        *option::borrow(&state.trading_end)
    }

    public fun dao_id(state: &MarketState): ID {
        state.dao_id  // Changed from market_id to dao_id
    }


    public fun get_winning_outcome(state: &MarketState): u64 {
    assert!(state.status.finalized, ENOT_FINALIZED);
    *option::borrow(&state.winning_outcome)
    }

    public fun get_outcome_message(state: &MarketState, outcome_idx: u64): vector<u8> {
        assert!(outcome_idx < state.outcome_count, EOUTCOME_OUT_OF_BOUNDS);
        *vector::borrow(&state.outcome_messages, outcome_idx)
    }

    public fun get_winning_outcome_message(state: &MarketState): vector<u8> {
        assert!(state.status.finalized, ENOT_FINALIZED);
        let winning_idx = *option::borrow(&state.winning_outcome);
        *vector::borrow(&state.outcome_messages, winning_idx)
    }

    #[test_only]
    public fun create_for_testing(outcomes: u64, ctx: &mut TxContext): MarketState {
        let dummy_id = object::new(ctx);
        let market_id = object::uid_to_inner(&dummy_id);
        object::delete(dummy_id);
        
        MarketState {
            id: object::new(ctx),
            market_id,
            dao_id: market_id, // Use market_id as dao_id for testing
            outcome_messages: vector::empty(),
            outcome_count: outcomes,
            admin: tx_context::sender(ctx),
            status: MarketStatus {
                created: true,
                trading_started: false,
                trading_ended: false,
                finalized: false
            },
            winning_outcome: option::none(),
            creation_time: 0,
            trading_start: 0,
            trading_end: option::none(),
            finalization_time: option::none(),
            twap_period: DEFAULT_TWAP_PERIOD,
            last_twap_price: 0
        }
    }

    #[test_only]
    public fun create_token_manager_cap_for_testing(state: &MarketState, ctx: &mut TxContext): TokenManagerCap {
        TokenManagerCap {
            id: object::new(ctx),
            market_id: state.market_id
        }
    }

    #[test_only]
    public fun init_trading_for_testing(state: &mut MarketState) {
        state.status.trading_started = true;
        state.trading_start = 0;
        state.trading_end = option::some(9999999999999);
    }

    #[test_only]
    public fun finalize_for_testing(state: &mut MarketState) {
        state.status.trading_ended = true;
        state.status.finalized = true;
        state.winning_outcome = option::some(0);
        state.finalization_time = option::some(0);
    }

    #[test_only]
    public fun destroy_for_testing(state: MarketState, admin_cap: AdminCap, token_cap: TokenManagerCap) {
        let MarketState { id, market_id: _, outcome_count: _, admin: _, status: _, winning_outcome: _, 
            creation_time: _, trading_start: _, trading_end: _, finalization_time: _,
            dao_id: _, outcome_messages: _, 
            twap_period: _, last_twap_price: _ } = state;
        let AdminCap { id: admin_id, market_id: _ } = admin_cap;
        let TokenManagerCap { id: token_id, market_id: _ } = token_cap;
        
        object::delete(id);
        object::delete(admin_id);
        object::delete(token_id);
    }
}