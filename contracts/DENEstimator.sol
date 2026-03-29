// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V4SwapLib.sol";
import "./interfaces/IV4PoolManager.sol";
import "./IDecentralizedExchangeNetwork.sol";

/**
 * @title DENEstimator
 * @dev View-only contract for price estimation across V2, V3, and V4 pools.
 *      Deployed independently from the main DEN contract to keep it under 24KB.
 *      Used by the UI for quote previews, the DENHelper for on-chain rate shopping,
 *      and partners for monitoring pending fees.
 */
contract DENEstimator {

    error ZeroAddressForPool();
    error ZeroAddressForTokenIn();
    error ZeroValueForAmountIn();
    error TokenCannotBeAPool();
    error UnsupportedDEX();
    error InvalidSwapDirection();

    IDecentralizedExchangeNetwork public immutable den;
    address public immutable WETH;
    address public immutable v4PoolManager;

    struct PendingFeeInfo {
        address token;      // address(0) for ETH
        uint256 systemFees;
        uint256 partnerFees;
    }

    constructor(address _den, address _weth, address _v4PoolManager) {
        den = IDecentralizedExchangeNetwork(_den);
        WETH = _weth;
        v4PoolManager = _v4PoolManager;
    }

    // ============================================================
    //  SINGLE-POOL ESTIMATION
    // ============================================================

    /**
     * @dev Estimates output for a V2 or V3 pool swap.
     *      This is a view function — callable by any address (EOA or contract).
     *      Estimates are spot-price only and do not account for price impact or pending txs.
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
     * @dev Discovers available V2 and V3 pools for a token pair.
     */
    function discoverPools(
        address[] calldata _v2Routers,
        address[] calldata _v3Routers,
        address _tokenA,
        address _tokenB
    ) external view returns (V4SwapLib.DiscoveredPool[] memory) {
        return V4SwapLib.discoverPools(_v2Routers, _v3Routers, _tokenA, _tokenB);
    }

    // ============================================================
    //  DIRECTION-AWARE ESTIMATION
    // ============================================================

    /**
     * @dev Estimates swap output with DEN fees applied correctly based on direction.
     *
     *      Swap directions:
     *        0 = ETH → Token (fees deducted from INPUT before swap)
     *        1 = Token → ETH (fees deducted from OUTPUT after swap)
     *        2 = Token → Token (fees deducted from OUTPUT after swap)
     *
     * @return estimatedOut  Net output after DEN fees
     * @return systemFee     System fee amount
     * @return partnerFee    Partner fee amount
     */
    function estimateSwap(
        address _pool,
        address _tokenIn,
        address, /* _tokenOut — unused for V2/V3 (pool determines pair), kept for interface symmetry with estimateSwapV4 */
        uint256 _amountIn,
        uint8 _swapDirection
    ) external view returns (uint256 estimatedOut, uint256 systemFee, uint256 partnerFee) {
        if (_pool == address(0)) revert ZeroAddressForPool();
        if (_amountIn == 0) revert ZeroValueForAmountIn();
        if (_swapDirection > 2) revert InvalidSwapDirection();

        uint8 _sysFeeNum = den.SYSTEM_FEE_NUMERATOR();
        uint8 _partFeeNum = den.partnerFeeNumerator();
        uint16 _feeDenom = den.FEE_DENOMINATOR();

        uint8 _version = _getUniswapVersion(_pool);
        if (_version == 0) revert UnsupportedDEX();

        if (_swapDirection == 0) {
            // ETH → Token: fees from input
            systemFee = (_amountIn * _sysFeeNum) / _feeDenom;
            partnerFee = (_amountIn * _partFeeNum) / _feeDenom;
            uint256 _effectiveIn = _amountIn - systemFee - partnerFee;
            estimatedOut = _estimateRawOutput(_pool, _version, _tokenIn, _effectiveIn);
        } else {
            // Token → ETH or Token → Token: fees from output
            uint256 _rawOut = _estimateRawOutput(_pool, _version, _tokenIn, _amountIn);
            systemFee = (_rawOut * _sysFeeNum) / _feeDenom;
            partnerFee = (_rawOut * _partFeeNum) / _feeDenom;
            estimatedOut = _rawOut - systemFee - partnerFee;
        }
    }

    /**
     * @dev Estimates V4 swap output with DEN fees applied correctly based on direction.
     */
    function estimateSwapV4(
        V4PoolKey memory _poolKey,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint8 _swapDirection
    ) external view returns (uint256 estimatedOut, uint256 systemFee, uint256 partnerFee) {
        if (_amountIn == 0) revert ZeroValueForAmountIn();
        if (_swapDirection > 2) revert InvalidSwapDirection();

        uint8 _sysFeeNum = den.SYSTEM_FEE_NUMERATOR();
        uint8 _partFeeNum = den.partnerFeeNumerator();
        uint16 _feeDenom = den.FEE_DENOMINATOR();

        if (_swapDirection == 0) {
            systemFee = (_amountIn * _sysFeeNum) / _feeDenom;
            partnerFee = (_amountIn * _partFeeNum) / _feeDenom;
            uint256 _effectiveIn = _amountIn - systemFee - partnerFee;
            estimatedOut = V4SwapLib.checkRate(v4PoolManager, WETH, _poolKey, _tokenIn, _tokenOut, _effectiveIn);
        } else {
            uint256 _rawOut = V4SwapLib.checkRate(v4PoolManager, WETH, _poolKey, _tokenIn, _tokenOut, _amountIn);
            systemFee = (_rawOut * _sysFeeNum) / _feeDenom;
            partnerFee = (_rawOut * _partFeeNum) / _feeDenom;
            estimatedOut = _rawOut - systemFee - partnerFee;
        }
    }

    // ============================================================
    //  MULTI-TIER RATE SHOPPING
    // ============================================================

    /**
     * @dev Finds the best single-hop output across all registered V2 routers,
     *      all V3 routers at all 4 standard fee tiers (100, 500, 3000, 10000),
     *      and all registered V4 pools — in one call.
     *
     * @return routerUsed   The router/PM yielding the best rate
     * @return versionUsed  2, 3, or 4
     * @return highestOut   Best output found
     * @return v4PoolIndex  Index in getSupportedV4Pools() (only valid when versionUsed == 4)
     * @return bestFeeTier  The V3 fee tier that won (only meaningful when versionUsed == 3)
     */
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
    ) {
        if (_amountIn == 0) return (address(0), 0, 0, 0, 0);

        // 1) V2 routers
        address[] memory _v2 = den.getSupportedV2Routers();
        for (uint256 i = 0; i < _v2.length; i++) {
            uint256 _out = V4SwapLib.checkV2Rate(_v2[i], _tokenIn, _tokenOut, _amountIn);
            if (_out > highestOut) {
                highestOut = _out;
                routerUsed = _v2[i];
                versionUsed = 2;
                bestFeeTier = 3000;
            }
        }

        // 2) V3 routers x 4 fee tiers (delegated to reduce stack depth)
        (address _v3Router, uint256 _v3Out, uint24 _v3Tier) = _bestV3Rate(_tokenIn, _tokenOut, _amountIn);
        if (_v3Out > highestOut) {
            highestOut = _v3Out;
            routerUsed = _v3Router;
            versionUsed = 3;
            bestFeeTier = _v3Tier;
        }

        // 3) V4 pools (delegated to reduce stack depth)
        (uint256 _v4Out, uint256 _v4Idx, uint24 _v4Fee) = _bestV4Rate(_tokenIn, _tokenOut, _amountIn);
        if (_v4Out > highestOut) {
            highestOut = _v4Out;
            routerUsed = v4PoolManager;
            versionUsed = 4;
            v4PoolIndex = _v4Idx;
            bestFeeTier = _v4Fee;
        }
    }

    function _bestV3Rate(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) internal view returns (address bestRouter, uint256 bestOut, uint24 bestTier) {
        address[] memory _v3 = den.getSupportedV3Routers();
        uint24[4] memory _tiers = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
        for (uint256 i = 0; i < _v3.length; i++) {
            for (uint256 j = 0; j < 4; j++) {
                uint256 _out = V4SwapLib.checkV3Rate(_v3[i], _tokenIn, _tokenOut, _amountIn, _tiers[j]);
                if (_out > bestOut) {
                    bestOut = _out;
                    bestRouter = _v3[i];
                    bestTier = _tiers[j];
                }
            }
        }
    }

    function _bestV4Rate(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) internal view returns (uint256 bestOut, uint256 bestIdx, uint24 bestFee) {
        V4PoolKey[] memory _v4 = den.getSupportedV4Pools();
        for (uint256 i = 0; i < _v4.length; i++) {
            uint256 _out = V4SwapLib.checkRate(v4PoolManager, WETH, _v4[i], _tokenIn, _tokenOut, _amountIn);
            if (_out > bestOut) {
                bestOut = _out;
                bestIdx = i;
                bestFee = _v4[i].fee;
            }
        }
    }

    // ============================================================
    //  POOL DISCOVERY (V2 + V3 + V4)
    // ============================================================

    /**
     * @dev Discovers all pools for a token pair across V2, V3, and V4 venues
     *      using the DEN's registered routers and pools.
     *      For ETH pairs, pass the WETH address as one of the tokens.
     */
    function discoverAllPools(
        address _tokenA,
        address _tokenB
    ) external view returns (V4SwapLib.DiscoveredPool[] memory) {
        // V2/V3 discovery
        address[] memory _v2 = den.getSupportedV2Routers();
        address[] memory _v3 = den.getSupportedV3Routers();
        V4SwapLib.DiscoveredPool[] memory _v2v3 = V4SwapLib.discoverPools(_v2, _v3, _tokenA, _tokenB);

        // V4 discovery
        V4PoolKey[] memory _v4Pools = den.getSupportedV4Pools();
        // Map WETH to address(0) for native-ETH V4 pool matching
        address _effA = _tokenA;
        address _effB = _tokenB;
        if (_tokenA == WETH) _effA = address(0);
        if (_tokenB == WETH) _effB = address(0);

        // Count V4 matches first
        uint256 _v4Count = 0;
        for (uint256 i = 0; i < _v4Pools.length; i++) {
            if (_matchesV4Pool(_v4Pools[i], _effA, _effB) || _matchesV4Pool(_v4Pools[i], _tokenA, _tokenB)) {
                _v4Count++;
            }
        }

        // Build combined result
        V4SwapLib.DiscoveredPool[] memory _all = new V4SwapLib.DiscoveredPool[](_v2v3.length + _v4Count);
        for (uint256 i = 0; i < _v2v3.length; i++) {
            _all[i] = _v2v3[i];
        }

        uint256 _idx = _v2v3.length;
        for (uint256 i = 0; i < _v4Pools.length; i++) {
            if (_matchesV4Pool(_v4Pools[i], _effA, _effB) || _matchesV4Pool(_v4Pools[i], _tokenA, _tokenB)) {
                _all[_idx] = V4SwapLib.DiscoveredPool({
                    version: 4,
                    poolAddress: address(0),
                    poolId: keccak256(abi.encode(_v4Pools[i])),
                    fee: _v4Pools[i].fee
                });
                _idx++;
            }
        }

        return _all;
    }

    // ============================================================
    //  BATCH PENDING FEE QUERY
    // ============================================================

    /**
     * @dev Returns pending fees for ETH and each specified token in one call.
     *      First element is always ETH (token = address(0)).
     *      Partners can use this to monitor all their accumulated fees.
     */
    function getPendingFees(
        address[] calldata _tokens
    ) external view returns (PendingFeeInfo[] memory) {
        PendingFeeInfo[] memory _result = new PendingFeeInfo[](_tokens.length + 1);

        // ETH fees
        _result[0] = PendingFeeInfo({
            token: address(0),
            systemFees: den.pendingSystemFeesETH(),
            partnerFees: den.pendingPartnerFeesETH()
        });

        // Token fees
        for (uint256 i = 0; i < _tokens.length; i++) {
            _result[i + 1] = PendingFeeInfo({
                token: _tokens[i],
                systemFees: den.pendingSystemFeesToken(_tokens[i]),
                partnerFees: den.pendingPartnerFeesToken(_tokens[i])
            });
        }

        return _result;
    }

    // ============================================================
    //  INTERNAL HELPERS
    // ============================================================

    function _getUniswapVersion(address _pool) internal view returns (uint8) {
        (bool s2,) = _pool.staticcall(abi.encodeWithSignature("getReserves()"));
        if (s2) return 2;
        (bool s3,) = _pool.staticcall(abi.encodeWithSignature("maxLiquidityPerTick()"));
        if (s3) return 3;
        return 0;
    }

    function _estimateRawOutput(
        address _pool,
        uint8 _version,
        address _tokenIn,
        uint256 _amountIn
    ) internal view returns (uint256) {
        if (_version == 2) {
            // Zero-fee config: denominator=10000, systemFee=0, partnerFee=0
            uint256 _noFeeConfig = uint256(10000) << 16;
            return V4SwapLib.estimateV2(_pool, _tokenIn, _amountIn, _noFeeConfig);
        } else {
            return V4SwapLib.estimateV3(_pool, _tokenIn, _amountIn);
        }
    }

    function _matchesV4Pool(V4PoolKey memory _key, address _a, address _b) internal pure returns (bool) {
        return (_key.currency0 == _a && _key.currency1 == _b) ||
               (_key.currency0 == _b && _key.currency1 == _a);
    }
}
