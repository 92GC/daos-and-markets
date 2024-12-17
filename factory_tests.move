#[test_only]
module futarchy::factory_tests {
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_utils;
    use futarchy::factory::{Self, Factory, FactoryOwnerCap};
    use futarchy::dao::{Self, DAO, AdminCap};

    // Test constants
    const ADMIN: address = @0xA;
    const USER: address = @0xB;
    const MIN_ASSET_AMOUNT: u64 = 2_000_000;
    const MIN_STABLE_AMOUNT: u64 = 2_000_000;

    // Test coins
    public struct ASSET_COIN {}
    public struct STABLE_COIN {}

    fun setup(scenario: &mut Scenario) {
        next_tx(scenario, ADMIN); 
        {
            factory::create_factory(ctx(scenario));
        };
    }

    fun mint_sui(amount: u64, ctx: &mut TxContext): Coin<SUI> {
        coin::mint_for_testing(amount, ctx) 
    }

    #[test]
    fun test_init() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        
        next_tx(&mut scenario, ADMIN);
        {
            let factory = test::take_shared<Factory>(&scenario);
            assert!(factory::dao_count(&factory) == 0, 0);
            assert!(!factory::is_paused(&factory), 1);
            assert!(factory::get_dao_creation_fee(&factory) == 10_000, 2);
            test::return_shared(factory);
            
            assert!(test::has_most_recent_for_address<FactoryOwnerCap>(ADMIN), 3);
        };
        test::end(scenario);
    }

    #[test]
    fun test_create_dao() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        
        let clock = clock::create_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let payment = mint_sui(factory::get_dao_creation_fee(&factory), ctx(&mut scenario));

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(factory::dao_count(&factory) == 1, 0);
            test::return_shared(factory);
        };
        
        next_tx(&mut scenario, USER);
        {
            assert!(test::has_most_recent_shared<DAO>(), 1);
            assert!(test::has_most_recent_for_address<AdminCap>(USER), 2);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = factory::EINVALID_PAYMENT)]
    fun test_create_dao_invalid_payment() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        next_tx(&mut scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let payment = mint_sui(10_000_000_000, ctx(&mut scenario)); // Wrong amount

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                &clock,
                ctx(&mut scenario)
            );
            
            test::return_shared(factory);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

#[test]
fun test_withdraw_fees() {
    let mut scenario = test::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ctx(&mut scenario));
    let dao_fee = 10_000;
    
    next_tx(&mut scenario, USER);
    {
        let mut factory = test::take_shared<Factory>(&scenario);
        let payment = mint_sui(dao_fee, ctx(&mut scenario));
        factory::create_dao<ASSET_COIN, STABLE_COIN>(
            &mut factory, payment, MIN_ASSET_AMOUNT, MIN_STABLE_AMOUNT, &clock, ctx(&mut scenario)
        );
        test::return_shared(factory);
    };

    next_tx(&mut scenario, ADMIN);
    {
        let mut factory = test::take_shared<Factory>(&scenario);
        let cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);
        assert!(factory::get_sui_balance(&factory) == dao_fee, 0);
        factory::withdraw_fees(&mut factory, &cap, &clock, ctx(&mut scenario));
        test::return_shared(factory);
        test::return_to_address(ADMIN, cap);
    };
    
    next_tx(&mut scenario, ADMIN);
    {
        let coin = test::take_from_address<Coin<SUI>>(&scenario, ADMIN);
        assert!(coin::value(&coin) == dao_fee, 1);
        test::return_to_address(ADMIN, coin);
    };
    
    clock::destroy_for_testing(clock);
    test::end(scenario);
}

    #[test]
    fun test_update_dao_creation_fee() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        next_tx(&mut scenario, ADMIN);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);
            let new_fee = 30_000_000_000;
            
            factory::update_dao_creation_fee(
                &mut factory,
                &owner_cap,
                new_fee,
                &clock,
                ctx(&mut scenario)
            );
            
            assert!(factory::get_dao_creation_fee(&factory) == new_fee, 0);
            
            test::return_shared(factory);
            test::return_to_address(ADMIN, owner_cap);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_toggle_pause() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        
        next_tx(&mut scenario, ADMIN);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);
            
            assert!(!factory::is_paused(&factory), 0);
            factory::toggle_pause(&mut factory, &owner_cap);
            assert!(factory::is_paused(&factory), 1);
            
            test::return_shared(factory);
            test::return_to_address(ADMIN, owner_cap);
        };
        
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = factory::EPAUSED)]
    fun test_create_dao_when_paused() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        // Pause the factory
        next_tx(&mut scenario, ADMIN);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);
            factory::toggle_pause(&mut factory, &owner_cap);
            test::return_shared(factory);
            test::return_to_address(ADMIN, owner_cap);
        };
        
        // Try to create DAO
        next_tx(&mut scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let payment = mint_sui(factory::get_dao_creation_fee(&factory), ctx(&mut scenario));

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                &clock,
                ctx(&mut scenario)
            );
            
            test::return_shared(factory);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
}