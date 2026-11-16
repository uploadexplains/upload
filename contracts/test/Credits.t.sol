// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Credits} from "../src/Credits.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @dev Takes 10% of every transfer, to check the totals count what arrived.
contract TaxToken is ERC20 {
    constructor() ERC20("Tax", "TAX") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = value / 10;
            super._update(from, address(0xbeef), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}

/// @dev Returns false instead of reverting, to check SafeERC20 catches it.
contract FalseToken is ERC20 {
    constructor() ERC20("False", "FALSE") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract CreditsTest is Test {
    MockToken token;
    Credits cr;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address agent = makeAddr("agent");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant PRICE = 1_000e18;

    event Bought(address indexed payer, address indexed account, uint256 credits, uint256 burned);
    event PriceSet(uint256 price);

    function setUp() public {
        token = new MockToken();
        cr = new Credits(IERC20(address(token)), owner, PRICE);
        token.transfer(alice, 400_000_000e18);
        token.transfer(bob, 400_000_000e18);
        vm.prank(alice);
        token.approve(address(cr), type(uint256).max);
        vm.prank(bob);
        token.approve(address(cr), type(uint256).max);
    }

    // ------------------------------------------------------------ setup

    function test_constructor() public view {
        assertEq(address(cr.token()), address(token));
        assertEq(cr.owner(), owner);
        assertEq(cr.price(), PRICE);
        assertEq(cr.totalCredits(), 0);
        assertEq(cr.totalBurned(), 0);
        assertEq(cr.DEAD(), DEAD);
        assertEq(cr.MAX_CREDITS_PER_BUY(), 1_000_000);
        assertEq(cr.MIN_PRICE(), 1e15);
        assertEq(cr.MAX_PRICE(), 10_000_000e18);
        assertFalse(cr.paused());
    }

    function test_constructor_emitsPriceSet() public {
        vm.expectEmit(false, false, false, true);
        emit PriceSet(PRICE);
        new Credits(IERC20(address(token)), owner, PRICE);
    }

    function test_constructor_revertsOnNonContractToken() public {
        vm.expectRevert(Credits.InvalidToken.selector);
        new Credits(IERC20(makeAddr("eoa")), owner, PRICE);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Credits(IERC20(address(token)), address(0), PRICE);
    }

    function test_constructor_revertsOnPriceBelowMin() public {
        vm.expectRevert(Credits.BadPrice.selector);
        new Credits(IERC20(address(token)), owner, 1e15 - 1);
    }

    function test_constructor_revertsOnPriceAboveMax() public {
        vm.expectRevert(Credits.BadPrice.selector);
        new Credits(IERC20(address(token)), owner, 10_000_000e18 + 1);
    }

    function test_constructor_acceptsPriceCaps() public {
        assertEq(new Credits(IERC20(address(token)), owner, 1e15).price(), 1e15);
        assertEq(new Credits(IERC20(address(token)), owner, 10_000_000e18).price(), 10_000_000e18);
    }

    // ------------------------------------------------------------ buy

    function test_buy() public {
        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 aliceBefore = token.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(cr));
        emit Bought(alice, alice, 100, 100 * PRICE);
        vm.prank(alice);
        uint256 burned = cr.buy(100, 100 * PRICE);

        assertEq(burned, 100 * PRICE);
        assertEq(cr.bought(alice), 100);
        assertEq(cr.totalCredits(), 100);
        assertEq(cr.totalBurned(), 100 * PRICE);
        assertEq(token.balanceOf(DEAD) - deadBefore, 100 * PRICE);
        assertEq(aliceBefore - token.balanceOf(alice), 100 * PRICE);
        assertEq(token.balanceOf(address(cr)), 0);
    }

    function test_buy_maxBurnAboveCostOnlyTakesCost() public {
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        uint256 burned = cr.buy(5, type(uint256).max);
        assertEq(burned, 5 * PRICE);
        assertEq(aliceBefore - token.balanceOf(alice), 5 * PRICE);
    }

    function test_buy_adds() public {
        vm.startPrank(alice);
        cr.buy(10, 10 * PRICE);
        cr.buy(15, 15 * PRICE);
        vm.stopPrank();
        assertEq(cr.bought(alice), 25);
        assertEq(cr.totalCredits(), 25);
        assertEq(cr.totalBurned(), 25 * PRICE);
    }

    function test_buy_max() public {
        vm.prank(owner);
        cr.setPrice(1e15);
        vm.prank(alice);
        cr.buy(1_000_000, 1_000_000 * 1e15);
        assertEq(cr.bought(alice), 1_000_000);
    }

    function test_buy_revertsOnZeroCredits() public {
        vm.prank(alice);
        vm.expectRevert(Credits.BadCredits.selector);
        cr.buy(0, type(uint256).max);
    }

    function test_buy_revertsAboveMaxPerBuy() public {
        vm.prank(alice);
        vm.expectRevert(Credits.BadCredits.selector);
        cr.buy(1_000_001, type(uint256).max);
    }

    function test_buy_revertsWhenCostAboveMaxBurn() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Credits.CostAboveMax.selector, 10 * PRICE, 10 * PRICE - 1));
        cr.buy(10, 10 * PRICE - 1);
    }

    function test_buy_revertsWhenPaused() public {
        vm.prank(owner);
        cr.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cr.buy(1, PRICE);
    }

    function test_buy_revertsWithoutAllowance() public {
        address carol = makeAddr("carol");
        token.transfer(carol, 10 * PRICE);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(cr), 0, PRICE));
        cr.buy(1, PRICE);
    }

    function test_buy_revertsWithoutBalance() public {
        address carol = makeAddr("carol");
        vm.prank(carol);
        token.approve(address(cr), type(uint256).max);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, carol, 0, PRICE));
        cr.buy(1, PRICE);
    }

    function test_buy_revertsWhenTokenReturnsFalse() public {
        FalseToken ft = new FalseToken();
        Credits c2 = new Credits(IERC20(address(ft)), owner, PRICE);
        vm.expectRevert();
        c2.buy(1, PRICE);
        assertEq(c2.bought(address(this)), 0);
    }

    // ------------------------------------------------------------ buyFor

    function test_buyFor() public {
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.expectEmit(true, true, false, true, address(cr));
        emit Bought(alice, agent, 40, 40 * PRICE);
        vm.prank(alice);
        uint256 burned = cr.buyFor(agent, 40, 40 * PRICE);

        assertEq(burned, 40 * PRICE);
        assertEq(cr.bought(agent), 40);
        assertEq(cr.bought(alice), 0);
        assertEq(token.balanceOf(DEAD) - deadBefore, 40 * PRICE);
        assertEq(token.balanceOf(agent), 0);
    }

    function test_buyFor_severalPayersOneAgent() public {
        vm.prank(alice);
        cr.buyFor(agent, 3, 3 * PRICE);
        vm.prank(bob);
        cr.buyFor(agent, 4, 4 * PRICE);
        assertEq(cr.bought(agent), 7);
        assertEq(cr.totalCredits(), 7);
    }

    function test_buyFor_revertsOnZeroAccount() public {
        vm.prank(alice);
        vm.expectRevert(Credits.BadAccount.selector);
        cr.buyFor(address(0), 1, PRICE);
    }

    function test_buyFor_revertsOnZeroCredits() public {
        vm.prank(alice);
        vm.expectRevert(Credits.BadCredits.selector);
        cr.buyFor(agent, 0, PRICE);
    }

    function test_buyFor_revertsAboveMaxPerBuy() public {
        vm.prank(alice);
        vm.expectRevert(Credits.BadCredits.selector);
        cr.buyFor(agent, 1_000_001, type(uint256).max);
    }

    function test_buyFor_revertsWhenCostAboveMaxBurn() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Credits.CostAboveMax.selector, 2 * PRICE, PRICE));
        cr.buyFor(agent, 2, PRICE);
    }

    function test_buyFor_revertsWhenPaused() public {
        vm.prank(owner);
        cr.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cr.buyFor(agent, 1, PRICE);
    }

    // ------------------------------------------------------------ price protection

    /// @dev The owner raises the price after a buyer signed: the buyer's maxBurn stops the purchase.
    function test_priceChangeProtection() public {
        uint256 quoted = 10 * cr.price();
        vm.prank(owner);
        cr.setPrice(PRICE * 2);
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Credits.CostAboveMax.selector, 20 * PRICE, quoted));
        cr.buy(10, quoted);
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(cr.bought(alice), 0);
    }

    /// @dev A price cut goes through and burns only the new, lower cost.
    function test_priceDropBurnsLess() public {
        uint256 quoted = 10 * cr.price();
        vm.prank(owner);
        cr.setPrice(PRICE / 2);
        vm.prank(alice);
        assertEq(cr.buy(10, quoted), 5 * PRICE);
        assertEq(cr.bought(alice), 10);
    }

    // ------------------------------------------------------------ transfer tax

    function test_taxToken_countsWhatArrived() public {
        TaxToken tax = new TaxToken();
        Credits c2 = new Credits(IERC20(address(tax)), owner, PRICE);
        tax.transfer(alice, 1_000_000e18);
        vm.prank(alice);
        tax.approve(address(c2), type(uint256).max);

        uint256 deadBefore = tax.balanceOf(DEAD);
        vm.expectEmit(true, true, false, true, address(c2));
        emit Bought(alice, alice, 10, 9 * PRICE);
        vm.prank(alice);
        uint256 burned = c2.buy(10, 10 * PRICE);

        assertEq(burned, 9 * PRICE);
        assertEq(c2.totalBurned(), 9 * PRICE);
        assertEq(tax.balanceOf(DEAD) - deadBefore, 9 * PRICE);
        assertEq(c2.bought(alice), 10);
        assertEq(c2.totalCredits(), 10);
        assertEq(tax.balanceOf(address(c2)), 0);
    }

    // ------------------------------------------------------------ owner

    function test_setPrice() public {
        vm.expectEmit(address(cr));
        emit PriceSet(5e18);
        vm.prank(owner);
        cr.setPrice(5e18);
        assertEq(cr.price(), 5e18);
    }

    function test_setPrice_caps() public {
        vm.startPrank(owner);
        cr.setPrice(1e15);
        assertEq(cr.price(), 1e15);
        cr.setPrice(10_000_000e18);
        assertEq(cr.price(), 10_000_000e18);
        vm.expectRevert(Credits.BadPrice.selector);
        cr.setPrice(1e15 - 1);
        vm.expectRevert(Credits.BadPrice.selector);
        cr.setPrice(10_000_000e18 + 1);
        vm.expectRevert(Credits.BadPrice.selector);
        cr.setPrice(0);
        vm.stopPrank();
    }

    function test_setPrice_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cr.setPrice(5e18);
    }

    function test_pauseAndUnpause() public {
        vm.prank(owner);
        cr.pause();
        assertTrue(cr.paused());
        vm.prank(owner);
        cr.unpause();
        assertFalse(cr.paused());
        vm.prank(alice);
        cr.buy(1, PRICE);
        assertEq(cr.bought(alice), 1);
    }

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cr.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        cr.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cr.unpause();
    }

    function test_pause_twiceReverts() public {
        vm.startPrank(owner);
        cr.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cr.pause();
        cr.unpause();
        vm.expectRevert(Pausable.ExpectedPause.selector);
        cr.unpause();
        vm.stopPrank();
    }

    function test_pause_setPriceStillWorks() public {
        vm.startPrank(owner);
        cr.pause();
        cr.setPrice(2e18);
        vm.stopPrank();
        assertEq(cr.price(), 2e18);
    }

    function test_ownership_twoStep() public {
        vm.prank(owner);
        cr.transferOwnership(bob);
        assertEq(cr.owner(), owner);
        assertEq(cr.pendingOwner(), bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cr.acceptOwnership();

        vm.prank(bob);
        cr.acceptOwnership();
        assertEq(cr.owner(), bob);
        assertEq(cr.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        cr.setPrice(2e18);
        vm.prank(bob);
        cr.setPrice(2e18);
        assertEq(cr.price(), 2e18);
    }

    function test_ownership_transferOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cr.transferOwnership(alice);
    }

    function test_renounce_freezesPrice() public {
        vm.prank(owner);
        cr.renounceOwnership();
        assertEq(cr.owner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        cr.setPrice(2e18);
        vm.prank(alice);
        cr.buy(1, PRICE);
        assertEq(cr.bought(alice), 1);
    }

    /// @dev The contract has nothing to withdraw: it never holds the token, even when sent some by mistake it has no way out.
    function test_neverHoldsTokens() public {
        vm.prank(alice);
        cr.buy(100, 100 * PRICE);
        vm.prank(bob);
        cr.buyFor(agent, 50, 50 * PRICE);
        assertEq(token.balanceOf(address(cr)), 0);
        assertEq(address(cr).balance, 0);
    }

    // ------------------------------------------------------------ fuzz

    function testFuzz_buy(uint256 credits, uint256 price) public {
        credits = bound(credits, 1, 1_000_000);
        price = bound(price, 1e15, 10_000_000e18);
        vm.prank(owner);
        cr.setPrice(price);
        uint256 cost = credits * price;
        deal(address(token), alice, cost);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(alice);
        uint256 burned = cr.buy(credits, cost);
        assertEq(burned, cost);
        assertEq(cr.bought(alice), credits);
        assertEq(cr.totalCredits(), credits);
        assertEq(cr.totalBurned(), cost);
        assertEq(token.balanceOf(DEAD) - deadBefore, cost);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(cr)), 0);
    }

    function testFuzz_buyFor(address account, uint256 credits) public {
        vm.assume(account != address(0));
        credits = bound(credits, 1, 100_000);
        vm.prank(alice);
        cr.buyFor(account, credits, credits * PRICE);
        assertEq(cr.bought(account), credits);
        assertEq(cr.totalCredits(), credits);
    }

    function testFuzz_maxBurnBelowCostReverts(uint256 credits, uint256 maxBurn) public {
        credits = bound(credits, 1, 1_000_000);
        maxBurn = bound(maxBurn, 0, credits * PRICE - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Credits.CostAboveMax.selector, credits * PRICE, maxBurn));
        cr.buy(credits, maxBurn);
    }

    function testFuzz_creditsAboveMaxRevert(uint256 credits) public {
        credits = bound(credits, 1_000_001, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(Credits.BadCredits.selector);
        cr.buy(credits, type(uint256).max);
    }

    function testFuzz_setPrice(uint256 price) public {
        vm.prank(owner);
        if (price < 1e15 || price > 10_000_000e18) {
            vm.expectRevert(Credits.BadPrice.selector);
            cr.setPrice(price);
            assertEq(cr.price(), PRICE);
        } else {
            cr.setPrice(price);
            assertEq(cr.price(), price);
        }
    }

    function testFuzz_onlyOwner(address who) public {
        vm.assume(who != owner);
        vm.startPrank(who);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        cr.setPrice(2e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        cr.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        cr.unpause();
        vm.stopPrank();
    }

    /// @dev Totals always equal the sum over buyers, across many buys at changing prices.
    function testFuzz_totals(uint256[8] memory amounts, uint256[8] memory prices) public {
        uint256 sumCredits;
        uint256 sumBurned;
        uint256 deadBefore = token.balanceOf(DEAD);
        for (uint256 i; i < 8; ++i) {
            uint256 p = bound(prices[i], 1e15, 1_000e18);
            uint256 n = bound(amounts[i], 1, 10_000);
            vm.prank(owner);
            cr.setPrice(p);
            address payer = i % 2 == 0 ? alice : bob;
            vm.prank(payer);
            sumBurned += cr.buyFor(i % 3 == 0 ? agent : payer, n, n * p);
            sumCredits += n;
        }
        assertEq(cr.totalCredits(), sumCredits);
        assertEq(cr.totalBurned(), sumBurned);
        assertEq(cr.bought(alice) + cr.bought(bob) + cr.bought(agent), sumCredits);
        assertEq(token.balanceOf(DEAD) - deadBefore, sumBurned);
    }

    // ------------------------------------------------------------ token set later

    function _deployedFirst() internal returns (Credits c) {
        c = new Credits(IERC20(address(0)), owner, PRICE);
        vm.prank(alice);
        token.approve(address(c), type(uint256).max);
    }

    function test_deployFirst_noTokenYet() public {
        Credits c = _deployedFirst();
        assertEq(address(c.token()), address(0));
        assertEq(c.price(), PRICE);
        assertEq(c.bought(alice), 0);
        vm.startPrank(alice);
        vm.expectRevert(Credits.TokenNotSet.selector);
        c.buy(1, PRICE);
        vm.expectRevert(Credits.TokenNotSet.selector);
        c.buyFor(agent, 1, PRICE);
        vm.stopPrank();
        // Owner admin still works.
        vm.startPrank(owner);
        c.setPrice(2 * PRICE);
        c.pause();
        c.unpause();
        vm.stopPrank();
        assertEq(c.price(), 2 * PRICE);
    }

    function test_setToken_onceThenBuyingOpens() public {
        Credits c = _deployedFirst();
        vm.expectEmit(address(c));
        emit Credits.TokenSet(address(token));
        vm.prank(owner);
        c.setToken(IERC20(address(token)));
        assertEq(address(c.token()), address(token));

        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(alice);
        c.buy(3, 3 * PRICE);
        assertEq(c.bought(alice), 3);
        assertEq(token.balanceOf(DEAD) - deadBefore, 3 * PRICE);

        MockToken other = new MockToken();
        vm.prank(owner);
        vm.expectRevert(Credits.TokenAlreadySet.selector);
        c.setToken(IERC20(address(other)));
    }

    function test_setToken_onlyOwner() public {
        Credits c = _deployedFirst();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        c.setToken(IERC20(address(token)));
    }

    function test_setToken_rejectsNonContract() public {
        Credits c = _deployedFirst();
        vm.startPrank(owner);
        vm.expectRevert(Credits.InvalidToken.selector);
        c.setToken(IERC20(address(0)));
        vm.expectRevert(Credits.InvalidToken.selector);
        c.setToken(IERC20(makeAddr("eoa")));
        vm.stopPrank();
    }

    function test_constructorToken_cannotBeReset() public {
        MockToken other = new MockToken();
        vm.prank(owner);
        vm.expectRevert(Credits.TokenAlreadySet.selector);
        cr.setToken(IERC20(address(other)));
    }
}
