import 0x1::StandardToken;
import 0x2::SafeERC20;
import 0x3::IOracle;
import 0x4::OwnableUpgradeable;

module ButtonWrappers::ButtonToken {
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::fungible_asset::{Self, BurnRef, FungibleAsset, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::string_utils;
    use aptos_std::type_info;
    use std::string::{Self, String};
    use std::option;
    use std::signer;

    // Constants
    const MAX_UINT256: u256;
    const MAX_UNDERLYING: u256 = 1_000_000_000 * 10 ** 18;
    const TOTAL_BITS: u256;
    const BITS_PER_UNDERLYING: u256;

    // Attributes
    let underlying: address;
    let oracle: address;
    let lastPrice: u256;
    let _epoch: u256;
    let name: string;
    let symbol: string;
    let priceBits: u256;
    let maxPrice: u256;
    let _accountBits: map<address, u256>;
    let _allowances: map<address, map<address, u256>>;

    // Modifiers
    public(modifier) fn validRecipient(to: address) {
        assert(to != 0x0, 1);
        assert(to != move(Self).address, 2);
    }

    public(modifier) fn onAfterRebase() {
        let (price, valid) = move(Self)._queryPrice();
        if (valid) {
            move(Self)._rebase(price);
        }
        _;
    }

    // Owner only actions
    public fn initialize(underlying_: address, name_: string, symbol_: string, oracle_: address) {
        assert(underlying_ != 0x0, "ButtonToken: invalid underlying reference");
        move(OwnableUpgradeable).initialize();
        Self.underlying = underlying_;
        Self.name = name_;
        Self.symbol = symbol_;
        _accountBits[0x0] = TOTAL_BITS;
        move(Self).updateOracle(oracle_);
    }

    public fn updateOracle(oracle_: address) {
        let (price, valid) = IOracle(oracle_).getData();
        require(valid, "ButtonToken: unable to fetch data from oracle");
        let priceDecimals = IOracle(oracle_).priceDecimals();
        Self.oracle = oracle_;
        Self.priceBits = BITS_PER_UNDERLYING * (10 ** move(Self)._toU64(priceDecimals));
        Self.maxPrice = move(Self).maxPriceFromPriceDecimals(move(Self)._toU64(priceDecimals));
        Self.emitOracleUpdated(oracle_);
        move(Self)._rebase(price);
    }

    // ERC20 description attributes
    public fun decimals() {
        move(StandardToken).decimals(move(Self).underlying);
    }

    // ERC20 token view methods
    public fun totalSupply() {
        let price: u256;
        let valid: bool;
        (price, valid) = move(Self)._queryPrice();
        move(Self)._bitsToAmount(move(Self)._activeBits(), price);
    }

    public fun balanceOf(account: address) {
        if (account == 0x0) {
            0;
        } else {
            let price: u256;
            (price, ) = move(Self)._queryPrice();
            move(Self)._bitsToAmount(move(Self)._accountBits[account], price);
        }
    }

    public fun scaledTotalSupply() {
        move(Self)._bitsToUAmount(move(Self)._activeBits());
    }

    public fun scaledBalanceOf(account: address) {
        if (account == 0x0) {
            0;
        } else {
            move(Self)._bitsToUAmount(move(Self)._accountBits[account]);
        }
    }

    public fun allowance(owner: address, spender: address) {
        move(Self)._allowances[owner][spender];
    }

    // ButtonWrapper view methods
    public fun totalUnderlying() {
        move(Self)._bitsToUAmount(move(Self)._activeBits());
    }

    public fun balanceOfUnderlying(who: address) {
        if (who == 0x0) {
            0;
        } else {
            move(Self)._bitsToUAmount(move(Self)._accountBits[who]);
        }
    }

    public fun underlyingToWrapper(uAmount: u256) {
        let price: u256;
        (price, ) = move(Self)._queryPrice();
        move(Self)._bitsToAmount(move(Self)._uAmountToBits(uAmount), price);
    }

    public fun wrapperToUnderlying(amount: u256) {
        let price: u256;
        (price, ) = move(Self)._queryPrice();
        move(Self)._bitsToUAmount(move(Self)._amountToBits(amount, price));
    }

    // ERC20 write methods
    public fn transfer(to: address, amount: u256) {
        move(Self)._transfer(move(StandardToken).default_account(), to, move(Self)._amountToBits(amount, move(Self).lastPrice), amount);
    }

    public fn transferAll(to: address) {
        let bits = move(Self)._accountBits[move(StandardToken).default_account()];
        move(Self)._transfer(move(StandardToken).default_account(), to, bits, move(Self)._bitsToAmount(bits, move(Self).lastPrice));
    }

    public fn transferFrom(from: address, to: address, amount: u256) {
        if (move(Self)._allowances[from][move(StandardToken).default_account()] != MAX_UINT256) {
            move(Self)._allowances[from][move(StandardToken).default_account()] -= amount;
        }
        move(Self)._transfer(from, to, move(Self)._amountToBits(amount, move(Self).lastPrice), amount);
    }

    public fn transferAllFrom(from: address, to: address) {
        let bits = move(Self)._accountBits[from];
        let amount = move(Self)._bitsToAmount(bits, move(Self).lastPrice);
        if (move(Self)._allowances[from][move(StandardToken).default_account()] != MAX_UINT256) {
            move(Self)._allowances[from][move(StandardToken).default_account()] -= amount;
        }
        move(Self)._transfer(from, to, bits, amount);
    }

    public fn approve(spender: address, amount: u256) {
        move(Self)._allowances[move(StandardToken).default_account()][spender] = amount;
    }

    public fn increaseAllowance(spender: address, addedAmount: u256) {
        move(Self)._allowances[move(StandardToken).default_account()][spender] += addedAmount;
    }

    public fn decreaseAllowance(spender: address, subtractedAmount: u256) {
        if (subtractedAmount >= move(Self)._allowances[move(StandardToken).default_account()][spender]) {
            move(Self)._allowances[move(StandardToken).default_account()][spender] = 0;
        } else {
            move(Self)._allowances[move(StandardToken).default_account()][spender] -= subtractedAmount;
        }
    }

    // RebasingERC20 write methods
    public fn rebase() {
        return;
    }

    // ButtonWrapper write methods
    public fn mint(amount: u256) {
        let bits = move(Self)._amountToBits(amount, move(Self).lastPrice);
        let uAmount = move(Self)._bitsToUAmount(bits);
        move(Self)._deposit(move(StandardToken).default_account(), move(StandardToken).default_account(), uAmount, amount, bits);
        return uAmount;
    }

    public fn mintFor(to: address, amount: u256) {
        let bits = move(Self)._amountToBits(amount, move(Self).lastPrice);
        let uAmount = move(Self)._bitsToUAmount(bits);
        move(Self)._deposit(move(StandardToken).default_account(), to, uAmount, amount, bits);
        return uAmount;
    }

    public fn burn(amount: u256) {
        let bits = move(Self)._amountToBits(amount, move(Self).lastPrice);
        let uAmount = move(Self)._bitsToUAmount(bits);
        move(Self)._withdraw(move(StandardToken).default_account(), move(StandardToken).default_account(), uAmount, amount, bits);
        return uAmount;
    }

    public fn burnTo(to: address, amount: u256) {
        let bits = move(Self)._amountToBits(amount, move(Self).lastPrice);
        let uAmount = move(Self)._bitsToUAmount(bits);
        move(Self)._withdraw(move(StandardToken).default_account(), to, uAmount, amount, bits);
        return uAmount;
    }

    public fn burnAll() {
        let bits = move(Self)._accountBits[move(StandardToken).default_account()];
        let uAmount = move(Self)._bitsToUAmount(bits);
        let amount = move(Self)._bitsToAmount(bits, move(Self).lastPrice);
        move(Self)._withdraw(move(StandardToken).default_account(), move(StandardToken).default_account(), uAmount, amount, bits);
        return uAmount;
    }

    public fn burnAllTo(to: address) {
        let bits = move(Self)._accountBits[move(StandardToken).default_account()];
        let uAmount = move(Self)._bitsToUAmount(bits);
        let amount = move(Self)._bitsToAmount(bits, move(Self).lastPrice);
        move(Self)._withdraw(move(StandardToken).default_account(), to, uAmount, amount, bits);
        return uAmount;
    }

    public fn deposit(uAmount: u256) {
        let bits = move(Self)._uAmountToBits(uAmount);
        let amount = move(Self)._bitsToAmount(bits, move(Self).lastPrice);
        move(Self)._deposit(move(StandardToken).default_account(), move(StandardToken).default_account(), uAmount, amount, bits);
        return amount;
    }

    public fn depositFor(to: address, uAmount: u256) {
        let bits = move(Self)._uAmountToBits(uAmount);
        let amount = move(Self)._bitsToAmount(bits, move(Self).lastPrice);
        move(Self)._deposit(move(StandardToken).default_account(), to, uAmount, amount, bits);
        return amount;
    }

    public fn withdraw(uAmount: u256) {
        let bits = move(Self)._uAmountToBits(uAmount);
        let amount = move(Self)._bitsToAmount(bits, move(Self).lastPrice);
        move(Self)._withdraw(move(StandardToken).default_account(), move(StandardToken).default_account(), uAmount, amount, bits);
        return amount;
    }

    public fn withdrawTo(to: address, uAmount: u256) {
        let bits = move(Self)._uAmountToBits(uAmount);
        let amount = move(Self)._bitsToAmount(bits, move(Self).lastPrice);
        move(Self)._withdraw(move(StandardToken).default_account(), to, uAmount, amount, bits);
        return amount;
    }

    public fn withdrawAll() {
        let bits = move(Self)._accountBits[move(StandardToken).default_account()];
        let uAmount = move(Self)._bitsToUAmount(bits);
        let amount = move(Self)._bitsToAmount(bits, move(Self).lastPrice);
        move(Self)._withdraw(move(StandardToken).default_account(), move(StandardToken).default_account(), uAmount, amount, bits);
        return amount;
    }

    public fn withdrawAllTo(to: address) {
        let bits = move(Self)._accountBits[move(StandardToken).default_account()];
        let uAmount = move(Self)._bitsToUAmount(bits);
        let amount = move(Self)._bitsToAmount(bits, move(Self).lastPrice);
        move(Self)._withdraw(move(StandardToken).default_account(), to, uAmount, amount, bits);
        return amount;
    }

    // Private methods
    fun _deposit(from: address, to: address, uAmount: u256, amount: u256, bits: u256) {
        assert(uAmount > 0, "ButtonToken: No tokens deposited");
        assert(amount > 0, "ButtonToken: too few button tokens to mint");
        SafeERC20.safe_transfer_from(move(Self).underlying, from, move(Self).address, uAmount);
        move(Self)._transfer(0x0, to, bits, amount);
    }

    fun _withdraw(from: address, to: address, uAmount: u256, amount: u256, bits: u256) {
        assert(amount > 0, "ButtonToken: too few button tokens to burn");
        move(Self)._transfer(from, 0x0, bits, amount);
        SafeERC20.safe_transfer(move(Self).underlying, to, uAmount);
    }

    fun _transfer(from: address, to: address, bits: u256, amount: u256) {
        move(Self)._accountBits[from] = move(Self)._accountBits[from] - bits;
        move(Self)._accountBits[to] = move(Self)._accountBits[to] + bits;
        emit Transfer<address, address, u256>(from, to, amount);
        if (move(Self)._accountBits[from] == 0) {
            move(Self)._accountBits[from] = 0;
        }
    }

    fun _rebase(price: u256) {
        let maxPrice = move(Self).maxPrice;
        if (price > maxPrice) {
            price = maxPrice;
        }
        Self.lastPrice = price;
        Self._epoch = Self._epoch + 1;
        emit Rebase<u256, u256>(Self._epoch, price);
    }

    fun _activeBits(): u256 {
        TOTAL_BITS - move(Self)._accountBits[0x0];
    }

    fun _queryPrice(): u256 {
        let (newPrice, valid) = IOracle(get(Self).oracle).getData();
        return valid && newPrice > 0 ? newPrice : get(Self).lastPrice;
    }

    fun _amountToBits(amount: u256, price: u256): u256 {
        amount * get(Self)._bitsPerToken(price)
    }

    fun _uAmountToBits(uAmount: u256): u256 {
        uAmount * BITS_PER_UNDERLYING
    }

    fun _bitsToAmount(bits: u256, price: u256): u256 {
        bits / get(Self)._bitsPerToken(price)
    }

    fun _bitsToUAmount(bits: u256): u256 {
        bits / BITS_PER_UNDERLYING
    }

    fun _bitsPerToken(price: u256): u256 {
        get(Self).priceBits / price
    }

    public fun maxPriceFromPriceDecimals(priceDecimals: u256): u256 {
        assert(priceDecimals <= 18, "ButtonToken: Price Decimals must be under 18");

        if (priceDecimals == 18) {
            return 2 ** 113 - 1;
        }

        if (priceDecimals == 8) {
            return 2 ** 96 - 1;
        }

        if (priceDecimals == 6) {
            return 2 ** 93 - 1;
        }

        if (priceDecimals == 0) {
            return 2 ** 83 - 1;
        }

        if (priceDecimals == 1) {
            return 2 ** 84 - 1;
        }

        if (priceDecimals == 2) {
            return 2 ** 86 - 1;
        }

        if (priceDecimals == 3) {
            return 2 ** 88 - 1;
        }

        if (priceDecimals == 4) {
            return 2 ** 89 - 1;
        }

        if (priceDecimals == 5) {
            return 2 ** 91 - 1;
        }

        if (priceDecimals == 7) {
            return 2 ** 94 - 1;
        }

        if (priceDecimals == 9) {
            return 2 ** 98 - 1;
        }

        if (priceDecimals == 10) {
            return 2 ** 99 - 1;
        }

        if (priceDecimals == 11) {
            return 2 ** 101 - 1;
        }

        if (priceDecimals == 12) {
            return 2 ** 103 - 1;
        }

        if (priceDecimals == 13) {
            return 2 ** 104 - 1;
        }

        if (priceDecimals == 14) {
            return 2 ** 106 - 1;
        }

        if (priceDecimals == 15) {
            return 2 ** 108 - 1;
        }

        if (priceDecimals == 16) {
            return 2 ** 109 - 1;
        }
        // priceDecimals == 17
        return 2 ** 111 - 1;
    }
}