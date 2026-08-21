// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @notice A signed-order / OTC settlement book. Each order has a fixed size and a
///         running filled amount; each filling account carries a nonce that must
///         strictly advance so no request executes twice.
///
///           - {orderSize}         — the total an order may ever be filled for.
///           - {filled}            — how much of it has been filled so far.
///           - {fillableRemaining} — orderSize - filled (what is still open).
///           - {nonceOf}           — a per-account counter that advances by exactly
///                                    one per executed fill (the replay guard).
///           - {fill}              — consume up to `fillableRemaining` of an order.
///
///         A real OTC settler / forwarder is a superset of this.
interface IOrderSettlement {
    function orderSize(bytes32 orderId) external view returns (uint256);
    function filled(bytes32 orderId) external view returns (uint256);
    function fillableRemaining(bytes32 orderId) external view returns (uint256);
    function nonceOf(address account) external view returns (uint256);
    function fill(bytes32 orderId, uint256 amount) external;
}

/// @notice Bounded random actor set that fills open orders. Two things are asserted
///         inline because they are statements about a *transition*: every executed
///         fill must advance the caller's nonce by exactly one (no request runs
///         twice, none is skipped), and a fill is only ever placed for an amount
///         that is genuinely open.
contract OrderSettlementHandler is Test {
    IOrderSettlement public immutable book;
    bytes32[] public orderIds;
    address[] public actors;
    mapping(address => uint256) public expectedNonce;

    uint256 internal constant NUM_ACTORS = 3;

    constructor(IOrderSettlement b, bytes32[] memory ids) {
        book = b;
        orderIds = ids;
        // Fund payouts so a value-settled fill never reverts for lack of ETH.
        vm.deal(address(b), 1e24);
        for (uint256 i; i < NUM_ACTORS; i++) {
            actors.push(makeAddr(string.concat("ik_taker_", vm.toString(i))));
        }
    }

    function fill(uint256 orderSeed, uint256 actorSeed, uint256 amount) external {
        bytes32 id = orderIds[orderSeed % orderIds.length];
        address a = actors[actorSeed % actors.length];

        uint256 remaining = book.fillableRemaining(id);
        if (remaining == 0) return;
        amount = bound(amount, 1, remaining);

        vm.prank(a);
        book.fill(id, amount);

        expectedNonce[a] += 1;
        assertEq(book.nonceOf(a), expectedNonce[a], "REPLAY: nonce did not advance by exactly one per fill");
    }
}

/// @notice Drop-in no-overfill / no-replay invariant for a signed-order settler.
///         No order is ever filled beyond its size, `fillableRemaining` stays
///         consistent with `orderSize - filled`, and the per-account nonce
///         advances once per execution (enforced by the handler).
///
///         The bug it catches is the settler that persists `filled` (or advances
///         the nonce) only after the external transfer: a reentrant taker fills
///         the same open amount twice before the book records the first fill,
///         driving `filled` past `orderSize` — a double-fill / replay with nothing
///         reverting.
///
///         Extend it, implement {_setUpBook} to deploy your settler and return it
///         with the order ids to track, and Foundry fuzzes fills against it.
abstract contract NoOverfillInvariant is StdInvariant, Test {
    IOrderSettlement internal book;
    OrderSettlementHandler internal handler;
    bytes32[] internal ids;

    /// @dev Teams override: deploy/return the settler and the order ids to track.
    function _setUpBook() internal virtual returns (IOrderSettlement book_, bytes32[] memory orderIds_);

    function setUp() public virtual {
        (IOrderSettlement b, bytes32[] memory orderIds) = _setUpBook();
        book = b;
        ids = orderIds;
        handler = new OrderSettlementHandler(b, orderIds);
        targetContract(address(handler));
    }

    /// No order is ever overfilled, and the open amount stays consistent.
    function invariant_noOverfill() public view {
        for (uint256 i; i < ids.length; i++) {
            bytes32 id = ids[i];
            assertLe(book.filled(id), book.orderSize(id), "OVERFILL: filled > orderSize (double-fill / replay)");
            assertEq(
                book.fillableRemaining(id),
                book.orderSize(id) - book.filled(id),
                "ACCOUNTING: fillableRemaining != orderSize - filled"
            );
        }
    }
}
