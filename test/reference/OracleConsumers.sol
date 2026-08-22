// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev A settable Chainlink-style price feed (AggregatorV3 subset). Tests wire
///      this into a consumer and drive it into each bad state: zero, negative,
///      stale, and incomplete-round answers.
contract MockAggregator {
    uint8 public decimals = 8;

    uint80 internal _roundId;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _answeredInRound;

    function setRoundData(uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound) external {
        _roundId = roundId;
        _answer = answer;
        _updatedAt = updatedAt;
        _answeredInRound = answeredInRound;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }
}

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @dev CORRECT consumer: validates the full round tuple before trusting a price
///      — positive answer, completed round, fresh enough, and not a carried-over
///      answer from an earlier round.
contract SafePriceConsumer {
    IAggregator public immutable agg;
    uint256 public immutable maxAge;

    constructor(IAggregator a, uint256 maxAge_) {
        agg = a;
        maxAge = maxAge_;
    }

    function getPrice() external view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = agg.latestRoundData();
        require(answer > 0, "bad price");
        require(updatedAt != 0, "round not complete");
        require(block.timestamp - updatedAt <= maxAge, "stale price");
        require(answeredInRound >= roundId, "stale round");
        return uint256(answer);
    }
}

/// @dev BROKEN consumer: reads `answer` and uses it with no validation — the
///      textbook mistake. A zero passes straight through, a negative answer wraps
///      to an enormous `uint256`, and a days-old price is treated as current.
contract NaivePriceConsumer {
    IAggregator public immutable agg;

    constructor(IAggregator a) {
        agg = a;
    }

    function getPrice() external view returns (uint256) {
        (, int256 answer,,,) = agg.latestRoundData();
        return uint256(answer);
    }
}
