// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title Credits: burn the token to buy API credits
/// @notice Anyone burns the project token to buy credits for a wallet: their own, or an agent's
///         they run. The product's server reads `bought` and spends credits from a ledger it
///         keeps, one paid API call at a time. A call that fails after it was charged gets its
///         credits back, and every refund is listed in a public log on the product's site.
/// @dev The contract never holds funds. Every burn goes straight from the payer to the dead
///      address, and the totals count what actually arrived there. The owner can only pause
///      buying and set the price per credit within the hard caps below. Nobody can withdraw,
///      mint credits or edit a balance.
contract Credits is Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice Most credits one purchase can buy.
    uint256 public constant MAX_CREDITS_PER_BUY = 1_000_000;
    /// @notice Price caps, in token base units per credit: 0.001 to 10M tokens of an 18-decimal token.
    uint256 public constant MIN_PRICE = 1e15;
    uint256 public constant MAX_PRICE = 10_000_000e18;

    /// @notice The project token. Zero until the owner sets it once with `setToken`.
    IERC20 public token;
    /// @notice Token base units burned per credit.
    uint256 public price;
    /// @notice Credits bought for all wallets, ever.
    uint256 public totalCredits;
    /// @notice Tokens that arrived at the dead address through this contract.
    uint256 public totalBurned;
    /// @notice Credits bought for each wallet, ever. The server subtracts what it has spent.
    mapping(address account => uint256) public bought;

    event Bought(address indexed payer, address indexed account, uint256 credits, uint256 burned);
    event PriceSet(uint256 price);
    event TokenSet(address token);

    error BadCredits();
    error BadAccount();
    error BadPrice();
    error CostAboveMax(uint256 cost, uint256 maxBurn);
    error TokenNotSet();
    error TokenAlreadySet();
    error InvalidToken();

    /// @param token_ The project token, or zero to set it later with `setToken`.
    constructor(IERC20 token_, address owner_, uint256 price_) Ownable(owner_) {
        if (address(token_) != address(0)) _setToken(token_);
        _setPrice(price_);
    }

    // ---------------------------------------------------------------- buyers

    /// @notice Buy `credits` for yourself. `maxBurn` is the most you agree to burn, which
    ///         protects you if the owner changes the price before your transaction lands.
    function buy(uint256 credits, uint256 maxBurn) external returns (uint256 burned) {
        return _buy(msg.sender, credits, maxBurn);
    }

    /// @notice Buy `credits` for another wallet, for example the agent you run.
    function buyFor(address account, uint256 credits, uint256 maxBurn) external returns (uint256 burned) {
        return _buy(account, credits, maxBurn);
    }

    // ---------------------------------------------------------------- owner

    /// @notice Sets the project token. Works once; after that the token can never change.
    function setToken(IERC20 token_) external onlyOwner {
        _setToken(token_);
    }

    /// @notice Set the price per credit, within MIN_PRICE and MAX_PRICE.
    function setPrice(uint256 price_) external onlyOwner {
        _setPrice(price_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------- internal

    function _setToken(IERC20 token_) private {
        if (address(token) != address(0)) revert TokenAlreadySet();
        if (address(token_).code.length == 0) revert InvalidToken();
        token = token_;
        emit TokenSet(address(token_));
    }

    function _setPrice(uint256 price_) private {
        if (price_ < MIN_PRICE || price_ > MAX_PRICE) revert BadPrice();
        price = price_;
        emit PriceSet(price_);
    }

    /// @dev Sends the cost to the dead address and counts what actually arrived,
    ///      so a token with a transfer tax cannot inflate the totals.
    function _buy(address account, uint256 credits, uint256 maxBurn) private whenNotPaused returns (uint256 burned) {
        if (credits == 0 || credits > MAX_CREDITS_PER_BUY) revert BadCredits();
        if (account == address(0)) revert BadAccount();
        if (address(token) == address(0)) revert TokenNotSet();
        uint256 cost = credits * price;
        if (cost > maxBurn) revert CostAboveMax(cost, maxBurn);
        uint256 before = token.balanceOf(DEAD);
        token.safeTransferFrom(msg.sender, DEAD, cost);
        burned = token.balanceOf(DEAD) - before;
        bought[account] += credits;
        totalCredits += credits;
        totalBurned += burned;
        emit Bought(msg.sender, account, credits, burned);
    }
}
