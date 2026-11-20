// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentHavenMarket.sol";
// Named imports: both Pass files declare file-level IAgentIDRegistry /
// IERC721Receiver interfaces, so plain imports would collide.
import {AgentHavenPass} from "../src/AgentHavenPass.sol";
import {AgentHavenPassV2} from "../src/AgentHavenPassV2.sol";
import "./MockRegistry.sol";

/// @notice 18-decimal ERC-20 stand-in for BSC USDT (which is also 18
///         decimals). Minimal on purpose: mint, approve, transfer,
///         transferFrom with standard revert-on-insufficient behaviour.
contract MockUSDT {
    string public constant name = "Mock USDT";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    error TransferToZeroAddress();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert TransferToZeroAddress();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert TransferToZeroAddress();
        if (allowance[from][msg.sender] < amount) revert InsufficientAllowance();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice A seller contract that tries to re-enter buyListing() while
///         receiving its BNB payout. The market's re-entrancy guard must make
///         the inner buy fail, while the outer buy still succeeds.
contract ReentrantSeller {
    AgentHavenMarket public immutable market;
    uint256 public targetListingId;
    bool public reentrySucceeded;

    constructor(address market_) {
        market = AgentHavenMarket(market_);
    }

    function setTarget(uint256 listingId) external {
        targetListingId = listingId;
    }

    // Accepts the safe-mint callback when claiming its Pass.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0x150b7a02; // IERC721Receiver.onERC721Received.selector
    }

    // Called when the market pays this contract its sale proceeds. Tries to
    // buy another listing from inside the payout — must fail.
    receive() external payable {
        (bool ok, ) = address(market).call{value: 1 ether}(
            abi.encodeWithSignature("buyListing(uint256)", targetListingId)
        );
        reentrySucceeded = ok;
    }
}

