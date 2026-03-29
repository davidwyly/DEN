// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @dev Uniswap V4 PoolKey struct for identifying pools.
 * In V4, pools are identified by this struct rather than a contract address.
 * The PoolManager singleton holds all pool state.
 *
 * currency0/currency1: address(0) represents native ETH; otherwise ERC20 token address.
 * hooks: address(0) means no hooks contract.
 */
struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/**
 * @dev Data passed through PM.unlock() → unlockCallback() for V4 swaps.
 *      Using a struct avoids stack-too-deep when encoding/decoding the 8 fields.
 */
struct V4SwapCallbackData {
    V4PoolKey poolKey;
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
    address currencyIn;
    address currencyOut;
    address payer;
    address recipient;
}

/**
 * @dev Minimal interface for the Uniswap V4 PoolManager singleton.
 * ABI-compatible with the deployed V4 PoolManager on supported chains.
 *
 * Note: Currency (user-defined value type wrapping address) and PoolId (wrapping bytes32)
 * are represented as their underlying types for ABI compatibility.
 */
interface IV4PoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Unlocks the PoolManager for multi-step operations (swap, settle, take).
    /// The PM will call msg.sender.unlockCallback(data) and verify all deltas settle to zero.
    function unlock(bytes calldata data) external returns (bytes memory result);

    /// @notice Executes a swap against a V4 pool. Must be called within an unlock callback.
    /// @return swapDelta Packed BalanceDelta (int128 amount0 in upper 128 bits, int128 amount1 in lower 128 bits).
    ///         Negative = caller owes PM (settle), positive = PM owes caller (take).
    function swap(
        V4PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external returns (int256 swapDelta);

    /// @notice Records the PM's current balance for flash accounting. Call before transferring ERC20 tokens.
    function sync(address currency) external;

    /// @notice Settles a debt to the PM. For native ETH, send value with the call.
    /// For ERC20, transfer tokens to PM first (after sync), then call settle().
    function settle() external payable returns (uint256 paid);

    /// @notice Takes tokens owed by the PM to the specified recipient.
    function take(address currency, address to, uint256 amount) external;

    /// @notice Reads an arbitrary storage slot from the PoolManager (for state introspection).
    function extsload(bytes32 slot) external view returns (bytes32 value);
}
