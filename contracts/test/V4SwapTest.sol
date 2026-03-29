// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/IV4PoolManager.sol";

contract V4SwapTest {
    address public pm;
    V4PoolKey public poolKey;
    uint256 public lastAmountOut;

    event Debug(string msg, uint256 val);
    event DebugInt(string msg, int256 val);

    constructor(address _pm) { pm = _pm; }

    function testSwap(V4PoolKey calldata _key) external payable {
        poolKey = _key;
        IV4PoolManager(pm).unlock(abi.encode(msg.value));
    }

    function unlockCallback(bytes calldata _data) external returns (bytes memory) {
        require(msg.sender == pm, "not pm");
        uint256 _amountIn = abi.decode(_data, (uint256));
        IV4PoolManager _pm = IV4PoolManager(pm);

        // CORRECT V4 native ETH pattern:
        // 1. swap
        // 2. For native ETH input: just call settle{value} (no sync needed)
        // 3. For token output: call take

        int256 _delta = _pm.swap(
            poolKey,
            IV4PoolManager.SwapParams(true, int256(_amountIn), 4295128739 + 1),
            ""
        );

        int128 _a0 = int128(_delta >> 128);
        int128 _a1 = int128(_delta);
        emit DebugInt("a0", int256(_a0));
        emit DebugInt("a1", int256(_a1));

        // Settle native ETH (token0 = address(0))
        // _a0 should be negative (we owe PM)
        uint256 _settleAmt = uint128(-_a0);
        emit Debug("settleAmt", _settleAmt);
        emit Debug("balance", address(this).balance);

        _pm.settle{value: _settleAmt}();

        // Take USDC (token1)
        uint256 _takeAmt = uint128(_a1);
        emit Debug("takeAmt", _takeAmt);
        _pm.take(poolKey.currency1, address(this), _takeAmt);

        lastAmountOut = _takeAmt;
        return abi.encode(_takeAmt);
    }

    receive() external payable {}
}
