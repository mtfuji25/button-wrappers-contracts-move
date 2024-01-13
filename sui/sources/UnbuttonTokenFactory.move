module button_token::UnbuttonTokenFactory {
    use std::string::String;
    use 0x1::UnbuttonToken;
    use sui::object::ObjectID;
    use sui::coin::Coin;
    use sui::vector::Vector;

    struct UnbuttonTokenInstance has key {
        underlying: ObjectID,
        name: String,
        symbol: String,
        initial_rate: u128,
        total_supply: u128,
    }

    struct TokenRegistry has key {
        tokens: vector<ObjectID>,
    }

    public fun create_unbutton_token(
        account: &signer,
        underlying: ObjectID,
        name: String,
        symbol: String,
        initial_rate: u128,
        initial_supply: u128,
    ): ObjectID {
        let token_id = UnbuttonToken::initialize(
            account,
            underlying,
            name,
            symbol,
            initial_rate,
            initial_supply,
        );

        add_to_registry(account, token_id);

        token_id
    }

    public fun add_to_registry(account: &signer, token_id: ObjectID) {
        let registry = borrow_global_mut<TokenRegistry>(Signer::address_of(account));
        Vector::push_back(&mut registry.tokens, token_id);
    }

    public fun init_registry(account: &signer) {
        let registry = TokenRegistry { tokens: Vector::empty() };
        move_to(account, registry);
    }

    public fun list_tokens(account: &signer): vector<ObjectID> acquires TokenRegistry {
        let registry = borrow_global<TokenRegistry>(Signer::address_of(account));
        *Vector::copy(&registry.tokens)
    }
}