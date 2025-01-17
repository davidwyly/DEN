// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IDecentralizedExchangeNetwork {
    function WETH() external view returns (address);
    function partnerFeeNumerator() external view returns (uint8);
    function PARTNER_FEE_DENOMINATOR() external view returns (uint16);
    function SYSTEM_FEE_NUMERATOR() external view returns (uint8);
    function SYSTEM_FEE_DENOMINATOR() external view returns (uint16);

    function isPoolSupported(address _pool) external view returns (bool);

    function getV2PoolFromRouter(address _router, address _token0, address _token1) external view returns (address);
    function getV3PoolFromFactory(address _factory, address _token0, address _token1, uint24 _fee) external view returns (address);

    function estimateAmountOut(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256 _amountOut);

    function swapETHForToken (
        address _pool,
        address _tokenOut,
        uint256 _amountOutMin
    ) external payable returns (uint256 amountOut);
}