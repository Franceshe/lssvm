// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {Ownable} from "./lib/Ownable.sol";
import {ICurve} from "./bonding-curves/ICurve.sol";
import {LSSVMRouter} from "./LSSVMRouter.sol";
import {LSSVMPairFactoryLike} from "./LSSVMPairFactoryLike.sol";
import {CurveErrorCodes} from "./bonding-curves/CurveErrorCodes.sol";

/// @title The base contract for an NFT/TOKEN AMM pair
/// @author boredGenius and 0xmons
/// @notice This implements the core swap logic from NFT to TOKEN
abstract contract LSSVMPair is Ownable, ReentrancyGuard {
    /// -----------------------------------------------------------------------
    /// Enums
    /// -----------------------------------------------------------------------

    enum PoolType {
        TOKEN,
        NFT,
        TRADE
    }

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event SwapWithAnyNFTs(
        uint256 tokenAmount,
        uint256 numNFTs,
        bool nftsIntoPool
    );
    event SwapWithSpecificNFTs(
        uint256 tokenAmount,
        uint256[] nftIds,
        bool nftsIntoPool
    );
    event SpotPriceUpdated(uint256 newSpotPrice);
    event TokenDeposited(uint256 amount);
    event TokenWithdrawn(uint256 amount);
    event DeltaUpdated(uint256 newDelta);
    event FeeUpdated(uint256 newFee);

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @notice The max fee charged by the pair owner
    /// @dev 90%, must <= 1 - MAX_PROTOCOL_FEE (set in LSSVMPairFactory)
    uint256 internal constant MAX_FEE = 9e17;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @dev Temporarily used during LSSVMRouter::_swapNFTsForToken to store the number of NFTs transferred
    /// directly to the pair. Should be 0 outside of the execution of routerSwapAnyNFTsForToken.
    uint256 internal assetRecipientNFTBalanceAtTransferStart;

    /// @notice The current price of the NFT
    uint256 public spotPrice;

    /// @notice The parameter used by the bonding curve
    uint256 public delta;

    /// @notice The fee charged by the pair owner from trades. Only relevant to TRADE pools.
    uint256 public fee;

    /// @notice If set to 0, NFTs/tokens sent by traders during trades will be sent to the pair.
    /// Otherwise, assets will be sent to the set address. Not available to TRADE pools.
    address payable public assetRecipient;

    /// -----------------------------------------------------------------------
    /// Initialization
    /// -----------------------------------------------------------------------

    /**
      @notice Called during pool creation to set initial parameters
      @dev Only called once by factory to initialize.
      We verify this by making sure that the current owner is address(0). 
      The Ownable library we use disallows setting the owner to be address(0), so this condition
      should only be valid before the first initialize call. 
      @param _owner The owner of the pair
      @param _assetRecipient The address that will receive the TOKEN or NFT sent to this pair during swaps. NOTE: If set to address(0), they will go to the pair itself.
      @param _delta The initial delta of the bonding curve
      @param _spotPrice The initial price to sell an asset into the pair
     */
    function initialize(
        address _owner,
        address payable _assetRecipient,
        uint256 _delta,
        uint256 _fee,
        uint256 _spotPrice
    ) external payable {
        require(owner() == address(0), "Initialized");
        __Ownable_init(_owner);

        ICurve _bondingCurve = bondingCurve();
        PoolType _poolType = poolType();

        if ((_poolType == PoolType.TOKEN) || (_poolType == PoolType.NFT)) {
            require(_fee == 0, "Only Trade Pools can have nonzero fee");

            assetRecipient = _assetRecipient;
        }
        if (_poolType == PoolType.TRADE) {
            require(_fee < MAX_FEE, "Trade fee must be less than 100%");
            require(
                _assetRecipient == address(0),
                "Trade pools can't set asset recipient"
            );

            fee = _fee;
        }
        require(_bondingCurve.validateDelta(_delta), "Invalid delta for curve");
        require(
            _bondingCurve.validateSpotPrice(_spotPrice),
            "Invalid new spot price for curve"
        );

        delta = _delta;
        spotPrice = _spotPrice;
    }

    /// -----------------------------------------------------------------------
    /// Swap functions
    /// -----------------------------------------------------------------------

    /**
        @notice Sends token to the pair in exchange for any `numNFTs` NFTs
        @dev To compute the amount of token to send, call bondingCurve.getBuyInfo.
        This swap function is meant for users who are ID agnostic
        @param numNFTs The number of NFTs to purchase
        @param nftRecipient The recipient of the NFTs
        @param isRouter True if calling from LSSVMRouter, false otherwise. Not used for
        ETH pairs.
        @param routerCaller If isRouter is true, ERC20 tokens will be transferred from this address. Not used for
        ETH pairs.
        @return inputAmount The amount of token used for purchase
     */
    function swapTokenForAnyNFTs(
        uint256 numNFTs,
        address nftRecipient,
        bool isRouter,
        address routerCaller
    ) external payable virtual returns (uint256 inputAmount) {
        LSSVMPairFactoryLike _factory = factory();
        ICurve _bondingCurve = bondingCurve();
        IERC721 _nft = nft();

        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        {
            PoolType _poolType = poolType();
            require(
                _poolType == PoolType.NFT || _poolType == PoolType.TRADE,
                "Wrong Pool type"
            );
            require(
                (numNFTs > 0) && (numNFTs <= _nft.balanceOf(address(this))),
                "Ask for > 0 and <= balanceOf NFTs"
            );
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        uint256 protocolFee;
        {
            // Call bonding curve for pricing information
            CurveErrorCodes.Error error;
            uint256 newSpotPrice;
            (error, newSpotPrice, inputAmount, protocolFee) = _bondingCurve
                .getBuyInfo(
                    spotPrice,
                    delta,
                    numNFTs,
                    fee,
                    _factory.protocolFeeMultiplier()
                );
            require(error == CurveErrorCodes.Error.OK, "Bonding curve error");

            // Update spot price
            spotPrice = newSpotPrice;
            emit SpotPriceUpdated(newSpotPrice);
        }

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        _validateTokenInput(inputAmount, isRouter, routerCaller, _factory);

        _sendAnyNFTsToRecipient(_nft, nftRecipient, numNFTs);

        _refundTokenToSender(inputAmount);

        _payProtocolFee(_factory, protocolFee);

        emit SwapWithAnyNFTs(inputAmount, numNFTs, false);
    }

    /**
        @notice Sends token to the pair in exchange for a specific set of NFTs
        @dev To compute the amount of token to send, call bondingCurve.getBuyInfo
        This swap is meant for users who want specific IDs. Also higher chance of
        reverting if some of the specified IDs leave the pool before the swap goes through.
        @param nftIds The list of IDs of the NFTs to purchase
        @param nftRecipient The recipient of the NFTs
        @param isRouter True if calling from LSSVMRouter, false otherwise. Not used for
        ETH pairs.
        @param routerCaller If isRouter is true, ERC20 tokens will be transferred from this address. Not used for
        ETH pairs.
        @return inputAmount The amount of token used for purchase
     */
    function swapTokenForSpecificNFTs(
        uint256[] calldata nftIds,
        address nftRecipient,
        bool isRouter,
        address routerCaller
    ) external payable virtual returns (uint256 inputAmount) {
        LSSVMPairFactoryLike _factory = factory();
        ICurve _bondingCurve = bondingCurve();
        IERC721 _nft = nft();

        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        {
            PoolType _poolType = poolType();
            require(
                _poolType == PoolType.NFT || _poolType == PoolType.TRADE,
                "Wrong Pool type"
            );
            require(
                (nftIds.length > 0) &&
                    (nftIds.length <= _nft.balanceOf(address(this))),
                "Must ask for > 0 and < balanceOf NFTs"
            );
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        uint256 protocolFee;
        {
            // Call bonding curve for pricing information

            CurveErrorCodes.Error error;
            uint256 newSpotPrice;
            (error, newSpotPrice, inputAmount, protocolFee) = _bondingCurve
                .getBuyInfo(
                    spotPrice,
                    delta,
                    nftIds.length,
                    fee,
                    _factory.protocolFeeMultiplier()
                );
            require(error == CurveErrorCodes.Error.OK, "Bonding curve error");

            // Update spot price
            spotPrice = newSpotPrice;
            emit SpotPriceUpdated(newSpotPrice);
        }

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        _validateTokenInput(inputAmount, isRouter, routerCaller, _factory);

        _sendSpecificNFTsToRecipient(_nft, nftRecipient, nftIds);

        _refundTokenToSender(inputAmount);

        _payProtocolFee(_factory, protocolFee);

        emit SwapWithSpecificNFTs(inputAmount, nftIds, false);
    }

    /**
        @notice Sends a set of NFTs to the pair in exchange for token
        @dev To compute the amount of token to that will be received, call bondingCurve.getSellInfo.
        Note that in practice, routerSwapNFTsForToken will be typically used to avoid users having
        to approve their NFTs for spending for each new pair.
        @param nftIds The list of IDs of the NFTs to sell to the pair
        @param minExpectedTokenOutput The minimum acceptable token received by the sender. If the actual
        amount is less than this value, the transaction will be reverted.
        @param tokenRecipient The recipient of the token output
        @return outputAmount The amount of token received
     */
    function swapNFTsForToken(
        //Red
        uint256[] calldata nftIds,
        uint256 minExpectedTokenOutput,
        address payable tokenRecipient
    ) external virtual returns (uint256 outputAmount) {
        LSSVMPairFactoryLike _factory = factory();
        ICurve _bondingCurve = bondingCurve();
        IERC721 _nft = nft();

        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        {
            PoolType _poolType = poolType();
            require(
                _poolType == PoolType.TOKEN || _poolType == PoolType.TRADE,
                "Wrong Pool type"
            );
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // Call bonding curve for pricing information
        uint256 protocolFee;
        {
            uint256 newSpotPrice;
            CurveErrorCodes.Error error;
            (error, newSpotPrice, outputAmount, protocolFee) = _bondingCurve
                .getSellInfo(
                    spotPrice,
                    delta,
                    nftIds.length,
                    fee,
                    _factory.protocolFeeMultiplier()
                );
            require(error == CurveErrorCodes.Error.OK, "Bonding curve error");

            // Update spot price
            spotPrice = newSpotPrice;
            emit SpotPriceUpdated(newSpotPrice);
        }

        // Pricing-dependent validation
        require(
            outputAmount >= minExpectedTokenOutput,
            "Out too little tokens"
        );

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        _takeNFTsFromSender(_nft, nftIds);

        _sendTokenOutput(tokenRecipient, outputAmount);

        _payProtocolFee(_factory, protocolFee);

        emit SwapWithSpecificNFTs(outputAmount, nftIds, true);
    }

    /**
        @notice Sells NFTs to the pair in exchange for token. Only intended to be callable by the LSSVMRouter.
        @dev To compute the amount of token to that will be received, we call bondingCurve.getSellInfo
        @param tokenRecipient The recipient of the token output
        @return outputAmount The amount of token received
     */
    function routerSwapNFTsForToken(address payable tokenRecipient)
        external
        virtual
        returns (uint256 outputAmount)
    {
        LSSVMPairFactoryLike _factory = factory();
        ICurve _bondingCurve = bondingCurve();
        IERC721 _nft = nft();
        uint256 _assetRecipientNFTBalanceAtTransferStart = assetRecipientNFTBalanceAtTransferStart -
                2;

        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        {
            PoolType _poolType = poolType();
            require(
                _poolType == PoolType.TOKEN || _poolType == PoolType.TRADE,
                "Wrong Pool type"
            );
        }

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        assetRecipientNFTBalanceAtTransferStart = 1;

        // Call bonding curve for pricing information
        uint256 protocolFee;
        uint256 numNFTs = _nft.balanceOf(getAssetRecipient()) -
            _assetRecipientNFTBalanceAtTransferStart;
        {
            uint256 newSpotPrice;
            CurveErrorCodes.Error error;
            (error, newSpotPrice, outputAmount, protocolFee) = _bondingCurve
                .getSellInfo(
                    spotPrice,
                    delta,
                    numNFTs,
                    fee,
                    _factory.protocolFeeMultiplier()
                );
            require(error == CurveErrorCodes.Error.OK, "Bonding curve error");

            // Update spot price
            spotPrice = newSpotPrice;
            emit SpotPriceUpdated(newSpotPrice);
        }

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        _sendTokenOutput(tokenRecipient, outputAmount);

        _payProtocolFee(_factory, protocolFee);

        emit SwapWithAnyNFTs(outputAmount, numNFTs, true);
    }

    /**
      @notice Stores the assetRecipient's current NFT balance for use with routerSwapNFTForToken. Only callable by the router
     */
    function cacheAssetRecipientNFTBalance() external {
        require(
            factory().routerAllowed(LSSVMRouter(payable(msg.sender))),
            "Not router"
        );
        assetRecipientNFTBalanceAtTransferStart =
            nft().balanceOf(getAssetRecipient()) +
            2;
    }

    /// -----------------------------------------------------------------------
    /// View functions
    /// -----------------------------------------------------------------------

    /**
        @dev Used as read function to query the bonding curve for buy pricing info
        @param numNFTs The number of NFTs to buy from the pair
     */
    function getBuyNFTQuote(uint256 numNFTs)
        external
        view
        returns (
            CurveErrorCodes.Error error,
            uint256 newSpotPrice,
            uint256 inputAmount,
            uint256 protocolFee
        )
    {
        (error, newSpotPrice, inputAmount, protocolFee) = bondingCurve()
            .getBuyInfo(
                spotPrice,
                delta,
                numNFTs,
                fee,
                factory().protocolFeeMultiplier()
            );
    }

    /**
        @dev Used as read function to query the bonding curve for sell pricing info
        @param numNFTs The number of NFTs to sell to the pair
     */
    function getSellNFTQuote(uint256 numNFTs)
        external
        view
        returns (
            CurveErrorCodes.Error error,
            uint256 newSpotPrice,
            uint256 outputAmount,
            uint256 protocolFee
        )
    {
        (error, newSpotPrice, outputAmount, protocolFee) = bondingCurve()
            .getSellInfo(
                spotPrice,
                delta,
                numNFTs,
                fee,
                factory().protocolFeeMultiplier()
            );
    }

    /**
        @notice Returns all NFT IDs held by the pool
     */
    function getAllHeldIds() external view virtual returns (uint256[] memory);

    /**
        @notice Returns the pair's variant (NFT is enumerable or not, pair uses ETH or ERC20)
     */
    function pairVariant()
        public
        pure
        virtual
        returns (LSSVMPairFactoryLike.PairVariant);

    function factory() public pure returns (LSSVMPairFactoryLike _factory) {
        uint256 paramsLength = _immutableParamsLength();
        assembly {
            _factory := shr(
                0x60,
                calldataload(sub(calldatasize(), paramsLength))
            )
        }
    }

    /**
        @notice Returns the type of bonding curve that parameterizes the pair
     */
    function bondingCurve() public pure returns (ICurve _bondingCurve) {
        uint256 paramsLength = _immutableParamsLength();
        assembly {
            _bondingCurve := shr(
                0x60,
                calldataload(add(sub(calldatasize(), paramsLength), 20))
            )
        }
    }

    /**
        @notice Returns the NFT collection that parameterizes the pair
     */
    function nft() public pure returns (IERC721 _nft) {
        uint256 paramsLength = _immutableParamsLength();
        assembly {
            _nft := shr(
                0x60,
                calldataload(add(sub(calldatasize(), paramsLength), 40))
            )
        }
    }

    /**
        @notice Returns the pair's type (TOKEN/NFT/TRADE)
     */
    function poolType() public pure returns (PoolType _poolType) {
        uint256 paramsLength = _immutableParamsLength();
        assembly {
            _poolType := shr(
                0xf8,
                calldataload(add(sub(calldatasize(), paramsLength), 60))
            )
        }
    }

    /**
        @notice Returns the address that assets that receives assets when a swap is done with this pair
        Can be set to another address by the owner, if set to address(0), defaults to the pair's own address
     */
    function getAssetRecipient()
        public
        view
        returns (address payable _assetRecipient)
    {
        // If it's a TRADE pool, we know the recipient is 0 (TRADE pools can't set asset recipients)
        // so just return address(this)
        if (poolType() == PoolType.TRADE) {
            return payable(address(this));
        }

        // Otherwise, we return the recipient if it's been set
        // or replace it with address(this) if it's 0
        _assetRecipient = assetRecipient;
        if (_assetRecipient == address(0)) {
            // Tokens will be transferred to address(this)
            _assetRecipient = payable(address(this));
        }
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    /**
        @notice Verifies and the correct amount of tokens needed for a swap is sent
        @param inputAmount The amount of tokens to be sent
     */
    function _validateTokenInput(
        uint256 inputAmount,
        bool isRouter,
        address routerCaller,
        LSSVMPairFactoryLike _factory
    ) internal virtual;

    /**
        @notice Sends excess tokens back to the caller
        @dev We send ETH back to the caller even when called from LSSVMRouter because we do an aggregate slippage check for certain bulk swaps. (Instead of sending directly back to the router caller) 
        Excess ETH sent for one swap can then be used to help pay for the next swap.
     */
    function _refundTokenToSender(uint256 inputAmount) internal virtual;

    /**
        @notice Sends protocol fee (if it exists) back to the LSSVMPairFactory
     */
    function _payProtocolFee(LSSVMPairFactoryLike _factory, uint256 protocolFee)
        internal
        virtual;

    /**
        @notice Sends tokens to a recipient
        @param tokenRecipient The address receiving the tokens
        @param outputAmount The amount of tokens to send
     */
    function _sendTokenOutput(
        address payable tokenRecipient,
        uint256 outputAmount
    ) internal virtual;

    /**
        @notice Sends some number of NFTs to a recipient address, ID agnostic
        @dev Even though we specify the NFT address here, this internal function is only 
        used to send NFTs associated with this specific pool.
        @param _nft The address of the NFT to send
        @param nftRecipient The receiving address for the NFTs
        @param numNFTs The number of NFTs to send  
     */
    function _sendAnyNFTsToRecipient(
        IERC721 _nft,
        address nftRecipient,
        uint256 numNFTs
    ) internal virtual;

    /**
        @notice Sends specific NFTs to a recipient address
        @dev Even though we specify the NFT address here, this internal function is only 
        used to send NFTs associated with this specific pool.
        @param _nft The address of the NFT to send
        @param nftRecipient The receiving address for the NFTs
        @param nftIds The specific IDs of NFTs to send  
     */
    function _sendSpecificNFTsToRecipient(
        IERC721 _nft,
        address nftRecipient,
        uint256[] calldata nftIds
    ) internal virtual;

    /**
        @notice Takes NFTs from the caller and sends them into the pair's asset recipient
        @dev This is used by the LSSVMPair's swapNFTForToken function. 
        Practically, we expect most users to use the LSSVMRouter and
        instead the routerSwapNFTsforToken function will be called
        which will not use this function.
        @param _nft The NFT collection to take from
        @param nftIds The specific NFT IDs to take
     */
    function _takeNFTsFromSender(IERC721 _nft, uint256[] calldata nftIds)
        internal
        virtual;

    /**
        @dev Used internally to grab pair parameters from calldata, see LSSVMPairCloner for technical details
     */
    function _immutableParamsLength() internal pure virtual returns (uint256);

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /**
        @notice Rescues a specified set of NFTs owned by the pair to the owner address.
        @dev If the NFT is the pair's collection, we also remove it from the id tracking.
        @param a The address of the NFT to transfer
        @param nftIds The list of IDs of the NFTs to send to the owner
     */
    function withdrawERC721(address a, uint256[] calldata nftIds)
        external
        virtual;

    /**
        @notice Rescues ERC20 tokens from the pair to the owner. Only callable by the owner.
        @param a The address of the token to transfer
        @param amount The amount of tokens to send to the owner
     */
    function withdrawERC20(address a, uint256 amount) external virtual;

    /**
        @notice Updates the selling spot price. Only callable by the owner.
        @param newSpotPrice The new selling spot price value, in Token
     */
    function changeSpotPrice(uint256 newSpotPrice) external onlyOwner {
        ICurve _bondingCurve = bondingCurve();
        require(
            _bondingCurve.validateSpotPrice(newSpotPrice),
            "Invalid new spot price for curve"
        );
        spotPrice = newSpotPrice;
        emit SpotPriceUpdated(newSpotPrice);
    }

    /**
        @notice Updates the delta parameter. Only callable by the owner.
        @param newDelta The new delta parameter
     */
    function changeDelta(uint256 newDelta) external onlyOwner {
        ICurve _bondingCurve = bondingCurve();
        require(
            _bondingCurve.validateDelta(newDelta),
            "Invalid delta for curve"
        );
        delta = newDelta;
        emit DeltaUpdated(newDelta);
    }

    /**
        @notice Updates the fee taken by the LP. Only callable by the owner.
        Only callable if the pool is a Trade pool. Reverts if the fee is >=
        MAX_FEE.
        @param newFee The new LP fee percentage, 18 decimals
     */
    function changeFee(uint256 newFee) external onlyOwner {
        PoolType _poolType = poolType();
        require(_poolType == PoolType.TRADE, "Only for Trade pools");
        require(newFee < MAX_FEE, "Trade fee must be less than 90%");
        fee = newFee;
        emit FeeUpdated(newFee);
    }

    /**
        @notice Changes the address that will receive assets received from
        trades. Only callable by the owner.
        @param newRecipient The new asset recipient
     */
    function changeAssetRecipient(
        address payable newRecipient //Red
    ) external onlyOwner {
        PoolType _poolType = poolType();
        require(_poolType != PoolType.TRADE, "Not for Trade pools");
        assetRecipient = newRecipient;
    }

    /**
        @notice Allows the pair to make arbitrary external calls to contracts
        whitelisted by the protocol. Only callable by the owner.
        @param target The contract to call
        @param data The calldata to pass to the contract
     */
    function call(address payable target, bytes calldata data)
        external
        onlyOwner
    {
        LSSVMPairFactoryLike _factory = factory();
        require(_factory.callAllowed(target), "Target must be whitelisted");
        (bool result, ) = target.call{value: 0}(data);
        require(result, "Call failed");
    }

    /**
        Including these decreases the gas cost of the swap functions.
        We're not quite sure why.
     */
    uint256 public unlockTime;

    function lockPool(uint256) external {}
}
