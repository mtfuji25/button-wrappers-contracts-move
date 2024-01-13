/**
 * @title The ButtonToken wrapper.
 *
 * @dev The ButtonToken is a rebasing wrapper for fixed balance coins.
 *
 *      Users deposit the "underlying" (wrapped) coins and are
 *      minted button (wrapper) coins with elastic balances
 *      which change up or down when the value of the underlying coin changes.
 *
 *      For example: Manny “wraps” 1 Ether when the price of Ether is $1800.
 *      Manny receives 1800 ButtonEther coins in return.
 *      The overall value of their ButtonEther is the same as their original Ether,
 *      however each unit is now priced at exactly $1. The next day,
 *      the price of Ether changes to $1900. The ButtonEther system detects
 *      this price change, and rebases such that Manny’s balance is
 *      now 1900 ButtonEther coins, still priced at $1 each.
 *
 *      The ButtonToken math is almost identical to Ampleforth's μFragments.
 *
 *      For AMPL, internal balances are represented using `gons` and
 *          -> internal account balance     `_gonBalances[account]`
 *          -> internal supply scalar       `gonsPerFragment = TOTAL_GONS / _totalSupply`
 *          -> public balance               `_gonBalances[account] * gonsPerFragment`
 *          -> public total supply          `_totalSupply`
 *
 *      In our case internal balances are stored as 'bits'.
 *          -> underlying coin unit price  `p_u = price / 10 ^ (PRICE_DECIMALS)`
 *          -> total underlying coins      `_totalUnderlying`
 *          -> internal account balance     `_accountBits[account]`
 *          -> internal supply scalar       `_bitsPerToken`
                                            ` = TOTAL_BITS / (MAX_UNDERLYING*p_u)`
 *                                          ` = BITS_PER_UNDERLYING*(10^PRICE_DECIMALS)/price`
 *                                          ` = PRICE_BITS / price`
 *          -> user's underlying balance    `(_accountBits[account] / BITS_PER_UNDERLYING`
 *          -> public balance               `_accountBits[account] * _bitsPerToken`
 *          -> public total supply          `_totalUnderlying * p_u`
 *
 *
 */
module button_token::ButtonToken {
    use sui::coin;
    use std::string::String;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    // use Token::token;
    // use Oracle::oracle;
    // use sui::token::{Self, ActionRequest, Token};

    struct ButtonToken has drop {}

    // struct ButtonTokenAttributes {
    //     oracle: address,
    //     last_price: u256,
    //     epoch: u256,
    //     name: vector<u8>,
    //     symbol: vector<u8>,
    //     price_bits: u256,
    //     max_price: u256,
    //     account_bits: vector<(address, u256)>,
    //     allowances: vector<(address, vector<(address, u256)>)>,
    // }

    // event
    struct Approval {
        from: address,
        spender: address,
        amount: u256
    }

    struct Transfer {
        from: address,
        to: address,
        amount: u256
    }

    struct Rebase {
        epoch: u256,
        price: u256
    }

    struct Balance {
        value: u256;
    }

    // 
    struct OwnerCapability has key { id: UID }

    public const MAX_UINT256: u256 = 2 ** 256 - 1;
    public const MAX_UNDERLYING: u256 = 1_000_000_000 * 10u256.pow(18);
    public const TOTAL_BITS: u256 = MAX_UINT256 - (MAX_UINT256 % MAX_UNDERLYING);
    public const BITS_PER_UNDERLYING: u256 = TOTAL_BITS / MAX_UNDERLYING;

    // modifiers
    public fun valid_recipient(to: address) {
        assert(to != 0x0, "ButtonToken: recipient zero address");
        assert(to != address_of_sender(), "ButtonToken: recipient token address");
    }

    public fun after_rebase() acquires ButtonToken {
        let (price, valid) = query_price();
        if (valid) {
            rebase(price);
        }
    }

    /**
     * 
     */
    fun init(
        witness_: ButtonToken, 
        ctx: &mut TxContext, 
        underlying_: address, 
        decimals_: u8,
        name_: vector<u8>, 
        symbol_: vector<u8>, 
        description_: vector<u8>, 
        oracle_: address) {
        let (treasury, metadata) = coin::create_currency(
            witness_,
            decimals_, // token decimals
            symbol_, // token symbol
            name_, // token name
            description_, // token description
            option::none(),   // token icon url: empty for now
            ctx
        );

        // transfer the `TreasuryCap` to the sender, so they can mint and burn
        transfer::public_transfer(treasury, tx_context::sender(ctx));

        // metadata is typically frozen after creation
        transfer::public_freeze_object(metadata);

        // let token = ButtonToken {
        //     last_price: 0,
        //     epoch: 0,
        //     name: name_,
        //     symbol: symbol_,
        //     price_bits: 0,
        //     max_price: 0,
        //     account_bits: empty_vector(),
        //     allowances: empty_vector(),
        // };
        
        transfer::transfer(OwnerCapability {
            id: object::new(ctx),
        }, tx_context::sender(ctx));

        transfer::transfer(token, tx_context::sender(ctx));
    }

