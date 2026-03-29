// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
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

            uint256 _squaredPrice = uint256(_sqrtPriceX96) * uint256(_sqrtPriceX96);
            uint256 _price0to1 = FullMath.mulDiv(_squaredPrice, 1e18, 1 << 192);

            uint256 _rawPrice;
            if (_effectiveIn == _poolKey.currency0) {
                _rawPrice = _price0to1;
            } else {
                if (_price0to1 == 0) return 0;
                _rawPrice = FullMath.mulDiv(1e18, 1e18, _price0to1);
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
        uint256 _denominator = (_rIn * 1000) + _withPoolFee;
        return (_withPoolFee * _rOut) / _denominator;
    }

    /**
     * @dev Estimates output on a Uniswap V3 pool using sqrtPriceX96.
     */
    function estimateV3(
        address _pool,
        address _tokenIn,
        uint256 _amountIn
    ) public view returns (uint256) {
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
        uint256 _denominator = (_reserveIn * _denom) - _withFee;
        if (_denominator == 0) return 0;
        return (_withFee * _reserveOut) / _denominator;
    }

    /**
     * @dev Determines Uniswap version of a pool (2, 3, or 0 for unknown).
     */
    function getUniswapVersion(address _pool) external view returns (uint8) {
        try IUniswapV2Pair(_pool).getReserves() { return 2; } catch {}
        try IUniswapV3Pool(_pool).maxLiquidityPerTick() { return 3; } catch {}
        return 0;
    }

    // ============================================================
    //  Rate shopping helpers (moved from main contract for size)
    // ============================================================

    function checkV2Rate(
        address _router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256) {
        if (_router == address(0) || _amountIn == 0) return 0;
        address[] memory _path = new address[](2);
        _path[0] = _tokenIn;
        _path[1] = _tokenOut;
        try IUniswapV2Router02(_router).getAmountsOut(_amountIn, _path) returns (uint256[] memory _amounts) {
            return _amounts[1];
        } catch {
            return 0;
        }
    }

    function checkV3Rate(
        address _router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint24 _fee
    ) external view returns (uint256) {
        if (_router == address(0) || _amountIn == 0) return 0;
        address _factory;
        try IUniswapV2Router02(_router).factory() returns (address f) {
            _factory = f;
        } catch {
            return 0;
        }
        try IUniswapV3Factory(_factory).getPool(_tokenIn, _tokenOut, _fee) returns (address _pool) {
            if (_pool == address(0)) return 0;
            return estimateV3(_pool, _tokenIn, _amountIn);
        } catch {
            return 0;
        }
    }

    // ============================================================
    //  Pool discovery — find pools for a token pair across venues
    // ============================================================

    struct DiscoveredPool {
        uint8 version;       // 2, 3, or 4
        address poolAddress; // V2/V3 pool address (address(0) for V4)
        bytes32 poolId;      // V4 pool ID (bytes32(0) for V2/V3)
        uint24 fee;          // pool fee tier
    }

    /**
     * @dev Finds all available pools for a token pair across registered V2 routers and V3 factories.
     *      Returns up to maxResults pools. The frontend calls this to discover where liquidity exists.
     *
     * @param _v2Routers   Array of registered V2 router addresses
     * @param _v3Routers   Array of registered V3 router addresses (SwapRouter with factory() method)
     * @param _tokenA      First token (use WETH address for ETH pairs)
     * @param _tokenB      Second token
     * @return pools       Array of discovered pools with version, address, and fee info
     */
    function discoverPools(
        address[] memory _v2Routers,
        address[] memory _v3Routers,
        address _tokenA,
        address _tokenB
    ) external view returns (DiscoveredPool[] memory pools) {
        // Pre-allocate max possible: v2Routers + v3Routers*4 fee tiers
        uint256 _maxPools = _v2Routers.length + (_v3Routers.length * 4);
        DiscoveredPool[] memory _results = new DiscoveredPool[](_maxPools);
        uint256 _count = 0;

        // Check V2 routers
        for (uint256 i = 0; i < _v2Routers.length; i++) {
            try IUniswapV2Router02(_v2Routers[i]).factory() returns (address _factory) {
                try IUniswapV2Factory(_factory).getPair(_tokenA, _tokenB) returns (address _pair) {
                    if (_pair != address(0)) {
                        _results[_count] = DiscoveredPool(2, _pair, bytes32(0), 3000);
                        _count++;
                    }
                } catch {}
            } catch {}
        }

        // Check V3 routers at common fee tiers
        uint24[4] memory _feeTiers = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
        for (uint256 i = 0; i < _v3Routers.length; i++) {
            try IUniswapV2Router02(_v3Routers[i]).factory() returns (address _factory) {
                for (uint256 j = 0; j < 4; j++) {
                    try IUniswapV3Factory(_factory).getPool(_tokenA, _tokenB, _feeTiers[j]) returns (address _pool) {
                        if (_pool != address(0)) {
                            _results[_count] = DiscoveredPool(3, _pool, bytes32(0), _feeTiers[j]);
                            _count++;
                        }
                    } catch {}
                }
            } catch {}
        }

        // Copy to correctly-sized array
        pools = new DiscoveredPool[](_count);
        for (uint256 i = 0; i < _count; i++) {
            pools[i] = _results[i];
        }
    }
}
