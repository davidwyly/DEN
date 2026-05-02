// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./IDecentralizedExchangeNetwork.sol";
import "./IDENEstimator.sol";
import "./interfaces/IV4PoolManager.sol";

/**
 * @title DENHelper
 * @dev Convenience contract that performs rate shopping and swap execution in a single
 *      transaction. Users interact with DENHelper instead of the DEN contract directly.
 *
 *      Flow: User → DENHelper → (rate shop via Estimator) → (swap via DEN) → User
 *
 *      For token swaps, users approve DENHelper (not DEN). The Helper pulls tokens,
 *      approves DEN, executes the swap, and forwards the output to the user.
 */
contract DENHelper is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IDecentralizedExchangeNetwork public immutable den;
    IDENEstimator public estimator;
    address public immutable WETH;

    // Internal struct to pass routing info without stack pressure
    struct Route {
        address router;
        uint8 version;
        uint256 v4PoolIndex;
        uint24 feeTier;
    }

    error NoLiquidityFound();
    error ZeroAmountIn();
    error ZeroAmountOutMin();
    error InvalidTokenOut();
    error InvalidTokenIn();
    error TokensCannotBeEqual();
    error ETHForwardFailed();
    error DeadlineExpired();
    error InsufficientFinalAmountOut();

    event BestSwap(
        address indexed caller,
        uint8 versionUsed,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address _den, address _estimator) Ownable(msg.sender) {
        den = IDecentralizedExchangeNetwork(_den);
        estimator = IDENEstimator(_estimator);
        WETH = IDecentralizedExchangeNetwork(_den).WETH();
    }

    /**
     * @dev Updates the estimator address. Useful when the estimator is redeployed.
     */
    function setEstimator(address _estimator) external onlyOwner {
        estimator = IDENEstimator(_estimator);
    }

    // ============================================================
    //  SWAP FUNCTIONS
    // ============================================================

    /**
     * @dev Swap ETH for tokens at the best rate across all registered venues.
     */
    function swapETHForBestToken(
        address _tokenOut,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > _deadline) revert DeadlineExpired();
        if (msg.value == 0) revert ZeroAmountIn();
        if (_amountOutMin == 0) revert ZeroAmountOutMin();
        if (_tokenOut == address(0) || _tokenOut == WETH) revert InvalidTokenOut();

        Route memory _route = _rateShop(WETH, _tokenOut, msg.value);

        uint256 _before = IERC20(_tokenOut).balanceOf(address(this));
        _executeETHForToken(_route, _tokenOut, msg.value, _amountOutMin, _deadline);
        uint256 _helperAmountOut = IERC20(_tokenOut).balanceOf(address(this)) - _before;

        uint256 _userBefore = IERC20(_tokenOut).balanceOf(msg.sender);
        IERC20(_tokenOut).safeTransfer(msg.sender, _helperAmountOut);
        amountOut = IERC20(_tokenOut).balanceOf(msg.sender) - _userBefore;
        if (amountOut < _amountOutMin) revert InsufficientFinalAmountOut();
        emit BestSwap(msg.sender, _route.version, WETH, _tokenOut, msg.value, amountOut);
    }

    /**
     * @dev Swap tokens for ETH at the best rate. User must approve this contract.
     */
    function swapTokenForBestETH(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > _deadline) revert DeadlineExpired();
        if (_amountIn == 0) revert ZeroAmountIn();
        if (_amountOutMin == 0) revert ZeroAmountOutMin();
        if (_tokenIn == address(0) || _tokenIn == WETH) revert InvalidTokenIn();

        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);

        Route memory _route = _rateShop(_tokenIn, WETH, _amountIn);

        IERC20(_tokenIn).forceApprove(address(den), _amountIn);
        uint256 _ethBefore = address(this).balance;
        _executeTokenForETH(_route, _tokenIn, _amountIn, _amountOutMin, _deadline);
        amountOut = address(this).balance - _ethBefore;

        (bool _ok,) = payable(msg.sender).call{value: amountOut}("");
        if (!_ok) revert ETHForwardFailed();

        IERC20(_tokenIn).forceApprove(address(den), 0);
        emit BestSwap(msg.sender, _route.version, _tokenIn, WETH, _amountIn, amountOut);
    }

    /**
     * @dev Swap tokens for tokens at the best rate. User must approve this contract.
     *      Neither token can be WETH.
     */
    function swapTokenForBestToken(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > _deadline) revert DeadlineExpired();
        if (_amountIn == 0) revert ZeroAmountIn();
        if (_amountOutMin == 0) revert ZeroAmountOutMin();
        if (_tokenIn == address(0) || _tokenIn == WETH) revert InvalidTokenIn();
        if (_tokenOut == address(0) || _tokenOut == WETH) revert InvalidTokenOut();
        if (_tokenIn == _tokenOut) revert TokensCannotBeEqual();

        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);

        Route memory _route = _rateShop(_tokenIn, _tokenOut, _amountIn);

        IERC20(_tokenIn).forceApprove(address(den), _amountIn);
        uint256 _before = IERC20(_tokenOut).balanceOf(address(this));
        _executeTokenForToken(_route, _tokenIn, _tokenOut, _amountIn, _amountOutMin, _deadline);
        uint256 _helperAmountOut = IERC20(_tokenOut).balanceOf(address(this)) - _before;

        uint256 _userBefore = IERC20(_tokenOut).balanceOf(msg.sender);
        IERC20(_tokenOut).safeTransfer(msg.sender, _helperAmountOut);
        amountOut = IERC20(_tokenOut).balanceOf(msg.sender) - _userBefore;
        if (amountOut < _amountOutMin) revert InsufficientFinalAmountOut();
        IERC20(_tokenIn).forceApprove(address(den), 0);
        emit BestSwap(msg.sender, _route.version, _tokenIn, _tokenOut, _amountIn, amountOut);
    }

    // ============================================================
    //  EMERGENCY FUNCTIONS
    // ============================================================

    function rescueETH() external onlyOwner {
        (bool _ok,) = payable(owner()).call{value: address(this).balance}("");
        if (!_ok) revert ETHForwardFailed();
    }

    function rescueToken(address _token) external onlyOwner {
        IERC20(_token).safeTransfer(owner(), IERC20(_token).balanceOf(address(this)));
    }

    // ============================================================
    //  INTERNAL: Rate shopping
    // ============================================================

    function _rateShop(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) internal view returns (Route memory route) {
        uint256 _bestOut;
        (route.router, route.version, _bestOut, route.v4PoolIndex, route.feeTier)
            = estimator.getBestRateAllTiers(_tokenIn, _tokenOut, _amountIn);
        if (_bestOut == 0) revert NoLiquidityFound();
    }

    // ============================================================
    //  INTERNAL: Pool resolution + DEN execution
    // ============================================================

    function _executeETHForToken(
        Route memory _r,
        address _tokenOut,
        uint256 _ethAmount,
        uint256 _amountOutMin,
        uint256 _deadline
    ) internal {
        if (_r.version == 4) {
            bytes32 _poolId = _resolveV4PoolId(_r.v4PoolIndex);
            den.swapETHForTokenV4{value: _ethAmount}(_poolId, _tokenOut, _amountOutMin, _deadline);
        } else {
            address _pool = _resolveV2V3Pool(_r, WETH, _tokenOut);
            den.swapETHForToken{value: _ethAmount}(_pool, _tokenOut, _amountOutMin, _deadline);
        }
    }

    function _executeTokenForETH(
        Route memory _r,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) internal {
        if (_r.version == 4) {
            bytes32 _poolId = _resolveV4PoolId(_r.v4PoolIndex);
            den.swapTokenForETHV4(_poolId, _tokenIn, _amountIn, _amountOutMin, _deadline);
        } else {
            address _pool = _resolveV2V3Pool(_r, _tokenIn, WETH);
            den.swapTokenForETH(_pool, _tokenIn, _amountIn, _amountOutMin, _deadline);
        }
    }

    function _executeTokenForToken(
        Route memory _r,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 _deadline
    ) internal {
        if (_r.version == 4) {
            bytes32 _poolId = _resolveV4PoolId(_r.v4PoolIndex);
            den.swapTokenForTokenV4(_poolId, _tokenIn, _tokenOut, _amountIn, _amountOutMin, _deadline);
        } else {
            address _pool = _resolveV2V3Pool(_r, _tokenIn, _tokenOut);
            den.swapTokenForToken(_pool, _tokenIn, _tokenOut, _amountIn, _amountOutMin, _deadline);
        }
    }

    function _resolveV2V3Pool(
        Route memory _r,
        address _tokenA,
        address _tokenB
    ) internal view returns (address) {
        if (_r.version == 2) {
            return den.getV2PoolFromRouter(_r.router, _tokenA, _tokenB);
        } else {
            address _factory = IUniswapV2Router02(_r.router).factory();
            return den.getV3PoolFromFactory(_factory, _tokenA, _tokenB, _r.feeTier);
        }
    }

    function _resolveV4PoolId(uint256 _index) internal view returns (bytes32) {
        V4PoolKey[] memory _pools = den.getSupportedV4Pools();
        return den.getV4PoolId(_pools[_index]);
    }

    receive() external payable {}
}