    public fun get_name(token_ref: &readable): vector<u8> {
        &move(token_ref).name
    }

    public fun get_symbol(token_ref: &readable): vector<u8> {
        &move(token_ref).symbol
    }

    public fun get_last_price(token_ref: &readable): u256 {
        &move(token_ref).last_price
    }

    public fun get_epoch(token_ref: &readable): u256 {
        &move(token_ref).epoch
    }

    public fun decimals(token_ref: &readable): u8 {
        IERC20Metadata(oracle).decimals();
    }

    public fun total_supply(token_ref: &readable): u256 {
        let (price, _) = query_price();
        bits_to_amount(active_bits(), price);
    }

    public fun balance_of(token_ref: &readable, account: address): u256 {
        if (account == 0x0) {
            return 0;
        }
        let (price, _) = query_price();
        bits_to_amount(account_bits[account], price);
    }

    public fun scaled_total_supply(token_ref: &readable): u256 {
        bits_to_uamount(active_bits());
    }

    public fun scale_balance_of(token_ref: &readable, account: address): u256 {
        if (account == 0x0) {
            return 0;
        }
        bits_to_uamount(token_ref.account_bits[account]);
    }

    public fun allowance(token_ref: &readable, owner_: address, spender: address): u256 {
        token_ref.allowances[owner_][spender];
    }

    // ButtonWrapper view methods
    public fun total_underlying(token_ref: &readable): u256 {
        bits_to_uamount(active_bits());
    }

    public fun balance_of_underlying(token_ref: &readable, who: address): u256 {
        if (who == 0x0) {
            return 0;
        }
        bits_to_uamount(token_ref.account_bits[who]);
    }

    public fun underlying_to_wrapper(token_ref: &readable, u_amount: u256): u256 {
        let (price, _) = query_price();
        bits_to_amount(u_amount_to_bits(u_amount), price);
    }

    public fun wrapper_to_underlying(token_ref: &readable, amount: u256): u256 {
        let (price, _) = query_price();
        bits_to_uamount(amount_to_bits(amount, price));
    }

    public fun transfer(from: address, to: address, amount: u256): bool {
        valid_recipient(to);
        after_rebase();
        let bits = amount_to_bits(amount, token_ref.last_price);
        transfer::transfer_from(from, to, amount)
        true
    }

    // Function to transfer all tokens
    public fun transfer_all(ctx: &mut TxContext, to: address): bool {
        valid_recipient(to);
        after_rebase();
        let bits = token_ref.account_bits[address_of_sender()];
        let amount = bits_to_amount(bits, token_ref.last_price);
        transfer(token_ref, to, amount);
        true
    }

    // Function to transfer tokens from an allowance
    public fun transfer_from(ctx: &mut TxContext, from: address, to: address, amount: u256): bool {
        valid_recipient(to);
        after_rebase();
        let allowance = token_ref.allowances[from][address_of_sender()];
        if (allowance != MAX_UINT256) {
            token_ref.allowances[from][address_of_sender()] = allowance - amount;
            event::emit(Approval{from, address_of_sender(), token_ref.allowances[from][address_of_sender()]});
        }
        let bits = amount_to_bits(amount, token_ref.last_price);
        transfer(from, to, amount);
        true
    }

    // Function to transfer all tokens from an allowance
    public fun transfer_all_from(token_ref: &mut ButtonToken, from: address, to: address): bool {
        valid_recipient(to);
        after_rebase();
        let bits = token_ref.account_bits[from];
        let amount = bits_to_amount(bits, token_ref.last_price);
        let allowance = token_ref.allowances[from][address_of_sender()];
        if (allowance != MAX_UINT256) {
            token_ref.allowances[from][address_of_sender()] = allowance - amount;
            event::emit(Approval{from, address_of_sender(), token_ref.allowances[from][address_of_sender()]});
        }
        transfer(from, to, amount);
        true
    }

    // Function to approve spending of tokens
    public fun approve(token_ref: &mut ButtonToken, spender: address, amount: u256): bool {
        token_ref.allowances[address_of_sender()][spender] = amount;
        event::emit(Approval{address_of_sender(), spender, amount});
        true
    }