/// @notice Unit tests for AgentHavenMarket (v1 + v2 Passes, BNB + USDT).
/// @dev Uses the REAL Pass contracts (v1 + v2) with the MockRegistry, so the
///      escrow / approval / transfer paths are exercised end to end.
contract AgentHavenMarketTest is Test {
    AgentHavenMarket public market;
    AgentHavenPass public passV1;
    AgentHavenPassV2 public passV2;
    MockRegistry public registry;
    MockUSDT public usdt;

    address public owner = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xCA901);
    address public dave = address(0xDA9E);

    event Listed(
        uint256 indexed id,
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        uint256 price,
        AgentHavenMarket.Currency currency
    );
    event Sale(
        uint256 indexed id,
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address buyer,
        uint256 price,
        uint256 fee,
        AgentHavenMarket.Currency currency
    );
    event Cancelled(uint256 indexed id, address indexed collection, uint256 indexed tokenId, address seller);
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    // The test contract is the market owner, so sale fees (BNB) are paid to
    // it via a low-level call. forge-std's Test has no receive(), so this
    // contract needs one. (In production the owner is an EOA.)
    receive() external payable {}

    function setUp() public {
        registry = new MockRegistry();
        passV1 = new AgentHavenPass(address(registry));
        passV2 = new AgentHavenPassV2(address(registry));
        usdt = new MockUSDT();
        market = new AgentHavenMarket(owner, address(usdt), address(passV1), address(passV2), 250);

        // Agent IDs for the traders (dave has none).
        registry.setHandle(alice, "alice");
        registry.setHandle(bob, "bob123");
        registry.setHandle(carol, "carol");

        // Each trader claims one v1 Pass and one v2 Pass.
        // v1 token IDs: alice 1, bob 2, carol 3. v2 token IDs: same order.
        vm.prank(alice);
        passV1.claim();
        vm.prank(bob);
        passV1.claim();
        vm.prank(carol);
        passV1.claim();
        vm.prank(alice);
        passV2.claim();
        vm.prank(bob);
        passV2.claim();
        vm.prank(carol);
        passV2.claim();

        // Trading funds.
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dave, 100 ether);
        usdt.mint(bob, 10_000 ether);
        usdt.mint(carol, 10_000 ether);
        usdt.mint(dave, 10_000 ether);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Approve the market for one token, then list it. Returns the
    ///      listing ID.
    function _list(address seller, address collection, uint256 tokenId, uint256 price, AgentHavenMarket.Currency currency)
        internal
        returns (uint256)
    {
        vm.startPrank(seller);
        if (collection == address(passV1)) {
            passV1.approve(address(market), tokenId);
        } else {
            passV2.approve(address(market), tokenId);
        }
        uint256 id = market.list(collection, tokenId, price, currency);
        vm.stopPrank();
        return id;
    }

    // ------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------

    function test_Deployment() public view {
        assertEq(market.owner(), owner);
        assertEq(market.feeBps(), 250);
        assertEq(market.USDT(), address(usdt));
        assertEq(market.PASS_V1(), address(passV1));
        assertEq(market.PASS_V2(), address(passV2));
        assertEq(market.MAX_FEE_BPS(), 1000);
        assertEq(market.BPS_DENOMINATOR(), 10000);
        assertEq(market.nextListingId(), 1);
        assertEq(market.listingCount(), 0);
        assertEq(market.activeCount(), 0);
    }

    function test_ConstructorRevertsOnZeroOwner() public {
        vm.expectRevert(AgentHavenMarket.ZeroAddress.selector);
        new AgentHavenMarket(address(0), address(usdt), address(passV1), address(passV2), 250);
    }

    function test_ConstructorRevertsOnZeroUSDT() public {
        vm.expectRevert(AgentHavenMarket.ZeroAddress.selector);
        new AgentHavenMarket(owner, address(0), address(passV1), address(passV2), 250);
    }

    function test_ConstructorRevertsOnZeroCollection() public {
        vm.expectRevert(AgentHavenMarket.ZeroAddress.selector);
        new AgentHavenMarket(owner, address(usdt), address(0), address(passV2), 250);
        vm.expectRevert(AgentHavenMarket.ZeroAddress.selector);
        new AgentHavenMarket(owner, address(usdt), address(passV1), address(0), 250);
    }

    function test_ConstructorRevertsOnFeeTooHigh() public {
        vm.expectRevert(AgentHavenMarket.FeeTooHigh.selector);
        new AgentHavenMarket(owner, address(usdt), address(passV1), address(passV2), 1001);
    }

    // ------------------------------------------------------------------
    // Listing — happy paths (both collections x both currencies)
    // ------------------------------------------------------------------

    function test_ListV1BNB() public {
        // Approve first: expectEmit matches the NEXT event, and approve()
        // emits an Approval event before list() emits Listed.
        vm.prank(alice);
        passV1.approve(address(market), 1);
        vm.expectEmit(true, true, true, true);
        emit Listed(1, address(passV1), 1, alice, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.prank(alice);
        uint256 id = market.list(address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        assertEq(id, 1);
        assertEq(passV1.ownerOf(1), address(market)); // escrowed
        assertEq(market.activeCount(), 1);
        assertEq(market.listingCount(), 1);
        assertEq(market.activeListingOf(address(passV1), 1), 1);
        AgentHavenMarket.Listing memory l = market.getListing(1);
        assertEq(l.id, 1);
        assertEq(l.collection, address(passV1));
        assertEq(l.tokenId, 1);
        assertEq(l.seller, alice);
        assertEq(l.price, 1 ether);
        assertEq(uint8(l.currency), uint8(AgentHavenMarket.Currency.BNB));
        assertTrue(l.active);
    }

    function test_ListV2BNB() public {
        uint256 id = _list(bob, address(passV2), 2, 0.5 ether, AgentHavenMarket.Currency.BNB);
        assertEq(id, 1);
        assertEq(passV2.ownerOf(2), address(market));
        assertEq(market.activeListingOf(address(passV2), 2), 1);
    }

    function test_ListV1USDT() public {
        uint256 id = _list(carol, address(passV1), 3, 50 ether, AgentHavenMarket.Currency.USDT);
        assertEq(id, 1);
        assertEq(passV1.ownerOf(3), address(market));
        AgentHavenMarket.Listing memory l = market.getListing(1);
        assertEq(uint8(l.currency), uint8(AgentHavenMarket.Currency.USDT));
        assertEq(l.price, 50 ether);
    }

    function test_ListV2USDT() public {
        uint256 id = _list(alice, address(passV2), 1, 0.25 ether, AgentHavenMarket.Currency.USDT);
        assertEq(id, 1);
        assertEq(passV2.ownerOf(1), address(market));
    }

    // ------------------------------------------------------------------
    // Listing — reverts
    // ------------------------------------------------------------------

    function test_ListRevertsForNonOwner() public {
        // Bob tries to list Alice's v1 Pass #1.
        vm.startPrank(bob);
        vm.expectRevert(AgentHavenMarket.NotTokenOwner.selector);
        market.list(address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.stopPrank();
    }

    function test_ListRevertsForZeroPrice() public {
        vm.startPrank(alice);
        passV1.approve(address(market), 1);
        vm.expectRevert(AgentHavenMarket.InvalidPrice.selector);
        market.list(address(passV1), 1, 0, AgentHavenMarket.Currency.BNB);
        vm.stopPrank();
    }

    function test_ListRevertsForUnsupportedCollection() public {
        vm.startPrank(alice);
        vm.expectRevert(AgentHavenMarket.UnsupportedCollection.selector);
        market.list(address(0x1234), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.stopPrank();
    }

    function test_ListRevertsWithoutApproval() public {
        // Alice owns v1 #1 but never approved the market: the escrow
        // transfer reverts inside the Pass contract.
        vm.startPrank(alice);
        vm.expectRevert(AgentHavenPassV2.NotTokenOwnerOrApproved.selector);
        market.list(address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.stopPrank();
    }

    function test_ListRevertsForNonexistentToken() public {
        vm.startPrank(alice);
        vm.expectRevert(AgentHavenPassV2.TokenDoesNotExist.selector);
        market.list(address(passV1), 999, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Buying — BNB
    // ------------------------------------------------------------------

    function test_BuyV1BNB() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        uint256 aliceBefore = alice.balance;
        uint256 ownerBefore = owner.balance;

        vm.expectEmit(true, true, true, true);
        emit Sale(id, address(passV1), 1, alice, bob, 1 ether, 0.025 ether, AgentHavenMarket.Currency.BNB);
        vm.prank(bob);
        market.buyListing{value: 1 ether}(id);

        assertEq(passV1.ownerOf(1), bob);
        assertEq(alice.balance, aliceBefore + 0.975 ether); // price - fee
        assertEq(owner.balance, ownerBefore + 0.025 ether); // 2.5% fee
        assertEq(market.activeCount(), 0);
        assertEq(market.activeListingOf(address(passV1), 1), 0);
        assertFalse(market.getListing(id).active);
    }

    function test_BuyV2BNB() public {
        uint256 id = _list(bob, address(passV2), 2, 0.1 ether, AgentHavenMarket.Currency.BNB);
        uint256 bobBefore = bob.balance;
        uint256 ownerBefore = owner.balance;
        vm.prank(carol);
        market.buyListing{value: 0.1 ether}(id);
        assertEq(passV2.ownerOf(2), carol);
        assertEq(bob.balance, bobBefore + 0.0975 ether);
        assertEq(owner.balance, ownerBefore + 0.0025 ether);
    }

    function test_BuyFeeRoundingDown() public {
        // 101 wei at 2.5%: fee = 101 * 250 / 10000 = 2 (2.525 truncated),
        // seller gets 99. The dust stays with the seller.
        uint256 id = _list(alice, address(passV1), 1, 101, AgentHavenMarket.Currency.BNB);
        uint256 aliceBefore = alice.balance;
        uint256 ownerBefore = owner.balance;
        vm.prank(bob);
        market.buyListing{value: 101}(id);
        assertEq(alice.balance, aliceBefore + 99);
        assertEq(owner.balance, ownerBefore + 2);
        assertEq(market.feeFor(101), 2);

        // 1 wei: fee rounds to 0, seller gets everything.
        uint256 id2 = _list(alice, address(passV2), 1, 1, AgentHavenMarket.Currency.BNB);
        uint256 aliceBefore2 = alice.balance;
        vm.prank(bob);
        market.buyListing{value: 1}(id2);
        assertEq(alice.balance, aliceBefore2 + 1);
        assertEq(market.feeFor(1), 0);
    }

    function test_BuyRevertsWrongValue() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.prank(bob);
        vm.expectRevert(AgentHavenMarket.WrongValue.selector);
        market.buyListing{value: 0.999 ether}(id);
        vm.prank(bob);
        vm.expectRevert(AgentHavenMarket.WrongValue.selector);
        market.buyListing{value: 1.001 ether}(id);
        // Listing is still active after the failed buys.
        assertTrue(market.getListing(id).active);
    }

    function test_BuyRevertsSelfBuy() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(AgentHavenMarket.SelfBuy.selector);
        market.buyListing{value: 1 ether}(id);
    }

    function test_BuyRevertsDoubleBuy() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.prank(bob);
        market.buyListing{value: 1 ether}(id);
        vm.prank(carol);
        vm.expectRevert(AgentHavenMarket.ListingNotActive.selector);
        market.buyListing{value: 1 ether}(id);
    }

    function test_BuyRevertsForNonexistentListing() public {
        vm.prank(bob);
        vm.expectRevert(AgentHavenMarket.ListingNotFound.selector);
        market.buyListing{value: 1 ether}(999);
    }

    // ------------------------------------------------------------------
    // Buying — USDT
    // ------------------------------------------------------------------

    function test_BuyV1USDT() public {
        uint256 id = _list(alice, address(passV1), 1, 50 ether, AgentHavenMarket.Currency.USDT);
        vm.prank(bob);
        usdt.approve(address(market), 50 ether);
        vm.expectEmit(true, true, true, true);
        emit Sale(id, address(passV1), 1, alice, bob, 50 ether, 1.25 ether, AgentHavenMarket.Currency.USDT);
        vm.prank(bob);
        market.buyListing(id);
        assertEq(passV1.ownerOf(1), bob);
        assertEq(usdt.balanceOf(alice), 48.75 ether);
        assertEq(usdt.balanceOf(owner), 1.25 ether);
        assertEq(usdt.balanceOf(bob), 10_000 ether - 50 ether);
        assertEq(usdt.balanceOf(address(market)), 0); // nothing left behind
        assertEq(market.activeCount(), 0);
    }

    function test_BuyV2USDT() public {
        uint256 id = _list(carol, address(passV2), 3, 0.5 ether, AgentHavenMarket.Currency.USDT);
        vm.prank(bob);
        usdt.approve(address(market), 0.5 ether);
        vm.prank(bob);
        market.buyListing(id);
        assertEq(passV2.ownerOf(3), bob);
        // Carol started with 10,000 USDT from setUp.
        assertEq(usdt.balanceOf(carol), 10_000 ether + 0.4875 ether);
        assertEq(usdt.balanceOf(owner), 0.0125 ether);
    }

    function test_BuyUSDTFeeRoundingDown() public {
        uint256 id = _list(alice, address(passV1), 1, 101, AgentHavenMarket.Currency.USDT);
        vm.prank(bob);
        usdt.approve(address(market), 101);
        vm.prank(bob);
        market.buyListing(id);
        assertEq(usdt.balanceOf(alice), 99);
        assertEq(usdt.balanceOf(owner), 2);
    }

    function test_BuyUSDTRevertsWithAttachedBNB() public {
        uint256 id = _list(alice, address(passV1), 1, 50 ether, AgentHavenMarket.Currency.USDT);
        vm.prank(bob);
        usdt.approve(address(market), 50 ether);
        vm.prank(bob);
        vm.expectRevert(AgentHavenMarket.WrongValue.selector);
        market.buyListing{value: 0.001 ether}(id);
        assertTrue(market.getListing(id).active);
    }

    function test_BuyUSDTRevertsWithoutApproval() public {
        uint256 id = _list(alice, address(passV1), 1, 50 ether, AgentHavenMarket.Currency.USDT);
        // Bob never approved: the USDT pull reverts.
        vm.prank(bob);
        vm.expectRevert(MockUSDT.InsufficientAllowance.selector);
        market.buyListing(id);
        assertTrue(market.getListing(id).active);
    }

    function test_BuyUSDTRevertsWithPartialApproval() public {
        uint256 id = _list(alice, address(passV1), 1, 50 ether, AgentHavenMarket.Currency.USDT);
        vm.prank(bob);
        usdt.approve(address(market), 49 ether);
        vm.prank(bob);
        vm.expectRevert(MockUSDT.InsufficientAllowance.selector);
        market.buyListing(id);
    }

    // ------------------------------------------------------------------
    // Cancelling
    // ------------------------------------------------------------------

    function test_CancelReturnsNFT() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.expectEmit(true, true, true, true);
        emit Cancelled(id, address(passV1), 1, alice);
        vm.prank(alice);
        market.cancelListing(id);
        assertEq(passV1.ownerOf(1), alice);
        assertEq(market.activeCount(), 0);
        assertEq(market.activeListingOf(address(passV1), 1), 0);
        assertFalse(market.getListing(id).active);
    }

    function test_CancelRevertsForNonSeller() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.prank(bob);
        vm.expectRevert(AgentHavenMarket.NotTokenOwner.selector);
        market.cancelListing(id);
        assertTrue(market.getListing(id).active);
    }

    function test_CancelRevertsAfterSale() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.prank(bob);
        market.buyListing{value: 1 ether}(id);
        vm.prank(alice);
        vm.expectRevert(AgentHavenMarket.ListingNotActive.selector);
        market.cancelListing(id);
    }

    function test_CancelRevertsForNonexistentListing() public {
        vm.prank(alice);
        vm.expectRevert(AgentHavenMarket.ListingNotFound.selector);
        market.cancelListing(999);
    }

    function test_BuyRevertsAfterCancel() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.prank(alice);
        market.cancelListing(id);
        vm.prank(bob);
        vm.expectRevert(AgentHavenMarket.ListingNotActive.selector);
        market.buyListing{value: 1 ether}(id);
    }

    function test_RelistAfterCancel() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        vm.prank(alice);
        market.cancelListing(id);
        // The Pass is back with Alice and can be listed again (new ID).
        uint256 id2 = _list(alice, address(passV1), 1, 2 ether, AgentHavenMarket.Currency.USDT);
        assertEq(id2, 2);
        assertEq(market.activeCount(), 1);
        assertEq(market.activeListingOf(address(passV1), 1), 2);
    }

    // ------------------------------------------------------------------
    // Views & pagination
    // ------------------------------------------------------------------

    function test_Pagination() public {
        _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        _list(bob, address(passV2), 2, 2 ether, AgentHavenMarket.Currency.BNB);
        _list(carol, address(passV1), 3, 50 ether, AgentHavenMarket.Currency.USDT);
        assertEq(market.listingCount(), 3);
        assertEq(market.activeCount(), 3);

        AgentHavenMarket.Listing[] memory page1 = market.getActiveListings(0, 2);
        assertEq(page1.length, 2);
        assertEq(page1[0].id, 1);
        assertEq(page1[1].id, 2);

        AgentHavenMarket.Listing[] memory page2 = market.getActiveListings(2, 10);
        assertEq(page2.length, 1);
        assertEq(page2[0].id, 3);

        AgentHavenMarket.Listing[] memory empty = market.getActiveListings(3, 10);
        assertEq(empty.length, 0);

        uint256[] memory ids = market.getActiveListingIds(0, 10);
        assertEq(ids.length, 3);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(ids[2], 3);

        // Selling the middle listing keeps the other two enumerable.
        vm.prank(carol);
        market.buyListing{value: 2 ether}(2);
        assertEq(market.activeCount(), 2);
        uint256[] memory idsAfter = market.getActiveListingIds(0, 10);
        assertEq(idsAfter.length, 2);
        // Swap-and-pop moved listing 3 into slot 1.
        assertEq(idsAfter[0], 1);
        assertEq(idsAfter[1], 3);
    }

    function test_GetListingRevertsForMissing() public {
        vm.expectRevert(AgentHavenMarket.ListingNotFound.selector);
        market.getListing(999);
    }

    // ------------------------------------------------------------------
    // Fee admin
    // ------------------------------------------------------------------

    function test_SetFee() public {
        vm.expectEmit(false, false, false, true);
        emit FeeUpdated(250, 500);
        market.setFee(500);
        assertEq(market.feeBps(), 500);
        assertEq(market.feeFor(1 ether), 0.05 ether);
    }

    function test_SetFeeRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(AgentHavenMarket.NotOwner.selector);
        market.setFee(500);
    }

    function test_SetFeeRevertsAboveCap() public {
        vm.expectRevert(AgentHavenMarket.FeeTooHigh.selector);
        market.setFee(1001);
        // Exactly at the cap is allowed.
        market.setFee(1000);
        assertEq(market.feeBps(), 1000);
    }

    function test_SetFeeZero() public {
        market.setFee(0);
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        market.buyListing{value: 1 ether}(id);
        assertEq(alice.balance, aliceBefore + 1 ether);
    }

    // ------------------------------------------------------------------
    // ERC-721 receiver & rescue
    // ------------------------------------------------------------------

    function test_OnERC721ReceivedAcceptsPasses() public {
        vm.prank(address(passV1));
        bytes4 ret = market.onERC721Received(address(0), alice, 1, "");
        assertTrue(ret == 0x150b7a02);
        vm.prank(address(passV2));
        ret = market.onERC721Received(address(0), alice, 1, "");
        assertTrue(ret == 0x150b7a02);
    }

    function test_OnERC721ReceivedRejectsOthers() public {
        vm.prank(alice);
        vm.expectRevert(AgentHavenMarket.UnsupportedCollection.selector);
        market.onERC721Received(address(0), alice, 1, "");
    }

    function test_RescueToken() public {
        // Alice fat-fingers a direct transfer of her v1 Pass to the market.
        vm.prank(alice);
        passV1.transferFrom(alice, address(market), 1);
        assertEq(passV1.ownerOf(1), address(market));
        // The owner can return it to her.
        market.rescueToken(address(passV1), 1, alice);
        assertEq(passV1.ownerOf(1), alice);
    }

    function test_RescueTokenRevertsForListedToken() public {
        uint256 id = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        assertEq(id, 1);
        vm.expectRevert(AgentHavenMarket.TokenIsListed.selector);
        market.rescueToken(address(passV1), 1, owner);
    }

    function test_RescueTokenRevertsForNonOwner() public {
        vm.prank(alice);
        passV1.transferFrom(alice, address(market), 1);
        vm.prank(alice);
        vm.expectRevert(AgentHavenMarket.NotOwner.selector);
        market.rescueToken(address(passV1), 1, alice);
    }

    function test_RescueERC20() public {
        usdt.mint(address(market), 100 ether);
        assertEq(usdt.balanceOf(address(market)), 100 ether);
        market.rescueERC20(address(usdt), alice, 100 ether);
        assertEq(usdt.balanceOf(alice), 100 ether);
        assertEq(usdt.balanceOf(address(market)), 0);
    }

    // ------------------------------------------------------------------
    // Re-entrancy
    // ------------------------------------------------------------------

    function test_ReentrantBuyFails() public {
        // A malicious seller contract claims a v2 Pass and lists it.
        ReentrantSeller evil = new ReentrantSeller(address(market));
        registry.setHandle(address(evil), "evil");
        evil.setTarget(2); // will try to buy listing 2 during its payout
        vm.prank(address(evil));
        passV2.claim(); // v2 token #4
        vm.prank(address(evil));
        passV2.approve(address(market), 4);
        vm.prank(address(evil));
        uint256 evilListing = market.list(address(passV2), 4, 1 ether, AgentHavenMarket.Currency.BNB);

        // Alice's listing is the re-entrancy target.
        uint256 target = _list(alice, address(passV1), 1, 1 ether, AgentHavenMarket.Currency.BNB);
        assertEq(target, 2);
        assertEq(evilListing, 1);

        // Bob buys the evil seller's Pass. The payout triggers the evil
        // receive(), whose inner buy must fail (guard), while the outer buy
        // still succeeds.
        vm.prank(bob);
        market.buyListing{value: 1 ether}(evilListing);
        assertEq(passV2.ownerOf(4), bob);
        assertFalse(evil.reentrySucceeded());
        assertTrue(market.getListing(target).active);
        assertEq(passV1.ownerOf(1), address(market)); // still escrowed
    }

    // ------------------------------------------------------------------
    // Fuzz: fee math invariants
    // ------------------------------------------------------------------

    function testFuzz_FeeNeverExceedsPrice(uint256 price) public view {
        price = bound(price, 1, 1e30);
        uint256 fee = market.feeFor(price);
        assertLe(fee, price);
        assertEq(fee + (price - fee), price);
        assertEq(fee, (price * 250) / 10000);
    }
}
