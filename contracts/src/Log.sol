// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title Log: a public record that can only grow
/// @notice Each entry records who wrote it, when, what kind of record it is, what it is about
///         (`subject`), a hash of the full record published off-chain, and where that record lives
///         (`uri`). An entry can point back at an earlier one with `ref`, so a settlement or score
///         can name the call it settles.
///
///         Nothing can be edited or deleted. This contract has no function that changes, removes or
///         reorders an entry once it is written, for anyone: not the author, not the operator, not
///         the owner. Ids count up from 1 in the order entries were written, and every entry carries
///         the block time it was written at, so the time cannot be faked after the fact. Pausing
///         only stops new writes; every entry stays readable.
///
///         Anyone can write. The product's agent (the operator) writes for free. Everyone else burns
///         `fee` tokens per entry, sent straight from the writer to the dead address.
/// @dev The contract never holds funds. The owner can only pause and unpause writing, choose the
///      operator, and set the fee up to MAX_FEE. There is no upgrade path and no withdraw function.
contract Log is Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice Longest `uri`, in bytes.
    uint256 public constant MAX_URI = 256;
    /// @notice Most entries in one `writeMany`.
    uint256 public constant MAX_BATCH = 50;
    /// @notice Most entries one `entries` call returns.
    uint256 public constant MAX_PAGE = 100;
    /// @notice Cap on the fee per entry: 1% of a 1B supply.
    uint256 public constant MAX_FEE = 10_000_000e18;

    struct Entry {
        address author;
        uint64 time;
        uint32 kind;
        uint256 ref;
        bytes32 subject;
        bytes32 hash;
        string uri;
    }

    /// @notice The project token. Zero until the owner sets it once with `setToken`.
    IERC20 public token;
    address public operator;
    /// @notice Tokens burned per entry by anyone but the operator.
    uint256 public fee;
    /// @notice Every token that has reached the dead address through this contract.
    uint256 public totalBurned;

    /// @dev Entry `id` is stored at index `id - 1`.
    Entry[] private _entries;

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
    event TokenSet(address token);

    error NotOperator();
    error FeeTooHigh();
    error UriTooLong();
    error BadRef();
    error BadBatch();
    error NoEntry();
    error TokenNotSet();
    error TokenAlreadySet();
    error InvalidToken();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @param token_ The project token, or zero to set it later with `setToken`.
    constructor(IERC20 token_, address owner_, address operator_, uint256 fee_) Ownable(owner_) {
        if (fee_ > MAX_FEE) revert FeeTooHigh();
        if (address(token_) != address(0)) _setToken(token_);
        operator = operator_;
        fee = fee_;
        emit OperatorSet(operator_);
        emit FeeSet(fee_);
    }

    // ---------------------------------------------------------------- writing

    /// @notice Add one entry. `ref` is 0 or the id of an earlier entry. The operator writes for
    ///         free; anyone else burns `fee` tokens (approve this contract first).
    /// @return id The new entry's id.
    function write(uint32 kind, bytes32 subject, bytes32 hash, uint256 ref, string calldata uri)
        external
        whenNotPaused
        returns (uint256 id)
    {
        _check(ref, uri, _entries.length + 1);
        uint256 burned = msg.sender == operator ? 0 : _burnFee();
        id = _push(kind, subject, hash, ref, uri, burned);
    }

    /// @notice Add up to MAX_BATCH entries in one transaction. Operator only, so nothing is burned.
    ///         An entry's `ref` may point at an earlier entry in the same batch.
    /// @return firstId The id of the first new entry; the rest follow in order.
    function writeMany(
        uint32[] calldata kinds,
        bytes32[] calldata subjects,
        bytes32[] calldata hashes,
        uint256[] calldata refs,
        string[] calldata uris
    ) external onlyOperator whenNotPaused returns (uint256 firstId) {
        uint256 n = kinds.length;
        if (
            n == 0 || n > MAX_BATCH || subjects.length != n || hashes.length != n || refs.length != n
                || uris.length != n
        ) revert BadBatch();
        firstId = _entries.length + 1;
        for (uint256 i; i < n; ++i) {
            _check(refs[i], uris[i], firstId + i);
            _push(kinds[i], subjects[i], hashes[i], refs[i], uris[i], 0);
        }
    }

    // ---------------------------------------------------------------- owner

    /// @notice Sets the project token. Works once; after that the token can never change.
    function setToken(IERC20 token_) external onlyOwner {
        _setToken(token_);
    }

    function setOperator(address operator_) external onlyOwner {
        operator = operator_;
        emit OperatorSet(operator_);
    }

    /// @notice Set the burn per entry for writers other than the operator, up to MAX_FEE.
    function setFee(uint256 fee_) external onlyOwner {
        if (fee_ > MAX_FEE) revert FeeTooHigh();
        fee = fee_;
        emit FeeSet(fee_);
    }

    /// @notice Stop new writes. Reads keep working and no entry changes.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------- reads

    /// @notice One entry. Reverts with NoEntry for id 0 or an id past `count()`.
    function entry(uint256 id) external view returns (Entry memory) {
        if (id == 0 || id > _entries.length) revert NoEntry();
        return _entries[id - 1];
    }

    /// @notice How many entries there are. The newest entry's id equals this.
    function count() external view returns (uint256) {
        return _entries.length;
    }

    /// @notice Entries with ids `from` to `from + n - 1`, oldest first. `from` of 0 is read as 1,
    ///         `n` is capped at MAX_PAGE, and the list stops at the newest entry.
    function entries(uint256 from, uint256 n) external view returns (Entry[] memory list) {
        uint256 total = _entries.length;
        if (from == 0) from = 1;
        if (n > MAX_PAGE) n = MAX_PAGE;
        if (from > total) n = 0;
        else if (n > total - from + 1) n = total - from + 1;
        list = new Entry[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = _entries[from - 1 + i];
        }
    }

    // ---------------------------------------------------------------- internal

    function _setToken(IERC20 token_) private {
        if (address(token) != address(0)) revert TokenAlreadySet();
        if (address(token_).code.length == 0) revert InvalidToken();
        token = token_;
        emit TokenSet(address(token_));
    }

    /// @dev `nextId` is the id the entry will get, so `ref` must be below it.
    function _check(uint256 ref, string calldata uri, uint256 nextId) private pure {
        if (ref >= nextId) revert BadRef();
        if (bytes(uri).length > MAX_URI) revert UriTooLong();
    }

    function _push(uint32 kind, bytes32 subject, bytes32 hash, uint256 ref, string calldata uri, uint256 burned)
        private
        returns (uint256 id)
    {
        Entry storage e = _entries.push();
        e.author = msg.sender;
        e.time = uint64(block.timestamp);
        e.kind = kind;
        e.ref = ref;
        e.subject = subject;
        e.hash = hash;
        e.uri = uri;
        id = _entries.length;
        emit Logged(id, msg.sender, kind, subject, hash, ref, uri, burned);
    }

    /// @dev Sends the fee to the dead address and counts what actually arrived, so a token with
    ///      a transfer tax cannot inflate the total. Nothing moves when the fee is 0, so free
    ///      entries work before the token is set.
    function _burnFee() private returns (uint256 burned) {
        uint256 amount = fee;
        if (amount == 0) return 0;
        if (address(token) == address(0)) revert TokenNotSet();
        uint256 before = token.balanceOf(DEAD);
        token.safeTransferFrom(msg.sender, DEAD, amount);
        burned = token.balanceOf(DEAD) - before;
        totalBurned += burned;
    }
}
