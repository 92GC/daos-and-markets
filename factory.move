module futarchy::factory {
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer::{Self, public_share_object, public_transfer};
    use sui::event;
    use sui::clock::{Self, Clock};
    use futarchy::dao::{Self, DAO, AdminCap};
    use sui::coin::{Self, Coin};
    use std::string::{Self, String};

    // ======== Error Constants ========
    /// Payment amount doesn't match required fee
    const EINVALID_PAYMENT: u64 = 0;
    /// Factory is paused
    const EPAUSED: u64 = 1;

    // ======== Constants ========
    const DAO_CREATION_FEE: u64 = 10_000; // 20 SUI (9 decimals) 20_000_000_000

    // ======== Core Structs ========
    public struct Factory has key, store {
        id: UID,
        dao_count: u64,
        dao_creation_fee: u64,
        sui_balance: Balance<SUI>,
        paused: bool
    }

    public struct FactoryOwnerCap has key, store {
        id: UID
    }

    // ======== Events ========
    public struct FeesWithdrawn has copy, drop {
        amount: u64,
        recipient: address,
        timestamp: u64
    }

    public struct DAOCreationFeeUpdated has copy, drop {
        old_fee: u64,
        new_fee: u64,
        admin: address,
        timestamp: u64
    }

    // ======== Constructor ========
    fun init(ctx: &mut TxContext) {
        let factory = Factory {
            id: object::new(ctx),
            dao_count: 0,
            dao_creation_fee: DAO_CREATION_FEE,
            sui_balance: balance::zero<SUI>(),
            paused: false
        };

        let owner_cap = FactoryOwnerCap {
            id: object::new(ctx)
        };

        public_share_object(factory);
        public_transfer(owner_cap, tx_context::sender(ctx));
    }

    // ======== Core Functions ========
    public entry fun create_dao<AssetType, StableType>(
        factory: &mut Factory,
        payment: Coin<SUI>,
        min_asset_amount: u64,
        min_stable_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Check factory is active
        assert!(!factory.paused, EPAUSED);

        // Verify payment
        let payment_amount = coin::value(&payment);
        assert!(payment_amount == factory.dao_creation_fee, EINVALID_PAYMENT);

        // Process payment
        let paid_balance = coin::into_balance(payment);
        balance::join(&mut factory.sui_balance, paid_balance);

        // Create DAO and AdminCap
        let (dao, admin_cap) = dao::create<AssetType, StableType>(
            min_asset_amount,
            min_stable_amount,
            clock,
            ctx
        );

        // Update state
        factory.dao_count = factory.dao_count + 1;

        // Transfer objects
        transfer::public_share_object(dao);
        transfer::public_transfer(admin_cap, tx_context::sender(ctx));
    }

    // ======== Admin Functions ========
    public entry fun withdraw_fees(
        factory: &mut Factory, 
        owner_cap: &FactoryOwnerCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let amount = balance::value(&factory.sui_balance);
        let sender = tx_context::sender(ctx);
        
        let withdrawal = coin::from_balance(
            balance::split(&mut factory.sui_balance, amount),
            ctx
        );
        
        event::emit(FeesWithdrawn {
            amount,
            recipient: sender,
            timestamp: clock::timestamp_ms(clock)
        });

        transfer::public_transfer(withdrawal, sender);
    }

    public entry fun update_dao_creation_fee(
        factory: &mut Factory,
        _cap: &FactoryOwnerCap,
        new_fee: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(new_fee >= 0);
        let old_fee = factory.dao_creation_fee;
        factory.dao_creation_fee = new_fee;

        event::emit(DAOCreationFeeUpdated {
            old_fee,
            new_fee,
            admin: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock)
        });
    }

    public entry fun toggle_pause(
        factory: &mut Factory,
        _cap: &FactoryOwnerCap
    ) {
        factory.paused = !factory.paused;
    }

    // ======== View Functions ========
    public fun get_dao_creation_fee(factory: &Factory): u64 {
        factory.dao_creation_fee
    }

    public fun get_sui_balance(factory: &Factory): u64 {
        balance::value(&factory.sui_balance)
    }

    public fun dao_count(factory: &Factory): u64 {
        factory.dao_count
    }

    public fun is_paused(factory: &Factory): bool {
        factory.paused
    }

    // ======== Test Functions ========
    #[test_only]
    public fun create_factory(ctx: &mut TxContext) {
        let factory = Factory {
            id: object::new(ctx),
            dao_count: 0,
            dao_creation_fee: DAO_CREATION_FEE,
            sui_balance: balance::zero<SUI>(),
            paused: false
        };

        let owner_cap = FactoryOwnerCap {
            id: object::new(ctx)
        };

        public_share_object(factory);
        public_transfer(owner_cap, tx_context::sender(ctx));
    }
}