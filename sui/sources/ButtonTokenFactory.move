module button_token::ButtonTokenFactory {
    use std::string::String;
    use sui::object::ObjectID;
    use 0x1::ButtonToken;
    use sui::vector::Vector;

    struct ButtonTokenInstance has key {
        underlying: ObjectID,
        name: String,
        symbol: String,
        oracle: ObjectID,
    }

    struct TokenRegistry has key {
        tokens: vector<ObjectID>,
    }

    public fun initialize_registry(account: &signer) {
        let registry = TokenRegistry { tokens: Vector::empty() };
        move_to(account, registry);
    }

    public fun create_button_token(
        account: &signer,
        underlying: ObjectID,
        name: String,
        symbol: String,
        oracle: ObjectID,
    ) acquires TokenRegistry {
        let button_token_instance = ButtonTokenInstance {
            underlying,
            name,
            symbol,
            oracle,
        };

        let token_id = ButtonToken::initialize(
            account,
            &button_token_instance,
        );

        let registry = borrow_global_mut<TokenRegistry>(Signer::address_of(account));
        Vector::push_back(&mut registry.tokens, token_id);

        token_id
    }

    public fun list_tokens(account: &signer): vector<ObjectID> acquires TokenRegistry {
        let registry = borrow_global<TokenRegistry>(Signer::address_of(account));
        *Vector::copy(&registry.tokens)
    }

    public fun get_token_instance(token_id: ObjectID): ButtonTokenInstance acquires ButtonTokenInstance {
        let token_instance: ButtonTokenInstance = borrow_global<ButtonTokenInstance>(token_id);
        token_instance
    }
}