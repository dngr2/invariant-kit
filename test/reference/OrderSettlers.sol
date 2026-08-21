// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title OrderSettlerBase — a tiny signed-order / OTC settlement book
/// @notice Orders are registered with a fixed size; a taker calls {fill} to
///         consume up to the open amount and is paid out (here, in native value).
///         The settler is pre-funded so payouts succeed. The only behaviour that
///         differs between the correct and the broken reference is the ordering
///         inside {_fill} — effects-before-interaction versus the reverse — so the
///         reentrancy bug is isolated to one override.
abstract contract OrderSettlerBase {
    mapping(bytes32 => uint256) public orderSize;
    mapping(bytes32 => uint256) public filled;
    mapping(address => uint256) public nonceOf;

    function createOrder(bytes32 orderId, uint256 size) external {
        orderSize[orderId] = size;
    }

    function fillableRemaining(bytes32 orderId) external view returns (uint256) {
        return orderSize[orderId] - filled[orderId];
    }

    function fill(bytes32 orderId, uint256 amount) external {
        require(amount > 0, "zero amount");
        require(filled[orderId] + amount <= orderSize[orderId], "overfill");
        _fill(orderId, amount);
    }

    function _fill(bytes32 orderId, uint256 amount) internal virtual;

    function _payout(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "payout failed");
    }

    /// Accept the pre-funding used to pay takers.
    receive() external payable {}
}

/// @title CEIOrderSettler (CORRECT)
/// @notice Persists `filled` and advances the nonce BEFORE paying the taker
///         (checks-effects-interactions). A reentrant taker re-entering during the
///         payout sees the already-updated `filled`, so the second fill fails the
///         overfill check and the whole attack reverts — no double-fill.
contract CEIOrderSettler is OrderSettlerBase {
    function _fill(bytes32 orderId, uint256 amount) internal override {
        filled[orderId] += amount; // effects first
        nonceOf[msg.sender] += 1;
        _payout(msg.sender, amount); // interaction last
    }
}

/// @title ReentrantOrderSettler (VULNERABLE — filled persisted after transfer)
/// @notice Pays the taker BEFORE recording `filled` / advancing the nonce. A taker
///         that re-enters {fill} inside the payout still sees `filled` at its old
///         value, passes the overfill check again, and gets paid twice for the same
///         open amount — `filled` ends past `orderSize`. Nothing reverts.
///
///         `NoOverfillInvariant.invariant_noOverfill` catches it (filled >
///         orderSize); the handler's nonce check catches the replay.
contract ReentrantOrderSettler is OrderSettlerBase {
    function _fill(bytes32 orderId, uint256 amount) internal override {
        _payout(msg.sender, amount); // interaction FIRST — reentrancy window
        filled[orderId] += amount; // effects after
        nonceOf[msg.sender] += 1;
    }
}

/// @notice A taker that re-enters {fill} exactly once during its payout — the
///         double-fill attacker for the reference pair.
contract ReentrantTaker {
    OrderSettlerBase public settler;
    bytes32 public orderId;
    uint256 public amount;
    bool internal entered;

    function attack(OrderSettlerBase s, bytes32 id, uint256 amt) external {
        settler = s;
        orderId = id;
        amount = amt;
        entered = false;
        s.fill(id, amt);
    }

    receive() external payable {
        if (!entered) {
            entered = true;
            settler.fill(orderId, amount); // reenter before the first fill is recorded
        }
    }
}