    // Function to increase allowance
    public fun increase_allowance(token_ref: &mut ButtonToken, spender: address, added_amount: u256): bool {
        token_ref.allowances[address_of_sender()][spender] += added_amount;
        event::emit(Approval{address_of_sender(), spender, amount});
        true
    }

    // Function to decrease allowance
    public fun decrease_allowance(token_ref: &mut ButtonToken, spender: address, subtracted_amount: u256): bool {
        let allowance = token_ref.allowances[address_of_sender()][spender];
        if (subtracted_amount >= allowance) {
            token_ref.allowances[address_of_sender()][spender] = 0;
        } else {
            token_ref.allowances[address_of_sender()][spender] -= subtracted_amount;
        }
        event::emit(Approval{address_of_sender(), spender, token_ref.allowances[address_of_sender()][spender]});
        
        true
    }

    public fun rebase(token_ref: &mut ButtonToken) {
        return;
    }

    // ButtonWrapper write methods
    public fun mint(token_ref: &mut ButtonToken, amount: u256): u256 {
        let bits = amount_to_bits(amount, token_ref.last_price);
        let u_amount = bits_to_uamount(bits);
        Token::transfer(address_of_sender(), token_ref, amount);
        u_amount
    }

    public fun mint_for(token_ref: &mut ButtonToken, to: address, amount: u256): u256 {
        let bits = amount_to_bits(amount, token_ref.last_price);
        let u_amount = bits_to_uamount(bits);
        Token::transfer(address_of_sender(), token_ref, amount);
        u_amount
    }

    public fun burn(token_ref: &mut ButtonToken, amount: u256): u256 {
        let bits = amount_to_bits(amount, token_ref.last_price);
        let u_amount = bits_to_uamount(bits);
        withdraw(move_from(token_ref), address_of_sender(), u_amount, amount, bits);
        Token::transfer(token_ref, address_of_sender(), amount);
        u_amount
    }

    public fun burn_to(token_ref: &mut ButtonToken, to: address, amount: u256): u256 {
        let bits = amount_to_bits(amount, token_ref.last_price);
        let u_amount = bits_to_uamount(bits);
        Token::transfer(token_ref, address_of_sender(), amount);
        u_amount
    }

    public fun burn_all(token_ref: &mut ButtonToken): u256 {
        let bits = token_ref.account_bits[address_of_sender()];
        let u_amount = bits_to_uamount(bits);
        let amount = bits_to_amount(bits, token_ref.last_price);
        Token::transfer(token_ref, address_of_sender(), amount);
        u_amount
    }

    public fun burn_all_to(token_ref: &mut ButtonToken, to: address): u256 {
        let bits = token_ref.account_bits[address_of_sender()];
        let u_amount = bits_to_uamount(bits);
        let amount = bits_to_amount(bits, token_ref.last_price);
        Token::transfer(token_ref, address_of_sender(), amount);
        u_amount
    }

    public fun deposit(token_ref: &mut ButtonToken, u_amount: u256): u256 {
        let bits = u_amount_to_bits(u_amount);
        let amount = bits_to_amount(bits, token_ref.last_price);
        Token::transfer(address_of_sender(), token_ref, amount);
        amount
    }

    public fun deposit_for(token_ref: &mut ButtonToken, to: address, u_amount: u256): u256 {
        let bits = u_amount_to_bits(u_amount);
        let amount = bits_to_amount(bits, token_ref.last_price);
        Token::transfer(address_of_sender(), token_ref, amount);
        amount
    }

    public fun withdraw(token_ref: &mut ButtonToken, u_amount: u256): u256 {
        let bits = u_amount_to_bits(u_amount);
        let amount = bits_to_amount(bits, token_ref.last_price);
        withdraw(move_from(token_ref), address_of_sender(), u_amount, amount, bits);
        Token::transfer(token_ref, address_of_sender(), amount);
        amount
    }

    public fun withdraw_to(token_ref: &mut ButtonToken, to: address, u_amount: u256): u256 {
        let bits = u_amount_to_bits(u_amount);
        let amount = bits_to_amount(bits, token_ref.last_price);
        Token::transfer(token_ref, address_of_sender(), amount);
        amount
    }

    public fun withdraw_all(token_ref: &mut ButtonToken): u256 {
        let bits = token_ref.account_bits[address_of_sender()];
        let u_amount = bits_to_uamount(bits);
        let amount = bits_to_amount(bits, token_ref.last_price);
        Token::transfer(token_ref, address_of_sender(), amount);
        amount
    }

    public fun withdraw_all_to(token_ref: &mut ButtonToken, to: address): u256 {
        let bits = token_ref.account_bits[address_of_sender()];
        let u_amount = bits_to_uamount(bits);
        let amount = bits_to_amount(bits, token_ref.last_price);
        Token::transfer(token_ref, address_of_sender(), amount);
        amount
    }

