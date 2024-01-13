module button_token::UnbuttonToken {
    use std::string::String;
    use sui::coin::Coin;
    use sui::object::ObjectID;
    use sui::object::Object;
    use sui::coin::transfer;
    use 0x1::Token; // Placeholder for now, this is the token to be unbuttoned, I think i need to use ButtonToken instead.

    struct UnbuttonToken has key {
        underlying: ObjectID,
        total_supply: u128,
        conversion_rate: u128,
        name: String,
        symbol: String,
    }

    public fun initialize(account: &signer, underlying: ObjectID, name: String, symbol: String, initial_supply: u128, conversion_rate: u128) {
        let unbutton_token = UnbuttonToken {
            underlying,
            total_supply: initial_supply,
            conversion_rate,
            name,
            symbol,
        };
        move_to(account, unbutton_token);
    }

    public fun deposit(account: &signer, uAmount: u128) acquires UnbuttonToken {
        let token_ref = borrow_global_mut<UnbuttonToken>(Signer::address_of(account));
        let token_amount = underlying_to_token(token_ref.conversion_rate, uAmount);

        // This will be always ButtonToken, will change later
        Token::transfer(account, token_ref.underlying, uAmount);

        // Total supply should be increased
        token_ref.total_supply += token_amount;
        
    }

    public fun withdraw(account: &signer, token_amount: u128) acquires UnbuttonToken {
        let token_ref = borrow_global_mut<UnbuttonToken>(Signer::address_of(account));
        let uAmount = token_to_underlying(token_ref.conversion_rate, token_amount);

        // Some notes:
        // Ensure the contract has enough of the underlying asset to fulfill the withdrawal
        // This check should correspond to actual balance checks or similar logic
        // to ensure that the contract can cover the withdrawal.

        // Reduce the total supply of the wrapped tokens
        token_ref.total_supply -= token_amount;

        // Transfer the underlying asset back to the user's account
        SimpleToken::transfer_to_account(account, token_ref.underlying, uAmount);
    }

    public fun underlying_to_token(conversion_rate: u128, uAmount: u128): u128 {
        uAmount * conversion_rate
    }

    public fun token_to_underlying(conversion_rate: u128, token_amount: u128): u128 {
        token_amount / conversion_rate
    }
}
