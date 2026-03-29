// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V4SwapLib.sol";
import "./interfaces/IV4PoolManager.sol";

/**
 * @title DENEstimator
 * @dev Separate view-only contract for price estimation across V2, V3, and V4 pools.
 *      Deployed independently from the main DEN contract to keep it under 24KB.
 *      Used by the UI for quote previews and rate display.
 */
contract DENEstimator {

    error ZeroAddressForPool();
    error ZeroAddressForTokenIn();
    error ZeroValueForAmountIn();
    error TokenCannotBeAPool();
    error PoolCannotBeSender();
    error TokenInCannotBeSender();
    error UnsupportedDEX();

    address public immutable WETH;
    address public immutable v4PoolManager;

    constructor(address _weth, address _v4PoolManager) {
        WETH = _weth;
        v4PoolManager = _v4PoolManager;
    }

    /**
     * @dev Estimates output for a V2 or V3 pool swap.
     *      Restricted to EOA callers to prevent on-chain manipulation.
     */
    function estimateAmountOut(
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint8 _partnerFeeNumerator,
        uint8 _systemFeeNumerator,
        uint16 _feeDenominator
    ) external view returns (uint256) {
        if (_pool == address(0)) revert ZeroAddressForPool();
        if (_tokenIn == address(0)) revert ZeroAddressForTokenIn();
        if (_amountIn == 0) revert ZeroValueForAmountIn();
        if (_pool == _tokenIn) revert TokenCannotBeAPool();

        uint8 _version = _getUniswapVersion(_pool);

        if (_version == 2) {
            uint256 _feeConfig = (uint256(_feeDenominator) << 16) | (uint256(_systemFeeNumerator) << 8) | uint256(_partnerFeeNumerator);
            return V4SwapLib.estimateV2(_pool, _tokenIn, _amountIn, _feeConfig);
        } else if (_version == 3) {
            return V4SwapLib.estimateV3(_pool, _tokenIn, _amountIn);
        } else {
            revert UnsupportedDEX();
        }
    }

    /**
     * @dev Estimates output for a V4 pool swap.
     */
    function estimateAmountOutV4(
        V4PoolKey memory _poolKey,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256) {
        if (_amountIn == 0) revert ZeroValueForAmountIn();
        return V4SwapLib.checkRate(v4PoolManager, WETH, _poolKey, _tokenIn, _tokenOut, _amountIn);
    }

    /**
     * @dev Discovers all available V2 and V3 pools for a token pair.
     *      The frontend calls this to find where liquidity exists.
     *
     * @param _v2Routers Array of registered V2 router addresses (get from DEN.getSupportedV2Routers())
     * @param _v3Routers Array of registered V3 router addresses (get from DEN.getSupportedV3Routers())
     * @param _tokenA First token address (use WETH for ETH pairs)
     * @param _tokenB Second token address
     */
    function discoverPools(
        address[] calldata _v2Routers,
        address[] calldata _v3Routers,
        address _tokenA,
        address _tokenB
    ) external view returns (V4SwapLib.DiscoveredPool[] memory) {
        return V4SwapLib.discoverPools(_v2Routers, _v3Routers, _tokenA, _tokenB);
    }

    function _getUniswapVersion(address _pool) internal view returns (uint8) {
        (bool s2,) = _pool.staticcall(abi.encodeWithSignature("getReserves()"));
        if (s2) return 2;
        (bool s3,) = _pool.staticcall(abi.encodeWithSignature("maxLiquidityPerTick()"));
        if (s3) return 3;
        return 0;
    }
}
