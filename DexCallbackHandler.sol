// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// OpenZeppelin
import "lib/OpenZeppelin/utils/ReentrancyGuard.sol";
import "lib/OpenZeppelin/access/Ownable.sol";
import "lib/OpenZeppelin/token/ERC20/IERC20.sol";
import "lib/OpenZeppelin/token/ERC20/SafeERC20.sol";
import "lib/Uniswap/v3-core/interfaces/IUniswapV3Pool.sol";

// Uniswap v2
import "lib/Uniswap/v2-core/interfaces/IUniswapV2Factory.sol";
import "lib/Uniswap/v2-core/interfaces/IUniswapV2Pair.sol";
import "lib/Uniswap/v2-periphery/interfaces/IUniswapV2Router02.sol";

// Uniswap v3
import "lib/Uniswap/v3-core/interfaces/IUniswapV3Factory.sol";
import "lib/Uniswap/v3-periphery/interfaces/ISwapRouter.sol";
import "lib/Uniswap/v3-core/interfaces/IUniswapV3Pool.sol";
import "lib/Uniswap/v3-core/libraries/TickMath.sol";

interface IWETH {
    function flashMinted() external view returns(uint256);
    function deposit() external payable;
    function depositTo(address to) external payable;
    function withdraw(uint256 value) external;
    function withdrawTo(address payable to, uint256 value) external;
    function withdrawFrom(address from, address payable to, uint256 value) external;
    function depositToAndCall(address to, bytes calldata data) external payable returns (bool);
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
    function transferAndCall(address to, uint value, bytes calldata data) external returns (bool);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/**
* @dev Abstract contract for handling callbacks from Uniswap-based V3 pools
*/
abstract contract DexCallbackHandler {
    using SafeERC20 for IERC20;

    /** 
    * @dev Wrapped native coins reference:
    *
    * 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 (Wrapped ETH)
    * 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c (Wrapped BSC)
    * 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270 (Wrapped MATIC)
    * 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7 (Wrapped AVAX)
    * 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83 (Wrapped FTM)
    * 0xcF664087a5bB0237a0BAd6742852ec6c8d69A27a (Wrapped ONE)
    * 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 (Wrapped Arbitrum)
    */
    address public WETH; // chain-specific WETH address

    address internal currentSwapPool; // Address of the pool currently mid-swap

    /**
    * @dev Callback for Uniswap V3 pool
    *
    * @param _amount0Delta The amount of token0 required to send to the pool
    * @param _amount1Delta The amount of token1 required to send to the pool
    */
    function uniswapV3SwapCallback(
        int256 _amount0Delta,
        int256 _amount1Delta,
        bytes calldata _data
    ) public {
        require(
            msg.sender == currentSwapPool,
            "Unauthorized callback"
        );
        require(
            (_amount0Delta > 0 
            || _amount1Delta > 0),
            "No tokens received"
        );
        require(
            _data.length > 0,
            "No callback data"
        );
        
        // Decode the callback data
        (   address _tokenIn,
            address _payer) = abi.decode(_data, (address, address));

        require(
            _tokenIn != address(0),
            "Invalid token"
        );
        require(
            _payer != address(0),
            "Invalid payer"
        );

        // Get the token that was received
        uint256 _amountToPay = 
            (_amount0Delta > 0) 
                ? uint256(_amount0Delta) 
                : uint256(_amount1Delta);

        // Pay the pool
        pay(_tokenIn, _payer, msg.sender, _amountToPay);
    }

    /**
    * @dev Pay a recipient
    *
    * @param _tokenIn The token to send
    * @param _payer The address that is paying
    * @param _recipient The address that is receiving
    * @param _amountToPay The amount of tokens to pay
    */
    function pay(
        address _tokenIn,
        address _payer,
        address _recipient,
        uint256 _amountToPay
    ) private {
        // If the payer is this contract, then we send the tokens to the pool from this contract
        if (_payer == address(this)) {

            // Load WETH into memory to reduce SLOAD costs
            address _WETH = WETH; 
            
            // Special handling for WETH
            if (_tokenIn == _WETH
                && address(this).balance >= _amountToPay
            ) {
                // If we have enough ETH, convert the ETH into WETH
                IWETH(_WETH).deposit{value: _amountToPay}();
            }
            
            // Verify that this contract has enough tokens
            // At this point, any ETH has been converted to WETH
            if (IERC20(_tokenIn).balanceOf(address(this)) < _amountToPay) {
                revert("Contract has insufficient token balance");
            }

            // Transfer the tokens to the pool
            IERC20(_tokenIn).safeTransfer(_recipient, _amountToPay);

        // If the payer is not this contract, then we send the tokens to the pool from the payer
        } else {

            // Verify that the payer has enough tokens
            if (IERC20(_tokenIn).balanceOf(_payer) < _amountToPay) {
                revert("Payer has insufficient token balance");
            }

            // Verify that the payer has approved this contract to spend their tokens
            if (IERC20(_tokenIn).allowance(_payer, address(this)) < _amountToPay) {
                revert("Payer has insufficient token allowance");
            }

            // Transfer the tokens to the pool
            IERC20(_tokenIn).safeTransferFrom(_payer, _recipient, _amountToPay);
        }
    }

    /**
    * @dev Callback for Pancakeswap V3 pool
    *
    * @param _amount0Delta The amount of token0 required to send to the pool
    * @param _amount1Delta The amount of token1 required to send to the pool
    * @param _data The callback data
    */
    function pancakeV3SwapCallback(
        int256 _amount0Delta,
        int256 _amount1Delta,
        bytes calldata _data
    ) external {
       uniswapV3SwapCallback(_amount0Delta, _amount1Delta, _data);
    }

    /**
    * @dev Callback for Quickswap/Algebra V3 pool
    *
    * @param _amount0Delta The amount of token0 required to send to the pool
    * @param _amount1Delta The amount of token1 required to send to the pool
    * @param _data The callback data
    */
    function algebraSwapCallback(
        int256 _amount0Delta,
        int256 _amount1Delta,
        bytes calldata _data
    ) external {
       uniswapV3SwapCallback(_amount0Delta, _amount1Delta, _data);
    }

    /**
    * @dev Callback for FusionX V3 pool
    *
    * @param _amount0Delta The amount of token0 required to send to the pool
    * @param _amount1Delta The amount of token1 required to send to the pool
    * @param _data The callback data
    */
    function fusionXV3SwapCallback(
        int256 _amount0Delta,
        int256 _amount1Delta,
        bytes calldata _data
    ) external {
       uniswapV3SwapCallback(_amount0Delta, _amount1Delta, _data);
    }

    /**
    * @dev Callback for Beamswap V3 pool
  *
    * @param _amount0Delta The amount of token0 required to send to the pool
    * @param _amount1Delta The amount of token1 required to send to the pool
    * @param _data The callback data
    */
    function beamswapV3SwapCallback(
        int256 _amount0Delta,
        int256 _amount1Delta,
        bytes calldata _data
    ) external {
       uniswapV3SwapCallback(_amount0Delta, _amount1Delta, _data);
    }

    /**
    * @dev Callback for Kyberswap V3 pool
  *
    * @param _amount0Delta The amount of token0 required to send to the pool
    * @param _amount1Delta The amount of token1 required to send to the pool
    * @param _data The callback data
    */
    function swapCallback(
        int256 _amount0Delta,
        int256 _amount1Delta,
        bytes calldata _data
    ) external {
       uniswapV3SwapCallback(_amount0Delta, _amount1Delta, _data);
    }
}