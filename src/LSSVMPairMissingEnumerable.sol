// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LSSVMPair} from "./LSSVMPair.sol";
import {LSSVMRouter} from "./LSSVMRouter.sol";
import {LSSVMPairFactoryLike} from "./LSSVMPairFactoryLike.sol";

abstract contract LSSVMPairMissingEnumerable is LSSVMPair {
    using EnumerableSet for EnumerableSet.UintSet;

    // ID tracking
    EnumerableSet.UintSet private idSet;

    function _sendAnyNFTsToRecipient(
        IERC721 _nft,
        address nftRecipient,
        uint256 numNFTs
    ) internal override {
        // Send NFTs to recipient
        // We're missing enumerable, so we also update the pair's own ID set
        for (uint256 i = 0; i < numNFTs; i++) {
            uint256 nftId = idSet.at(0);
            _nft.safeTransferFrom(address(this), nftRecipient, nftId);
            idSet.remove(nftId);
        }
    }

    function _sendSpecificNFTsToRecipient(
        IERC721 _nft,
        address nftRecipient,
        uint256[] calldata nftIds
    ) internal override {
        // Send NFTs to caller
        // If missing enumerable, update pool's own ID set
        for (uint256 i = 0; i < nftIds.length; i++) {
            _nft.safeTransferFrom(address(this), nftRecipient, nftIds[i]);
            // Remove from id set
            idSet.remove(nftIds[i]);
        }
    }

    function _takeNFTsFromSender(IERC721 _nft, uint256[] calldata nftIds)
        internal
        override
    {
        address _assetRecipient = getAssetRecipient();

        // Take in NFTs from caller
        // Because we're missing enumerable, update pool's own ID set
        for (uint256 i = 0; i < nftIds.length; i++) {
            _nft.safeTransferFrom(msg.sender, _assetRecipient, nftIds[i]);
            idSet.add(nftIds[i]);
        }
    }

    /**
       @notice Returns all NFT IDs held by the pool
     */
    function getAllHeldIds() external view override returns (uint256[] memory) {
        uint256 numNFTs = nft().balanceOf(address(this));
        uint256[] memory ids = new uint256[](numNFTs);
        for (uint256 i; i < numNFTs; i++) {
            ids[i] = idSet.at(i);
        }
        return ids;
    }

    /**
        @dev Callback when safeTransfering an ERC721 in, we add ID to the idSet
        if it's the same collection used by pool (and doesn't auto-track via enumerable)
     */
    function onERC721Received(
        address,
        address,
        uint256 id,
        bytes memory 
    ) public virtual returns (bytes4) {
        IERC721 _nft = nft();
        // If it's from the pair's NFT, add the ID to ID set
        if (msg.sender == address(_nft)) {
            idSet.add(id);
        }
        return this.onERC721Received.selector;
    }

    function withdrawERC721(address a, uint256[] calldata nftIds)
        external
        override
        onlyOwner
    {
        IERC721 _nft = nft();
        if (a != address(_nft)) {
            for (uint256 i = 0; i < nftIds.length; i++) {
                IERC721(a).safeTransferFrom(
                    address(this),
                    msg.sender,
                    nftIds[i]
                );
            }
        } else {
            for (uint256 i = 0; i < nftIds.length; i++) {
                _nft.safeTransferFrom(address(this), msg.sender, nftIds[i]);
                idSet.remove(nftIds[i]);
            }
        }
    }
}
