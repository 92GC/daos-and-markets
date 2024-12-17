module futarchy::amm {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event;
    use futarchy::math;
    use futarchy::conditional_token::{Self as token, ConditionalToken, Supply};
    use futarchy::market_state::{Self, MarketState, TokenManagerCap};
    use futarchy::token_escrow::{Self, TokenEscrow};
    use futarchy::oracle::{Self, Oracle};
    use std::debug;

    // ======== Error Constants ========
    const EZERO_AMOUNT: u64 = 0;
    const EPOOL_EMPTY: u64 = 1;
    const EEXCESSIVE_SLIPPAGE: u64 = 2;
    const EOUTCOME_OUT_OF_BOUNDS: u64 = 3;
    const EINVALID_POOL: u64 = 4;
    const EMATH_OVERFLOW: u64 = 5;
    const EZERO_LIQUIDITY: u64 = 6;
    const EINVALID_K: u64 = 7;
    const EPRICE_IMPACT_TOO_HIGH: u64 = 8;
    const EINSUFFICIENT_UPDATE_TIME: u64 = 9;
    const EOBSERVATION_OVERFLOW: u64 = 10;
    const EINVALID_TIME: u64 = 11;

    // ======== Constants ========
    const FEE_SCALE: u64 = 10000;
    const DEFAULT_FEE: u64 = 30; // 0.3%
    const BASIS_POINTS: u64 = 10000;
    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MAX_PRICE_IMPACT: u64 = 1000; // 10% max price impact
    const MIN_TIME_BETWEEN_UPDATES: u64 = 1000; // 1 second minimum between updates

    // ======== TWAP Oracle Structs ========
    public struct AMMConfig has copy, drop, store {
        basis_points: u64,
        twap_start_delay: u64,
        twap_step_max: u64
    }

    // ======== Events ========
    public struct SwapEvent has copy, drop {
        market_id: ID,
        outcome: u8,
        is_buy: bool,
        amount_in: u64,
        amount_out: u64,
        price_impact: u64,
        price: u64,
        sender: address,
        timestamp: u64
    }

    public struct LiquidityEvent has copy, drop {
        market_id: ID,
        outcome: u8,
        is_add: bool,
        asset_amount: u64,
        stable_amount: u64,
        price: u64,
        sender: address,
        timestamp: u64
    }

    public struct OracleUpdateEvent has copy, drop {
        market_id: ID,
        outcome: u8,
        price: u64,
        liquidity: u64,
        timestamp: u64
    }

    // ======== Pool ========
    public struct LiquidityPool has key, store {
        id: UID,
        market_id: ID,
        outcome_idx: u8,
        asset_reserve: u64,
        stable_reserve: u64,
        k: u64,
        fee_percent: u64,
        oracle: Oracle,
    }

    // ======== Pool Creation ========
    public fun new_pool(
        state: &MarketState,
        cap: &TokenManagerCap,
        outcome_idx: u8,
        initial_asset: u64,
        initial_stable: u64,
        basis_points: u64,
        twap_start_delay: u64,
        twap_step_max: u64,
        start_time: u64,
        ctx: &mut TxContext
    ): LiquidityPool {
        assert!(initial_asset > 0 && initial_stable > 0, EZERO_AMOUNT);
        
        let k = math::mul_div(initial_asset, initial_stable, 1);
        assert!(k >= MINIMUM_LIQUIDITY, EZERO_LIQUIDITY);

        let initial_price = math::mul_div(initial_stable, BASIS_POINTS, initial_asset);

        // Initialize oracle with the first observation at market start
        let mut oracle = oracle::new_oracle(
            initial_price,
            start_time,
            basis_points,
            twap_start_delay,
            twap_step_max,
        );

        // Write initial observation at market start time
        oracle::write_observation(&mut oracle, start_time, initial_price, initial_asset + initial_stable);

        LiquidityPool {
            id: object::new(ctx),
            market_id: market_state::market_id(state),
            outcome_idx,
            asset_reserve: initial_asset,
            stable_reserve: initial_stable,
            k,
            fee_percent: DEFAULT_FEE,
            oracle,
        }
    }

    // ======== Core Swap Functions ========
    public fun swap_asset_to_stable(
        pool: &mut LiquidityPool,
        state: &MarketState,
        cap: &TokenManagerCap,
        amount_in: u64,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): u64 {
        market_state::assert_trading_active(state);
        assert!(amount_in > 0, EZERO_AMOUNT);
        
        let amount_in_with_fee = amount_in - calculate_fee(amount_in, pool.fee_percent);
        
        // Calculate output using x * y = k formula
        let amount_out = calculate_output(
            amount_in_with_fee,
            pool.asset_reserve,
            pool.stable_reserve
        );
        
        assert!(amount_out >= min_amount_out, EEXCESSIVE_SLIPPAGE);
        assert!(amount_out < pool.stable_reserve, EPOOL_EMPTY);

        let price_impact = calculate_price_impact(
            amount_in,
            pool.asset_reserve,
            amount_out,
            pool.stable_reserve
        );
        assert!(price_impact <= MAX_PRICE_IMPACT, EPRICE_IMPACT_TOO_HIGH);

        // Update reserves
        pool.asset_reserve = pool.asset_reserve + amount_in;
        pool.stable_reserve = pool.stable_reserve - amount_out;
        
        // Calculate new price after reserve update
        let timestamp = clock::timestamp_ms(clock);
        let current_price = get_current_price(pool);
        
        debug::print(&b"Swap Summary:");
        debug::print(&b"Price Before:");
        let old_price = math::mul_div(pool.asset_reserve - amount_in, BASIS_POINTS, pool.stable_reserve + amount_out);
        debug::print(&old_price);
        debug::print(&b"Price After:");
        debug::print(&current_price);
        
        write_observation(
            &mut pool.oracle,
            timestamp,
            current_price,
            pool.asset_reserve + pool.stable_reserve
        );

        event::emit(SwapEvent {
            market_id: pool.market_id,
            outcome: pool.outcome_idx,
            is_buy: false,
            amount_in,
            amount_out,
            price_impact,
            price: current_price,
            sender: tx_context::sender(ctx),
            timestamp
        });

        amount_out
    }

    public fun swap_stable_to_asset(
        pool: &mut LiquidityPool,
        state: &MarketState,
        cap: &TokenManagerCap,
        amount_in: u64,
        min_amount_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): u64 {
        market_state::assert_trading_active(state);
        assert!(amount_in > 0, EZERO_AMOUNT);
        
        let amount_in_with_fee = amount_in - calculate_fee(amount_in, pool.fee_percent);
        let amount_out = calculate_output(
            amount_in_with_fee,
            pool.stable_reserve,
            pool.asset_reserve
        );
        
        assert!(amount_out >= min_amount_out, EEXCESSIVE_SLIPPAGE);

        let price_impact = calculate_price_impact(
            amount_in,
            pool.stable_reserve,
            amount_out,
            pool.asset_reserve
        );
        assert!(price_impact <= MAX_PRICE_IMPACT, EPRICE_IMPACT_TOO_HIGH);

        // Update reserves - do this before calculating new price
        pool.stable_reserve = pool.stable_reserve + amount_in;
        pool.asset_reserve = pool.asset_reserve - amount_out;
        
        // Update K
        pool.k = math::mul_div(pool.asset_reserve, pool.stable_reserve, 1);
        
        // Calculate new price after reserve updates
        let timestamp = clock::timestamp_ms(clock);
        let current_price = get_current_price(pool);

        // Write observation with updated price
        write_observation(
            &mut pool.oracle,
            timestamp,
            current_price,
            pool.asset_reserve + pool.stable_reserve
        );

        event::emit(SwapEvent {
            market_id: pool.market_id,
            outcome: pool.outcome_idx,
            is_buy: true,
            amount_in,
            amount_out,
            price_impact,
            price: current_price,
            sender: tx_context::sender(ctx),
            timestamp
        });

        amount_out
    }

    // ======== Liquidity Functions ========
    public fun add_liquidity(
        pool: &mut LiquidityPool,
        state: &MarketState,
        cap: &TokenManagerCap,
        asset_amount: u64,
        stable_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (u64, u64) {
        // Validate trading is active
        market_state::assert_trading_active(state);
        assert!(asset_amount > 0 && stable_amount > 0, EZERO_AMOUNT);
        
        let optimal_stable = math::mul_div(
            asset_amount,
            pool.stable_reserve,
            pool.asset_reserve
        );
        
        let (asset_to_add, stable_to_add) = if (optimal_stable <= stable_amount) {
            (asset_amount, optimal_stable)
        } else {
            let optimal_asset = math::mul_div(
                stable_amount,
                pool.asset_reserve,
                pool.stable_reserve
            );
            (optimal_asset, stable_amount)
        };

        // Update reserves
        pool.asset_reserve = pool.asset_reserve + asset_to_add;
        pool.stable_reserve = pool.stable_reserve + stable_to_add;
        
        // Update K
        pool.k = math::mul_div(pool.asset_reserve, pool.stable_reserve, 1);
        
        // Update oracle
        let timestamp = clock::timestamp_ms(clock);
        let current_price = get_current_price(pool);
        write_observation(
            &mut pool.oracle,
            timestamp,
            current_price,
            pool.asset_reserve + pool.stable_reserve
        );

        // Emit event
        event::emit(LiquidityEvent {
            market_id: pool.market_id,
            outcome: pool.outcome_idx,
            is_add: true,
            asset_amount: asset_to_add,
            stable_amount: stable_to_add,
            price: current_price,
            sender: tx_context::sender(ctx),
            timestamp
        });

        (asset_to_add, stable_to_add)
    }

    public fun remove_liquidity(
        pool: &mut LiquidityPool,
        state: &MarketState,
        cap: &TokenManagerCap,
        percentage: u64,
        min_asset_out: u64,
        min_stable_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (u64, u64) {
        market_state::assert_trading_active(state);
        assert!(percentage > 0 && percentage <= FEE_SCALE, EZERO_AMOUNT);

        let asset_amount = math::mul_div(pool.asset_reserve, percentage, FEE_SCALE);
        let stable_amount = math::mul_div(pool.stable_reserve, percentage, FEE_SCALE);

        assert!(asset_amount >= min_asset_out, EEXCESSIVE_SLIPPAGE);
        assert!(stable_amount >= min_stable_out, EEXCESSIVE_SLIPPAGE);

        // Update reserves
        pool.asset_reserve = pool.asset_reserve - asset_amount;
        pool.stable_reserve = pool.stable_reserve - stable_amount;
        
        // Update K
        pool.k = math::mul_div(pool.asset_reserve, pool.stable_reserve, 1);
        
        // Update oracle
        let timestamp = clock::timestamp_ms(clock);
        let current_price = get_current_price(pool);
        write_observation(
            &mut pool.oracle,
            timestamp,
            current_price,
            pool.asset_reserve + pool.stable_reserve
        );
        

        // Emit event
        event::emit(LiquidityEvent {
            market_id: pool.market_id,
            outcome: pool.outcome_idx,
            is_add: false,
            asset_amount,
            stable_amount,
            price: current_price,
            sender: tx_context::sender(ctx),
            timestamp
        });

        (asset_amount, stable_amount)
    }

    // ======== Oracle Functions ========
    // Update new_oracle to be simpler:
    fun write_observation(
        oracle: &mut Oracle,
        timestamp: u64,
        price: u64,
        liquidity: u64
    ) {
        oracle::write_observation(oracle, timestamp, price, liquidity)
    }

    public fun get_oracle(pool: &LiquidityPool): &Oracle {
        &pool.oracle
    }

    // ======== View Functions ========
    public fun get_reserves(pool: &LiquidityPool): (u64, u64) {
        (pool.asset_reserve, pool.stable_reserve)
    }
    public fun get_price(pool: &LiquidityPool): u64 {
        oracle::get_last_price(&pool.oracle)
    }

    public fun get_twap(pool: &LiquidityPool, period: u64, clock: &Clock): u64 {
        oracle::get_twap(&pool.oracle, clock)
    }

    public fun quote_swap_asset_to_stable(
        pool: &LiquidityPool,
        amount_in: u64
    ): u64 {
        let amount_in_with_fee = amount_in - calculate_fee(amount_in, pool.fee_percent);
        calculate_output(
            amount_in_with_fee,
            pool.asset_reserve,
            pool.stable_reserve
        )
    }

    public fun quote_swap_stable_to_asset(
        pool: &LiquidityPool,
        amount_in: u64
    ): u64 {
        let amount_in_with_fee = amount_in - calculate_fee(amount_in, pool.fee_percent);
        calculate_output(
            amount_in_with_fee,
            pool.stable_reserve,
            pool.asset_reserve
        )
    }

    fun calculate_price_impact(
        amount_in: u64,
        reserve_in: u64,
        amount_out: u64,
        reserve_out: u64
    ): u64 {
        let ideal_out = math::mul_div(amount_in, reserve_out, reserve_in);
        if (ideal_out <= amount_out) {
            0
        } else {
            math::mul_div(ideal_out - amount_out, FEE_SCALE, ideal_out)
        }
    }


    // Update the LiquidityPool struct price calculation to use TWAP:
    public fun get_current_price(pool: &LiquidityPool): u64 {
        assert!(pool.asset_reserve > 0 && pool.stable_reserve > 0, EZERO_LIQUIDITY);
        
        // When selling assets TO the pool:
        // - asset_reserve increases, stable_reserve decreases
        // - So price = stable/asset should INCREASE
        // We need to invert the price calculation
        let price = math::mul_div(
        pool.stable_reserve,
        BASIS_POINTS,
        pool.asset_reserve
        );

        debug::print(&b"Price calculation:");
        debug::print(&b"Asset/Stable ratio:");
        debug::print(&price);
        
        price
    }


    // ======== Internal Functions ========
    fun calculate_fee(amount: u64, fee_percent: u64): u64 {
        math::mul_div(amount, fee_percent, FEE_SCALE)
    }

    public fun calculate_output(
        amount_in_with_fee: u64,
        reserve_in: u64,
        reserve_out: u64
    ): u64 {
        assert!(reserve_in > 0 && reserve_out > 0, EPOOL_EMPTY);
        
        // Use standard AMM formula: dx * y / (x + dx)
        let numerator = math::mul_div(amount_in_with_fee, reserve_out, 1);
        let denominator = reserve_in + amount_in_with_fee;
        
        assert!(denominator > 0, EMATH_OVERFLOW);
        math::mul_div(numerator, 1, denominator)
    }


    public fun get_outcome_idx(pool: &LiquidityPool): u8 {
        pool.outcome_idx
    }

    public fun get_id(pool: &LiquidityPool): ID {
        object::uid_to_inner(&pool.id)
    }

    // ======== Tests ========
    #[test_only]
    public fun create_test_pool(
        market_id: ID,
        outcome_idx: u8,
        asset_reserve: u64,
        stable_reserve: u64,
        ctx: &mut TxContext
    ): LiquidityPool {
        LiquidityPool {
            id: object::new(ctx),
            market_id,
            outcome_idx,
            asset_reserve,
            stable_reserve,
            k: math::mul_div(asset_reserve, stable_reserve, 1),
            fee_percent: DEFAULT_FEE,
            oracle: oracle::new_oracle(
            math::mul_div(stable_reserve, 10_0000, asset_reserve),
            0,  // market start time
            10_000,
            2_000,
            1_000,
            ),
        }
    }

    #[test_only]
    public fun destroy_for_testing(pool: LiquidityPool) {
        let LiquidityPool { 
            id,
            market_id: _,
            outcome_idx: _,
            asset_reserve: _,
            stable_reserve: _,
            k: _,
            fee_percent: _,
            oracle
        } = pool;
        object::delete(id);
    }
}