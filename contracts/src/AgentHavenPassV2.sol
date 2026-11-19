// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base64.sol";

/// @notice Minimal interface of the official Agent ID registry (SPACE ID Agent ID)
///         on BNB Smart Chain: 0x60b9262456de011f7d15a54cdd8c48baaa8b022f
interface IAgentIDRegistry {
    /// @notice Returns how many Agent IDs `owner` holds (0 or 1 in practice).
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Returns the .ai handle registered to `owner` (without the
    ///         ".ai" suffix, e.g. "idawati"). Empty string if none.
    function handleOf(address owner) external view returns (string memory);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @title AgentHavenPassV2
/// @notice A tiered-pricing on-chain pass NFT for holders of a .ai Agent ID.
/// @dev AgentHaven is an independent community project built for the Binance
///      Agent ID Hackathon. It is NOT affiliated with Binance or SPACE ID.
///      There is no token and no promised return.
///
///      Pricing: the first 1,111 Passes (token IDs 1-1111) are free to claim
///      (gas only); every later claim costs exactly 0.00005 BNB. claim() is
///      payable and requires msg.value == claimPrice() — overpaying or
///      underpaying reverts, so no BNB can be accidentally locked in the
///      contract. Claim fees accumulate in the contract and only the owner
///      can withdraw them (see withdraw()). There is no receive/fallback
///      function, so BNB can only enter the contract through claim().
///
///      v1 note: AgentHavenPass v1 (0xf8118d518a228B704947eCf89C264B4F4F79aC5D)
///      was the all-free pilot drop. Its passes remain valid on-chain; v2 is
///      a separate contract with the same name, symbol, supply cap, and
///      metadata format, plus the tiered pricing above.
///
///      Agent ID integration (the core of this project):
///      - Access control: claim() requires the caller to hold an Agent ID,
///        verified on-chain via the registry's balanceOf().
///      - Identity: claim() resolves the caller's .ai handle on-chain via the
///        registry's handleOf() and embeds it permanently in the Pass
///        metadata (name, SVG artwork, and attributes).
///      - One Pass per wallet, enforced by the `claimed` mapping.
///
///      Owner permissions (fully disclosed, see README):
///      - setPaused(bool): emergency pause/unpause of claiming only.
///      - withdraw(): sends the full contract balance (accumulated claim
///        fees) to the owner. Reverts if the balance is zero.
///      - transferOwnership(address) / renounceOwnership(): standard ownership.
///      The owner CANNOT mint, burn, change metadata, move tokens, or change
///      the price (FREE_SUPPLY and PAID_PRICE are immutable constants).
contract AgentHavenPassV2 {
    // ------------------------------------------------------------------------
    // Constants & immutable state
    // ------------------------------------------------------------------------

    string public constant name = "AgentHaven Pass";
    string public constant symbol = "AHPASS";

    /// @notice Maximum number of Passes ever claimable.
    uint256 public constant MAX_SUPPLY = 10000;

    /// @notice The first FREE_SUPPLY claims (token IDs 1-1111) are free.
    uint256 public constant FREE_SUPPLY = 1111;

    /// @notice Price of each claim after the free tier (token IDs 1112+).
    uint256 public constant PAID_PRICE = 0.00005 ether;

    /// @notice The official Agent ID registry on BNB Smart Chain.
    address public immutable REGISTRY;

    /// @notice Number of Passes claimed so far. Token IDs are sequential
    ///         starting at 1, so totalSupply() == totalMinted.
    uint256 public totalMinted;

    /// @notice True once an address has claimed its one Pass.
    mapping(address => bool) public claimed;

    /// @notice Whether claiming is paused (emergency only).
    bool public paused;

    /// @notice Contract owner (the deployer). See the permission disclosure above.
    address public owner;

    // ------------------------------------------------------------------------
    // ERC-721 state
    // ------------------------------------------------------------------------

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    /// @notice The .ai handle embedded in each Pass (without ".ai" suffix).
    mapping(uint256 => string) private _agentHandles;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Claimed(address indexed claimer, uint256 indexed tokenId, string handle);
    event Withdrawn(address indexed to, uint256 amount);
    event PausedSet(bool paused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------

    error NotAgentIDHolder();
    error AlreadyClaimed();
    error SoldOut();
    error ClaimPaused();
    error WrongValue();
    error NothingToWithdraw();
    error WithdrawFailed();
    error NotOwner();
    error TokenDoesNotExist();
    error TransferToZeroAddress();
    error NotTokenOwnerOrApproved();
    error InvalidReceiver();
    error ZeroAddress();

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    constructor(address registry_) {
        if (registry_ == address(0)) revert ZeroAddress();
        REGISTRY = registry_;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ------------------------------------------------------------------------
    // Claiming
    // ------------------------------------------------------------------------

    /// @notice The price of the NEXT claim: 0 while fewer than FREE_SUPPLY
    ///         Passes have been claimed, PAID_PRICE (0.00005 BNB) after that.
    function claimPrice() public view returns (uint256) {
        return totalMinted < FREE_SUPPLY ? 0 : PAID_PRICE;
    }

    /// @notice Claim the caller's one AgentHaven Pass.
    /// @dev Requirements, in order:
    ///      1. Claiming is not paused.
    ///      2. The attached BNB equals claimPrice() exactly (0 for the first
    ///         1,111 claims, 0.00005 BNB after that). Overpaying reverts so
    ///         no excess BNB can be locked in the contract.
    ///      3. The caller holds an Agent ID (registry balanceOf > 0).
    ///      4. The caller has not claimed before.
    ///      5. Supply remains below MAX_SUPPLY.
    ///      The caller's .ai handle is resolved on-chain and stored with the
    ///      token, so the Pass is permanently personalised.
    /// @return tokenId The ID of the newly claimed Pass (sequential from 1).
    function claim() external payable returns (uint256 tokenId) {
        if (paused) revert ClaimPaused();
        if (msg.value != claimPrice()) revert WrongValue();
        IAgentIDRegistry registry = IAgentIDRegistry(REGISTRY);
        if (registry.balanceOf(msg.sender) == 0) revert NotAgentIDHolder();
        if (claimed[msg.sender]) revert AlreadyClaimed();
        if (totalMinted >= MAX_SUPPLY) revert SoldOut();

        // Effects before interaction: mark claimed and bump supply BEFORE
        // the safe-mint receiver callback, so re-entrancy cannot double-claim.
        claimed[msg.sender] = true;
        totalMinted += 1;
        tokenId = totalMinted;

        string memory handle = registry.handleOf(msg.sender);
        _agentHandles[tokenId] = handle;

        _safeMint(msg.sender, tokenId);
        emit Claimed(msg.sender, tokenId, handle);
    }

    /// @notice The .ai handle embedded in `tokenId` (without ".ai" suffix).
    function agentHandle(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        return _agentHandles[tokenId];
    }

    /// @notice Total Passes in existence (== totalMinted, tokens never burn).
    function totalSupply() external view returns (uint256) {
        return totalMinted;
    }

    // ------------------------------------------------------------------------
    // Metadata (fully on-chain)
    // ------------------------------------------------------------------------

    /// @notice Fully on-chain token metadata: a base64 data-URI JSON document
    ///         whose image is a base64 data-URI SVG badge showing the holder's
    ///         .ai handle and the Pass number. No external dependency.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();

        string memory handle = _agentHandles[tokenId];
        string memory handleWithSuffix = string.concat(handle, ".ai");
        string memory idString = _toString(tokenId);

        string memory svg = _svg(handleWithSuffix, idString);

        string memory json = string.concat(
            '{"name":"AgentHaven Pass #',
            idString,
            " \\u2014 ",
            handleWithSuffix,
            '","description":"An on-chain pass for .ai Agent ID holders, claimed from AgentHaven. The first 1,111 Passes are free to claim (gas only); later claims cost 0.00005 BNB. No token, no promised returns. AgentHaven is an independent community project, unaffiliated with Binance or SPACE ID.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"Agent ID","value":"',
            handleWithSuffix,
            '"},{"trait_type":"Pass Number","value":',
            idString,
            '},{"trait_type":"Claim Order","value":',
            idString,
            "}]}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice Renders the SVG badge. Font size adapts to handle length so
    ///         long handles (up to 20 chars + ".ai") still fit the badge.
    function _svg(string memory handleWithSuffix, string memory idString) internal pure returns (string memory) {
        uint256 len = bytes(handleWithSuffix).length;
        string memory fontSize = len <= 13 ? "34" : len <= 18 ? "28" : "22";

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 400 400">',
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0" stop-color="#0b1026"/><stop offset="1" stop-color="#1b2a6b"/>',
            "</linearGradient></defs>",
            '<rect width="400" height="400" rx="24" fill="url(#g)"/>',
            '<rect x="10" y="10" width="380" height="380" rx="18" fill="none" stroke="#f0b90b" stroke-width="2"/>',
            '<text x="200" y="76" text-anchor="middle" font-family="monospace" font-size="22" letter-spacing="6" fill="#f0b90b">AGENTHAVEN</text>',
            '<text x="200" y="104" text-anchor="middle" font-family="monospace" font-size="12" letter-spacing="4" fill="#8a93b2">AGENT PASS</text>',
            // No decorative circle around the handle: at 34px a typical
            // handle is ~220px wide, far wider than any circle that fits
            // between the header and the pass number.
            '<text x="200" y="202" text-anchor="middle" font-family="monospace" font-size="',
            fontSize,
            '" fill="#ffffff">',
            handleWithSuffix,
            "</text>",
            '<text x="200" y="300" text-anchor="middle" font-family="monospace" font-size="16" fill="#8a93b2">PASS #',
            idString,
            "</text>",
            '<text x="200" y="336" text-anchor="middle" font-family="monospace" font-size="12" fill="#8a93b2">AGENT ID HOLDER</text>',
            "</svg>"
        );
    }

    // ------------------------------------------------------------------------
    // Owner (minimal, disclosed)
    // ------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Emergency pause/unpause of claiming. Does not affect existing
    ///         Passes or transfers in any way.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Withdraw all accumulated claim fees to the owner.
    /// @dev Only the owner can call this, and only the full balance can be
    ///      withdrawn (no partial amounts, no recipient parameter). Reverts
    ///      when the contract holds nothing. Claim fees are the ONLY BNB the
    ///      contract can ever hold: there is no receive/fallback function,
    ///      so BNB enters only through claim() at the exact claim price.
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToWithdraw();
        emit Withdrawn(owner, balance);
        (bool ok, ) = payable(owner).call{value: balance}("");
        if (!ok) revert WithdrawFailed();
    }

    /// @notice Transfer ownership to a new owner.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Renounce ownership. Irreversible: after this, claiming can
    ///         never be paused again.
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ------------------------------------------------------------------------
    // ERC-721 (minimal, self-contained)
    // ------------------------------------------------------------------------

    function balanceOf(address owner_) external view returns (uint256) {
        if (owner_ == address(0)) revert ZeroAddress();
        return _balances[owner_];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address tokenOwner = _owners[tokenId];
        if (tokenOwner == address(0)) revert TokenDoesNotExist();
        return tokenOwner;
    }

    function approve(address to, uint256 tokenId) external {
        address tokenOwner = _owners[tokenId];
        if (tokenOwner == address(0)) revert TokenDoesNotExist();
        if (msg.sender != tokenOwner && !_operatorApprovals[tokenOwner][msg.sender]) {
            revert NotTokenOwnerOrApproved();
        }
        _tokenApprovals[tokenId] = to;
        emit Approval(tokenOwner, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        if (operator == address(0)) revert ZeroAddress();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (to == address(0)) revert TransferToZeroAddress();
        address tokenOwner = _owners[tokenId];
        if (tokenOwner == address(0)) revert TokenDoesNotExist();
        if (tokenOwner != from) revert NotTokenOwnerOrApproved();
        if (
            msg.sender != tokenOwner && _tokenApprovals[tokenId] != msg.sender
                && !_operatorApprovals[tokenOwner][msg.sender]
        ) revert NotTokenOwnerOrApproved();
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        _checkReceiver(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
        transferFrom(from, to, tokenId);
        _checkReceiver(from, to, tokenId, data);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0x80ac58cd // ERC-721
            || interfaceId == 0x5b5e139f; // ERC-721 Metadata
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        delete _tokenApprovals[tokenId];
        unchecked {
            _balances[from] -= 1;
            _balances[to] += 1;
        }
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function _safeMint(address to, uint256 tokenId) internal {
        if (to == address(0)) revert TransferToZeroAddress();
        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
        _checkReceiver(address(0), to, tokenId, "");
    }

    function _checkReceiver(address from, address to, uint256 tokenId, bytes memory data) internal {
        if (to.code.length == 0) return;
        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
            if (retval != IERC721Receiver.onERC721Received.selector) revert InvalidReceiver();
        } catch (bytes memory reason) {
            if (reason.length == 0) revert InvalidReceiver();
            assembly {
                revert(add(32, reason), mload(reason))
            }
        }
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
