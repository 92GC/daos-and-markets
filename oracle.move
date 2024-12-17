module futarchy::oracle {
    use sui::clock::{Self, Clock};
    use std::option::{Self, Option};
    use std::debug;

    
    // ======== Error Constants ========
    const ETIMESTAMP_REGRESSION: u64 = 0;
    const ETIME_WINDOW_TOO_SMALL: u64 = 1;
    const EZERO_PERIOD: u64 = 2;
    const EZERO_PRICE: u64 = 3;
    const EINVALID_CONFIG: u64 = 4;
    const EINVALID_ARITHMETIC: u64 = 5;
    const E_TWAP_NOT_FINISHED: u64 = 6;
    
    // ======== Default Constants ========
    const DEFAULT_BASIS_POINTS: u64 = 10_000;
    const DEFAULT_TWAP_START_DELAY: u64 = 2_000; // 2 seconds delay before TWAP starts
    const DEFAULT_TWAP_STEP_MAX: u64 = 1_000; // Maximum step size in basis points
    const TWAP_UPDATE_INTERVAL: u64 = 60_000; // 60 seconds in milliseconds
    
    // ======== Configuration Struct ========
    public struct OracleConfig has store, drop {
        basis_points: u64,
        twap_start_delay: u64,
        twap_step_max: u64,  // Maximum step size for TWAP calculations
        market_start_time: u64,
        twap_initialization_price: u64
    }

    public struct Oracle has store, drop {
        // Price tracking
        last_price: u64,
        last_timestamp: u64,
        
        // TWAP calculation fields - using u128 for overflow protection
        cumulative_price: u128,
        last_cumulative_update: u64,
        
        // Configuration
        config: OracleConfig
    }

    // ======== Constructor ========
    public fun new_oracle(
        twap_initialization_price: u64,
        market_start_time: u64,
        basis_points: u64,
        twap_start_delay: u64,
        twap_step_max: u64,
    ): Oracle {
        // Validate inputs
        assert!(basis_points > 0, EINVALID_CONFIG);
        assert!(twap_initialization_price > 0, EZERO_PRICE);
        
        Oracle {
            last_price: twap_initialization_price,
            last_timestamp: market_start_time,
            cumulative_price: 0,
            last_cumulative_update: market_start_time,
            config: OracleConfig {
                basis_points,
                twap_start_delay,
                twap_step_max,
                market_start_time,
                twap_initialization_price,
            }
        }
    }

    // ======== Configuration Functions ========
    public(package) fun update_config(
        oracle: &mut Oracle,
        basis_points: u64,
        twap_start_delay: u64,
        twap_step_max: u64,
        market_start_time: u64,
        twap_initialization_price: u64
    ) {
        // Validate configuration
        assert!(basis_points > 0, EINVALID_CONFIG);
        
        oracle.config = OracleConfig {
                basis_points,
                twap_start_delay,
                twap_step_max,
                market_start_time,
                twap_initialization_price
        };
    }

    // ======== Helper Functions ========
    fun cap_price_change(current_price: u64, new_price: u64, max_step: u64): u64 {
        if (new_price > current_price) {
            let max_increase = (current_price * max_step) / DEFAULT_BASIS_POINTS;
            if (new_price - current_price > max_increase) {
                current_price + max_increase
            } else {
                new_price
            }
        } else {
            let max_decrease = (current_price * max_step) / DEFAULT_BASIS_POINTS;
            if (current_price - new_price > max_decrease) {
                current_price - max_decrease
            } else {
                new_price
            }
        }
    }

    // how are we using first price here
    // ======== Core Functions ========
    public(package) fun write_observation(
        oracle: &mut Oracle,
        timestamp: u64,
        price: u64,
        _liquidity: u64
    ) {
        debug::print(&b"write_observation entry:");
        debug::print(&timestamp);
        debug::print(&price);
        
        assert!(price > 0, EZERO_PRICE);
        
        if (oracle.last_timestamp > 0) {
            assert!(
                timestamp >= oracle.last_timestamp,
                ETIMESTAMP_REGRESSION
            );
        };

        let time_elapsed = if (oracle.last_timestamp == 0) {
            0
        } else {
            timestamp - oracle.last_timestamp
        };
        
        // Fix #1: Only apply price capping if we're past market start time
        let capped_price = if (timestamp <= oracle.config.market_start_time) {
            price // Use raw price during initialization
        } else {
            let base_price = if (oracle.last_timestamp == 0) {
                oracle.config.twap_initialization_price
            } else {
                oracle.last_price
            };
            cap_price_change(base_price, price, oracle.config.twap_step_max)
        };

        // Fix #2: Update cumulative pricing only after market start
        if (time_elapsed > 0 && timestamp > oracle.config.market_start_time) {
            if (timestamp >= oracle.last_cumulative_update + TWAP_UPDATE_INTERVAL) {
                let scaled_price = (oracle.last_price as u128);  // Price is already scaled by basis points from AMM
                let price_contribution = scaled_price * (time_elapsed as u128);
                oracle.cumulative_price = oracle.cumulative_price + price_contribution;
                oracle.last_cumulative_update = timestamp;
            };
        };
        
        oracle.last_price = capped_price;
        oracle.last_timestamp = timestamp;
        
        // Fix #3: Only update last_cumulative_update if we're past market start
        if (timestamp > oracle.config.market_start_time) {
            oracle.last_cumulative_update = timestamp;
        }
    }

    // how are we using first price here, and is calling this after ended market risky???
    public(package) fun get_twap(oracle: &Oracle, clock: &Clock): u64 {
        let current_time = clock::timestamp_ms(clock);
        debug::print(&b"TWAP Calculation Debug:");
        debug::print(&b"Current time:");
        debug::print(&current_time);
        debug::print(&b"Market start time:");
        debug::print(&oracle.config.market_start_time);
        debug::print(&b"Last timestamp:");
        debug::print(&oracle.last_timestamp);
        debug::print(&b"Last price:");
        debug::print(&oracle.last_price);
        debug::print(&b"Cumulative price:");
        debug::print(&oracle.cumulative_price);
        debug::print(&b"Last cumulative update:");
        debug::print(&oracle.last_cumulative_update);
        
        // Validate TWAP requirements
        assert!(oracle.last_timestamp != 0, ETIMESTAMP_REGRESSION);
        assert!(current_time - oracle.last_timestamp >= oracle.config.twap_start_delay, E_TWAP_NOT_FINISHED);
        assert!(current_time >= oracle.config.market_start_time, ETIMESTAMP_REGRESSION);
        
        // Calculate period
        let period = current_time - oracle.config.market_start_time;
        assert!(period > 0, EZERO_PERIOD);
        
        debug::print(&b"Total period:");
        debug::print(&period);
        
        let mut total_accumulation = oracle.cumulative_price;
        debug::print(&b"Initial accumulation:");
        debug::print(&total_accumulation);
        
        // Add accumulation since last update
        let time_elapsed = current_time - oracle.last_cumulative_update;
        debug::print(&b"Time elapsed since last update:");
        debug::print(&time_elapsed);
        
        if (time_elapsed >= TWAP_UPDATE_INTERVAL) {
            let full_periods = time_elapsed / TWAP_UPDATE_INTERVAL;
            let additional_accumulation = (oracle.last_price as u128) * 
                ((full_periods * TWAP_UPDATE_INTERVAL) as u128);
            
            debug::print(&b"Additional accumulation:");
            debug::print(&additional_accumulation);
            
            assert!(additional_accumulation <= (340282366920938463463374607431768211455 - total_accumulation), 
                EINVALID_ARITHMETIC);
            total_accumulation = total_accumulation + additional_accumulation;
            
            debug::print(&b"Total accumulation after adding:");
            debug::print(&total_accumulation);
        };
        
        // Calculate and validate TWAP
        let twap = (total_accumulation * (oracle.config.basis_points as u128)) / (period as u128);
        debug::print(&b"Final TWAP value:");
        debug::print(&twap);
        
        assert!(twap <= (18446744073709551615 as u128), EINVALID_ARITHMETIC);
        
        (twap as u64)
    }


    // ======== Validation Functions ========
    public fun is_twap_valid(oracle: &Oracle, min_period: u64, clock: &Clock): bool {
        let current_time = clock::timestamp_ms(clock);
        current_time >= oracle.last_timestamp + min_period
    }

    // ======== Getters ========
    public fun get_last_price(oracle: &Oracle): u64 {
        oracle.last_price
    }

    public fun get_last_timestamp(oracle: &Oracle): u64 {
        oracle.last_timestamp
    }
    
    public fun get_basis_points(oracle: &Oracle): u64 { 
        oracle.config.basis_points 
    }

    public fun get_config(oracle: &Oracle): (u64, u64, u64) {
        (
            oracle.config.basis_points,
            oracle.config.twap_start_delay,
            oracle.config.twap_step_max
        )
    }

    public fun get_market_start_time(oracle: &Oracle): u64 {
        oracle.config.market_start_time  // Access through config
    }

    public fun get_twap_initialization_price(oracle: &Oracle): u64 {
        oracle.config.twap_initialization_price  // Access through config
    }

    #[test_only]
    public fun debug_print_state(oracle: &Oracle) {
        debug::print(&b"Oracle State:");
        debug::print(&oracle.last_price);
        debug::print(&oracle.last_timestamp);
        debug::print(&oracle.cumulative_price);
    }

    #[test_only]
    public fun debug_get_state(oracle: &Oracle): (u64, u64, u128) {
        (oracle.last_price, oracle.last_timestamp, oracle.cumulative_price)
    }

    #[test_only]
    public fun test_oracle(): Oracle {
        new_oracle(
            10000, // twap_initialization_price 
            0, // market_start_time
            10000, // basis_points 
            2000, // twap_start_delay
            1000 // twap_step_max
        )
    }
}