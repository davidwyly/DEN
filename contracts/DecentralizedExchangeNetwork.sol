// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./DexCallbackHandler.sol";
import "./V4SwapLib.sol";

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

Facilitates Uniswap v2/v3/v4 token swaps for our partner:

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

    // V4 pool storage
    V4PoolKey[] internal supportedV4Pools;
    mapping ( bytes32 => bool ) public v4PoolRegistered;

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

    // V4 callback state (set before PM.unlock, read in unlockCallback)
    bool internal v4SwapInProgress;

    // events
    event Swap(
        address indexed caller,
        address indexed pool,
        uint8 uniswapVersion,
        address tokenIn,
        address tokenOut
    );
    event SwapV4(
        address indexed caller,
        bytes32 indexed poolId,
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
    event V4PoolManagerSet(
        address indexed oldPoolManager,
        address indexed newPoolManager
    );
    event V4PoolAdded(
        bytes32 indexed poolId
    );
    event V4PoolRemoved(
        bytes32 indexed poolId
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
    error V4PoolManagerNotSet();
    error V4PoolAlreadyRegistered();
    error V4PoolNotRegistered();
    error UnauthorizedUnlockCallback();
    error InvalidV4PoolKey();
    error ReceivedLessThanMinimum();
    error UnsupportedDEX();

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
        if (_partnerFeeNumerator == 0 || _partnerFeeNumerator > MAX_PARTNER_FEE_NUMERATOR) {
            revert PartnerFeeTooHigh();
        }

        // Set the values
        WETH = _WETH; // immutable assignment of wrapped native coin for deployed network
        partner = _partner; // partner can change with transferPartnership
        systemFeeReceiver = _systemFeeReceiver; // owner can change with setSystemFeeReceiver
        partnerFeeReceiver = _partnerFeeReceiver; // partner can change with setPartnerFeeReceiver
        partnerFeeNumerator = _partnerFeeNumerator; // partner can change with setPartnerFeeNumerator
    }

    ////////////////////////////
    /// V2/V3 ROUTER MANAGEMENT
    ////////////////////////////

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
        if (_index >= supportedV2Routers.length) {
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
        if (_index >= supportedV3Routers.length) {
            revert IndexOutOfRange();
        }
        address _removedRouter = supportedV3Routers[_index];
        supportedV3Routers[_index] = supportedV3Routers[
            supportedV3Routers.length - 1
        ];
        supportedV3Routers.pop();
        emit V3RouterRemoved(_removedRouter);
    }

    /////////////////////////////
    /// V4 POOL MANAGEMENT    ///
    /////////////////////////////

    /**
    * @dev Sets the Uniswap V4 PoolManager address
    *
    * @param _v4PoolManager The address of the V4 PoolManager singleton
    */
    function setV4PoolManager(address _v4PoolManager) external onlyOwner {
        if (_v4PoolManager == address(0)) {
            revert ZeroAddress();
        }
        if (_v4PoolManager == v4PoolManager) {
            revert NoChange();
        }
        emit V4PoolManagerSet(v4PoolManager, _v4PoolManager);
        v4PoolManager = _v4PoolManager;
    }

    /**
    * @dev Registers a V4 pool key for rate shopping and swaps
    *
    * @param _poolKey The V4 pool key to register
    */
    function addV4Pool(V4PoolKey calldata _poolKey) external onlyOwner {
        if (v4PoolManager == address(0)) {
            revert V4PoolManagerNotSet();
        }
        if (_poolKey.currency0 >= _poolKey.currency1) {
            revert InvalidV4PoolKey();
        }

        bytes32 _poolId = getV4PoolId(_poolKey);
        if (v4PoolRegistered[_poolId]) {
            revert V4PoolAlreadyRegistered();
        }

        supportedV4Pools.push(_poolKey);
        v4PoolRegistered[_poolId] = true;
        emit V4PoolAdded(_poolId);
    }

    /**
    * @dev Removes a registered V4 pool by index (swap-and-pop)
    *
    * @param _index The index in the supportedV4Pools array
    */
    function removeV4Pool(uint256 _index) external onlyOwner {
        if (_index >= supportedV4Pools.length) {
            revert IndexOutOfRange();
        }

        bytes32 _poolId = getV4PoolId(supportedV4Pools[_index]);
        v4PoolRegistered[_poolId] = false;
        supportedV4Pools[_index] = supportedV4Pools[supportedV4Pools.length - 1];
        supportedV4Pools.pop();
        emit V4PoolRemoved(_poolId);
    }

    /**
    * @dev Computes the V4 pool ID from a pool key (keccak256 hash)
    */
    function getV4PoolId(V4PoolKey memory _poolKey) public pure returns (bytes32) {
        return V4SwapLib.computePoolId(_poolKey);
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
    ) public view returns (uint256) {
        if (_router == address(0) || _amountIn == 0) return 0;

        // Look up the V3 factory from the router to find the pool
        address _factory;
        try IUniswapV2Router02(_router).factory() returns (address f) {
            _factory = f;
        } catch {
            return 0;
        }

        // Find the pool for this pair and fee
        try IUniswapV3Factory(_factory).getPool(_tokenIn, _tokenOut, _fee) returns (address _pool) {
            if (_pool == address(0)) return 0;
            // Use sqrtPriceX96-based estimate via the library
            return V4SwapLib.estimateV3(_pool, _tokenIn, _amountIn);
        } catch {
            return 0;
        }
    }

    /**
    * @dev Checks the estimated output from a V4 pool using on-chain price data.
    *      Delegates to V4SwapLib (external library) to keep main contract under 24KB.
    */
    function checkV4Rate(
        V4PoolKey memory _poolKey,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) public view returns (uint256) {
        return V4SwapLib.checkRate(v4PoolManager, WETH, _poolKey, _tokenIn, _tokenOut, _amountIn);
    }

    // ------------------------------------------------------------------
    // RATE-SHOP ACROSS ALL REGISTERED V2 + V3 ROUTERS + V4 POOLS
    // ------------------------------------------------------------------

    /**
     * @notice Returns the highest single-hop output across:
     *          - All stored V2 routers
     *          - All stored V3 routers (with the specified feeTier)
     *          - All registered V4 pools
     *
     * @param _tokenIn      The token you're selling
     * @param _tokenOut     The token you're buying
     * @param _amountIn     The amountIn
     * @param _feeTier      The V3 fee tier (e.g. 500, 3000, 10000)
     *
     * @return _routerUsed   The router/PM that yields the best rate
     * @return _versionUsed  2, 3, or 4 (Uniswap version)
     * @return _highestOut   The best output found
     * @return _v4PoolIndex  Index in supportedV4Pools (only valid when _versionUsed == 4)
     */
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
            uint256 _out = checkV3Rate(_v3, _tokenIn, _tokenOut, _amountIn, _feeTier);
            if (_out > _highestOut) {
                _highestOut = _out;
                _routerUsed = _v3;
                _versionUsed = 3;
            }
        }

        // 3) Check all V4 pools
        for (uint256 _i = 0; _i < supportedV4Pools.length; _i++) {
            uint256 _out = checkV4Rate(supportedV4Pools[_i], _tokenIn, _tokenOut, _amountIn);
            if (_out > _highestOut) {
                _highestOut = _out;
                _routerUsed = v4PoolManager;
                _versionUsed = 4;
                _v4PoolIndex = _i;
            }
        }

        return (_routerUsed, _versionUsed, _highestOut, _v4PoolIndex);
    }

    ///////////////////////////////
    /// EXTERNAL SWAP FUNCTIONS ///
    ///////////////////////////////

    // ============ V2/V3 SWAP ENTRY POINTS (unchanged API) ============

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
        executeSwapETHForToken(
            _pool,
            _tokenOut,
            _amountOutMin,
            partnerFeeNumerator
        );
    }

    /**
    * @dev Main function to swap ETH for tokens with a custom partner fee
    */
    function swapETHForTokenWithCustomFee(
        address _pool,
        address _tokenOut,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum
    ) external payable nonReentrant {
        executeSwapETHForToken(
            _pool,
            _tokenOut,
            _amountOutMin,
            _customPartnerFeeNum
        );
    }

    /**
    * @dev Main function to swap tokens for ETH
    */
    function swapTokenForETH (
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin
    ) external nonReentrant {
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
    */
    function swapTokenForETHWithCustomFee (
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum
    ) external nonReentrant {
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
    */
    function swapTokenForToken (
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin
    ) external nonReentrant {
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
    */
    function swapTokenForTokenWithCustomFee (
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum
    ) external nonReentrant {
        executeSwapTokenForToken(
            _pool,
            _tokenIn,
            _tokenOut,
            _amountIn,
            _amountOutMin,
            _customPartnerFeeNum
        );
    }

    // ============ V4 SWAP ENTRY POINTS ============

    /**
    * @dev Swap ETH for tokens through a Uniswap V4 pool.
    *      The V4 pool can use native ETH (currency = address(0)) directly.
    *
    * @param _poolId The V4 pool ID (keccak256 of the pool key)
    * @param _tokenOut The address of the output token
    * @param _amountOutMin The minimum amount of output tokens to receive
    */
    function swapETHForTokenV4(
        bytes32 _poolId,
        address _tokenOut,
        uint256 _amountOutMin
    ) external payable nonReentrant {
        _executeSwapETHForTokenV4(
            _poolId,
            _tokenOut,
            _amountOutMin,
            partnerFeeNumerator
        );
    }

    function swapETHForTokenV4WithCustomFee(
        bytes32 _poolId,
        address _tokenOut,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum
    ) external payable nonReentrant {
        _executeSwapETHForTokenV4(
            _poolId,
            _tokenOut,
            _amountOutMin,
            _customPartnerFeeNum
        );
    }

    /**
    * @dev Swap tokens for ETH through a Uniswap V4 pool.
    *
    * @param _poolId The V4 pool ID
    * @param _tokenIn The address of the input token
    * @param _amountIn The amount of input tokens to swap
    * @param _amountOutMin The minimum amount of ETH to receive
    */
    function swapTokenForETHV4(
        bytes32 _poolId,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin
    ) external nonReentrant {
        _executeSwapTokenForETHV4(
            _poolId,
            _tokenIn,
            _amountIn,
            _amountOutMin,
            partnerFeeNumerator
        );
    }

    function swapTokenForETHV4WithCustomFee(
        bytes32 _poolId,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum
    ) external nonReentrant {
        _executeSwapTokenForETHV4(
            _poolId,
            _tokenIn,
            _amountIn,
            _amountOutMin,
            _customPartnerFeeNum
        );
    }

    /**
    * @dev Swap tokens for tokens through a Uniswap V4 pool.
    *
    * @param _poolId The V4 pool ID
    * @param _tokenIn The address of the input token
    * @param _tokenOut The address of the output token
    * @param _amountIn The amount of input tokens to swap
    * @param _amountOutMin The minimum amount of output tokens to receive
    */
    function swapTokenForTokenV4(
        bytes32 _poolId,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin
    ) external nonReentrant {
        _executeSwapTokenForTokenV4(
            _poolId,
            _tokenIn,
            _tokenOut,
            _amountIn,
            _amountOutMin,
            partnerFeeNumerator
        );
    }

    function swapTokenForTokenV4WithCustomFee(
        bytes32 _poolId,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _customPartnerFeeNum
    ) external nonReentrant {
        _executeSwapTokenForTokenV4(
            _poolId,
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
    * @dev Swap ETH for tokens (V2/V3 path)
    */
    function executeSwapETHForToken(
        address _pool,
        address _tokenOut,
        uint256 _amountOutMin,
        uint8 _partnerFeeNumerator
    ) internal {

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
            revert ReceivedLessThanMinimum();
        }
    }

    /**
    * @dev Swap tokens for ETH (V2/V3 path)
    */
    function executeSwapTokenForETH(
        address _pool,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _partnerFeeNumerator
    ) internal {

        if (_tokenIn == WETH) {
            revert CannotHaveWETHAsTokenIn();
        }
        if (_amountOutMin == 0) {
            revert ZeroValueForAmountOutMin();
        }

        // Set WETH into memory to avoid repeated SLOADs
        address _WETH = WETH;

        // Execute the swap
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
            revert ReceivedLessThanMinimum();
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
    * @dev Swap tokens for tokens (V2/V3 path)
    */
    function executeSwapTokenForToken(
        address _pool,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _partnerFeeNumerator
    ) internal {

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
                emit SystemFeesCollectedOverflow(_tokenOut);
            }

            // Add partner fees only if it won't overflow
            uint256 currentPartnerFee = partnerFeesCollected[_tokenOut];
            if (currentPartnerFee <= type(uint256).max - _partnerFee) {
                partnerFeesCollected[_tokenOut] += _partnerFee;
            } else {
                emit PartnerFeesCollectedOverflow(_tokenOut);
            }
        }

        // Verify the amount of output tokens received from the swap
        uint256 _amountOutAfterTax = _amountOut - (_systemFee + _partnerFee);
        if (_amountOutAfterTax < _amountOutMin) {
            revert ReceivedLessThanMinimum();
        }

        // Transfer the system fees to the system receiver
        IERC20(_tokenOut).safeTransfer(systemFeeReceiver, _systemFee);

        // Transfer the partner fees to the partner receiver
        IERC20(_tokenOut).safeTransfer(partnerFeeReceiver, _partnerFee);

        // Transfer the rest to the sender
        IERC20(_tokenOut).safeTransfer(_msgSender, _amountOutAfterTax);
    }

    ///////////////////////////
    /// V4 SWAP SETUP LOGIC ///
    ///////////////////////////

    /**
    * @dev Internal: Swap ETH for tokens via a V4 pool.
    *      Fees are deducted from the input ETH before the swap.
    */
    function _executeSwapETHForTokenV4(
        bytes32 _poolId,
        address _tokenOut,
        uint256 _amountOutMin,
        uint8 _partnerFeeNumerator
    ) internal {
        if (v4PoolManager == address(0)) revert V4PoolManagerNotSet();
        if (!v4PoolRegistered[_poolId]) revert V4PoolNotRegistered();
        if (_amountOutMin == 0) revert ZeroValueForAmountOutMin();
        if (msg.value == 0) revert ZeroValueForMsgValue();
        if (_tokenOut == WETH) revert CannotHaveWETHAsTokenOut();

        (uint256 _systemFee, uint256 _partnerFee) = getFees(msg.value, _partnerFeeNumerator);
        unchecked {
            statistics.swapETHForTokenCount++;
            systemFeesCollected[WETH] += _systemFee;
            partnerFeesCollected[WETH] += _partnerFee;
        }

        uint256 _amountInLessFees = msg.value - (_systemFee + _partnerFee);
        _sendETH(systemFeeReceiver, _systemFee);
        _sendETH(partnerFeeReceiver, _partnerFee);

        V4PoolKey memory _poolKey = _findV4PoolKey(_poolId);
        V4SwapCallbackData memory _cbData;
        _cbData.poolKey = _poolKey;
        _cbData.amountSpecified = -int256(_amountInLessFees); // V4: negative = exact input
        _cbData.recipient = _msgSender();
        _cbData.payer = address(this);
        _cbData.currencyOut = _tokenOut;

        bool _poolHasNativeETH = (_poolKey.currency0 == address(0) || _poolKey.currency1 == address(0));
        _cbData.currencyIn = _poolHasNativeETH ? address(0) : WETH;
        if (!_poolHasNativeETH) IWETH(WETH).deposit{value: _amountInLessFees}();

        _cbData.zeroForOne = (_cbData.currencyIn == _poolKey.currency0);
        _cbData.sqrtPriceLimitX96 = V4SwapLib.getSqrtPriceLimitX96(_cbData.zeroForOne);

        uint256 _before = IERC20(_tokenOut).balanceOf(_msgSender());
        emit SwapV4(_msgSender(), _poolId, WETH, _tokenOut);
        _executeV4Unlock(_cbData);

        if (IERC20(_tokenOut).balanceOf(_msgSender()) - _before < _amountOutMin) {
            revert ReceivedLessThanMinimum();
        }
    }

    /**
    * @dev Internal: Swap tokens for ETH via a V4 pool.
    */
    function _executeSwapTokenForETHV4(
        bytes32 _poolId,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _partnerFeeNumerator
    ) internal {
        if (v4PoolManager == address(0)) revert V4PoolManagerNotSet();
        if (!v4PoolRegistered[_poolId]) revert V4PoolNotRegistered();
        if (_tokenIn == WETH) revert CannotHaveWETHAsTokenIn();
        if (_amountOutMin == 0) revert ZeroValueForAmountOutMin();
        if (_amountIn == 0) revert ZeroValueForAmountIn();

        V4PoolKey memory _poolKey = _findV4PoolKey(_poolId);
        V4SwapCallbackData memory _cbData;
        _cbData.poolKey = _poolKey;
        _cbData.amountSpecified = -int256(_amountIn); // V4: negative = exact input
        _cbData.currencyIn = _tokenIn;
        _cbData.payer = _msgSender();
        _cbData.recipient = address(this);

        bool _poolHasNativeETH = (_poolKey.currency0 == address(0) || _poolKey.currency1 == address(0));
        _cbData.currencyOut = _poolHasNativeETH ? address(0) : WETH;
        _cbData.zeroForOne = (_tokenIn == _poolKey.currency0);
        _cbData.sqrtPriceLimitX96 = V4SwapLib.getSqrtPriceLimitX96(_cbData.zeroForOne);

        uint256 _ethBefore = address(this).balance;
        uint256 _wethBefore = (_cbData.currencyOut != address(0)) ? IERC20(WETH).balanceOf(address(this)) : 0;
        emit SwapV4(_msgSender(), _poolId, _tokenIn, WETH);
        _executeV4Unlock(_cbData);

        uint256 _amountOut;
        if (_cbData.currencyOut == address(0)) {
            _amountOut = address(this).balance - _ethBefore;
        } else {
            _amountOut = IERC20(WETH).balanceOf(address(this)) - _wethBefore;
            IWETH(WETH).withdraw(_amountOut);
        }

        (uint256 _systemFee, uint256 _partnerFee) = getFees(_amountOut, _partnerFeeNumerator);
        unchecked {
            statistics.swapTokenForETHCount++;
            systemFeesCollected[WETH] += _systemFee;
            partnerFeesCollected[WETH] += _partnerFee;
        }

        uint256 _amountOutAfterTax = _amountOut - (_systemFee + _partnerFee);
        if (_amountOutAfterTax < _amountOutMin) revert ReceivedLessThanMinimum();

        _sendETH(systemFeeReceiver, _systemFee);
        _sendETH(partnerFeeReceiver, _partnerFee);
        _sendETH(_msgSender(), _amountOutAfterTax);
    }

    /**
    * @dev Internal: Swap tokens for tokens via a V4 pool.
    */
    function _executeSwapTokenForTokenV4(
        bytes32 _poolId,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint8 _partnerFeeNumerator
    ) internal {
        if (v4PoolManager == address(0)) revert V4PoolManagerNotSet();
        if (!v4PoolRegistered[_poolId]) revert V4PoolNotRegistered();
        if (_amountOutMin == 0) revert ZeroValueForAmountOutMin();
        if (_amountIn == 0) revert ZeroValueForAmountIn();
        if (_tokenIn == WETH) revert CannotHaveWETHAsTokenIn();
        if (_tokenOut == WETH) revert CannotHaveWETHAsTokenOut();
        if (_tokenIn == _tokenOut) revert TokensCannotBeEqual();

        V4PoolKey memory _poolKey = _findV4PoolKey(_poolId);
        V4SwapCallbackData memory _cbData;
        _cbData.poolKey = _poolKey;
        _cbData.zeroForOne = (_tokenIn == _poolKey.currency0);
        _cbData.amountSpecified = -int256(_amountIn); // V4: negative = exact input
        _cbData.sqrtPriceLimitX96 = V4SwapLib.getSqrtPriceLimitX96(_cbData.zeroForOne);
        _cbData.currencyIn = _tokenIn;
        _cbData.currencyOut = _tokenOut;
        _cbData.payer = _msgSender();
        _cbData.recipient = address(this);

        uint256 _before = IERC20(_tokenOut).balanceOf(address(this));
        emit SwapV4(_msgSender(), _poolId, _tokenIn, _tokenOut);
        _executeV4Unlock(_cbData);

        uint256 _amountOut = IERC20(_tokenOut).balanceOf(address(this)) - _before;
        (uint256 _systemFee, uint256 _partnerFee) = getFees(_amountOut, _partnerFeeNumerator);

        unchecked {
            statistics.swapTokenForTokenCount++;
            uint256 cs = systemFeesCollected[_tokenOut];
            if (cs <= type(uint256).max - _systemFee) systemFeesCollected[_tokenOut] += _systemFee;
            else emit SystemFeesCollectedOverflow(_tokenOut);
            uint256 cp = partnerFeesCollected[_tokenOut];
            if (cp <= type(uint256).max - _partnerFee) partnerFeesCollected[_tokenOut] += _partnerFee;
            else emit PartnerFeesCollectedOverflow(_tokenOut);
        }

        uint256 _amountOutAfterTax = _amountOut - (_systemFee + _partnerFee);
        if (_amountOutAfterTax < _amountOutMin) revert ReceivedLessThanMinimum();

        IERC20(_tokenOut).safeTransfer(systemFeeReceiver, _systemFee);
        IERC20(_tokenOut).safeTransfer(partnerFeeReceiver, _partnerFee);
        IERC20(_tokenOut).safeTransfer(_msgSender(), _amountOutAfterTax);
    }

    /**
    * @dev Shared V4 unlock execution — sets the flag, calls PM.unlock, clears the flag.
    */
    function _executeV4Unlock(V4SwapCallbackData memory _cbData) internal {
        v4SwapInProgress = true;
        IV4PoolManager(v4PoolManager).unlock(abi.encode(_cbData));
        v4SwapInProgress = false;
    }

    /////////////////////////////
    /// V4 UNLOCK CALLBACK    ///
    /////////////////////////////

    /**
    * @dev Called by the V4 PoolManager during unlock(). Executes the swap and settles all token deltas.
    *      Security: Only the PoolManager can call this, and only during an active V4 swap.
    *
    * @param _data Encoded swap parameters: (V4PoolKey, bool zeroForOne, int256 amountSpecified,
    *              uint160 sqrtPriceLimitX96, address currencyIn, address currencyOut,
    *              address payer, address recipient)
    * @return Encoded amount of output tokens received
    */
    function unlockCallback(bytes calldata _data) external returns (bytes memory) {
        if (msg.sender != v4PoolManager) revert UnauthorizedUnlockCallback();
        if (!v4SwapInProgress) revert UnauthorizedUnlockCallback();

        V4SwapCallbackData memory _cb = abi.decode(_data, (V4SwapCallbackData));
        IV4PoolManager _pm = IV4PoolManager(v4PoolManager);

        int256 _delta = _pm.swap(
            _cb.poolKey,
            IV4PoolManager.SwapParams(_cb.zeroForOne, _cb.amountSpecified, _cb.sqrtPriceLimitX96),
            ""
        );

        int128 _a0 = int128(_delta >> 128);
        int128 _a1 = int128(_delta);

        // Settle input (negative delta = we owe PM; negate to get positive amount)
        {
            uint256 _s = _cb.zeroForOne ? uint256(uint128(-_a0)) : uint256(uint128(-_a1));
            if (_cb.currencyIn == address(0)) {
                _pm.settle{value: _s}();
            } else {
                _pm.sync(_cb.currencyIn);
                if (_cb.payer == address(this)) {
                    IERC20(_cb.currencyIn).safeTransfer(address(_pm), _s);
                } else {
                    IERC20(_cb.currencyIn).safeTransferFrom(_cb.payer, address(_pm), _s);
                }
                _pm.settle();
            }
        }

        // Take output (positive delta = PM owes us)
        uint256 _t = _cb.zeroForOne ? uint256(uint128(_a1)) : uint256(uint128(_a0));
        _pm.take(_cb.currencyOut, _cb.recipient, _t);
        return abi.encode(_t);
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
    * @dev Calculates the fees to be deducted from a given amount
    */
    function getFees(
        uint256 _amount,
        uint8 _partnerFeeNumerator
    ) public pure returns (
        uint256 _systemFee,
        uint256 _partnerFee
    ) {

        if (_partnerFeeNumerator == 0 || _partnerFeeNumerator > MAX_PARTNER_FEE_NUMERATOR) {
            revert PartnerFeeTooHigh();
        }

        _systemFee = (_amount * SYSTEM_FEE_NUMERATOR) / FEE_DENOMINATOR;
        _partnerFee = (_amount * _partnerFeeNumerator) / FEE_DENOMINATOR;

        return (_systemFee, _partnerFee);
    }

    //////////////////
    /// SWAP LOGIC ///
    //////////////////

    /**
    * @dev Internal function of unified logic to execute a V2/V3 swap
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

        if (currentSwapPool != address(0) && currentSwapPool != address(1)) {
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
            revert UnsupportedDEX();
        }

        // Calculate the amount of output tokens received
        return IERC20(_tokenOut).balanceOf(_recipient) - _before;
    }

    /**
    * @dev Generalized function to swap tokens on Uniswap v2.
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
            revert InvalidTokensForV3Pool();
        }

        bool _zeroForOne =
            (_tokenIn == _v3Pool.token0())
                ? true
                : false;

        uint160 _sqrtPriceLimitX96 =
            (_zeroForOne)
                ? 4295128739 + 1                                         // min
                : 1461446703485210103287273052203988822378723970342 - 1; // max

        // V3 convention: positive = exact input, negative = exact output
        int256 _amountSpecified = int256(_amountIn);

        // Prepare the callback data
        bytes memory _data = abi.encode(_tokenIn, _payer);

        // Set the current pool to the pool that is being used for the swap
        currentSwapPool = address(_v3Pool);

        _v3Pool.swap(
            _recipient,
            _zeroForOne,
            _amountSpecified,
            _sqrtPriceLimitX96,
            _data
        );

        // Reset to sentinel (non-zero → non-zero is cheap: 5000 gas vs 20000 for zero → non-zero)
        currentSwapPool = address(1);
    }

    /////////////////////////////////
    /// EXTERNAL HELPER FUNCTIONS ///
    /////////////////////////////////

    function isV4PoolSupported(bytes32 _poolId) external view returns (bool) {
        return v4PoolRegistered[_poolId];
    }

    /**
    * @dev For a Uniswapv2 router and a pair of tokens, returns the address of the pool
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



    /////////////////////////////////
    /// INTERNAL HELPER FUNCTIONS ///
    /////////////////////////////////

    function _findV4PoolKey(bytes32 _poolId) internal view returns (V4PoolKey memory) {
        for (uint256 i = 0; i < supportedV4Pools.length; i++) {
            if (getV4PoolId(supportedV4Pools[i]) == _poolId) return supportedV4Pools[i];
        }
        revert V4PoolNotRegistered();
    }

    function _getAmountOut(
        uint256 _amountIn,
        uint256 _reserveIn,
        uint256 _reserveOut
    ) internal pure returns (uint256) {
        if (_amountIn == 0) revert InsufficientInputAmount();
        if (_reserveIn == 0 || _reserveOut == 0) revert InsufficientLiquidity();
        // Use standard Uniswap V2 fee (0.3% = 997/1000). DEN fees are handled externally.
        uint256 _amountInWithFee = _amountIn * 997;
        uint256 _numerator = _amountInWithFee * _reserveOut;
        uint256 _denominator = (_reserveIn * 1000) + _amountInWithFee;
        return _numerator / _denominator;
    }

    /**
    * @dev Sends ETH to a receiver
    */
    function _sendETH(address _receiver, uint256 _amount) internal {
        if (address(this).balance < _amount) {
            revert InsufficientETHBalance();
        }

        (bool success,) = payable(_receiver).call{value: _amount}("");
        if (!success) {
            revert SendETHToRecipientFailed();
        }
    }

    function _sortTokens(address _tokenA, address _tokenB) internal pure returns (address _token0, address _token1) {
        if (_tokenA == _tokenB) revert IdenticalTokenAddresses();
        (_token0, _token1) = (_tokenA < _tokenB) ? (_tokenA, _tokenB) : (_tokenB, _tokenA);
        if (_token0 == address(0)) revert ZeroAddress();
    }

    function _isValidV2TokenPool(IUniswapV2Pair p, address a, address b) internal view returns (bool) {
        address t0 = p.token0(); address t1 = p.token1();
        return (a == t0 && b == t1) || (a == t1 && b == t0);
    }

    function _isValidV3TokenPool(IUniswapV3Pool p, address a, address b) internal view returns (bool) {
        address t0 = p.token0(); address t1 = p.token1();
        return (a == t0 && b == t1) || (a == t1 && b == t0);
    }


    ///////////////////////////
    /// EMERGENCY FUNCTIONS ///
    ///////////////////////////

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

    ///////////////
    /// GETTERS ///
    ///////////////

    function getSupportedV2Routers() external view returns (address[] memory) {
        return supportedV2Routers;
    }

    function getSupportedV3Routers() external view returns (address[] memory) {
        return supportedV3Routers;
    }

    function getSupportedV4Pools() external view returns (V4PoolKey[] memory) {
        return supportedV4Pools;
    }

    function getSupportedV4PoolCount() external view returns (uint256) {
        return supportedV4Pools.length;
    }
}
