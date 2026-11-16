// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Credits} from "../src/Credits.sol";

/// @notice Runs against a real Pons v2 token on a Robinhood Chain fork, to check that
///         buying credits by transfer to the dead address works with Pons tokens.
///         Run with: forge test --match-contract Fork --fork-url https://rpc.mainnet.chain.robinhood.com
contract CreditsForkTest is Test {
    IERC20 constant PONS_TOKEN = IERC20(0xC15eC2E093Ca1423A8c16B4bcf0CDa6a59a06367);
    address constant CURVE = 0x9e8CdC6323A9bc1EC818E329F21536C16DAC0ec2;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function test_fork_buyWithPonsToken() public {
        if (block.chainid != 4663) return;
        address alice = makeAddr("alice");
        address agent = makeAddr("agent");
        Credits cr = new Credits(PONS_TOKEN, address(this), 1_000e18);

        vm.prank(CURVE);
        PONS_TOKEN.transfer(alice, 1_000_000e18);

        uint256 deadBefore = PONS_TOKEN.balanceOf(DEAD);
        vm.startPrank(alice);
        PONS_TOKEN.approve(address(cr), type(uint256).max);
        assertEq(cr.buy(5, 5_000e18), 5_000e18);
        assertEq(cr.buyFor(agent, 2, 2_000e18), 2_000e18);
        vm.stopPrank();

        assertEq(cr.bought(alice), 5);
        assertEq(cr.bought(agent), 2);
        assertEq(cr.totalCredits(), 7);
        assertEq(cr.totalBurned(), 7_000e18);
        assertEq(PONS_TOKEN.balanceOf(DEAD) - deadBefore, 7_000e18);
        assertEq(PONS_TOKEN.balanceOf(address(cr)), 0);

        cr.setPrice(2_000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Credits.CostAboveMax.selector, 2_000e18, 1_000e18));
        cr.buy(1, 1_000e18);
    }
}
