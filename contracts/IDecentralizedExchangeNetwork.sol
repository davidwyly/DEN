// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IV4PoolManager.sol";

interface IDecentralizedExchangeNetwork {
    function WETH() external view returns (address);
    function partnerFeeNumerator() external view returns (uint8);
    function SYSTEM_FEE_NUMERATOR() external view returns (uint8);
    function FEE_DENOMINATOR() external view returns (uint16);

    // Pool support
    function isV4PoolSupported(bytes32 _poolId) external view returns (bool);

    // Pool lookups
    function getV2PoolFromRouter(address _router, address _token0, address _token1) external view returns (address);
    function getV3PoolFromFactory(address _factory, address _token0, address _token1, uint24 _fee) external view returns (address);
    function getV4PoolId(V4PoolKey memory _poolKey) external pure returns (bytes32);

    // V2/V3 swaps
    function swapETHForToken(
        address _pool,
        address _tokenOut,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external payable returns (uint256 amountOut);

    function swapETHForTokenWithCustomFee(
        address _pool,
        address _tokenOut,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum,
        uint256 _deadline
    ) external payable returns (uint256 amountOut);

    function swapTokenForETH(
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external returns (uint256 amountOut);

    function swapTokenForETHWithCustomFee(
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum,
        uint256 _deadline
    ) external returns (uint256 amountOut);

    function swapTokenForToken(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external returns (uint256 amountOut);

    function swapTokenForTokenWithCustomFee(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum,
        uint256 _deadline
    ) external returns (uint256 amountOut);

    // V4 swaps
    function swapETHForTokenV4(
        bytes32 _poolId,
        address _tokenOut,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external payable;

    function swapETHForTokenV4WithCustomFee(
        bytes32 _poolId,
        address _tokenOut,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum,
        uint256 _deadline
    ) external payable;

    function swapTokenForETHV4(
        bytes32 _poolId,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external;

    function swapTokenForETHV4WithCustomFee(
        bytes32 _poolId,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum,
        uint256 _deadline
    ) external;

    function swapTokenForTokenV4(
        bytes32 _poolId,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external;

    function swapTokenForTokenV4WithCustomFee(
        bytes32 _poolId,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum,
        uint256 _deadline
    ) external;

    // Router/pool management
    function getSupportedV2Routers() external view returns (address[] memory);
    function getSupportedV3Routers() external view returns (address[] memory);
    function getSupportedV4Pools() external view returns (V4PoolKey[] memory);
    function getSupportedV4PoolCount() external view returns (uint256);

    function addV2Router(address _router) external;
    function removeV2Router(uint256 _index) external;
    function addV3Router(address _router) external;
    function removeV3Router(uint256 _index) external;
    function setV4PoolManager(address _v4PoolManager) external;
    function addV4Pool(V4PoolKey calldata _poolKey) external;
    function removeV4Pool(uint256 _index) external;

    // Rate shopping
    function checkV4Rate(
        V4PoolKey memory _poolKey,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256);

    function getBestRate(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint24 _feeTier
    ) external view returns (
        address _routerUsed,
        uint8 _versionUsed,
        uint256 _highestOut,
        uint256 _v4PoolIndex
    );
}
