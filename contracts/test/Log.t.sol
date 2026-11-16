// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Log} from "../src/Log.sol";

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

contract LogTest is Test {
    MockToken token;
    Log lg;

    address owner = makeAddr("owner");
    address op = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant FEE = 1_000e18;

    event Logged(
        uint256 indexed id,
        address indexed author,
        uint32 indexed kind,
        bytes32 subject,
        bytes32 hash,
        uint256 ref,
        string uri,
        uint256 burned
    );
    event OperatorSet(address operator);
    event FeeSet(uint256 fee);

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MockToken();
        lg = new Log(IERC20(address(token)), owner, op, FEE);
        token.transfer(alice, 100_000_000e18);
        token.transfer(bob, 100_000_000e18);
        vm.prank(alice);
        token.approve(address(lg), type(uint256).max);
        vm.prank(bob);
        token.approve(address(lg), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers

    function _opWrite(uint32 kind, uint256 ref) internal returns (uint256) {
        vm.prank(op);
        return lg.write(kind, bytes32(uint256(kind)), keccak256(abi.encode(kind, ref)), ref, "https://x.test/r.json");
    }

    function _batch(uint256 n)
        internal
        pure
        returns (uint32[] memory k, bytes32[] memory s, bytes32[] memory h, uint256[] memory r, string[] memory u)
    {
        k = new uint32[](n);
        s = new bytes32[](n);
        h = new bytes32[](n);
        r = new uint256[](n);
        u = new string[](n);
        for (uint256 i; i < n; ++i) {
            k[i] = uint32(i + 1);
            s[i] = bytes32(i + 100);
            h[i] = keccak256(abi.encode(i));
            u[i] = string.concat("https://x.test/", vm.toString(i), ".json");
        }
    }

    // ------------------------------------------------------------ constructor

    function test_constructor() public view {
        assertEq(address(lg.token()), address(token));
        assertEq(lg.owner(), owner);
        assertEq(lg.operator(), op);
        assertEq(lg.fee(), FEE);
        assertEq(lg.count(), 0);
        assertEq(lg.totalBurned(), 0);
        assertEq(lg.DEAD(), DEAD);
        assertEq(lg.MAX_URI(), 256);
        assertEq(lg.MAX_BATCH(), 50);
        assertEq(lg.MAX_PAGE(), 100);
        assertEq(lg.MAX_FEE(), 10_000_000e18);
        assertFalse(lg.paused());
    }

    function test_constructor_events() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(false, false, false, true, next);
        emit OperatorSet(op);
        vm.expectEmit(false, false, false, true, next);
        emit FeeSet(5e18);
        new Log(IERC20(address(token)), owner, op, 5e18);
    }

    function test_constructor_reverts() public {
        vm.expectRevert(Log.InvalidToken.selector);
        new Log(IERC20(makeAddr("eoa")), owner, op, 0);
        vm.expectRevert(Log.FeeTooHigh.selector);
        new Log(IERC20(address(token)), owner, op, 10_000_000e18 + 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Log(IERC20(address(token)), address(0), op, 0);
        // The cap itself and a zero operator are fine.
        Log l = new Log(IERC20(address(token)), owner, address(0), 10_000_000e18);
        assertEq(l.fee(), 10_000_000e18);
        assertEq(l.operator(), address(0));
    }

    // ------------------------------------------------------------ write: operator

    function test_write_operatorIsFree() public {
        vm.expectEmit(true, true, true, true, address(lg));
        emit Logged(1, op, 7, bytes32("subj"), bytes32("hash"), 0, "https://x.test/1.json", 0);
        vm.prank(op);
        uint256 id = lg.write(7, bytes32("subj"), bytes32("hash"), 0, "https://x.test/1.json");
        assertEq(id, 1);
        assertEq(lg.count(), 1);
        Log.Entry memory e = lg.entry(1);
        assertEq(e.author, op);
        assertEq(e.time, block.timestamp);
        assertEq(e.kind, 7);
        assertEq(e.ref, 0);
        assertEq(e.subject, bytes32("subj"));
        assertEq(e.hash, bytes32("hash"));
        assertEq(e.uri, "https://x.test/1.json");
        assertEq(lg.totalBurned(), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_write_operatorNeedsNoApprovalOrBalance() public {
        assertEq(token.balanceOf(op), 0);
        assertEq(token.allowance(op, address(lg)), 0);
        _opWrite(1, 0);
        assertEq(lg.count(), 1);
    }

    // ------------------------------------------------------------ write: fee

    function test_write_burnsFee() public {
        uint256 before = token.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(lg));
        emit Logged(1, alice, 2, bytes32(uint256(1)), bytes32(uint256(2)), 0, "", FEE);
        vm.prank(alice);
        uint256 id = lg.write(2, bytes32(uint256(1)), bytes32(uint256(2)), 0, "");
        assertEq(id, 1);
        assertEq(token.balanceOf(alice), before - FEE);
        assertEq(token.balanceOf(DEAD), FEE);
        assertEq(token.balanceOf(address(lg)), 0);
        assertEq(lg.totalBurned(), FEE);
        assertEq(lg.entry(1).author, alice);
    }

    function test_write_feeAddsUp() public {
        vm.prank(alice);
        lg.write(1, 0, 0, 0, "");
        vm.prank(bob);
        lg.write(1, 0, 0, 0, "");
        _opWrite(1, 0);
        vm.prank(alice);
        lg.write(1, 0, 0, 0, "");
        assertEq(lg.totalBurned(), 3 * FEE);
        assertEq(token.balanceOf(DEAD), 3 * FEE);
        assertEq(lg.count(), 4);
    }

    function test_write_noFeeBurnsNothing() public {
        vm.prank(owner);
        lg.setFee(0);
        address carol = makeAddr("carol"); // no tokens and no approval
        vm.expectEmit(true, true, true, true, address(lg));
        emit Logged(1, carol, 0, 0, 0, 0, "", 0);
        vm.prank(carol);
        assertEq(lg.write(0, 0, 0, 0, ""), 1);
        assertEq(lg.totalBurned(), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_write_withoutApprovalReverts() public {
        address carol = makeAddr("carol");
        token.transfer(carol, FEE);
        vm.prank(carol);
        vm.expectRevert();
        lg.write(1, 0, 0, 0, "");
        assertEq(lg.count(), 0);
    }

    function test_write_withoutBalanceReverts() public {
        address carol = makeAddr("carol");
        token.transfer(carol, FEE - 1);
        vm.startPrank(carol);
        token.approve(address(lg), type(uint256).max);
        vm.expectRevert();
        lg.write(1, 0, 0, 0, "");
        vm.stopPrank();
    }

    function test_write_ownerPaysToo() public {
        token.transfer(owner, FEE);
        vm.startPrank(owner);
        token.approve(address(lg), FEE);
        lg.write(1, 0, 0, 0, "");
        vm.stopPrank();
        assertEq(lg.totalBurned(), FEE);
    }

    function test_taxToken_countsWhatArrived() public {
        TaxToken tax = new TaxToken();
        Log t = new Log(IERC20(address(tax)), owner, op, FEE);
        tax.transfer(alice, 1_000_000e18);
        vm.prank(alice);
        tax.approve(address(t), type(uint256).max);
        vm.expectEmit(true, true, true, true, address(t));
        emit Logged(1, alice, 1, 0, 0, 0, "", 900e18);
        vm.prank(alice);
        t.write(1, 0, 0, 0, "");
        assertEq(t.totalBurned(), 900e18);
        assertEq(tax.balanceOf(DEAD), 900e18);
        assertEq(tax.balanceOf(address(t)), 0);
    }

    // ------------------------------------------------------------ write: limits

    function test_write_uriLimit() public {
        vm.startPrank(op);
        lg.write(1, 0, 0, 0, string(new bytes(256)));
        vm.expectRevert(Log.UriTooLong.selector);
        lg.write(1, 0, 0, 0, string(new bytes(257)));
        vm.stopPrank();
        assertEq(bytes(lg.entry(1).uri).length, 256);
    }

    function test_write_refBounds() public {
        vm.startPrank(op);
        // Nothing to point at yet: only 0 works.
        vm.expectRevert(Log.BadRef.selector);
        lg.write(1, 0, 0, 1, "");
        assertEq(lg.write(1, 0, 0, 0, ""), 1);
        assertEq(lg.write(2, 0, 0, 1, ""), 2);
        // Not itself, not the future.
        vm.expectRevert(Log.BadRef.selector);
        lg.write(2, 0, 0, 3, "");
        vm.expectRevert(Log.BadRef.selector);
        lg.write(2, 0, 0, type(uint256).max, "");
        assertEq(lg.write(3, 0, 0, 2, ""), 3);
        vm.stopPrank();
        assertEq(lg.entry(2).ref, 1);
        assertEq(lg.entry(3).ref, 2);
    }

    function test_write_badRefBurnsNothing() public {
        vm.prank(alice);
        vm.expectRevert(Log.BadRef.selector);
        lg.write(1, 0, 0, 5, "");
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_write_paused() public {
        vm.prank(owner);
        lg.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lg.write(1, 0, 0, 0, "");
        vm.prank(op);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lg.write(1, 0, 0, 0, "");
        vm.prank(owner);
        lg.unpause();
        vm.prank(alice);
        assertEq(lg.write(1, 0, 0, 0, ""), 1);
    }

    function test_write_timeIsBlockTime() public {
        _opWrite(1, 0);
        vm.warp(block.timestamp + 3 days);
        _opWrite(1, 1);
        assertEq(lg.entry(1).time, 1_800_000_000);
        assertEq(lg.entry(2).time, 1_800_000_000 + 3 days);
    }

    // ------------------------------------------------------------ writeMany

    function test_writeMany() public {
        _opWrite(9, 0);
        (uint32[] memory k, bytes32[] memory s, bytes32[] memory h, uint256[] memory r, string[] memory u) = _batch(3);
        r[0] = 1; // an earlier entry
        r[2] = 3; // an earlier entry in this same batch (ids 2, 3, 4)
        vm.recordLogs();
        vm.prank(op);
        uint256 first = lg.writeMany(k, s, h, r, u);
        assertEq(first, 2);
        assertEq(lg.count(), 4);
        for (uint256 i; i < 3; ++i) {
            Log.Entry memory e = lg.entry(first + i);
            assertEq(e.author, op);
            assertEq(e.kind, k[i]);
            assertEq(e.subject, s[i]);
            assertEq(e.hash, h[i]);
            assertEq(e.ref, r[i]);
            assertEq(e.uri, u[i]);
            assertEq(e.time, block.timestamp);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(logs[i].topics[0], Logged.selector);
            assertEq(uint256(logs[i].topics[1]), first + i);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), op);
            assertEq(uint256(logs[i].topics[3]), k[i]);
        }
        assertEq(lg.totalBurned(), 0);
    }

    function test_writeMany_max() public {
        (uint32[] memory k, bytes32[] memory s, bytes32[] memory h, uint256[] memory r, string[] memory u) =
            _batch(50);
        vm.prank(op);
        assertEq(lg.writeMany(k, s, h, r, u), 1);
        assertEq(lg.count(), 50);
        (k, s, h, r, u) = _batch(51);
        vm.prank(op);
        vm.expectRevert(Log.BadBatch.selector);
        lg.writeMany(k, s, h, r, u);
    }

    function test_writeMany_reverts() public {
        (uint32[] memory k, bytes32[] memory s, bytes32[] memory h, uint256[] memory r, string[] memory u) = _batch(2);
        // Operator only, even with a fee paid.
        vm.prank(alice);
        vm.expectRevert(Log.NotOperator.selector);
        lg.writeMany(k, s, h, r, u);
        vm.prank(owner);
        vm.expectRevert(Log.NotOperator.selector);
        lg.writeMany(k, s, h, r, u);

        vm.startPrank(op);
        // Empty.
        (uint32[] memory k0, bytes32[] memory s0, bytes32[] memory h0, uint256[] memory r0, string[] memory u0) =
            _batch(0);
        vm.expectRevert(Log.BadBatch.selector);
        lg.writeMany(k0, s0, h0, r0, u0);
        // Lengths that do not match, one array at a time.
        vm.expectRevert(Log.BadBatch.selector);
        lg.writeMany(k, s0, h, r, u);
        vm.expectRevert(Log.BadBatch.selector);
        lg.writeMany(k, s, h0, r, u);
        vm.expectRevert(Log.BadBatch.selector);
        lg.writeMany(k, s, h, r0, u);
        vm.expectRevert(Log.BadBatch.selector);
        lg.writeMany(k, s, h, r, u0);
        // A ref to itself or later, inside the batch.
        r[1] = 2;
        vm.expectRevert(Log.BadRef.selector);
        lg.writeMany(k, s, h, r, u);
        r[1] = 0;
        // A long uri anywhere fails the whole batch.
        u[1] = string(new bytes(257));
        vm.expectRevert(Log.UriTooLong.selector);
        lg.writeMany(k, s, h, r, u);
        vm.stopPrank();
        assertEq(lg.count(), 0);
    }

    function test_writeMany_paused() public {
        (uint32[] memory k, bytes32[] memory s, bytes32[] memory h, uint256[] memory r, string[] memory u) = _batch(2);
        vm.prank(owner);
        lg.pause();
        vm.prank(op);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lg.writeMany(k, s, h, r, u);
    }

    // ------------------------------------------------------------ reads

    function test_entry_reverts() public {
        vm.expectRevert(Log.NoEntry.selector);
        lg.entry(0);
        vm.expectRevert(Log.NoEntry.selector);
        lg.entry(1);
        _opWrite(1, 0);
        lg.entry(1);
        vm.expectRevert(Log.NoEntry.selector);
        lg.entry(2);
    }

    function test_entries_paging() public {
        (uint32[] memory k, bytes32[] memory s, bytes32[] memory h, uint256[] memory r, string[] memory u) =
            _batch(50);
        vm.startPrank(op);
        lg.writeMany(k, s, h, r, u);
        lg.writeMany(k, s, h, r, u);
        lg.writeMany(k, s, h, r, u);
        vm.stopPrank();
        assertEq(lg.count(), 150);

        Log.Entry[] memory list = lg.entries(1, 10);
        assertEq(list.length, 10);
        assertEq(list[0].kind, 1);
        assertEq(list[9].kind, 10);
        // from 0 reads as 1
        assertEq(lg.entries(0, 3)[0].kind, 1);
        assertEq(lg.entries(0, 3).length, 3);
        // capped at 100
        assertEq(lg.entries(1, 1000).length, 100);
        assertEq(lg.entries(1, type(uint256).max).length, 100);
        // clipped at count
        list = lg.entries(141, 100);
        assertEq(list.length, 10);
        assertEq(list[9].kind, 50); // id 150 is the 50th of the third batch
        assertEq(lg.entries(150, 5).length, 1);
        assertEq(lg.entries(151, 5).length, 0);
        assertEq(lg.entries(type(uint256).max, 5).length, 0);
        assertEq(lg.entries(1, 0).length, 0);
        // same entries as entry(id)
        list = lg.entries(51, 2);
        assertEq(list[0].uri, lg.entry(51).uri);
        assertEq(list[1].hash, lg.entry(52).hash);
    }

    function test_entries_empty() public view {
        assertEq(lg.entries(0, 10).length, 0);
        assertEq(lg.entries(1, 10).length, 0);
    }

    // ------------------------------------------------------------ owner

    function test_setFee() public {
        vm.expectEmit(false, false, false, true, address(lg));
        emit FeeSet(5e18);
        vm.prank(owner);
        lg.setFee(5e18);
        assertEq(lg.fee(), 5e18);
        vm.prank(alice);
        lg.write(1, 0, 0, 0, "");
        assertEq(lg.totalBurned(), 5e18);

        vm.startPrank(owner);
        lg.setFee(10_000_000e18);
        assertEq(lg.fee(), 10_000_000e18);
        vm.expectRevert(Log.FeeTooHigh.selector);
        lg.setFee(10_000_000e18 + 1);
        vm.stopPrank();
        assertEq(lg.fee(), 10_000_000e18);
    }

    function test_setOperator() public {
        address next = makeAddr("next");
        vm.expectEmit(false, false, false, true, address(lg));
        emit OperatorSet(next);
        vm.prank(owner);
        lg.setOperator(next);
        assertEq(lg.operator(), next);

        // The old operator now pays like anyone else.
        vm.prank(op);
        vm.expectRevert();
        lg.write(1, 0, 0, 0, "");
        (uint32[] memory k, bytes32[] memory s, bytes32[] memory h, uint256[] memory r, string[] memory u) = _batch(1);
        vm.prank(op);
        vm.expectRevert(Log.NotOperator.selector);
        lg.writeMany(k, s, h, r, u);

        // The new one writes for free.
        vm.prank(next);
        lg.write(1, 0, 0, 0, "");
        vm.prank(next);
        lg.writeMany(k, s, h, r, u);
        assertEq(lg.totalBurned(), 0);
        assertEq(lg.count(), 2);
    }

    function test_owner_only() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        lg.setOperator(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        lg.setFee(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        lg.pause();
        vm.stopPrank();
        vm.startPrank(op);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, op));
        lg.unpause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, op));
        lg.setFee(0);
        vm.stopPrank();
    }

    function test_owner_twoStepTransfer() public {
        vm.prank(owner);
        lg.transferOwnership(alice);
        assertEq(lg.owner(), owner);
        assertEq(lg.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        lg.acceptOwnership();
        vm.prank(alice);
        lg.acceptOwnership();
        assertEq(lg.owner(), alice);
        vm.prank(alice);
        lg.setFee(1);
        assertEq(lg.fee(), 1);
    }

    function test_pause_readsStillWork() public {
        _opWrite(1, 0);
        vm.prank(owner);
        lg.pause();
        assertTrue(lg.paused());
        assertEq(lg.count(), 1);
        assertEq(lg.entry(1).author, op);
        assertEq(lg.entries(1, 10).length, 1);
    }

    /// Everything the owner and operator can do leaves written entries exactly as they were.
    function test_entriesNeverChange() public {
        vm.prank(alice);
        lg.write(3, bytes32("a"), bytes32("h"), 0, "https://x.test/a.json");
        Log.Entry memory before = lg.entry(1);

        vm.startPrank(owner);
        lg.setFee(0);
        lg.setOperator(bob);
        lg.pause();
        lg.unpause();
        lg.transferOwnership(bob);
        vm.stopPrank();
        vm.prank(bob);
        lg.acceptOwnership();
        vm.warp(block.timestamp + 365 days);
        vm.prank(bob);
        lg.write(4, bytes32("b"), bytes32("h2"), 1, "https://x.test/b.json");

        Log.Entry memory afterAll = lg.entry(1);
        assertEq(afterAll.author, before.author);
        assertEq(afterAll.time, before.time);
        assertEq(afterAll.kind, before.kind);
        assertEq(afterAll.ref, before.ref);
        assertEq(afterAll.subject, before.subject);
        assertEq(afterAll.hash, before.hash);
        assertEq(afterAll.uri, before.uri);
        assertEq(lg.count(), 2);
    }

    // ------------------------------------------------------------ fuzz

    function testFuzz_feeBurns(uint256 fee, uint8 writes) public {
        fee = bound(fee, 0, 10_000_000e18);
        uint256 n = bound(writes, 1, 8);
        vm.prank(owner);
        lg.setFee(fee);
        for (uint256 i; i < n; ++i) {
            vm.prank(alice);
            assertEq(lg.write(uint32(i), 0, 0, 0, ""), i + 1);
        }
        assertEq(lg.totalBurned(), fee * n);
        assertEq(token.balanceOf(DEAD), fee * n);
        assertEq(token.balanceOf(address(lg)), 0);
    }

    function testFuzz_refBounds(uint8 existing, uint256 ref) public {
        uint256 n = bound(existing, 0, 20);
        for (uint256 i; i < n; ++i) {
            _opWrite(1, 0);
        }
        vm.prank(op);
        if (ref > n) {
            vm.expectRevert(Log.BadRef.selector);
            lg.write(1, 0, 0, ref, "");
        } else {
            assertEq(lg.write(1, 0, 0, ref, ""), n + 1);
            assertEq(lg.entry(n + 1).ref, ref);
        }
    }

    function testFuzz_uriLength(uint16 len) public {
        uint256 l = bound(len, 0, 600);
        vm.prank(alice);
        if (l > 256) {
            vm.expectRevert(Log.UriTooLong.selector);
            lg.write(1, 0, 0, 0, string(new bytes(l)));
        } else {
            lg.write(1, 0, 0, 0, string(new bytes(l)));
            assertEq(bytes(lg.entry(1).uri).length, l);
        }
    }

    function testFuzz_writeManyIds(uint8 pre, uint8 size) public {
        uint256 p = bound(pre, 0, 10);
        uint256 n = bound(size, 1, 50);
        for (uint256 i; i < p; ++i) {
            _opWrite(1, 0);
        }
        (uint32[] memory k, bytes32[] memory s, bytes32[] memory h, uint256[] memory r, string[] memory u) = _batch(n);
        for (uint256 i; i < n; ++i) {
            r[i] = p + i; // each points at the entry just before it (0 for the very first entry)
        }
        vm.prank(op);
        uint256 first = lg.writeMany(k, s, h, r, u);
        assertEq(first, p + 1);
        assertEq(lg.count(), p + n);
        assertEq(lg.entry(p + n).kind, k[n - 1]);
        assertEq(lg.entry(p + n).ref, p + n - 1);
    }

    function testFuzz_entriesPaging(uint8 total, uint256 from, uint256 n) public {
        uint256 t = bound(total, 0, 120);
        uint256 done;
        while (done < t) {
            uint256 size = t - done > 50 ? 50 : t - done;
            (uint32[] memory k, bytes32[] memory s, bytes32[] memory h, uint256[] memory r, string[] memory u) =
                _batch(size);
            vm.prank(op);
            lg.writeMany(k, s, h, r, u);
            done += size;
        }
        from = bound(from, 0, 200);
        Log.Entry[] memory list = lg.entries(from, n);
        uint256 start = from == 0 ? 1 : from;
        uint256 want = start > t ? 0 : t - start + 1;
        if (want > 100) want = 100;
        if (n < want) want = n;
        assertEq(list.length, want);
        for (uint256 i; i < list.length; ++i) {
            assertEq(list[i].uri, lg.entry(start + i).uri);
        }
    }

    // ------------------------------------------------------------ token set later

    function _deployedFirst() internal returns (Log c) {
        c = new Log(IERC20(address(0)), owner, op, FEE);
        vm.prank(alice);
        token.approve(address(c), type(uint256).max);
    }

    function test_deployFirst_noTokenYet() public {
        Log c = _deployedFirst();
        assertEq(address(c.token()), address(0));
        // Paid writes need the token.
        vm.prank(alice);
        vm.expectRevert(Log.TokenNotSet.selector);
        c.write(1, bytes32(0), bytes32(0), 0, "");
        // The operator's free writes and reads keep working.
        vm.prank(op);
        uint256 id = c.write(1, bytes32("s"), bytes32("h"), 0, "u");
        assertEq(id, 1);
        assertEq(c.count(), 1);
        assertEq(c.entry(1).author, op);
        // A zero fee means nobody needs the token.
        vm.prank(owner);
        c.setFee(0);
        vm.prank(alice);
        c.write(2, bytes32(0), bytes32(0), 1, "");
        assertEq(c.count(), 2);
        assertEq(c.totalBurned(), 0);
    }

    function test_setToken_onceThenPaidWritesOpen() public {
        Log c = _deployedFirst();
        vm.expectEmit(address(c));
        emit Log.TokenSet(address(token));
        vm.prank(owner);
        c.setToken(IERC20(address(token)));
        assertEq(address(c.token()), address(token));

        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(alice);
        c.write(1, bytes32(0), bytes32(0), 0, "");
        assertEq(token.balanceOf(DEAD) - deadBefore, FEE);
        assertEq(c.totalBurned(), FEE);

        MockToken other = new MockToken();
        vm.prank(owner);
        vm.expectRevert(Log.TokenAlreadySet.selector);
        c.setToken(IERC20(address(other)));
    }

    function test_setToken_onlyOwner() public {
        Log c = _deployedFirst();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        c.setToken(IERC20(address(token)));
    }

    function test_setToken_rejectsNonContract() public {
        Log c = _deployedFirst();
        vm.startPrank(owner);
        vm.expectRevert(Log.InvalidToken.selector);
        c.setToken(IERC20(address(0)));
        vm.expectRevert(Log.InvalidToken.selector);
        c.setToken(IERC20(makeAddr("eoa")));
        vm.stopPrank();
    }

    function test_constructorToken_cannotBeReset() public {
        MockToken other = new MockToken();
        vm.prank(owner);
        vm.expectRevert(Log.TokenAlreadySet.selector);
        lg.setToken(IERC20(address(other)));
    }
}