    public fun deposit(
        token_ref: &mut ButtonToken,
        from: address,
        to: address,
        u_amount: u256,
        amount: u256,
        bits: u256
    ) {
        assert(u_amount > 0, 0x0); // "ButtonToken: No tokens deposited"
        assert(amount > 0, 0x1); // "ButtonToken: too few button tokens to mint"
        transfer(from, move_from(token_ref), bits, amount);
        Token::transfer(address_of_sender(), token_ref, amount);
    }

    // Function to withdraw
    public fun withdraw(
        token_ref: &mut ButtonToken,
        from: address,
        to: address,
        u_amount: u256,
        amount: u256,
        bits: u256
    ) {
        assert(amount > 0, 0x2); // "ButtonToken: too few button tokens to burn"

        transfer(move_from(token_ref), from, bits, amount);

        Token::transfer(address_of_sender(), token_ref, amount);    }

    // Function to transfer
    public fun transfer(token_ref: &mut ButtonToken, from: address, to: address, bits: u256, amount: u256) {
        token_ref.account_bits[from] -= bits;
        token_ref.account_bits[to] += bits;

        event::emit(Transfer{from, to, amount});

        if (token_ref.account_bits[from] == 0) {
            delete token_ref.account_bits[from];
        }
    }

    // Function to rebase
    public fun rebase(token_ref: &mut ButtonToken, price: u256) {
        let max_price = token_ref.max_price;
        let new_price = if (price > max_price) { max_price } else { price };

        token_ref.last_price = new_price;
        token_ref.epoch += 1;

        event::emit(Rebase{token_ref.epoch, new_price});
    }

    // Function to calculate active bits
    public fun active_bits(token_ref: &ButtonToken): u256 {
        TOTAL_BITS - token_ref.account_bits[0x1]
    }

    // Function to query price from oracle
    public fun query_price(token_ref: &ButtonToken): (u256, bool) {
        let (new_price, valid) = oracle::get_data();

        // Note: we consider newPrice == 0 to be invalid because accounting fails with price == 0
        // For example, _bitsPerToken needs to be able to divide by price so a div/0 is caused
        if (valid && new_price > 0) {
            (new_price, true)
        } else {
            (token_ref.last_price, false)
        }
    }

    // Function to convert amount to bits
    public fun amount_to_bits(amount: u256, price: u256): u256 {
        amount * bits_per_token(price)
    }

    // Function to convert u_amount to bits
    public fun u_amount_to_bits(u_amount: u256): u256 {
        u_amount * BITS_PER_UNDERLYING
    }

    // Function to convert bits to amount
    public fun bits_to_amount(bits: u256, price: u256): u256 {
        bits / bits_per_token(price)
    }

    // Function to convert bits to u_amount
    public fun bits_to_u_amount(bits: u256): u256 {
        bits / BITS_PER_UNDERLYING
    }

    // Function to calculate bits per token
    public fun bits_per_token(price: u256): u256 {
        price_bits / price
    }


    public fun max_price_from_price_decimals(price_decimals: u256): u256 {
        assert(price_decimals <= 18, 0x3); // "ButtonToken: Price Decimals must be under 18"

        if price_decimals == 18 {
            2u256 ** 113 - 1
        } else if price_decimals == 8 {
            2u256 ** 96 - 1
        } else if price_decimals == 6 {
            2u256 ** 93 - 1
        } else if price_decimals == 0 {
            2u256 ** 83 - 1
        } else if price_decimals == 1 {
            2u256 ** 84 - 1
        } else if price_decimals == 2 {
            2u256 ** 86 - 1
        } else if price_decimals == 3 {
            2u256 ** 88 - 1
        } else if price_decimals == 4 {
            2u256 ** 89 - 1
        } else if price_decimals == 5 {
            2u256 ** 91 - 1
        } else if price_decimals == 7 {
            2u256 ** 94 - 1
        } else if price_decimals == 9 {
            2u256 ** 98 - 1
        } else if price_decimals == 10 {
            2u256 ** 99 - 1
        } else if price_decimals == 11 {
            2u256 ** 101 - 1
        } else if price_decimals == 12 {
            2u256 ** 103 - 1
        } else if price_decimals == 13 {
            2u256 ** 104 - 1
        } else if price_decimals == 14 {
            2u256 ** 106 - 1
        } else if price_decimals == 15 {
            2u256 ** 108 - 1
        } else if price_decimals == 16 {
            2u256 ** 109 - 1
        } else {
            // priceDecimals == 17
            2u256 ** 111 - 1
        }
    }
}
