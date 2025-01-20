// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// OpenZeppelin
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap v2
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

// Uniswap v3
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "./IWETH.sol";

import "./IERC20Decimals.sol";


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
    * 0x4200000000000000000000000000000000000006 (Wrapped ETH on Base)
    */
    address public WETH; // chain-specific WETH address

    address internal currentSwapPool; // Address of the pool currently mid-swap

    fallback() external payable {
        // If there is no data or not enough data, revert early.
        // Each V3-like callback typically has >=68 bytes: 
        // 4-byte selector + (int256 + int256 + bytes offset).
        if (msg.data.length < 68) {
            revert("Not enough data for a V3 callback");
        }

        // 1. Decode the arguments (skipping the first 4 bytes which is the function selector).
        (int256 amount0Delta, int256 amount1Delta, bytes memory data) = abi.decode(
            msg.data[4:], 
            (int256, int256, bytes)
        );

        // 2. Enforce your checks:
        if (msg.sender != currentSwapPool) {
            revert("Unauthorized callback");
        }
        if (amount0Delta <= 0 && amount1Delta <= 0) {
            revert("No tokens received");
        }

        // 3. Decode your custom `_data` – typically `(tokenIn, payer)`.
        if (data.length < 64) {
            revert("Missing inner callback data");
        }
        (address tokenIn, address payer) = abi.decode(data, (address, address));
        if (tokenIn == address(0)) {
            revert("Invalid tokenIn");
        }
        if (payer == address(0)) {
            revert("Invalid payer");
        }

        // 4. Figure out how many tokens we owe the pool:
        uint256 amountToPay = amount0Delta > 0
            ? uint256(amount0Delta)
            : uint256(amount1Delta);

        // 5. Pay the pool. (Calls the same `_pay` logic you already wrote.)
        _pay(tokenIn, payer, msg.sender, amountToPay);
    }


    function _pay(
        address _tokenIn,
        address _payer,
        address _recipient,
        uint256 _amountToPay
    ) internal {
        // If the payer is this contract, then we send the tokens to the pool from this contract
        if (_payer == address(this)) {
            // Load WETH into memory to reduce extra SLOAD
            address _WETH = WETH;
            
            // Special handling for WETH: if we have enough raw ETH sitting in the contract,
            // convert it to WETH before transferring
            if (_tokenIn == _WETH && address(this).balance >= _amountToPay) {
                // Deposit raw ETH into WETH
                IWETH(_WETH).deposit{value: _amountToPay}();
            }
            
            // Verify that this contract has enough of _tokenIn after potentially wrapping
            uint256 balance = IERC20(_tokenIn).balanceOf(address(this));
            if (balance < _amountToPay) {
                revert("Contract has insufficient token balance");
            }

            // Transfer the tokens from this contract to the recipient (the pool)
            IERC20(_tokenIn).safeTransfer(_recipient, _amountToPay);

        } else {
            // If the payer is not this contract, transfer from the payer's wallet

            // Check that the payer has enough tokens
            uint256 payerBalance = IERC20(_tokenIn).balanceOf(_payer);
            if (payerBalance < _amountToPay) {
                revert("Payer has insufficient token balance");
            }

            // Check that the payer has approved this contract to spend the required amount
            uint256 allowed = IERC20(_tokenIn).allowance(_payer, address(this));
            if (allowed < _amountToPay) {
                revert("Payer has insufficient token allowance");
            }

            // Transfer the tokens from payer to the recipient (the pool)
            IERC20(_tokenIn).safeTransferFrom(_payer, _recipient, _amountToPay);
        }
    }

    receive() external payable {}
}