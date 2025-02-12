// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "base64-sol/base64.sol";
import "./lib/ERC721Enumerable.sol";
import "./lib/ColorUtils.sol";
import "./lib/StringUtils.sol";
import "./IDixelClubV2Factory.sol";
import "./Shared.sol";
import "./Constants.sol";
import "./SVGGenerator.sol"; // inheriting Constants

/**
 * @dev DixelArt NFT token, including:
 *
 *  - ability for holders to burn (destroy) their tokens
 *  - a owner (Dixel contract) that allows for token minting (creation)
 *  - token ID and URI autogeneration
 */
contract DixelClubV2NFT is ERC721Enumerable, Ownable, Constants, SVGGenerator {
    error DixelClubV2__NotExist();
    error DixelClubV2__Initalized();
    error DixelClubV2__InvalidCost(uint256 expected, uint256 actual);
    error DixelClubV2__MaximumMinted();
    error DixelClubV2__NotStarted(uint40 beginAt, uint40 nowAt);
    error DixelClubV2__NotWhitelisted();
    error DixelClubV2__NotApproved();
    error DixelClubV2__PublicCollection();
    error DixelClubV2__PrivateCollection();
    error DixelClubV2__InvalidRoyalty(uint256 invalid);
    error DixelClubV2__AlreadyStarted();
    error DixelClubV2__DescriptionTooLong();
    error DixelClubV2__ContainMalicious();
    error DixelClubV2__WhiteListValueDoNotMatch(address expected, address actual);

    struct EditionData {
        uint24[PALETTE_SIZE] palette; // 24bit color (16,777,216) - up to 16 colors
    }

    IDixelClubV2Factory private _factory;
    uint40 private _initializedAt;
    Shared.MetaData private _metaData; // Collection meta data
    uint256 private _tokenIdTracker;

    EditionData[] private _editionData; // Color (palette) data for each edition
    uint8[PIXEL_ARRAY_SIZE] private _pixels; // 8 * 288 = 2304bit = 9 of 256bit storage block. Each uint8 saves 2 pixels.
    address[] private _whitelist;
    string private _description;

    event Mint(address indexed to, uint256 indexed tokenId);
    event Burn(uint256 indexed tokenId);

    modifier checkTokenExists(uint256 tokenId) {
        if (!_exists(tokenId)) revert DixelClubV2__NotExist();
        _;
    }

    function init(
        address owner_,
        string calldata name_,
        string calldata symbol_,
        string calldata description_,
        Shared.MetaData calldata metaData_,
        uint24[PALETTE_SIZE] calldata palette_,
        uint8[PIXEL_ARRAY_SIZE] calldata pixels_
    ) external {
        if(_initializedAt != 0) revert DixelClubV2__Initalized();
        _initializedAt = uint40(block.timestamp);

        _factory = IDixelClubV2Factory(msg.sender);

        // ERC721 attributes
        _name = name_;
        _symbol = symbol_;
        _description = description_;

        // Custom attributes
        _metaData = metaData_;
        _pixels = pixels_;

        // Transfer ownership to the collection creator, so he/she can edit info on marketplaces like Opeansea
        _transferOwnership(owner_);

        // Mint edition #0 to the creator with the default palette set automatically
        _mintNewEdition(owner_, palette_);
    }

    function mintPublic(address to, uint24[PALETTE_SIZE] calldata palette) external payable {
        if(_metaData.whitelistOnly) revert DixelClubV2__PrivateCollection();

        _mintWithFees(to, palette);
    }

    function mintPrivate(uint256 whitelistIndex, address to, uint24[PALETTE_SIZE] calldata palette) external payable {
        if(!_metaData.whitelistOnly) revert DixelClubV2__PublicCollection();

        _removeWhitelist(whitelistIndex, msg.sender);

        _mintWithFees(to, palette);
    }

    function _mintWithFees(address to, uint24[PALETTE_SIZE] calldata palette) private {
        uint256 mintingCost = uint256(_metaData.mintingCost);

        if(msg.value != mintingCost) revert DixelClubV2__InvalidCost(mintingCost, msg.value);
        if(_tokenIdTracker >= _metaData.maxSupply) revert DixelClubV2__MaximumMinted();
        if(uint40(block.timestamp) < _metaData.mintingBeginsFrom) revert DixelClubV2__NotStarted(_metaData.mintingBeginsFrom, uint40(block.timestamp));

        if (mintingCost > 0) {
            // Send fee to the beneficiary
            uint256 fee = (mintingCost * _factory.mintingFee()) / FRICTION_BASE;
            (bool sent, ) = (_factory.beneficiary()).call{ value: fee }("");
            require(sent, "FEE_TRANSFER_FAILED");

            // Send the rest of minting cost to the collection creator
            (bool sent2, ) = (owner()).call{ value: mintingCost - fee }("");
            require(sent2, "MINTING_COST_TRANSFER_FAILED");
        }

        _mintNewEdition(to, palette);
    }

    function _mintNewEdition(address to, uint24[PALETTE_SIZE] calldata palette) private {
        // We cannot just use balanceOf to create the new tokenId because tokens
        // can be burned (destroyed), so we need a separate counter.
        uint256 tokenId;
        unchecked {
            tokenId = _tokenIdTracker++;
        }

        _editionData.push(EditionData(palette));
        unchecked {
            assert(tokenId == _editionData.length - 1);
        }

        _safeMint(to, tokenId);

        emit Mint(to, tokenId);
    }

    function burn(uint256 tokenId) external {
        if(!_isApprovedOrOwner(msg.sender, tokenId)) revert DixelClubV2__NotApproved(); // This will check existence of token

        delete _editionData[tokenId];
        _burn(tokenId);

        emit Burn(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override checkTokenExists(tokenId) returns (string memory) {
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(tokenJSON(tokenId)))));
    }

    // Contract-level metadata for Opeansea
    // REF: https://docs.opensea.io/docs/contract-level-metadata
    function contractURI() public view returns (string memory) {
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(contractJSON()))));
    }

    // MARK: - Whitelist related functions

    // @dev Maximum length of list parameter can be limited by block gas limit of blockchain
    // @notice Duplicated address input means multiple allowance
    function addWhitelist(address[] calldata list) external onlyOwner {
        if(!_metaData.whitelistOnly) revert DixelClubV2__PublicCollection();

        uint256 length = list.length; // gas saving
        for (uint256 i; i != length; ) {
            _whitelist.push(list[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _removeWhitelist(uint256 index, address value) private {
        if(!_metaData.whitelistOnly) revert DixelClubV2__PublicCollection();
        if (_whitelist[index] != value) revert DixelClubV2__WhiteListValueDoNotMatch(value, _whitelist[index]);

        _whitelist[index] = _whitelist[_whitelist.length - 1]; // put the last element into the delete index
        _whitelist.pop(); // delete the last element to decrease array length;
    }

    function removeWhitelist(uint256 index, address value) external onlyOwner {
        _removeWhitelist(index, value);
    }

    // @dev offset & limit for pagination
    function getAllWhitelist(uint256 offset, uint256 limit) external view returns (address[] memory list) {
        uint256 length = _whitelist.length;
        uint256 count = limit;

        if (offset >= length) {
            return list; // empty list
        } else if (offset + limit > length) {
            count = length - offset;
        }

        list = new address[](count);
        for (uint256 i = 0; i != count;) {
            list[i] = _whitelist[offset + i];
            unchecked {
                ++i;
            }
        }
    }

    function getWhitelistCount() external view returns (uint256) {
        return _whitelist.length;
    }

    function getWhitelistAllowanceLeft(address wallet) external view returns (uint256 allowance) {
        uint256 length = _whitelist.length; // gas saving
        for (uint256 i; i != length; ) {
            if (_whitelist[i] == wallet) {
                allowance++;
            }
            unchecked {
                ++i;
            }
        }

        return allowance;
    }

    function getWhitelistIndex(address wallet) external view returns (uint256) {
        uint256 length = _whitelist.length; // gas saving
        for (uint256 i; i != length; ) {
            if (_whitelist[i] == wallet) {
                return i;
            }
            unchecked {
                ++i;
            }
        }

        revert DixelClubV2__NotWhitelisted();
    }


    // MARK: - Update metadata

    function updateMetadata(bool whitelistOnly, bool hidden, uint24 royaltyFriction, uint40 mintingBeginsFrom, uint152 mintingCost) external onlyOwner {
        if(royaltyFriction > MAX_ROYALTY_FRACTION) revert DixelClubV2__InvalidRoyalty(royaltyFriction);
        if(_metaData.mintingBeginsFrom != mintingBeginsFrom && uint40(block.timestamp) >= _metaData.mintingBeginsFrom) revert DixelClubV2__AlreadyStarted();

        _metaData.whitelistOnly = whitelistOnly;
        if (!_metaData.whitelistOnly) {
            delete _whitelist; // empty whitelist array data if it becomes public
        }

        _metaData.hidden = hidden;
        _metaData.royaltyFriction = royaltyFriction;
        _metaData.mintingBeginsFrom = mintingBeginsFrom;

        _metaData.mintingCost = mintingCost;
        // Neutralize minting starts date
        if (_metaData.mintingBeginsFrom < block.timestamp) {
            _metaData.mintingBeginsFrom = uint40(block.timestamp);
        }
    }

    function updateDescription(string calldata description) external onlyOwner {
        if (bytes(description).length > 1000) revert DixelClubV2__DescriptionTooLong(); // ~900 gas per character
        if (StringUtils.contains(description, 0x22)) revert DixelClubV2__ContainMalicious();

        _description = description;
    }

    // MARK: - External utility functions

    function generateSVG(uint256 tokenId) external view checkTokenExists(tokenId) returns (string memory) {
        return _generateSVG(_editionData[tokenId].palette, _pixels);
    }

    function generateBase64SVG(uint256 tokenId) public view checkTokenExists(tokenId) returns (string memory) {
        return _generateBase64SVG(_editionData[tokenId].palette, _pixels);
    }

    function tokenJSON(uint256 tokenId) public view checkTokenExists(tokenId) returns (string memory) {
        return string(abi.encodePacked(
            '{"name":"',
            _symbol, ' #', ColorUtils.uint2str(tokenId),
            '","description":"',
            _description,
            '","external_url":"https://dixel.club/collection/',
            ColorUtils.uint2str(block.chainid), '/', StringUtils.address2str(address(this)), '/', ColorUtils.uint2str(tokenId),
            '","image":"',
            generateBase64SVG(tokenId),
            '"}'
        ));
    }

    function contractJSON() public view returns (string memory) {
        return string(abi.encodePacked(
            '{"name":"',
            _name,
            '","description":"',
            _description,
            '","image":"',
            generateBase64SVG(0),
            '","external_link":"https://dixel.club/collection/',
            ColorUtils.uint2str(block.chainid), '/', StringUtils.address2str(address(this)),
            '","seller_fee_basis_points":"',
            ColorUtils.uint2str(_metaData.royaltyFriction),
            '","fee_recipient":"',
            StringUtils.address2str(owner()),
            '"}'
        ));
    }

    function nextTokenId() external view returns (uint256) {
        return _tokenIdTracker;
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _exists(tokenId);
    }

    function listData() external view returns (uint40 initializedAt_, bool hidden_) {
        initializedAt_ = _initializedAt;
        hidden_ = _metaData.hidden;
    }

    function metaData() external view returns (
        string memory name_,
        string memory symbol_,
        bool whitelistOnly_,
        uint24 maxSupply_,
        uint24 royaltyFriction_,
        uint40 mintingBeginsFrom_,
        uint168 mintingCost_,
        string memory description_,
        uint256 totalSupply_,
        address owner_,
        uint8[PIXEL_ARRAY_SIZE] memory pixels_,
        uint24[PALETTE_SIZE] memory defaultPalette_
    ) {
        name_ = name();
        symbol_ = symbol();
        whitelistOnly_ = _metaData.whitelistOnly;
        maxSupply_ = _metaData.maxSupply;
        royaltyFriction_ = _metaData.royaltyFriction;
        mintingBeginsFrom_ = _metaData.mintingBeginsFrom;
        mintingCost_ = _metaData.mintingCost;
        description_ = _description;
        totalSupply_ = totalSupply();
        owner_ = owner();
        pixels_ = _pixels;
        defaultPalette_ = _editionData[0].palette;
    }

    function paletteOf(uint256 tokenId) external view checkTokenExists(tokenId) returns (uint24[PALETTE_SIZE] memory) {
        return _editionData[tokenId].palette;
    }

    function getAllPixels() external view returns (uint8[PIXEL_ARRAY_SIZE] memory) {
        return _pixels;
    }

    // MARK: - Override extensions

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev IERC2981 implementation
     * - NOTE: ERC2981 royalty info may not be applied on some marketplaces
     * - NOTE: Opensea uses contract-level metadata: https://docs.opensea.io/docs/contract-level-metadata
     */
    function royaltyInfo(uint256 /*_tokenId*/, uint256 _salePrice) public view returns (address, uint256) {
        // NOTE:
        // 1. The same royalty friction for all tokens in the same collection
        // 2. Receiver is collection owner

        return (owner(), (_salePrice * _metaData.royaltyFriction) / FRICTION_BASE);
    }

    // NFT implementation version
    function version() external pure virtual returns (uint16) {
        return 1;
    }
}
