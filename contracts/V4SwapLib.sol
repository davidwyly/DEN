// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./interfaces/IV4PoolManager.sol";
import "./FullMath.sol";

/**
 * @title V4SwapLib
 * @dev External library for Uniswap V4 swap operations.
 *      Deployed as a separate contract — its bytecode does NOT count toward
 *      the DEN contract's 24 KB Spurious Dragon limit.
 *
 *      All public/external functions use DELEGATECALL when invoked from
 *      the main contract, so `address(this)` and storage context belong
 *      to the calling DEN contract.
 */
library V4SwapLib {
    using SafeERC20 for IERC20;

    uint256 internal constant V4_POOLS_SLOT = 6;

    /**
     * @dev Computes the V4 pool ID from a pool key.
     */
    function computePoolId(V4PoolKey memory _poolKey) external pure returns (bytes32) {
        return keccak256(abi.encode(_poolKey));
    }

    /**
     * @dev Returns the sqrtPriceLimitX96 for a V3/V4 swap direction.
     */
    function getSqrtPriceLimitX96(bool _zeroForOne) external pure returns (uint160) {
        return _zeroForOne
            ? 4295128739 + 1
            : 1461446703485210103287273052203988822378723970342 - 1;
    }

    /**
     * @dev Estimates output from a V4 pool by reading sqrtPriceX96 via extsload.
     *      Handles WETH ↔ native ETH equivalence automatically.
     *
     * @return Estimated output amount, or 0 on failure.
     */
    function checkRate(
        address _v4PoolManager,
        address _weth,
        V4PoolKey memory _poolKey,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256) {
        if (_v4PoolManager == address(0) || _amountIn == 0) return 0;

        // Map WETH to address(0) for native-ETH V4 pools
        address _effectiveIn = _tokenIn;
        address _effectiveOut = _tokenOut;
        bool _poolHasNativeETH = (_poolKey.currency0 == address(0) || _poolKey.currency1 == address(0));
        if (_tokenIn == _weth && _poolHasNativeETH) _effectiveIn = address(0);
        if (_tokenOut == _weth && _poolHasNativeETH) _effectiveOut = address(0);

        // Verify the pool contains both tokens
        bool _validPair = (
            (_effectiveIn == _poolKey.currency0 && _effectiveOut == _poolKey.currency1) ||
            (_effectiveIn == _poolKey.currency1 && _effectiveOut == _poolKey.currency0)
        );
        if (!_validPair) return 0;

        // Read sqrtPriceX96 from PM via extsload
        bytes32 _poolId = keccak256(abi.encode(_poolKey));
        try IV4PoolManager(_v4PoolManager).extsload(
            keccak256(abi.encode(_poolId, V4_POOLS_SLOT))
        ) returns (bytes32 _slot0Data) {
            uint160 _sqrtPriceX96;
            assembly {
                _sqrtPriceX96 := and(_slot0Data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            }
            if (_sqrtPriceX96 == 0) return 0;

            uint256 _sq = uint256(_sqrtPriceX96) * uint256(_sqrtPriceX96);
            uint256 _p = FullMath.mulDiv(_sq, 1e18, 1 << 192);

            uint256 _rawPrice;
            if (_effectiveIn == _poolKey.currency0) {
                _rawPrice = _p;
            } else {
                if (_p == 0) return 0;
                _rawPrice = FullMath.mulDiv(1e18, 1e18, _p);
            }

            return FullMath.mulDiv(_amountIn, _rawPrice, 1e18);
        } catch {
            return 0;
        }
    }

    // ============================================================
    //  V2 / V3 estimation helpers (external to reduce main contract size)
    // ============================================================

    /**
     * @dev Estimates output on a Uniswap V2 pool.
     *      @param _feeConfig Packed: uint16 denominator | uint8 systemFee | uint8 partnerFee
     */
    function estimateV2(
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _feeConfig
    ) external view returns (uint256) {
        IUniswapV2Pair _v2 = IUniswapV2Pair(_pool);
        (uint256 _r0, uint256 _r1,) = _v2.getReserves();

        (uint256 _rIn, uint256 _rOut) = (_tokenIn == _v2.token0())
            ? (_r0, _r1) : (_r1, _r0);

        if (_amountIn == 0 || _rIn == 0 || _rOut == 0) return 0;

        // Deduct DEN fees first: _feeConfig = feeDenom << 16 | systemFee << 8 | partnerFee
        uint256 _denom = _feeConfig >> 16;
        uint256 _totalFee = ((_feeConfig >> 8) & 0xFF) + (_feeConfig & 0xFF);
        uint256 _afterDENFees = _amountIn * (_denom - _totalFee) / _denom;

        // Then apply standard V2 pool fee (0.3% = 997/1000)
        uint256 _withPoolFee = _afterDENFees * 997;
        uint256 _d = (_rIn * 1000) + _withPoolFee;
        return (_withPoolFee * _rOut) / _d;
    }

    /**
     * @dev Estimates output on a Uniswap V3 pool using sqrtPriceX96.
     */
    function estimateV3(
        address _pool,
        address _tokenIn,
        uint256 _amountIn
    ) external view returns (uint256) {
        IUniswapV3Pool _v3 = IUniswapV3Pool(_pool);
        (uint160 _sqrtPriceX96, , , , , , ) = _v3.slot0();
        uint256 _sq = uint256(_sqrtPriceX96) * uint256(_sqrtPriceX96);
        uint256 _p = FullMath.mulDiv(_sq, 1e18, 1 << 192);

        uint256 _raw;
        if (_tokenIn == _v3.token0()) {
            _raw = _p;
        } else {
            if (_p == 0) return 0;
            _raw = FullMath.mulDiv(1e18, 1e18, _p);
        }

        return FullMath.mulDiv(_amountIn, _raw, 1e18);
    }

    /**
     * @dev Validates a V2 pool contains the expected token pair.
     */
    function isValidV2Pool(
        address _pool,
        address _tokenA,
        address _tokenB
    ) external view returns (bool) {
        address _t0 = IUniswapV2Pair(_pool).token0();
        address _t1 = IUniswapV2Pair(_pool).token1();
        return (_tokenA == _t0 && _tokenB == _t1) || (_tokenA == _t1 && _tokenB == _t0);
    }

    /**
     * @dev Validates a V3 pool contains the expected token pair.
     */
    function isValidV3Pool(
        address _pool,
        address _tokenA,
        address _tokenB
    ) external view returns (bool) {
        address _t0 = IUniswapV3Pool(_pool).token0();
        address _t1 = IUniswapV3Pool(_pool).token1();
        return (_tokenA == _t0 && _tokenB == _t1) || (_tokenA == _t1 && _tokenB == _t0);
    }

    /**
     * @dev Sorts two token addresses canonically.
     */
    function sortTokens(address _a, address _b) external pure returns (address _t0, address _t1) {
        (_t0, _t1) = (_a < _b) ? (_a, _b) : (_b, _a);
    }

    /**
     * @dev V2 output calculation given reserves and fee configuration.
     */
    function getAmountOut(
        uint256 _amountIn,
        uint256 _reserveIn,
        uint256 _reserveOut,
        uint256 _feeConfig
    ) external pure returns (uint256) {
        if (_amountIn == 0 || _reserveIn == 0 || _reserveOut == 0) return 0;
        uint256 _denom = _feeConfig >> 16;
        uint256 _totalFee = ((_feeConfig >> 8) & 0xFF) + (_feeConfig & 0xFF);
        uint256 _withFee = _amountIn * (_denom - _totalFee);
        uint256 _d = (_reserveIn * _denom) - _withFee;
        if (_d == 0) return 0;
        return (_withFee * _reserveOut) / _d;
    }
}
