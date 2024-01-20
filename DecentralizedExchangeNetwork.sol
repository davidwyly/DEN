// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./DexCallbackHandler.sol";

/**
@title  Decentralized Exchange Network (DEN)

@author David Wyly, a.k.a. Carc
        x/twitter: CryptoCarc

        Special thanks to DeFi Mark for his contributions

@notice   __|   __|  |    _ _|  _ \   __|  __|    _ \    \     _ \ 
          _|   (     |      |   __/ \__ \  _|     |  |  _ \   (   |
         ___| \___| ____| ___| _|   ____/ ___|   ___/ _/  _\ \___/ 

        Powered By Eclipse
        For more information, please visit: 
        https://eclipsedefi.com
        
Facilitates Uniswap v2/v3 token swaps for our partner:

        All For One, available for iOS and Android
        A product of Decentra, Inc.
        https://allforone.app
        https://decentrasoftware.com

                                 _.,,,===---                                
                          _,,;bSC:"'                                        
                      _,dMARk"'                                             
                   _zAO8P"'                                                 
                ,sRZ88"'                                                    
              ,dKEUP"                                                       
            ,d8NMB"                                                         
           rA8OO"                                                           
         .aE8TO                                                             
        .t2BSB                                                              
       .mAPEP                                                               
      .dALAL"                                         _.                    
      ,RNDCY                                      _,:"                      
      hEUES;                                  _adC'                         
      AEENN:                              _,5x""                            
      RDLLI:                          _,gM;"'                               
      RORIC;                      _,dAO;"'                                  
      YNUVHb |                _,oNE;"'                                      
      "ESEOR.|            _,uSE;"'                                         .
      '7K4LOb|        _,smED;"                                            / 
       'IOAO|||   _,rIMa;"'                                              d' 
        "RS// \\eiNNa;'                                                ,p'  
  ------=<<     >>=------                                            _p;'   
        _,d\\ //DAo,                                               ,a8"'    
     _;P""  ||`hCTIM;,                                           ,eTH"      
  ,a"        | `KGNIDAEr,                                    _,cARc"        
'            |   `'tFYLLEJ;,_                            _,oNETAP"          
             |      `'"$USELESsa,,__              _,,,;lYNXb;"'             
                         `'"aNIREVESMATHIasmmORFSGNITEERG;"'                
                               ``"":;_ECLIPSE_DAO_;:"''                     
*/
contract DecentralizedExchangeNetwork is 
    DexCallbackHandler,
    Ownable, 
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    struct Statistics {
        uint64 swapTokenForETHCount;
        uint64 swapETHForTokenCount;
        uint64 swapTokenForTokenCount;
    }

    // mappings
    mapping ( address => uint256 ) systemFeesCollected;
    mapping ( address => uint256 ) partnerFeesCollected;

    // variables
    uint8 public partnerFeeNumerator = 50; // Numerator for the partner fee percentage, default 0.5%
    address public partner; // Address of the partner who can set partner fees, preferably a multi-sig
    address public systemFeeReceiver; // Address to receive system fees, preferably a multi-sig
    address public partnerFeeReceiver; // Address to receive partner fees, preferably a multi-sig

    // constants
    uint8 constant SYSTEM_FEE_NUMERATOR = 15; // Numerator for the system fee percentage, 0.15%
    uint8 constant MAX_PARTNER_FEE_NUMERATOR = 235; // Maximum partner fee percentage numerator, 2.35%
    uint16 constant FEE_DENOMINATOR = 10000; // Fee denominator for percentage calculation
    
    // structs
    Statistics public statistics;

    // events
    event Swap(
        address indexed caller,
        address indexed pool,
        uint8 uniswapVersion,
        address tokenIn,
        address tokenOut
    );
    event SystemFeeReceiverChanged(
        address indexed caller,
        address indexed oldSystemFeeReceiver,
        address indexed newSystemFeeReceiver
    );
    event PartnerFeeReceiverChanged(
        address indexed caller,
        address indexed oldPartnerFeeReceiver,
        address indexed newPartnerFeeReceiver
    );
    event PartnerFeeNumeratorChanged(
        address indexed caller,
        uint256 oldFeeNumerator,
        uint256 newFeeNumerator
    );
    event PartnershipTransferred(
        address indexed caller,
        address indexed oldPartner,
        address indexed newPartner
    );
    event EmergencyWithdrawETH(
        address indexed caller,
        uint256 amount
    );
    event EmergencyWithdrawToken(
        address indexed caller,
        address token,
        uint256 amount
    );

    // modifiers
    modifier onlyPartner() {
        require(
            msg.sender == partner,
            "Only partner can call this function"
        );
        _;
    }

    ///////////////////
    /// CONSTRUCTOR ///
    ///////////////////

    /**
    * @dev Constructor for the contract
    *
    * @param WETH_ Address of the WETH contract
    * @param partner_ Address of the partner, for more granular access
    * @param systemFeeReceiver_ Address of the system fee receiver
    * @param partnerFeeReceiver_ Address of the partner fee receiver
    */
    constructor(
        address WETH_,
        address partner_,
        address systemFeeReceiver_,
        address partnerFeeReceiver_
    ) {
        require(
            WETH_ != address(0)
            && partner_ != address(0)
            && systemFeeReceiver_ != address(0)
            && partnerFeeReceiver_ != address(0),
            "Zero Address"
        );
        require(
            partnerFeeReceiver != systemFeeReceiver_,
            "Same Address for systemFeeReceiver and partnerFeeReceiver"
        );

        // Set the values
        WETH = WETH_; // immutable assignment of wrapped native coin for deployed network
        partner = partner_; // partner can change with transferPartnership
        systemFeeReceiver = systemFeeReceiver_; // owner can change with setSystemFeeReceiver
        partnerFeeReceiver = partnerFeeReceiver_; // partner can change with setPartnerFeeReceiver
    }

    ///////////////
    /// SETTERS ///
    ///////////////

    /**
    * @dev Sets the system fee receiver address
    *
    * @param _newSystemFeeReceiver The new system fee receiver address to set
    */
    function setSystemFeeReceiver(
        address _newSystemFeeReceiver
    ) external onlyOwner {
        require(
            _newSystemFeeReceiver != address(0),
            "Zero Address"
        );
        require(
            _newSystemFeeReceiver != systemFeeReceiver,
            "No Change"
        );
        require(
            _newSystemFeeReceiver != partnerFeeReceiver,
            "Same as partner fee receiver"
        );
        require(
            _newSystemFeeReceiver != address(this),
            "Same as this contract"
        );

        // Emit an event to notify of the change
        emit SystemFeeReceiverChanged(
            msg.sender,
            systemFeeReceiver,
            _newSystemFeeReceiver
        );

        // Set the new system fee receiver address
        systemFeeReceiver = _newSystemFeeReceiver;
    }

    /**
    * @dev Sets the partner fee numerator
    *
    * @param _newPartnerFeeNumerator The new partner fee numerator to set
    */
    function setPartnerFeeNumerator(
        uint8 _newPartnerFeeNumerator
    ) external onlyPartner {
        require(
            _newPartnerFeeNumerator <= MAX_PARTNER_FEE_NUMERATOR,
            "Fee Too High"
        );
        require(
            _newPartnerFeeNumerator != partnerFeeNumerator,
            "No Change"
        );
        require(
            _newPartnerFeeNumerator != 0,
            "Zero Value"
        );

        // Emit an event to notify of the change
        emit PartnerFeeNumeratorChanged(
            msg.sender, 
            partnerFeeNumerator,
            _newPartnerFeeNumerator
        );

        // Set the new partner fee numerator
        partnerFeeNumerator = _newPartnerFeeNumerator;
    }

    /**
    * @dev Sets the partner fee receiver address
    *
    * @param _newPartnerFeeReceiver The new partner fee receiver address to set
    */
    function setPartnerFeeReceiver(
        address _newPartnerFeeReceiver
    ) external onlyPartner {
        require(
            _newPartnerFeeReceiver != address(0),
            "Zero Address"
        );
        require(
            _newPartnerFeeReceiver != partnerFeeReceiver,
            "No Change"
        );
        require(
            _newPartnerFeeReceiver != systemFeeReceiver,
            "Same as system fee receiver"
        );
        require(
            _newPartnerFeeReceiver != address(this),
            "Same as this contract"
        );

        // Emit an event to notify of the change
        emit PartnerFeeReceiverChanged(
            msg.sender,
            partnerFeeReceiver,
            _newPartnerFeeReceiver
        );

        // Set the new partner fee receiver address
        partnerFeeReceiver = _newPartnerFeeReceiver;
    }

    /**
    * @dev Transfers the partnership to a new partner
    *
    * @param _newPartner The new partner address to set
    */
    function transferPartnership(
        address _newPartner
    ) external onlyPartner {
        require(
            _newPartner != address(0),
            "Zero Address"
        );
        require(
            _newPartner != partner,
            "No Change"
        );

        emit PartnershipTransferred(
            msg.sender,
            partner,
            _newPartner
        );

        // Set the new partner address
        partner = _newPartner;
    }

    ///////////////////////////////
    /// EXTERNAL SWAP FUNCTIONS ///
    ///////////////////////////////

    /**
    * @dev Main function to swap ETH for tokens
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenOut The address of the output token
    * @param _amountOutMin The minimum amount of output tokens to receive
    */
    function swapETHForToken (
        address _pool,
        address _tokenOut,
        uint256 _amountOutMin
    ) external payable nonReentrant {
        /**
        * note: External parameter checks are performed downstream
        */
        executeSwapETHForToken(
            _pool,
            _tokenOut,
            _amountOutMin,
            partnerFeeNumerator
        );
    }

    /**
    * @dev Main function to swap ETH for tokens with a custom partner fee
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenOut The address of the output token
    * @param _amountOutMin The minimum amount of output tokens to receive
    * @param _customPartnerFeeNum The custom partner fee numerator to use
    */
    function swapETHForTokenWithCustomFee(
        address _pool,
        address _tokenOut,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum
    ) external payable nonReentrant {
        /**
        * note: External parameter checks are performed downstream
        */
        executeSwapETHForToken(
            _pool,
            _tokenOut,
            _amountOutMin,
            _customPartnerFeeNum
        );
    }

    /**
    * @dev Main function to swap tokens for ETH
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenIn The address of the input token
    * @param _amountIn The amount of input tokens to swap
    * @param _amountOutMin The minimum amount of ETH to receive
    */
    function swapTokenForETH (
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin
    ) external nonReentrant {
       /**
        * note: External parameter checks are performed downstream
        */
        executeSwapTokenForETH(
            _pool,
            _tokenIn,
            _amountIn,
            _amountOutMin,
            partnerFeeNumerator
        );
    }

    /**
    * @dev Main function to swap tokens for ETH with a custom partner fee
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenIn The address of the input token
    * @param _amountIn The amount of input tokens to swap
    * @param _amountOutMin The minimum amount of ETH to receive
    * @param _customPartnerFeeNum The custom partner fee numerator to use
    */
    function swapTokenForETHWithCustomFee (
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum
    ) external nonReentrant {
        /**
        * note: External parameter checks are performed downstream
        */
        executeSwapTokenForETH(
            _pool,
            _tokenIn,
            _amountIn,
            _amountOutMin,
            _customPartnerFeeNum
        );
    }

    /**
    * @dev Main function to swap tokens for tokens
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of input tokens to swap
    * @param _amountOutMin The minimum amount of output tokens to receive
    */
    function swapTokenForToken (
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin
    ) external nonReentrant {
        /**
        * note: External parameter checks are performed downstream
        */
        executeSwapTokenForToken(
            _pool,
            _tokenIn,
            _tokenOut,
            _amountIn,
            _amountOutMin,
            partnerFeeNumerator
        );
    }

    /**
    * @dev Main function to swap tokens for tokens with a custom partner fee
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of input tokens to swap
    * @param _amountOutMin The minimum amount of output tokens to receive
    * @param _customPartnerFeeNum The custom partner fee numerator to use
    */
    function swapTokenForTokenWithCustomFee (
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum
    ) external nonReentrant {
        /**
        * note: External parameter checks are performed downstream
        */
        executeSwapTokenForToken(
            _pool,
            _tokenIn,
            _tokenOut,
            _amountIn,
            _amountOutMin,
            _customPartnerFeeNum
        );
    }

    //////////////////
    /// SWAP SETUP ///
    //////////////////

    /**
    * @dev Swap ETH for tokens
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenOut The address of the output token
    * @param _amountOutMin The minimum amount of output tokens to receive
    * @param _partnerFeeNumerator The partner fee numerator to use
    */
    function executeSwapETHForToken(
        address _pool,
        address _tokenOut,
        uint256 _amountOutMin,
        uint8 _partnerFeeNumerator
    ) internal {

        /**
        * @dev Logic flow:
        *      - The caller pays ETH to this contract
        *      - ETH System fees are sent to the system receiver
        *      - ETH Partner fees are sent to the partner receiver
        *      - The remaining ETH is wrapped to WETH
        *      - This WETH is sent to the pool
        *      - The pool swaps the WETH for the output token
        *      - The output tokens are sent directly to the caller
        *
        * note: External parameter checks are performed downstream
        */

        require(
            _amountOutMin > 0,
            "Zero Value for amountOutMin"
        );
        require(
            msg.value > 0,
            "Zero Value for msg.value"
        );
        require(
            _tokenOut != WETH,
            "Cannot have WETH as tokenOut, use swapTokenForETH instead"
        );

        // Handle the fees on the payed amount
        (   uint256 _systemFee,
            uint256 _partnerFee) = getFees(msg.value, _partnerFeeNumerator);

        // Update statistics
        unchecked {
            statistics.swapETHForTokenCount++;
            systemFeesCollected[WETH] += _systemFee;
            partnerFeesCollected[WETH] += _partnerFee;
        }

        // Calculate the amount of ETH to swap by subtracting the fees
        uint256 _amountInLessFees = msg.value - (_systemFee + _partnerFee);

        // Send the system fees to the system receiver
        _sendETH(systemFeeReceiver, _systemFee);

        // Send the partner fees to the partner receiver
        _sendETH(partnerFeeReceiver, _partnerFee);

        // Wrap the remaining ETH to WETH in preparation for the swap
        IWETH(WETH).deposit{value: _amountInLessFees}();

        // Execute the swap
        // amountOut is the amount of tokens received by the sender
        uint256 _amountOut = _executeSwap(
            _pool,
            WETH,               // tokenIn is WETH  
            _tokenOut,          
            _amountInLessFees,  // msg.value less fees
            address(this),      // payer is this contract which is paying with WETH
            msg.sender          // recipient is the sender who will receive the tokens
        );

        // Verify the amount of output tokens received from the swap
        if (_amountOut < _amountOutMin) {
            revert("Received less than minimum");
        }
    }

    /**
    * @dev Swap tokens for ETH
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenIn The address of the input token
    * @param _amountIn The amount of input tokens to swap
    * @param _amountOutMin The minimum amount of ETH to receive
    * @param _partnerFeeNumerator The partner fee numerator to use
    */
    function executeSwapTokenForETH(
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _partnerFeeNumerator
    ) internal {

        /**
        * @dev Logic flow:
        *      - The caller needs to approve this contract to spend their tokens
        *      - Input tokens are pulled from the caller and directly swapped for WETH
        *      - The contract receives the WETH
        *      - WETH is unwrapped to ETH
        *      - System fees are sent to the system receiver
        *      - Partner fees are sent to the partner receiver
        *      - The remaining ETH is sent to the caller
        * 
        * note: External parameter checks are performed downstream
        */

        require(
            _tokenIn != WETH,
            "Cannot have WETH as tokenIn, use swapETHForToken instead"
        );
        require(
            _amountOutMin > 0,
            "Zero Value for amountOutMin"
        );

        // Set WETH into memory to avoid repeated SLOADs
        address _WETH = WETH;

        // Execute the swap
        // amountOut is the amount of WETH received by this contract
        uint256 _amountOut = _executeSwap(
            _pool,
            _tokenIn,
            _WETH,           // tokenOut is WETH
            _amountIn,
            msg.sender,     // payer is the sender who is paying with tokens
            address(this)   // recipient is this contract which will receive the WETH
        ); 

        // Handle the fees on the received WETH amount in this contract
        (   uint256 _systemFee,
            uint256 _partnerFee) = getFees(_amountOut, _partnerFeeNumerator);

        // Update statistics
        unchecked {
            statistics.swapTokenForETHCount++;
            systemFeesCollected[_WETH] += _systemFee;
            partnerFeesCollected[_WETH] += _partnerFee;
        }

        // Verify the amount of output WETH received from the swap
        uint256 _amountOutAfterTax = _amountOut - (_systemFee + _partnerFee);
        if (_amountOutAfterTax < _amountOutMin) {
            revert("Received less than minimum");
        }

        // Unwrap the wrapped ETH
        IWETH(_WETH).withdraw(_amountOut);
        
        // Send the system fees to the system receiver
        _sendETH(systemFeeReceiver, _systemFee);

        // Send the partner fees to the partner receiver
        _sendETH(partnerFeeReceiver, _partnerFee);

        // Send the rest to the sender
        _sendETH(msg.sender, _amountOutAfterTax);
    }

    /**
    * @dev Swap tokens for tokens
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of input tokens to swap
    * @param _amountOutMin The minimum amount of output tokens to receive
    * @param _partnerFeeNumerator The partner fee numerator to use
    */
    function executeSwapTokenForToken(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _partnerFeeNumerator
    ) internal {

        /**
        * @dev Logic flow:
        *      - The caller needs to approve this contract to spend their tokens
        *      - Input tokens are pulled from the caller and directly swapped for tokens
        *      - The contract receives the output tokens
        *      - System fees are sent to the system receiver
        *      - Partner fees are sent to the partner receiver
        *      - The remaining output tokens are sent to the caller
        *
        * note: Parameter checks are performed downstream
        */

        // Set WETH into memory to avoid repeated SLOADs
        address _WETH = WETH;

        require(
            _amountOutMin > 0,
            "Zero Value for amountOutMin"
        );
        require(
            _tokenIn != _WETH,
            "Cannot have WETH as tokenIn, use swapETHForToken instead"
        );
        require(
            _tokenOut != _WETH,
            "Cannot have WETH as tokenOut, use swapTokenForETH instead"
        );

        // Execute the swap
        // amountOut is the amount of tokens received by this contract
        uint256 _amountOut = _executeSwap(
            _pool,
            _tokenIn,
            _tokenOut,
            _amountIn,
            msg.sender,     // payer is the sender who is paying with tokens
            address(this)   // recipient is this contract which will receive the tokens
        ); 

        // Handle the fees
        (   uint256 _systemFee,
            uint256 _partnerFee) = getFees(_amountOut, _partnerFeeNumerator);

        // Update statistics
        unchecked {
            statistics.swapTokenForTokenCount++;
            systemFeesCollected[_tokenOut] += _systemFee;
            partnerFeesCollected[_tokenOut] += _partnerFee;
        }

        // Verify the amount of output tokens received from the swap
        uint256 _amountOutAfterTax = _amountOut - (_systemFee + _partnerFee);
        if (_amountOutAfterTax < _amountOutMin) {
            revert("Received less than minimum");
        }
        
        // Transfer the system fees to the system receiver
        IERC20(_tokenOut).safeTransfer(systemFeeReceiver, _systemFee);

        // Transfer the partner fees to the partner receiver
        IERC20(_tokenOut).safeTransfer(partnerFeeReceiver, _partnerFee);

        // Transfer the rest to the sender
        IERC20(_tokenOut).safeTransfer(msg.sender, _amountOutAfterTax);
    }

    /**
    * @dev Given an address for a Uniswap pool, determines its Uniswap version (if any)
    *
    * @param _pool The address of the Uniswap pool
    * @return _uniswapVersion The Uniswap version of the pool (2, 3) or 0 if it's not a Uniswap pool
    */
    function getUniswapVersion(address _pool) public view returns (uint8 _uniswapVersion) {
        require(
            _pool != address(0),
            "Zero Address"
        );

        // Check for Uniswap V2 function
        try IUniswapV2Pair(_pool).getReserves() {
            return 2;
        } catch {}

        // Check for Uniswap V3 function
        try IUniswapV3Pool(_pool).maxLiquidityPerTick() {
            return 3;
        } catch {}

        // If the pool is not for a Uniswap v2 or v3 DEX, return 0
        return 0;
    }

    /**
    * @dev Calculates the fees to be deducted from a given amount, based on system/partner fee percentages
    *
    *      note: - Partner fees are passed in as a parameter to allow for custom partner fees
    *            - The partner application routes user transactions through this contract
    *            - The partner fee numerator is capped at 2.35% to prevent abuse
    *            - The partner fee numerator may be set to 0 to disable partner fees
    *            - Anyone can use this system and set the partner fee to 0
    *            - The system fee is hardcoded to 0.15% and is not customizable
    *            - This constraint is intentional as it avoids fee uncertainty for the partner
    *            
    * @param _amount The amount to calculate fees for
    * @param _partnerFeeNumerator The partner fee percentage to use, if any
    * @return _systemFee The system fee, calculated as a fraction of the amount
    * @return _partnerFee The partner fee, calculated as a fraction of the amount
    */
    function getFees(
        uint256 _amount,
        uint8 _partnerFeeNumerator
    ) public pure returns (
        uint256 _systemFee,
        uint256 _partnerFee
    ) {
        require (
            _partnerFeeNumerator <= MAX_PARTNER_FEE_NUMERATOR,
            "Partner fee too high"
        );

        // Calculate the system fee as a fraction of the amount, based on the systemFeeNumerator and FEE_DENOMINATOR
        _systemFee = (_amount * SYSTEM_FEE_NUMERATOR) / FEE_DENOMINATOR;
        
        // Calculate the partner fee as a fraction of the amount, based on the partnerFeeNumerator and FEE_DENOMINATOR
        _partnerFee = (_amount * _partnerFeeNumerator) / FEE_DENOMINATOR;
        
        // Return the system fee and partner fee as a tuple
        return (_systemFee, _partnerFee);
    }

    //////////////////
    /// SWAP LOGIC ///
    //////////////////

    /**
    * @dev Internal function of unified logic to execute a swap
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of input tokens to swap
    * @param _payer The address paying the input tokens
    * @param _recipient The address receiving the output tokens
    * @return _amountOut The amount of output tokens received
    */
    function _executeSwap(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        address _payer,
        address _recipient
    ) internal returns (uint256 _amountOut) {
        require(
            currentSwapPool == address(0),
            "Another swap is in progress"
        );
        require(
            _pool != address(0)
            && _tokenIn != address(0)
            && _tokenOut != address(0),
            // _payer and _recipient are not checked because they set upstream
            "Zero Address"
        );
        require(
            _amountIn > 0,
            "Zero Value for amountIn"
        );
        require(
            _tokenIn != _tokenOut,
            "Tokens cannot be equal"
        );
        require(
            _pool != _tokenIn 
            && _pool != _tokenOut,
            "Pool cannot be a token"
        );
        require(
            _pool != msg.sender
            && _tokenIn != msg.sender
            && _tokenOut != msg.sender,
            // there is no foreseeable case where these addresses should ever be msg.sender
            // this is a sanity check to gate off unexpected behavior
            "Address cannot be msg.sender"
        );
        require(
            _pool != address(this)
            && _tokenIn != address(this)
            && _tokenOut != address(this),
            // there is no foreseeable case where these addresses should ever be this contract
            // this is a sanity check to gate off unexpected behavior
            "Address cannot be this contract"
        );
        require(
            IERC20(_tokenIn).balanceOf(_payer) >= _amountIn,
            "Insufficient token balance"
        );
        if (_payer != address(this)) {
            require(
                IERC20(_tokenIn).allowance(_payer, address(this)) >= _amountIn,
                "Insufficient token allowance"
            );
        }

        // Determine the Uniswap version
        uint8 _uniswapVersion = getUniswapVersion(_pool);

        // Emit an event to notify of the swap
        emit Swap(
            msg.sender,
            _pool,
            _uniswapVersion,
            _tokenIn,
            _tokenOut
        );

        // Determine the amount of output tokens before the swap
        uint256 _before = IERC20(_tokenOut).balanceOf(_recipient);
        
        // Execute the swap
        if (_uniswapVersion == 2) {
            _executeSwapV2(_pool, _tokenIn, _tokenOut, _amountIn, _payer, _recipient);
        } else if (_uniswapVersion == 3) {
            _executeSwapV3(_pool, _tokenIn, _tokenOut, _amountIn, _payer, _recipient);
        } else {
            revert("Unsupported DEX");
        }

        // Calculate the amount of output tokens received
        return IERC20(_tokenOut).balanceOf(_recipient) - _before;
    }

    /**
    * @dev Generalized function to swap tokens on Uniswap v2.
    *
    * @param _pool The address of the Uniswap v2 pool
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of the input token to swap
    * @param _payer The address paying the input tokens
    * @param _recipient The address receiving the output tokens
    */
    function _executeSwapV2(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        address _payer,
        address _recipient
    ) internal {
        IUniswapV2Pair _v2Pool = IUniswapV2Pair(_pool);
        require(
            _isValidV2TokenPool(_v2Pool, _tokenIn, _tokenOut),
            "Invalid tokens for V2 pair"
        );

        // When the payer is not this contract, pull tokens from the payer to the pool
        if (_payer != address(this)) {
            IERC20(_tokenIn).safeTransferFrom(_payer, address(_v2Pool), _amountIn);

        // Otherwise, we just transfer the tokens from this contract to the pool
        } else { 
            IERC20(_tokenIn).safeTransfer(address(_v2Pool), _amountIn);
        }
        
        uint256 _amount0Out;
        uint256 _amount1Out;
        {
            // Sort to determine input/output
            (address _token0,) = _sortTokens(_tokenIn, _tokenOut);

            // Get the reserves of the pool
            (   uint256 _reserve0,
                uint256 _reserve1,) = _v2Pool.getReserves();

            // Determine reserve directionality
            (   uint256 _reserveInput, 
                uint256 _reserveOutput) = 
                    (_tokenIn == _token0)
                        ? (_reserve0, _reserve1)
                        : (_reserve1, _reserve0);

            // Calculate the amount of output tokens
            uint256 _amountInput = IERC20(_tokenIn).balanceOf(address(_v2Pool)) - _reserveInput;
            uint256 _amountOutput = _getAmountOut(_amountInput, _reserveInput, _reserveOutput);
            
            // Determine output swap parameters
            if (_tokenIn == _token0) {
                _amount0Out = 0;
                _amount1Out = _amountOutput;
            } else {
                _amount0Out = _amountOutput;
                _amount1Out = 0;
            }
        }

        _v2Pool.swap(
            _amount0Out,
            _amount1Out,
            _recipient,
            new bytes(0)
        );
    }

    /**
    * @dev Generalized function to swap tokens on Uniswap v3.
    *
    * @param _pool The address of the Uniswap v3 pool
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of the input token to swap
    * @param _payer The address paying the input tokens
    * @param _recipient The address receiving the output tokens
    */
    function _executeSwapV3(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        address _payer,
        address _recipient
    ) internal {
        IUniswapV3Pool _v3Pool = IUniswapV3Pool(_pool);
        
        // Validation and Direction Logic
        if (!_isValidV3TokenPool(_v3Pool, _tokenIn, _tokenOut)) {
            revert("Invalid tokens for V3 pool");
        }

        bool _zeroForOne = 
            (_tokenIn == _v3Pool.token0())
                ? true
                : false;

        uint160 _sqrtPriceLimitX96 =
            (_zeroForOne) 
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1;

        int256 _amountSpecified =
            (_zeroForOne) 
                ? int256(_amountIn) 
                : int256(_amountIn) * -1;

        // Prepare the callback data
        bytes memory _data = abi.encode(_tokenIn, _payer);

        // Set the current pool to the pool that is being used for the swap
        // This is used to verify that the callback received is from the correct pool
        currentSwapPool = address(_v3Pool);

        _v3Pool.swap(
            _recipient,
            _zeroForOne,
            _amountSpecified,
            _sqrtPriceLimitX96,
            _data
        );

        /* 
        * Gas optimization note:
        * - It's less expensive in terms of gas to change a storage variable from one non-zero value 
        *   to another (5,000 gas) than it is to set it from zero to a non-zero value (20,000 gas).
        * - Conversely, when setting a non-zero storage variable to zero, we get a 10,000 gas refund. 
        * - By not resetting `currentSwapPool` to zero after each swap, we avoid the higher 20,000 gas
        *   cost in subsequent swaps, achieving a net savings of 5,000 gas.
        */
    }

    /////////////////////////////////
    /// EXTERNAL HELPER FUNCTIONS ///
    /////////////////////////////////

    /**
    * @dev Checks whether a given pool is supported by the contract
    * This may not be fully accurate, but it means that this contract will attempt the swap
    *
    * @param _pool The address of the Uniswap pool
    * @return bool Whether the pool is supported by the contract
    */
    function isPoolSupported(address _pool) external view returns (bool) {
        uint8 _uniswapVersion = getUniswapVersion(_pool);
        return (
            _uniswapVersion == 2 
            || _uniswapVersion == 3
        );
    }

    /**
    * @dev For a Uniswapv2 router and a pair of tokens, returns the address of the pool
    *
    * @param _router The address of the Uniswap router
    * @param _token0 The address of the first token
    * @param _token1 The address of the second token
    * @return _pool The address of the pool
    */
    function getV2PoolFromRouter(
        address _router,
        address _token0,
        address _token1
    ) external view returns (address _pool) {
        require(
            _router != address(0),
            "Zero Address for router"
        );
        require(
            _token0 != address(0),
            "Zero Address for token"
        );
        require(
            _token1 != address(0),
            "Zero Address for token"
        );
        require(
            _token0 != _token1,
            "Same token"
        );
        address _factory = IUniswapV2Router02(_router).factory();
        return IUniswapV2Factory(_factory).getPair(_token0, _token1);
    }

    /**
    * @dev Estimates the amount of output tokens that will be received for a given input amount
    *
    * note: This function should not be relied upon in on-chain decision-making to avoid potential 
    *       manipulation. Front-runners can observe the pending transaction and manipulate the pool's price
    *       with flash loans, resulting in an inaccurate estimation when the transaction is mined.
    *       Due to this, restrictions have been put in place to prevent contracts from calling this function.
    *
    * @param _pool The address of the Uniswap pool
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of input tokens to swap
    * @return _amountOut The estimated amount of output tokens to receive
    */
    function estimateAmountOut(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256 _amountOut) {
        require(
            !_isContract(msg.sender),
            "Contracts may not call this function"
        );
        require(
            _pool != address(0),
            "Zero Address for pool"
        );
        require(
            _tokenIn != address(0),
            "Zero Address for tokenIn"
        );
        require(
            _tokenOut != address(0),
            "Zero Address for tokenOut"
        );
        require(
            _tokenIn != _tokenOut,
            "Tokens cannot be equal"
        );
        require(
            _amountIn > 0,
            "Zero Value for amountIn"
        );
        require(
            _pool != _tokenIn 
            && _pool != _tokenOut,
            "Token cannot be pool"
        );
        require(
            _pool != msg.sender,
            "Pool cannot be sender"
        );
        require(
            _tokenIn != msg.sender,
            "TokenIn cannot be sender"
        );
        require(
            _tokenOut != msg.sender,
            "TokenOut cannot be sender"
        );

        uint8 _uniswapVersion = getUniswapVersion(_pool);
        if (_uniswapVersion == 2) {
            return _estimateAmountOutV2(_pool, _tokenIn, _tokenOut, _amountIn);
        } else if (_uniswapVersion == 3) {
            return _estimateAmountOutV3(_pool, _tokenIn, _tokenOut, _amountIn);
        } else {
            revert("Unsupported DEX");
        }
    }

    /////////////////////////////////
    /// INTERNAL HELPER FUNCTIONS ///
    /////////////////////////////////

        /**
    * @dev Determines if the given address is a contract.
    * 
    * note: Caveats:
    *       - 'false' for a contract in construction
    *       - 'false' for an address where a contract will be created
    *       - 'false' for an address where a contract once existed but was destroyed
    *
    * @param _address Address to check.
    * @return bool True if the address hosts contract code.
    */
    function _isContract(address _address) internal view returns (bool) {
        uint32 _size;
        assembly {
            _size := extcodesize(_address)
        }
        return (_size > 0);
    }

    /**
    * @dev Estimates the amount of output tokens that will be received for a given input amount on Uniswap v2
    *
    * @param _pool The address of the Uniswap V2 pool
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of input tokens to swap
    * @return _amountOut The estimated amount of output tokens to receive
    */
    function _estimateAmountOutV2(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) internal view returns (uint256 _amountOut) {
        IUniswapV2Pair _v2Pool = IUniswapV2Pair(_pool);
        require(
            _isValidV2TokenPool(_v2Pool, _tokenIn, _tokenOut),
            "Invalid tokens for V2 pair"
        );

        (   uint256 _reserve0,
            uint256 _reserve1,) = _v2Pool.getReserves();

        (   uint256 _reserveInput,
            uint256 _reserveOutput) = 
                (_tokenIn == _v2Pool.token0()) 
                    ? (_reserve0, _reserve1)
                    : (_reserve1, _reserve0);
        
        // Emulating the token transfer to the pool to get the virtual input amount
        uint256 virtualAmountInput = IERC20(_tokenIn).balanceOf(address(_v2Pool)) + _amountIn - _reserveInput;
        
        return _getAmountOut(virtualAmountInput, _reserveInput, _reserveOutput);
    }

    /**
    * @dev Estimates the amount of output tokens that will be received for a given input amount on Uniswap v3
    *
    * @param _pool The address of the Uniswap V3 pool
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of input tokens to swap
    * @return _amountOut The estimated amount of output tokens to receive
    */
    function _estimateAmountOutV3(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) internal view returns (uint256 _amountOut) {
        IUniswapV3Pool _v3Pool = IUniswapV3Pool(_pool);
        require(
            _isValidV3TokenPool(_v3Pool, _tokenIn, _tokenOut),
            "Invalid tokens for V3 pool"
        );

        // Get the current price of the pool
        (uint160 _sqrtPriceX96,,,,,,) = _v3Pool.slot0();

        uint8 _decimalsTokenIn = IERC20Decimals(_tokenIn).decimals();
        uint8 _decimalsTokenOut = IERC20Decimals(_tokenOut).decimals();

        // Calculate squared price keeping as much precision as possible
        uint256 _squaredPriceX96 = _sqrtPriceX96 * _sqrtPriceX96;

        // Order of operations matters here to avoid overflow
        uint256 _tmpPrice = (_squaredPriceX96 / (2**96)) * (10**_decimalsTokenIn) / (10**_decimalsTokenOut);

        // If _tokenIn isn't pool.token0(), we need the inverse of the price
        if (_tokenIn != _v3Pool.token0()) {
            require(_tmpPrice > 0, "Divide by Zero");
            // Inverse the price and adjust for potential 1e36 multiplication
            _tmpPrice = (1e36 / _tmpPrice) / (10**(_decimalsTokenIn + _decimalsTokenOut)); 
        }

        return _amountIn * _tmpPrice;
    }

    /**
    * @dev Given an input amount, calculates the output amount based on the reserves in a v2 liquidity pool
    *
    * @param _amountIn The input amount
    * @param _reserveIn The reserve amount of the input token
    * @param _reserveOut The reserve amount of the output token
    * @return _amountOut The output amount, calculated based on the input amount and the reserve amounts of the tokens
    */
    function _getAmountOut(
        uint256 _amountIn, 
        uint256 _reserveIn, 
        uint256 _reserveOut
    ) internal view returns (uint256 _amountOut) {
        // Ensure that the input amount is greater than zero
        require(
            _amountIn > 0,
            'Insufficient input amount'
        );
        
        // Ensure that both reserves are greater than zero
        require(
            _reserveIn > 0 
            && _reserveOut > 0,
            'Insufficient liquidity'
        );
        
        // Calculate the input amount with the fee deducted
        uint256 _amountInWithFee = _amountIn * (FEE_DENOMINATOR - (partnerFeeNumerator + SYSTEM_FEE_NUMERATOR));
        
        // Calculate the numerator of the output amount equation
        uint256 _numerator = _amountInWithFee * _reserveOut;
        
        // Calculate the denominator of the output amount equation
        uint256 _denominator = (_reserveIn * FEE_DENOMINATOR) - _amountInWithFee;
        require(
            _denominator > 0,
            'Divide by zero'
        );
        
        // Calculate the output amount based on the input amount and the reserve amounts of the tokens
        return _numerator / _denominator;
    }

    /**
    * @dev Sends a specified amount of Ether (ETH) from the contract to the specified receiver's address
    *
    * @param _receiver The address of the receiver of the ETH
    * @param _amount The amount of ETH to be sent
    */
    function _sendETH(address _receiver, uint256 _amount) internal {
        // Check that the contract has enough ETH balance to send
        require(
            address(this).balance >= _amount,
            'Insufficient ETH balance'
        );
        
        // Transfer the specified amount of ETH to the receiver's address
        (bool success,) = payable(_receiver).call{value: _amount}("");
        require(
            success, 'Send ETH To Recipient Failed'
        );
    }

    /**
    * @dev Given two ERC20 tokens, returns them in the order that they should be sorted in for use in other functions
    *
    * @param _tokenA The first token address
    * @param _tokenB The second token address
    * @return _token0 The address of the first token, sorted alphabetically
    * @return _token1 The address of the second token, sorted alphabetically
    */
    function _sortTokens(
        address _tokenA,
        address _tokenB
    ) internal pure returns (
        address _token0,
        address _token1
    ) {
        // Ensure that the two token addresses are not identical
        require(
            _tokenA != _tokenB,
            'Identical token addresses'
        );
        
        // Sort the two token addresses alphabetically and return them
        (_token0, _token1) = 
            (_tokenA < _tokenB) 
                ? (_tokenA, _tokenB)
                : (_tokenB, _tokenA);
        
        // Ensure that the first token address is not the zero address
        require(
            _token0 != address(0),
            'Zero addres'
        );
    }

    /**
    * @dev Given a Uniswap v2 pool and two ERC20 tokens, determines whether the pool is valid for the given tokens
    *
    * @param pool The address of the Uniswap v2 pool
    * @param tokenA The address of the first token
    * @param tokenB The address of the second token
    * @return bool Whether the pool is valid for the given tokens
    */
    function _isValidV2TokenPool(
        IUniswapV2Pair pool,
        address tokenA,
        address tokenB
    ) internal view returns (bool) {
        address _token0 = pool.token0();
        address _token1 = pool.token1();
        return (
            (tokenA == _token0 
                && tokenB == _token1) 
            || (tokenA == _token1 
                && tokenB == _token0)
        );
    }

    /**
    * @dev Given a Uniswap v3 pool and two ERC20 tokens, determines whether the pool is valid for the given tokens
    *
    * @param pool The address of the Uniswap v3 pool
    * @param tokenA The address of the first token
    * @param tokenB The address of the second token
    * @return bool Whether the pool is valid for the given tokens
    */
    function _isValidV3TokenPool(
        IUniswapV3Pool pool,
        address tokenA,
        address tokenB
    ) internal view returns (bool) {
        address _token0 = pool.token0();
        address _token1 = pool.token1();
        return (
            (tokenA == _token0 
                && tokenB == _token1) 
            || (tokenA == _token1 
                && tokenB == _token0)
        );
    }

    ///////////////////////////
    /// EMERGENCY FUNCTIONS ///
    ///////////////////////////

    /**
    * @dev Emergency function to withdraw ETH accidentally stuck in the contract
    */
    function emergencyWithdrawETH() external nonReentrant onlyOwner {
        uint256 _balance = address(this).balance;
        require(
            _balance > 0,
            "No ETH to withdraw"
        );
        _sendETH(msg.sender, _balance);
        emit EmergencyWithdrawETH(
            msg.sender,
            _balance
        );
    }

    /**
    * @dev Emergency function to withdraw ERC20 tokens accidentally stuck in the contract
    *
    * @param _token The address of the ERC20 token to withdraw
    */
    function emergencyWithdrawToken(address _token) external nonReentrant onlyOwner {
        uint256 _balance = IERC20(_token).balanceOf(address(this));
        require(
            _balance > 0,
            "No tokens to withdraw"
        );
        IERC20(_token).safeTransfer(msg.sender, _balance);
        emit EmergencyWithdrawToken(
            msg.sender,
            _token,
            _balance
        );
    }

    //////////////////////////
    /// BASE FUNCTIONALITY ///
    //////////////////////////
    
    receive() external payable {}
}