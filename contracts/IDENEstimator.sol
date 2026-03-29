// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V4SwapLib.sol";
import "./interfaces/IV4PoolManager.sol";

interface IDENEstimator {
    struct PendingFeeInfo {
        address token;      // address(0) for ETH
        uint256 systemFees;
        uint256 partnerFees;
    }

    // Single-pool estimation
    function estimateAmountOut(
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint8 _partnerFeeNumerator,
        uint8 _systemFeeNumerator,
        uint16 _feeDenominator
    ) external view returns (uint256);

    function estimateAmountOutV4(
        V4PoolKey memory _poolKey,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256);

    function discoverPools(
        address[] calldata _v2Routers,
        address[] calldata _v3Routers,
        address _tokenA,
        address _tokenB
    ) external view returns (V4SwapLib.DiscoveredPool[] memory);

    // Direction-aware estimation with correct fee handling
    function estimateSwap(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint8 _swapDirection  // 0 = ETH->Token, 1 = Token->ETH, 2 = Token->Token
    ) external view returns (uint256 estimatedOut, uint256 systemFee, uint256 partnerFee);

    function estimateSwapV4(
        V4PoolKey memory _poolKey,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint8 _swapDirection
    ) external view returns (uint256 estimatedOut, uint256 systemFee, uint256 partnerFee);

    // Multi-tier rate shopping (all V3 fee tiers in one call)
    function getBestRateAllTiers(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (
        address routerUsed,
        uint8 versionUsed,
        uint256 highestOut,
        uint256 v4PoolIndex,
        uint24 bestFeeTier
    );

    // Discover all pools including V4
    function discoverAllPools(
        address _tokenA,
        address _tokenB
    ) external view returns (V4SwapLib.DiscoveredPool[] memory);

    // Batch pending fee query
    function getPendingFees(
        address[] calldata _tokens
    ) external view returns (PendingFeeInfo[] memory);
}
