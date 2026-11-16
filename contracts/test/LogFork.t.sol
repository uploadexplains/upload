// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Log} from "../src/Log.sol";

/// @notice Runs against a real Pons v2 token on a Robinhood Chain fork, to check that the
///         write fee burns by transfer to the dead address with Pons tokens.
///         Run with: forge test --match-contract Fork --fork-url https://rpc.mainnet.chain.robinhood.com
contract LogForkTest is Test {
    IERC20 constant PONS_TOKEN = IERC20(0xC15eC2E093Ca1423A8c16B4bcf0CDa6a59a06367);
    address constant CURVE = 0x9e8CdC6323A9bc1EC818E329F21536C16DAC0ec2;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function test_fork_writeBurnsPonsToken() public {
        if (block.chainid != 4663) return;
        address alice = makeAddr("alice");
        address op = makeAddr("operator");
        Log lg = new Log(PONS_TOKEN, address(this), op, 1_000e18);

        vm.prank(CURVE);
        PONS_TOKEN.transfer(alice, 1_000_000e18);

        // The operator writes for free.
        vm.prank(op);
        assertEq(lg.write(1, bytes32(uint256(uint160(alice))), keccak256("call"), 0, "https://example.com/1.json"), 1);

        uint256 deadBefore = PONS_TOKEN.balanceOf(DEAD);
        vm.startPrank(alice);
        PONS_TOKEN.approve(address(lg), type(uint256).max);
        assertEq(lg.write(2, 0, keccak256("reply"), 1, "https://example.com/2.json"), 2);
        lg.write(2, 0, keccak256("reply 2"), 1, "");
        vm.stopPrank();

        assertEq(lg.totalBurned(), 2_000e18);
        assertEq(PONS_TOKEN.balanceOf(DEAD) - deadBefore, 2_000e18);
        assertEq(PONS_TOKEN.balanceOf(address(lg)), 0);
        assertEq(lg.entry(2).ref, 1);
        assertEq(lg.entries(1, 10).length, 3);
    }
}
