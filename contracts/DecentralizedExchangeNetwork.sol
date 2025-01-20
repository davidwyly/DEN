// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DexCallbackHandler.sol";
import "./FullMath.sol";
import "hardhat/console.sol";

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

    address[] public supportedV2Routers;
    address[] public supportedV3Routers;

    // variables
    address public partner; // Address of the partner who can set partner fees, preferably a multi-sig
    address public systemFeeReceiver; // Address to receive system fees, preferably a multi-sig
    address public partnerFeeReceiver; // Address to receive partner fees, preferably a multi-sig
    uint8 public partnerFeeNumerator = 50; // Numerator for the partner fee percentage, default 0.5%

    // constants
    uint8 public constant SYSTEM_FEE_NUMERATOR = 15; // Numerator for the system fee percentage, 0.15%
    uint8 public constant MAX_PARTNER_FEE_NUMERATOR = 235; // Maximum partner fee percentage numerator, 2.35%
    uint16 public constant FEE_DENOMINATOR = 10000; // Fee denominator for percentage calculation
    
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
    event SystemFeesCollectedOverflow(
        address indexed token
    );
    event PartnerFeesCollectedOverflow(
        address indexed token
    );
    event V2RouterAdded(
        address indexed router
    );
    event V3RouterAdded(
        address indexed router
    );
    event V2RouterRemoved(
        address indexed router
    );
    event V3RouterRemoved(
        address indexed router
    );

    error OnlyPartnerAllowed();
    error ZeroAddress();
    error SameAddress();
    error NoChange();
    error SameAsPartnerFeeReceiver();
    error SameAsThisContract();
    error ZeroValueForAmountOutMin();
    error ZeroValueForMsgValue();
    error CannotHaveWETHAsTokenOut();
    error FeeTooHigh();
    error ZeroValue();
    error SameAsSystemFeeReceiver();
    error CannotHaveWETHAsTokenIn();
    error PartnerFeeTooHigh();
    error AnotherSwapInProgress();
    error ZeroValueForAmountIn();
    error TokensCannotBeEqual();
    error PoolCannotBeAToken();
    error AddressCannotBeMsgSender();
    error AddressCannotBeThisContract();
    error InsufficientTokenBalance();
    error InsufficientTokenAllowance();
    error InvalidTokensForV2Pair();
    error ZeroAddressForRouter();
    error ZeroAddressForToken0();
    error ZeroAddressForToken1();
    error SameToken();
    error ContractsMayNotCallThisFunction();
    error ZeroAddressForPool();
    error ZeroAddressForTokenIn();
    error ZeroAddressForTokenOut();
    error TokenCannotBeAPool();
    error PoolCannotBeSender();
    error TokenInCannotBeSender();
    error TokenOutCannotBeSender();
    error InvalidTokensForV3Pool();
    error DivideByZero();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InsufficientETHBalance();
    error SendETHToRecipientFailed();
    error IdenticalTokenAddresses();
    error NoETHToWithdraw();
    error NoTokensToWithdraw();
    error IndexOutOfRange();

    // modifiers
    modifier onlyPartner() {
        if (_msgSender() != partner) {
            revert OnlyPartnerAllowed();
        }
        _;
    }

    ///////////////////
    /// CONSTRUCTOR ///
    ///////////////////

    /**
    * @dev Constructor for the contract
    *
    * @param _WETH Address of the WETH contract
    * @param _partner Address of the partner, for more granular access
    * @param _systemFeeReceiver Address of the system fee receiver
    * @param _partnerFeeReceiver Address of the partner fee receiver
    * @param _partnerFeeNumerator Numerator for the partner fee percentage
    */
    constructor(
        address _WETH,
        address _partner,
        address _systemFeeReceiver,
        address _partnerFeeReceiver,
        uint8 _partnerFeeNumerator
    ) Ownable(_msgSender()) {
        if (
            _WETH == address(0) ||
            _partner == address(0) ||
            _systemFeeReceiver == address(0) ||
            _partnerFeeReceiver == address(0)
        ) {
            revert ZeroAddress();
        }

        if (_partnerFeeReceiver == _systemFeeReceiver) {
            revert SameAddress();
        }

        // Set the values
        WETH = _WETH; // immutable assignment of wrapped native coin for deployed network
        partner = _partner; // partner can change with transferPartnership
        systemFeeReceiver = _systemFeeReceiver; // owner can change with setSystemFeeReceiver
        partnerFeeReceiver = _partnerFeeReceiver; // partner can change with setPartnerFeeReceiver
        partnerFeeNumerator = _partnerFeeNumerator; // partner can change with setPartnerFeeNumerator
    }

    function addV2Router(address _router) public onlyOwner {
        if (_router == address(0)) {
            revert ZeroAddress();
        }
        if (supportedV2Routers.length > 0) {
            for (uint256 i = 0; i < supportedV2Routers.length; i++) {
                if (supportedV2Routers[i] == _router) {
                    revert NoChange();
                }
            }
        }
        supportedV2Routers.push(_router);
        emit V2RouterAdded(_router);
    }

    function removeV2Router(uint256 _index) external onlyOwner {
        if (supportedV2Routers.length == 0) {
            revert NoChange();
        }
        if (_index > supportedV2Routers.length) {
            revert IndexOutOfRange();
        }
        address _removedRouter = supportedV2Routers[_index];
        supportedV2Routers[_index] = supportedV2Routers[
            supportedV2Routers.length - 1
        ];
        supportedV2Routers.pop();
        emit V2RouterRemoved(_removedRouter);
    }

    function addV3Router(address _router) public onlyOwner {
        if (_router == address(0)) {
            revert ZeroAddress();
        }
        if (supportedV3Routers.length > 0) {
            for (uint256 i = 0; i < supportedV3Routers.length; i++) {
                if (supportedV3Routers[i] == _router) {
                    revert NoChange();
                }
            }
        }
        supportedV3Routers.push(_router);
        emit V3RouterAdded(_router);
    }

    function removeV3Router(uint256 _index) external onlyOwner {
        if (supportedV3Routers.length == 0) {
            revert NoChange();
        }
        if (_index > supportedV3Routers.length) {
            revert IndexOutOfRange();
        }
        address _removedRouter = supportedV3Routers[_index];
        supportedV3Routers[_index] = supportedV3Routers[
            supportedV3Routers.length - 1
        ];
        supportedV3Routers.pop();
        emit V3RouterRemoved(_removedRouter);
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

        if (_newSystemFeeReceiver == address(0)) {
            revert ZeroAddress();
        }
        if (_newSystemFeeReceiver == systemFeeReceiver) {
            revert NoChange();
        }
        if (_newSystemFeeReceiver == partnerFeeReceiver) {
            revert SameAsPartnerFeeReceiver();
        }
        if (_newSystemFeeReceiver == address(this)) {
            revert SameAsThisContract();
        }

        // Emit an event to notify of the change
        emit SystemFeeReceiverChanged(
            _msgSender(),
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

        if (_newPartnerFeeNumerator > MAX_PARTNER_FEE_NUMERATOR) {
            revert FeeTooHigh();
        }
        if (_newPartnerFeeNumerator == partnerFeeNumerator) {
            revert NoChange();
        }
        if (_newPartnerFeeNumerator == 0) {
            revert ZeroValue();
        }

        // Emit an event to notify of the change
        emit PartnerFeeNumeratorChanged(
            _msgSender(), 
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

        if (_newPartnerFeeReceiver == address(0)) {
            revert ZeroAddress();
        }
        if (_newPartnerFeeReceiver == partnerFeeReceiver) {
            revert NoChange();
        }
        if (_newPartnerFeeReceiver == systemFeeReceiver) {
            revert SameAsSystemFeeReceiver();
        }
        if (_newPartnerFeeReceiver == address(this)) {
            revert SameAsThisContract();
        }

        // Emit an event to notify of the change
        emit PartnerFeeReceiverChanged(
            _msgSender(),
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
        if (_newPartner == address(0)) {
            revert ZeroAddress();
        }
        if (_newPartner == partner) {
            revert NoChange();
        }

        emit PartnershipTransferred(
            _msgSender(),
            partner,
            _newPartner
        );

        // Set the new partner address
        partner = _newPartner;
    }

    /////////////////////
    /// RATE SHOPPING ///
    /////////////////////

    function checkV2Rate(
        address _router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) public view returns (uint256) {
        if (_router == address(0) || _amountIn == 0) return 0;

        address[] memory _path = new address[](2);
        _path[0] = _tokenIn;
        _path[1] = _tokenOut;

        try IUniswapV2Router02(_router).getAmountsOut(_amountIn, _path) returns (
            uint256[] memory _amounts
        ) {
            return _amounts[1]; // single-hop => amounts[1]
        } catch {
            // If getAmountsOut reverts or fails, return 0
            return 0;
        }
    }

    function checkV3Rate(
        address _router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint24 _fee
    ) public returns (uint256) {
        if (_router == address(0) || _amountIn == 0) return 0;

        ISwapRouter.ExactInputSingleParams memory _params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                fee: _fee,
                recipient: address(this), // we just need a placeholder
                deadline: block.timestamp, // or some future time
                amountIn: _amountIn,
                amountOutMinimum: 1, // to avoid revert from 0 output
                sqrtPriceLimitX96: 0 // no price limit
            });

        // We do a "staticcall" by using `callStatic`. 
        // If it reverts (e.g. no liquidity, missing approvals, etc.), we catch and return 0.
        try ISwapRouter(_router).exactInputSingle{value: 0}(_params) returns (
            uint256 _amountOut
        ) {
            return _amountOut;
        } catch {
            return 0;
        }
    }

    // ------------------------------------------------------------------
    // 4. RATE-SHOP ACROSS ALL REGISTERED V2 + V3 ROUTERS
    // ------------------------------------------------------------------

    /**
     * @notice Returns the highest single-hop output across:
     *          - All stored V2 routers
     *          - All stored V3 routers (with the specified feeTier)
     * @dev If you want to check multiple fee tiers, call this multiple times
     *      or code a loop externally. This is a single-tier version for brevity.
     *
     * @param _tokenIn      The token you're selling
     * @param _tokenOut     The token you're buying
     * @param _amountIn     The amountIn
     * @param _feeTier      The V3 fee tier (e.g. 500, 3000, 10000)
     *
     * @return _routerUsed  The router that yields the best rate
     * @return _versionUsed 2 or 3 (Uniswap version)
     * @return _highestOut  The best output found
     */
    function getBestRate(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint24 _feeTier
    ) external returns (
            address _routerUsed,
            uint8 _versionUsed,
            uint256 _highestOut
    ) {
        // 1) Check all V2 routers
        for (uint256 _i = 0; _i < supportedV2Routers.length; _i++) {
            address _v2 = supportedV2Routers[_i];
            uint256 _out = checkV2Rate(_v2, _tokenIn, _tokenOut, _amountIn);
            if (_out > _highestOut) {
                _highestOut = _out;
                _routerUsed = _v2;
                _versionUsed = 2;
            }
        }

        // 2) Check all V3 routers
        for (uint256 _i = 0; _i < supportedV3Routers.length; _i++) {
            address _v3 = supportedV3Routers[_i];
            // This is not a view call— we do try/catch with `callStatic`
            uint256 _out = checkV3Rate(_v3, _tokenIn, _tokenOut, _amountIn, _feeTier);
            if (_out > _highestOut) {
                _highestOut = _out;
                _routerUsed = _v3;
                _versionUsed = 3;
            }
        }

        return (_routerUsed, _versionUsed, _highestOut);
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

        if (_amountOutMin == 0) {
            revert ZeroValueForAmountOutMin();
        }
        if (msg.value == 0) {
            revert ZeroValueForMsgValue();
        }
        if (_tokenOut == WETH) {
            revert CannotHaveWETHAsTokenOut();
        }

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
            _msgSender()        // recipient is the sender who will receive the tokens
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

        if (_tokenIn == WETH) {
            revert CannotHaveWETHAsTokenIn();
        }
        if (_amountOutMin == 0) {
            revert ZeroValueForAmountOutMin();
        }

        // Set WETH into memory to avoid repeated SLOADs
        address _WETH = WETH;

        // Execute the swap
        // amountOut is the amount of WETH received by this contract
        uint256 _amountOut = _executeSwap(
            _pool,
            _tokenIn,
            _WETH,          // tokenOut is WETH
            _amountIn,
            _msgSender(),   // payer is the sender who is paying with tokens
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
        _sendETH(_msgSender(), _amountOutAfterTax);
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
        address _msgSender = _msgSender();

        if (_amountOutMin == 0) {
            revert ZeroValueForAmountOutMin();
        }
        if (_tokenIn == _WETH) {
            revert CannotHaveWETHAsTokenIn();
        }
        if (_tokenOut == _WETH) {
            revert CannotHaveWETHAsTokenOut();
        }

        // Execute the swap
        // amountOut is the amount of tokens received by this contract
        uint256 _amountOut = _executeSwap(
            _pool,
            _tokenIn,
            _tokenOut,
            _amountIn,
            _msgSender,     // payer is the sender who is paying with tokens
            address(this)   // recipient is this contract which will receive the tokens
        ); 

        // Handle the fees
        (   uint256 _systemFee,
            uint256 _partnerFee) = getFees(_amountOut, _partnerFeeNumerator);

        // Update statistics
        unchecked {
            statistics.swapTokenForTokenCount++;
                // Add system fees only if it won't overflow
            uint256 currentSystemFee = systemFeesCollected[_tokenOut];
            if (currentSystemFee <= type(uint256).max - _systemFee) {
                systemFeesCollected[_tokenOut] += _systemFee;
            } else {
                // Emit an event to notify of the overflow, statistics will be inaccurate
                // but we don't want to brick the contract
                emit SystemFeesCollectedOverflow(_tokenOut);
            }

            // Add partner fees only if it won't overflow
            uint256 currentPartnerFee = partnerFeesCollected[_tokenOut];
            if (currentPartnerFee <= type(uint256).max - _partnerFee) {
                partnerFeesCollected[_tokenOut] += _partnerFee;
            } else {
                // Emit an event to notify of the overflow, statistics will be inaccurate
                // but we don't want to brick the contract
                emit PartnerFeesCollectedOverflow(_tokenOut);
            }
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
        IERC20(_tokenOut).safeTransfer(_msgSender, _amountOutAfterTax);
    }

    /**
    * @dev Given an address for a Uniswap pool, determines its Uniswap version (if any)
    *
    * @param _pool The address of the Uniswap pool
    * @return _uniswapVersion The Uniswap version of the pool (2, 3) or 0 if it's not a Uniswap pool
    */
    function getUniswapVersion(address _pool) public view returns (uint8 _uniswapVersion) {
        if (_pool == address(0)) {
            revert ZeroAddress();
        }

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

        if (_partnerFeeNumerator > MAX_PARTNER_FEE_NUMERATOR) {
            revert PartnerFeeTooHigh();
        }

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

        address _msgSender = _msgSender();

        if (currentSwapPool != address(0)) {
            revert AnotherSwapInProgress();
        }
        if (
            _pool == address(0) ||
            _tokenIn == address(0) ||
            _tokenOut == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_amountIn == 0) {
            revert ZeroValueForAmountIn();
        }
        if (_tokenIn == _tokenOut) {
            revert TokensCannotBeEqual();
        }
        if (_pool == _tokenIn || _pool == _tokenOut) {
            revert PoolCannotBeAToken();
        }
        if (
            _pool == _msgSender ||
            _tokenIn == _msgSender ||
            _tokenOut == _msgSender
        ) {
            revert AddressCannotBeMsgSender();
        }
        if (
            _pool == address(this) ||
            _tokenIn == address(this) ||
            _tokenOut == address(this)
        ) {
            revert AddressCannotBeThisContract();
        }
        if (IERC20(_tokenIn).balanceOf(_payer) < _amountIn) {
            revert InsufficientTokenBalance();
        }
        if (_payer != address(this)) {
            if (IERC20(_tokenIn).allowance(_payer, address(this)) < _amountIn) {
                revert InsufficientTokenAllowance();
            }
        }

        // Determine the Uniswap version
        uint8 _uniswapVersion = getUniswapVersion(_pool);

        // Emit an event to notify of the swap
        emit Swap(
            _msgSender,
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

        if (!_isValidV2TokenPool(_v2Pool, _tokenIn, _tokenOut)) {
            revert InvalidTokensForV2Pair();
        }

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
                ? 4295128739 + 1                                         // min 
                : 1461446703485210103287273052203988822378723970342 - 1; // max

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

        if (_router == address(0)) {
            revert ZeroAddressForRouter();
        }
        if (_token0 == address(0)) {
            revert ZeroAddressForToken0();
        }
        if (_token1 == address(0)) {
            revert ZeroAddressForToken1();
        }
        if (_token0 == _token1) {
            revert SameToken();
        }

        address _factory = IUniswapV2Router02(_router).factory();
        return IUniswapV2Factory(_factory).getPair(_token0, _token1);
    }

    /**
    * @dev For a Uniswapv3 factory and a pair of tokens, returns the address of the pool
    *
    * @param _factory The address of the Uniswap v3 factory
    * @param _token0 The address of the first token
    * @param _token1 The address of the second token
    * @param _fee The fee tier of the pool
    * @return _pool The address of the pool
    */
    function getV3PoolFromFactory(
        address _factory,
        address _token0,
        address _token1,
        uint24 _fee
    ) external view returns (address _pool) {
        
        if (_factory == address(0)) {
            revert ZeroAddressForRouter();
        }
        if (_token0 == address(0)) {
            revert ZeroAddressForToken0();
        }
        if (_token1 == address(0)) {
            revert ZeroAddressForToken1();
        }
        if (_token0 == _token1) {
            revert SameToken();
        }

        return IUniswapV3Factory(_factory).getPool(_token0, _token1, _fee);
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
    * @param _amountIn The amount of input tokens to swap
    * @return _amountOut The estimated amount of output tokens to receive
    */
    function estimateAmountOut(
        address _pool,
        address _tokenIn,
        uint256 _amountIn
    ) external view returns (uint256 _amountOut) {
        address _msgSender = _msgSender();

        if (_isContract(_msgSender)) {
            revert ContractsMayNotCallThisFunction();
        }
        if (_pool == address(0)) {
            revert ZeroAddressForPool();
        }
        if (_tokenIn == address(0)) {
            revert ZeroAddressForTokenIn();
        }
        if (_amountIn == 0) {
            revert ZeroValueForAmountIn();
        }
        if (_pool == _tokenIn) {
            revert TokenCannotBeAPool();
        }
        if (_pool == _msgSender) {
            revert PoolCannotBeSender();
        }
        if (_tokenIn == _msgSender) {
            revert TokenInCannotBeSender();
        }

        uint8 _uniswapVersion = getUniswapVersion(_pool);
        if (_uniswapVersion == 2) {
            return _estimateAmountOutV2(_pool, _tokenIn, _amountIn);
        } else if (_uniswapVersion == 3) {
            return _estimateAmountOutV3(_pool, _tokenIn, _amountIn);
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
    * @param _amountIn The amount of input tokens to swap
    * @return _amountOut The estimated amount of output tokens to receive
    */
    function _estimateAmountOutV2(
        address _pool,
        address _tokenIn,
        uint256 _amountIn
    ) internal view returns (uint256 _amountOut) {
        IUniswapV2Pair _v2Pool = IUniswapV2Pair(_pool);

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
    * @param _amountIn The amount of input tokens to swap
    * @return _amountOut The estimated amount of output tokens to receive
    */
    function _estimateAmountOutV3(
        address _pool,
        address _tokenIn,
        uint256 _amountIn
    ) internal view returns (uint256 _amountOut) {
        IUniswapV3Pool _v3Pool = IUniswapV3Pool(_pool);
        (uint160 sqrtPriceX96, , , , , , ) = _v3Pool.slot0();
        uint256 squaredPriceX96 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 price0to1_1e18 = FullMath.mulDiv(
            squaredPriceX96,
            1e18,
            1 << 192
        );
        
        uint256 rawPrice_1e18;
        if (_tokenIn == _v3Pool.token0()) {
            rawPrice_1e18 = price0to1_1e18;
        } else {
            if (price0to1_1e18 == 0) {
                revert("DivideByZero");
            }
            rawPrice_1e18 = FullMath.mulDiv(1e18, 1e18, price0to1_1e18);
        }

        _amountOut = FullMath.mulDiv(
            _amountIn,
            rawPrice_1e18,
            1e18
        );
    
        return _amountOut;
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
        if (_amountIn == 0) {
            revert InsufficientInputAmount();
        }
        
        // Ensure that both reserves are greater than zero
        if (_reserveIn == 0 || _reserveOut == 0) {
            revert InsufficientLiquidity();
        }
        
        // Calculate the input amount with the fee deducted
        uint256 _amountInWithFee = _amountIn * (FEE_DENOMINATOR - (partnerFeeNumerator + SYSTEM_FEE_NUMERATOR));
        
        // Calculate the numerator of the output amount equation
        uint256 _numerator = _amountInWithFee * _reserveOut;
        
        // Calculate the denominator of the output amount equation
        uint256 _denominator = (_reserveIn * FEE_DENOMINATOR) - _amountInWithFee;
        if (_denominator == 0) {
            revert DivideByZero();
        }

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
        if (address(this).balance < _amount) {
            revert InsufficientETHBalance();
        }
        
        // Transfer the specified amount of ETH to the receiver's address
        (bool success,) = payable(_receiver).call{value: _amount}("");
        if (!success) {
            revert SendETHToRecipientFailed();
        }
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
        if (_tokenA == _tokenB) {
            revert IdenticalTokenAddresses();
        }
        
        // Sort the two token addresses alphabetically and return them
        (_token0, _token1) = 
            (_tokenA < _tokenB) 
                ? (_tokenA, _tokenB)
                : (_tokenB, _tokenA);
        
        // Ensure that the first token address is not the zero address
        if (_token0 == address(0)) {
            revert ZeroAddress();
        }
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
        address _msgSender = _msgSender();

        uint256 _balance = address(this).balance;
        if (_balance == 0) {
            revert NoETHToWithdraw();
        }

        _sendETH(_msgSender, _balance);
        emit EmergencyWithdrawETH(
            _msgSender,
            _balance
        );
    }

    /**
    * @dev Emergency function to withdraw ERC20 tokens accidentally stuck in the contract
    *
    * @param _token The address of the ERC20 token to withdraw
    */
    function emergencyWithdrawToken(address _token) external nonReentrant onlyOwner {
        address _msgSender = _msgSender();

        uint256 _balance = IERC20(_token).balanceOf(address(this));
        if (_balance == 0) {
            revert NoTokensToWithdraw();
        }

        IERC20(_token).safeTransfer(_msgSender, _balance);
        emit EmergencyWithdrawToken(
            _msgSender,
            _token,
            _balance
        );
    }

    function getSupportedV2Routers() external view returns (address[] memory) {
        return supportedV2Routers;
    }

    function getSupportedV3Routers() external view returns (address[] memory) {
        return supportedV3Routers;
    }
}
