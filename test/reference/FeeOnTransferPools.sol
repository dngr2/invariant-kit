// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev A deflationary / fee-on-transfer ERC-20: every transfer burns a fee in
///      basis points, so the recipient receives strictly less than the amount
///      sent. This is the token class (USDT with fees enabled, PAXG, STA, many
///      "reflection" tokens) that breaks face-value accounting.
contract FeeOnTransferToken {
    string public name = "FeeToken";
    string public symbol = "FEE";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public immutable feeBps; // e.g. 100 = 1%
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 feeBps_) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        uint256 fee = (a * feeBps) / 10_000;
        uint256 net = a - fee;
        balanceOf[from] -= a;
        balanceOf[to] += net; // recipient gets the net, the fee is burned
        totalSupply -= fee;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        _move(f, t, a);
        return true;
    }
}

interface IFeeToken {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev Shared custody state. Depositors pull tokens in and receive an internal
///      credit; withdrawals burn credit and pay tokens back. The two variants
///      differ only in HOW MUCH they credit on deposit.
abstract contract FeeAwarePoolBase {
    IFeeToken public immutable token;
    uint256 public creditedTotal;
    mapping(address => uint256) public creditOf;

    constructor(IFeeToken t) {
        token = t;
    }

    function tokenBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @dev Each variant credits a different amount for the same pull.
    function _creditFor(uint256 requested, uint256 received) internal virtual returns (uint256);

    function deposit(uint256 amount) external {
        uint256 before = token.balanceOf(address(this));
        token.transferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;

        uint256 credit = _creditFor(amount, received);
        creditOf[msg.sender] += credit;
        creditedTotal += credit;
    }

    function withdraw(uint256 amount) external {
        require(creditOf[msg.sender] >= amount, "insufficient credit");
        creditOf[msg.sender] -= amount;
        creditedTotal -= amount;
        token.transfer(msg.sender, amount);
    }
}

/// @dev CORRECT: credits the real balance delta, so credit can never exceed the
///      tokens actually held regardless of transfer fees.
contract DeltaMeasuredPool is FeeAwarePoolBase {
    constructor(IFeeToken t) FeeAwarePoolBase(t) {}

    function _creditFor(uint256, uint256 received) internal pure override returns (uint256) {
        return received;
    }
}

/// @dev BROKEN: credits the requested face value, ignoring that a fee-on-transfer
///      token delivered less. creditedTotal outgrows tokenBalance immediately.
contract FaceValuePool is FeeAwarePoolBase {
    constructor(IFeeToken t) FeeAwarePoolBase(t) {}

    function _creditFor(uint256 requested, uint256) internal pure override returns (uint256) {
        return requested;
    }
}
