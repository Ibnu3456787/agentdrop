// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ERC-721 interface used by the market (both AgentHaven
///         Pass contracts implement it).
interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Minimal ERC-20 interface used for USDT settlement. BSC USDT
///         (0x55d398326f99059fF775485246999027B3197955) is a standard BEP-20
///         with 18 decimals whose transfer/transferFrom return a bool.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner_, address spender) external view returns (uint256);
}

// The ERC-721 receiver selector (bytes4(keccak256(
// "onERC721Received(address,address,uint256,bytes)"))).
// Returned by onERC721Received to accept safe transfers.
bytes4 constant ERC721_RECEIVED = 0x150b7a02;

/// @title AgentHavenMarket
/// @notice A simple escrow marketplace for AgentHaven Pass NFTs (v1 + v2),
///         settling in BNB or USDT (BSC, 18 decimals).
/// @dev AgentHaven is an independent community project built for the Binance
///      Agent ID Hackathon. It is NOT affiliated with Binance or SPACE ID.
///      There is no token and no promised return.
///
///      How it works:
///      - list(): the seller escrows their Pass in this contract and sets a
///        price in BNB or USDT. Listing is free (gas only). The seller must
///        have approved the market for the token first
///        (approve(market, tokenId) is enough — no operator approval needed).
///      - buyListing(): the buyer pays exactly the listed price. BNB buys
///        send the price as msg.value; USDT buys pull the price from the
///        buyer via transferFrom (the buyer must approve the market for the
///        exact price first). The NFT moves to the buyer, the seller receives
///        the price minus the fee, and the fee goes to the owner.
///      - cancelListing(): the seller (only the seller) can cancel at any
///        time; the escrowed Pass returns to them. No fee is charged.
///
///      Fee: 2.5% (250 bps) of the sale price, rounded DOWN (the seller keeps
///      any sub-wei dust: fee = price * feeBps / 10000, seller gets
///      price - fee). The owner can change the fee via setFee, capped at
///      10% (1000 bps), and the cap is a constant — it can never be raised.
///
///      Safety properties:
///      - Escrow: a listed Pass is held by this contract, so a sold Pass is
///        always delivered and a token cannot be listed twice.
///      - Exact payment: BNB buys require msg.value == price exactly, and
///        USDT buys require msg.value == 0, so no excess BNB can be locked
///        in the contract. There is no receive/fallback function.
///      - Checks-effects-interactions + a re-entrancy guard on every
///        state-changing function that moves value or NFTs.
///      - The market only accepts ERC-721 safe transfers from the two Pass
///        contracts (onERC721Received reverts for any other caller), so
///        random NFTs cannot be sent here by accident.
///
///      Owner permissions (fully disclosed, see README):
///      - setFee(uint256): change the marketplace fee, capped at 10%.
///      - transferOwnership(address) / renounceOwnership(): standard ownership.
///      - rescueToken(collection, tokenId, to): return a Pass that was sent
///        to the market WITHOUT being listed (e.g. a fat-fingered direct
///        transfer). Reverts for any token that is part of an ACTIVE listing,
///        so escrowed listed Passes can never be rescued away.
///      - rescueERC20(token, to, amount): return ERC-20 tokens sent to the
///        market by mistake. USDT only ever sits in the contract during a
///        single buy transaction (pulled and paid out atomically), so this
///        cannot touch sale proceeds.
///      The owner CANNOT move escrowed listed Passes, change listing prices,
///      cancel other people's listings, or take a fee above 10%.
contract AgentHavenMarket {
    // ------------------------------------------------------------------------
    // Types & constants
    // ------------------------------------------------------------------------

    /// @notice Payment currency of a listing.
    enum Currency {
        BNB,
        USDT
    }

    /// @notice A single listing. `active` is false after a sale or cancel.
    struct Listing {
        uint256 id;
        address collection;
        uint256 tokenId;
        address seller;
        uint256 price;
        Currency currency;
        bool active;
    }

    /// @notice Basis points denominator (100% = 10000 bps).
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice The fee can never exceed 10% (1000 bps).
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice USDT on BNB Smart Chain (BEP-20, 18 decimals).
    address public immutable USDT;

    /// @notice AgentHaven Pass v1 (all-free pilot drop).
    address public immutable PASS_V1;

    /// @notice AgentHaven Pass v2 (1,111 free, then 0.00005 BNB per claim).
    address public immutable PASS_V2;

    /// @notice Contract owner (the deployer, or the address set at deploy).
    ///         Receives the marketplace fee and holds the disclosed powers
    ///         listed in the header above.
    address public owner;

    /// @notice Marketplace fee in basis points (250 = 2.5%).
    uint256 public feeBps;

    /// @notice Next listing ID to assign (starts at 1).
    uint256 public nextListingId = 1;

    /// @notice All listings ever created, by ID (including sold/cancelled).
    mapping(uint256 => Listing) private _listings;

    /// @notice IDs of currently active listings (swap-and-pop on removal).
    uint256[] private _activeIds;

    /// @notice 1-based index of a listing ID in _activeIds (0 = not active).
    mapping(uint256 => uint256) private _activeIndex;

    /// @notice Active listing ID for a token (0 = not listed).
    mapping(address => mapping(uint256 => uint256)) public activeListingOf;

    // Re-entrancy guard (hand-rolled; the project has no OpenZeppelin dep).
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event Listed(
        uint256 indexed id,
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        uint256 price,
        Currency currency
    );
    event Sale(
        uint256 indexed id,
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address buyer,
        uint256 price,
        uint256 fee,
        Currency currency
    );
    event Cancelled(uint256 indexed id, address indexed collection, uint256 indexed tokenId, address seller);
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenRescued(address indexed collection, uint256 indexed tokenId, address indexed to);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    // ------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------

    error NotOwner();
    error ZeroAddress();
    error FeeTooHigh();
    error UnsupportedCollection();
    error InvalidPrice();
    error NotTokenOwner();
    error ListingNotFound();
    error ListingNotActive();
    error SelfBuy();
    error WrongValue();
    error PaymentFailed();
    error TokenTransferFailed();
    error TokenIsListed();
    error Reentrancy();

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    constructor(address owner_, address usdt_, address passV1_, address passV2_, uint256 feeBps_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (usdt_ == address(0)) revert ZeroAddress();
        if (passV1_ == address(0)) revert ZeroAddress();
        if (passV2_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        owner = owner_;
        USDT = usdt_;
        PASS_V1 = passV1_;
        PASS_V2 = passV2_;
        feeBps = feeBps_;
        emit OwnershipTransferred(address(0), owner_);
        emit FeeUpdated(0, feeBps_);
    }

    // ------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ------------------------------------------------------------------------
    // Listing
    // ------------------------------------------------------------------------

    /// @notice List a Pass for sale. The Pass is escrowed in this contract
    ///         until it sells or the listing is cancelled. Listing is free
    ///         (gas only). The caller must own the token and must have
    ///         approved this contract for it first (approve(market, tokenId)
    ///         is enough).
    /// @param collection The Pass contract (v1 or v2 only).
    /// @param tokenId The Pass token ID.
    /// @param price Sale price in the listing currency's smallest unit
    ///        (wei for BNB, 1e-18 USDT for USDT). Must be > 0.
    /// @param currency BNB or USDT.
    /// @return listingId The new listing's ID (sequential from 1).
    function list(address collection, uint256 tokenId, uint256 price, Currency currency)
        external
        nonReentrant
        returns (uint256 listingId)
    {
        if (collection != PASS_V1 && collection != PASS_V2) revert UnsupportedCollection();
        if (price == 0) revert InvalidPrice();
        // ownerOf reverts if the token does not exist; the revert is
        // intentional — a non-existent token cannot be listed.
        if (IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        // Effects before interaction: record the listing, then escrow.
        // If the escrow transfer reverts (e.g. no approval), the whole
        // transaction reverts and no listing is recorded.
        listingId = nextListingId;
        nextListingId += 1;
        _listings[listingId] = Listing({
            id: listingId,
            collection: collection,
            tokenId: tokenId,
            seller: msg.sender,
            price: price,
            currency: currency,
            active: true
        });
        _activeIds.push(listingId);
        _activeIndex[listingId] = _activeIds.length;
        activeListingOf[collection][tokenId] = listingId;

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
        emit Listed(listingId, collection, tokenId, msg.sender, price, currency);
    }

    /// @notice Cancel an active listing. Only the seller can cancel. The
    ///         escrowed Pass returns to the seller. No fee is charged.
    function cancelListing(uint256 listingId) external nonReentrant {
        Listing storage listing = _listings[listingId];
        if (listing.id == 0) revert ListingNotFound();
        if (!listing.active) revert ListingNotActive();
        if (listing.seller != msg.sender) revert NotTokenOwner();

        // Effects before interaction.
        listing.active = false;
        _removeActive(listingId);
        delete activeListingOf[listing.collection][listing.tokenId];

        IERC721(listing.collection).transferFrom(address(this), listing.seller, listing.tokenId);
        emit Cancelled(listingId, listing.collection, listing.tokenId, listing.seller);
    }

    /// @notice Buy an active listing at its listed price.
    /// @dev BNB listings: send exactly `price` wei as msg.value.
    ///      USDT listings: send 0 BNB and approve this contract for exactly
    ///      `price` USDT first; the price is pulled via transferFrom.
    ///      The NFT goes to the buyer, the seller receives price - fee, and
    ///      the fee (price * feeBps / 10000, rounded down) goes to the owner.
    function buyListing(uint256 listingId) external payable nonReentrant {
        Listing storage listing = _listings[listingId];
        if (listing.id == 0) revert ListingNotFound();
        if (!listing.active) revert ListingNotActive();
        if (listing.seller == msg.sender) revert SelfBuy();

        uint256 price = listing.price;
        uint256 fee = feeFor(price);
        uint256 proceeds = price - fee;

        if (listing.currency == Currency.BNB) {
            if (msg.value != price) revert WrongValue();
        } else {
            // USDT buys must not attach BNB: anything attached would be
            // locked in the contract (there is no withdraw for stray BNB).
            if (msg.value != 0) revert WrongValue();
        }

        // Effects before interactions: deactivate the listing first, so a
        // re-entrant buy of the same listing always reverts.
        listing.active = false;
        _removeActive(listingId);
        delete activeListingOf[listing.collection][listing.tokenId];

        address collection = listing.collection;
        uint256 tokenId = listing.tokenId;
        address seller = listing.seller;

        if (listing.currency == Currency.BNB) {
            IERC721(collection).transferFrom(address(this), msg.sender, tokenId);
            (bool okSeller, ) = payable(seller).call{value: proceeds}("");
            if (!okSeller) revert PaymentFailed();
            (bool okFee, ) = payable(owner).call{value: fee}("");
            if (!okFee) revert PaymentFailed();
        } else {
            // Pull the payment first, then distribute. If the buyer did not
            // approve enough USDT, transferFrom reverts and nothing moves.
            if (!IERC20(USDT).transferFrom(msg.sender, address(this), price)) {
                revert TokenTransferFailed();
            }
            IERC721(collection).transferFrom(address(this), msg.sender, tokenId);
            if (!IERC20(USDT).transfer(seller, proceeds)) revert TokenTransferFailed();
            if (!IERC20(USDT).transfer(owner, fee)) revert TokenTransferFailed();
        }

        emit Sale(listingId, collection, tokenId, seller, msg.sender, price, fee, listing.currency);
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    /// @notice The fee charged on a sale of `price` (rounded down).
    function feeFor(uint256 price) public view returns (uint256) {
        return (price * feeBps) / BPS_DENOMINATOR;
    }

    /// @notice A single listing by ID (reverts if it never existed).
    function getListing(uint256 listingId) external view returns (Listing memory) {
        Listing memory listing = _listings[listingId];
        if (listing.id == 0) revert ListingNotFound();
        return listing;
    }

    /// @notice Active listings, paginated (newest listings are at the end of
    ///         the internal order; the frontend sorts as it wishes).
    /// @param offset Index of the first listing to return.
    /// @param limit Maximum number of listings to return.
    function getActiveListings(uint256 offset, uint256 limit) external view returns (Listing[] memory result) {
        uint256 total = _activeIds.length;
        if (offset >= total) return new Listing[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        result = new Listing[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = _listings[_activeIds[i]];
        }
    }

    /// @notice IDs of active listings, paginated. Cheaper to decode than
    ///         getActiveListings for frontends that fetch listings one by one.
    function getActiveListingIds(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory result)
    {
        uint256 total = _activeIds.length;
        if (offset >= total) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        result = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = _activeIds[i];
        }
    }

    /// @notice Total listings ever created (including sold/cancelled).
    function listingCount() external view returns (uint256) {
        return nextListingId - 1;
    }

    /// @notice Number of currently active listings.
    function activeCount() external view returns (uint256) {
        return _activeIds.length;
    }

    // ------------------------------------------------------------------------
    // ERC-721 receiver
    // ------------------------------------------------------------------------

    /// @notice Accepts safe transfers ONLY from the two Pass contracts, so
    ///         unrelated NFTs cannot be sent here by accident. (A Pass sent
    ///         directly without listing can be returned via rescueToken.)
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != PASS_V1 && msg.sender != PASS_V2) revert UnsupportedCollection();
        return ERC721_RECEIVED;
    }

    // ------------------------------------------------------------------------
    // Owner (minimal, disclosed)
    // ------------------------------------------------------------------------

    /// @notice Change the marketplace fee. Capped at 10% (1000 bps).
    ///         Applies to future sales only; existing listings keep their
    ///         price, and the fee is computed at sale time.
    function setFee(uint256 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 oldFee = feeBps;
        feeBps = feeBps_;
        emit FeeUpdated(oldFee, feeBps_);
    }

    /// @notice Return a Pass that was sent to the market WITHOUT being
    ///         listed (e.g. a fat-fingered direct transfer). Reverts for any
    ///         token that is part of an ACTIVE listing — escrowed listed
    ///         Passes can never be rescued away.
    function rescueToken(address collection, uint256 tokenId, address to) external onlyOwner {
        if (collection != PASS_V1 && collection != PASS_V2) revert UnsupportedCollection();
        if (to == address(0)) revert ZeroAddress();
        if (activeListingOf[collection][tokenId] != 0) revert TokenIsListed();
        IERC721(collection).transferFrom(address(this), to, tokenId);
        emit TokenRescued(collection, tokenId, to);
    }

    /// @notice Return ERC-20 tokens sent to the market by mistake. USDT only
    ///         ever sits in this contract during a single buy transaction
    ///         (pulled and paid out atomically), so this cannot touch sale
    ///         proceeds.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (!IERC20(token).transfer(to, amount)) revert TokenTransferFailed();
        emit ERC20Rescued(token, to, amount);
    }

    /// @notice Transfer ownership to a new owner (who then receives the fee).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Renounce ownership. Irreversible: after this, the fee can
    ///         never change again and rescue functions are unusable. Note the
    ///         fee is still paid to the zero address on every sale, so this
    ///         effectively burns the fee — do not renounce unless that is
    ///         intended.
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------

    /// @notice Remove a listing ID from the active array (swap-and-pop).
    function _removeActive(uint256 listingId) internal {
        uint256 indexPlusOne = _activeIndex[listingId];
        uint256 idx = indexPlusOne - 1;
        uint256 lastId = _activeIds[_activeIds.length - 1];
        _activeIds[idx] = lastId;
        _activeIndex[lastId] = idx + 1;
        _activeIds.pop();
        delete _activeIndex[listingId];
    }
}
