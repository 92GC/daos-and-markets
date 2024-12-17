module futarchy::dao {
    use std::string::{String};
    use std::ascii::{String as AsciiString};
    use sui::object::{Self, ID, UID};
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::transfer;
    use std::option::{Self, Option};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use futarchy::proposal::{Self, Proposal};
    use futarchy::market_state::{Self, AdminCap as MarketAdminCap};
    use std::vector;
    use std::type_name::{Self};
    use futarchy::token_escrow;

    // ======== Error Constants ========
    const EINVALID_AMOUNT: u64 = 0;
    const EPROPOSAL_EXISTS: u64 = 1;
    const EINVALID_STATE: u64 = 2;
    const EUNAUTHORIZED: u64 = 3;
    const EINVALID_OUTCOME_COUNT: u64 = 4;
    const EPROPOSAL_NOT_FOUND: u64 = 5;
    const EINVALID_MIN_AMOUNTS: u64 = 6;
    const EALREADY_EXECUTED: u64 = 7;
    const ENOT_FINALIZED: u64 = 8;
    const EINVALID_ACTION: u64 = 9;
    const EINVALID_PAYLOAD_LENGTH: u64 = 13;
    const EINVALID_DESCRIPTION_LENGTH: u64 = 14;
    const EINVALID_RESULT: u64 = 15;
    const EINVALID_MESSAGES: u64 = 16;
    const EINVALID_FAIL_MESSAGE: u64 = 17;
    const EINVALID_ASSET_TYPE: u64 = 18;
    const EINVALID_STABLE_TYPE: u64 = 19;

    // ======== Constants ========
    const MIN_OUTCOMES: u64 = 2;
    const MAX_OUTCOMES: u64 = 10;
    const MAX_DESCRIPTION_LENGTH: u64 = 4096;
    const MAX_RESULT_LENGTH: u64 = 1024;
    const DEFAULT_TWAP_PERIOD: u64 = 3600000; // 1 hour in milliseconds
    const DEFAULT_MAX_TWAP_DEVIATION: u64 = 2000; // 20% in basis points
    
    const DEFAULT_BASIS_POINTS: u64 = 10000; // 100%
    const DEFAULT_TWAP_START_DELAY: u64 = 60_000; // 1 minute
    const DEFAULT_TWAP_STEP_MAX: u64 = 300_000; // 5 minutes

    // Action Types
    const ACTION_UPDATE_MIN_AMOUNTS: u8 = 0;
    const ACTION_SIGN_RESULT: u8 = 1;

    // ======== Structs ========
     /// The coin_type string must be in the following format:
    /// - Must NOT include "0x" prefix
    /// - Address must be padded to 32 bytes (64 characters) with leading zeros
    /// - Format: "{padded_address}::{module}::{type}"
    /// 
    /// Examples:
    /// - For SUI: "0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"
    /// - For custom coin: "a120dcbf48d1791fe6e93913bcb374c47d84f52d2edb709172e1a875a5215547::my_coin::MY_COIN"
    /// 
    /// This format must match what type_name::into_string(type_name::get<T>) would produce.
    /// If the format doesn't match, create_dao will fail with EINVALID_ASSET_TYPE or EINVALID_STABLE_TYPE.
    public struct DAO has key, store {
        id: UID,
        admin: address,
        asset_type: AsciiString,
        stable_type: AsciiString,
        min_asset_amount: u64,
        min_stable_amount: u64,
        proposals: Table<ID, ProposalInfo>,
        active_proposal_count: u64,
        total_proposals: u64,
        creation_time: u64,
        twap_period: u64,
        max_twap_deviation: u64,
        amm_basis_points: u64,
        amm_twap_start_delay: u64,
        amm_twap_step_max: u64
    }

    public struct ProposalAction has store, drop {
        action_type: u8,
        payload: vector<u8>
    }

    public struct ProposalInfo has store {
        proposer: address,
        created_at: u64,
        state: u8,
        outcome_count: u64,
        description: vector<u8>,
        market_admin_cap: Option<MarketAdminCap>,
        action: Option<ProposalAction>,
        result: Option<vector<u8>>,
        execution_time: Option<u64>,
        executed: bool,
        market_state_id: ID
    }

    public struct AdminCap has key, store {
        id: UID,
        dao_id: ID
    }

    // ======== Events ========
    public struct DAOCreated has copy, drop {
        dao_id: ID,
        admin: address,
        min_asset_amount: u64,
        min_stable_amount: u64,
        timestamp: u64,
        asset_type: AsciiString,
        stable_type: AsciiString,
    }

    public struct ProposalRegistered has copy, drop {
        dao_id: ID,
        proposal_id: ID,
        proposer: address,
        outcome_count: u64,
        initial_asset: u64,
        initial_stable: u64,
        timestamp: u64
    }

    public struct ResultSigned has copy, drop {
        dao_id: ID,
        proposal_id: ID,
        result: vector<u8>,
        winning_outcome: u64,
        timestamp: u64
    }

    public struct TWAPConfigUpdated has copy, drop {
        dao_id: ID,
        new_period: u64,
        new_max_deviation: u64,
        timestamp: u64
    }

    // ======== Creation Functions ========
    public fun create<AssetType, StableType>(
        min_asset_amount: u64,
        min_stable_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (DAO, AdminCap) {
        assert!(min_asset_amount > 0 && min_stable_amount > 0, EINVALID_MIN_AMOUNTS);
        
        let sender = tx_context::sender(ctx);
        let timestamp = clock::timestamp_ms(clock);

        let dao = DAO {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            asset_type: type_name::into_string(type_name::get<AssetType>()),
            stable_type: type_name::into_string(type_name::get<StableType>()),
            min_asset_amount,
            min_stable_amount,
            proposals: table::new(ctx),
            active_proposal_count: 0,
            total_proposals: 0,
            creation_time: timestamp,
            twap_period: DEFAULT_TWAP_PERIOD,
            max_twap_deviation: DEFAULT_MAX_TWAP_DEVIATION,
            amm_basis_points: DEFAULT_BASIS_POINTS,
            amm_twap_start_delay: DEFAULT_TWAP_START_DELAY,
            amm_twap_step_max: DEFAULT_TWAP_STEP_MAX
        };

        let admin_cap = AdminCap {
            id: object::new(ctx),
            dao_id: object::uid_to_inner(&dao.id)
        };

        event::emit(DAOCreated {
            dao_id: object::uid_to_inner(&dao.id),
            admin: sender,
            min_asset_amount,
            min_stable_amount,
            timestamp,
            asset_type: type_name::into_string(type_name::get<AssetType>()),
            stable_type: type_name::into_string(type_name::get<StableType>())
        });

        (dao, admin_cap)
    }

    // ======== Proposal Functions ========
    public fun create_proposal<AssetType, StableType>(
        dao: &mut DAO,
        outcome_count: u64,
        asset_coin: Coin<AssetType>,
        stable_coin: Coin<StableType>,
        description: vector<u8>,
        metadata: vector<u8>,
        outcome_messages: vector<vector<u8>>,
        basis_points: u64,
        twap_start_delay: u64,
        twap_step_max: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let asset_type = type_name::into_string(type_name::get<AssetType>());
        let stable_type = type_name::into_string(type_name::get<StableType>());
        
        // Direct comparison of AsciiStrings
        assert!(&asset_type == &dao.asset_type, EINVALID_ASSET_TYPE);
        assert!(&stable_type == &dao.stable_type, EINVALID_STABLE_TYPE);

        assert!(outcome_count >= MIN_OUTCOMES && outcome_count <= MAX_OUTCOMES, EINVALID_OUTCOME_COUNT);
        let asset_amount = coin::value(&asset_coin);
        let stable_amount = coin::value(&stable_coin);
        assert!(asset_amount >= dao.min_asset_amount, EINVALID_AMOUNT);
        assert!(stable_amount >= dao.min_stable_amount, EINVALID_AMOUNT);
        assert!(vector::length(&outcome_messages) == outcome_count, EINVALID_MESSAGES);  // Fixed: Added & to get reference
        
        // Assert first outcome is "Reject"
        let reject_bytes = b"Reject";
        let first_message = vector::borrow(&outcome_messages, 0);
        assert!(first_message == &reject_bytes, EINVALID_DESCRIPTION_LENGTH);
        
        validate_description(&description);
        
        // Convert coins to balances for proposal creation
        let initial_asset = coin::into_balance(asset_coin);
        let initial_stable = coin::into_balance(stable_coin);
        
        let proposal = proposal::create<AssetType, StableType>(
            object::uid_to_inner(&dao.id),
            outcome_count,
            initial_asset,
            initial_stable,
            description,
            metadata,
            outcome_messages,
            basis_points,
            twap_start_delay,
            twap_step_max,
            clock,
            ctx
        );
        
        let proposal_id = object::id(&proposal);  // Changed to use object::id directly
        let info = ProposalInfo {
            proposer: tx_context::sender(ctx),
            created_at: clock::timestamp_ms(clock),
            state: proposal::state(&proposal),
            outcome_count,
            description,
            market_admin_cap: option::none(),
            action: option::none(),
            result: option::none(),
            execution_time: option::none(),
            executed: false,
            market_state_id: proposal::market_state_id(&proposal),
        };
        
        assert!(!table::contains(&dao.proposals, proposal_id), EPROPOSAL_EXISTS);
        table::add(&mut dao.proposals, proposal_id, info);
        dao.active_proposal_count = dao.active_proposal_count + 1;
        dao.total_proposals = dao.total_proposals + 1;

        event::emit(ProposalRegistered {
            dao_id: object::uid_to_inner(&dao.id),
            proposal_id,
            proposer: tx_context::sender(ctx),
            outcome_count,
            initial_asset: asset_amount,
            initial_stable: stable_amount,
            timestamp: clock::timestamp_ms(clock)
        });

        transfer::public_transfer(proposal, tx_context::sender(ctx));
    }

    fun validate_description(description: &vector<u8>) {
        assert!(vector::length(description) <= MAX_DESCRIPTION_LENGTH, EINVALID_DESCRIPTION_LENGTH);
        assert!(vector::length(description) > 0, EINVALID_DESCRIPTION_LENGTH);
    }

    // ======== Result Signing ========
    public(package)fun sign_result(
        dao: &mut DAO,
        proposal_id: ID,
        market_state: &market_state::MarketState,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(table::contains(&dao.proposals, proposal_id), EPROPOSAL_NOT_FOUND);
        
        let info = table::borrow_mut(&mut dao.proposals, proposal_id);
        assert!(!info.executed, EALREADY_EXECUTED);
        
        assert!(object::id(market_state) == info.market_state_id, EUNAUTHORIZED);
        assert!(market_state::dao_id(market_state) == object::uid_to_inner(&dao.id), EUNAUTHORIZED);

        market_state::assert_market_finalized(market_state);

        let winning_outcome = market_state::get_winning_outcome(market_state);
        let message = market_state::get_outcome_message(market_state, winning_outcome);
        
        option::fill(&mut info.result, message);
        info.executed = true;
        info.execution_time = option::some(clock::timestamp_ms(clock));
        
        event::emit(ResultSigned {
            dao_id: object::uid_to_inner(&dao.id),
            proposal_id,
            result: message,
            winning_outcome: winning_outcome,
            timestamp: clock::timestamp_ms(clock)
        });
    }

    public entry fun sign_result_entry<AssetType, StableType>(
        dao: &mut DAO,
        proposal_id: ID,
        escrow: &mut token_escrow::TokenEscrow<AssetType, StableType>,  // Use fully qualified path
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let market_state = token_escrow::get_market_state_mut(escrow);
        sign_result(
            dao,
            proposal_id,
            market_state,
            clock,
            ctx
        );
    }

    // ======== Admin Functions ========
    fun assert_admin(dao: &DAO, cap: &AdminCap) {
        assert!(cap.dao_id == object::uid_to_inner(&dao.id), EUNAUTHORIZED);
    }

    public fun update_minimum_amounts(
        dao: &mut DAO,
        cap: &AdminCap,
        new_min_asset: u64,
        new_min_stable: u64,
    ) {
        assert_admin(dao, cap);
        assert!(new_min_asset > 0 && new_min_stable > 0, EINVALID_MIN_AMOUNTS);
        dao.min_asset_amount = new_min_asset;
        dao.min_stable_amount = new_min_stable;
    }

    public fun update_amm_config(dao: &mut DAO, cap: &AdminCap, basis_points: u64, twap_start_delay: u64, twap_step_max: u64) {
        assert_admin(dao, cap);
        dao.amm_basis_points = basis_points;
        dao.amm_twap_start_delay = twap_start_delay;
        dao.amm_twap_step_max = twap_step_max;
    }

    public fun update_twap_config(
        dao: &mut DAO,
        cap: &AdminCap,
        new_period: u64,
        new_max_deviation: u64,
        clock: &Clock
    ) {
        assert_admin(dao, cap);
        
        dao.twap_period = new_period;
        dao.max_twap_deviation = new_max_deviation;
        
        event::emit(TWAPConfigUpdated {
            dao_id: object::uid_to_inner(&dao.id),
            new_period,
            new_max_deviation,
            timestamp: clock::timestamp_ms(clock)
        });
    }

    // ======== Query Functions ========

    public fun get_twap_config(dao: &DAO): (u64, u64) {
        (dao.twap_period, dao.max_twap_deviation)
    }

    public fun get_amm_config(dao: &DAO): (u64, u64, u64) {
        (
            dao.amm_basis_points,
            dao.amm_twap_start_delay,
            dao.amm_twap_step_max
        )
    }

    public fun get_proposal_info(
        dao: &DAO,
        proposal_id: ID
    ): &ProposalInfo {
        assert!(table::contains(&dao.proposals, proposal_id), EPROPOSAL_NOT_FOUND);
        table::borrow(&dao.proposals, proposal_id)
    }

    public fun get_result(info: &ProposalInfo): &Option<vector<u8>> {
        &info.result
    }

    public fun get_stats(dao: &DAO): (u64, u64, u64) {
        (dao.active_proposal_count, dao.total_proposals, dao.creation_time)
    }

    public fun get_min_amounts(dao: &DAO): (u64, u64) {
        (dao.min_asset_amount, dao.min_stable_amount)
    }

    public fun is_executed(info: &ProposalInfo): bool {
        info.executed
    }

    public fun get_execution_time(info: &ProposalInfo): Option<u64> {
        info.execution_time
    }

    public fun get_proposer(info: &ProposalInfo): address {
        info.proposer
    }

    public fun get_created_at(info: &ProposalInfo): u64 {
        info.created_at
    }

    public fun get_description(info: &ProposalInfo): &vector<u8> {
        &info.description
    }

    /// Gets the asset type string of the DAO
    /// Returns the fully qualified type name as an AsciiString
    public fun get_asset_type(dao: &DAO): &AsciiString {
        &dao.asset_type
    }

    /// Gets the stable type string of the DAO
    /// Returns the fully qualified type name as an AsciiString
    public fun get_stable_type(dao: &DAO): &AsciiString {
        &dao.stable_type
    }

    /// Gets both asset and stable type strings of the DAO
    /// Returns a tuple of references to the type AsciiStrings
    public fun get_types(dao: &DAO): (&AsciiString, &AsciiString) {
        (&dao.asset_type, &dao.stable_type)
    }

    #[test_only]
    /// Test helper function to set proposal state directly
    public fun test_set_proposal_state(dao: &mut DAO, proposal_id: ID, state: u8) {
        let info = table::borrow_mut(&mut dao.proposals, proposal_id);
        info.state = state;
    }

}