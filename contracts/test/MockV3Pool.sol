// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title MockV3Pool
 * @dev Minimal mock of a Uniswap V3 pool for exercising estimator math with
 *      configurable sqrtPriceX96 values — including extreme values that
 *      would overflow a naive squaring.
 */
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint160 public sqrtPriceX96Value;
    uint128 public liquidityValue;

    constructor(address _t0, address _t1, uint24 _fee, uint160 _sqrtPriceX96) {
        token0 = _t0;
        token1 = _t1;
        fee = _fee;
        sqrtPriceX96Value = _sqrtPriceX96;
        liquidityValue = type(uint128).max; // healthy pool by default
    }

    function setSqrtPriceX96(uint160 _v) external {
        sqrtPriceX96Value = _v;
    }

    function setLiquidity(uint128 _v) external {
        liquidityValue = _v;
    }

    function liquidity() external view returns (uint128) {
        return liquidityValue;
    }

    // Matches IUniswapV3Pool.slot0 tuple layout.
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    ) {
        return (sqrtPriceX96Value, 0, 0, 0, 0, 0, true);
    }

    // Presence of this method is how the estimator detects a V3 pool.
    function maxLiquidityPerTick() external pure returns (uint128) {
        return 1;
    }
}
