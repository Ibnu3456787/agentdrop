// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentHavenPassV2.sol";
import "./MockRegistry.sol";

/// @notice Unit tests for AgentHavenPassV2 (tiered pricing).
/// @dev Mirrors the v1 suite's structure and mock-registry pattern, plus
///      pricing (free tier / paid tier boundary / exact-value enforcement)
///      and withdraw coverage.
contract AgentHavenPassV2Test is Test {
    AgentHavenPassV2 public pass;
    MockRegistry public registry;

    address public owner = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xCA901);
    address public dave = address(0xDA9E);

    event Claimed(address indexed claimer, uint256 indexed tokenId, string handle);
    event Withdrawn(address indexed to, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    // The test contract is the pass owner (deployer), and withdraw() sends
    // ETH to the owner via a low-level call. The vendored forge-std Test
    // contract has no receive(), so this test contract needs one to accept
    // the withdrawal. (In production the owner is an EOA, which always
    // accepts ETH.)
    receive() external payable {}

    function setUp() public {
        registry = new MockRegistry();
        pass = new AgentHavenPassV2(address(registry));
        registry.setHandle(alice, "alice");
        registry.setHandle(bob, "bob123");
        registry.setHandle(dave, "dave");
        // carol has no Agent ID.
    }

    // ------------------------------------------------------------------
    // Deployment & identity
    // ------------------------------------------------------------------

    function test_NameSymbolRegistry() public view {
        assertEq(pass.name(), "AgentHaven Pass");
        assertEq(pass.symbol(), "AHPASS");
        assertEq(pass.REGISTRY(), address(registry));
        assertEq(pass.MAX_SUPPLY(), 10000);
        assertEq(pass.FREE_SUPPLY(), 1111);
        assertEq(pass.PAID_PRICE(), 0.00005 ether);
        assertEq(pass.claimPrice(), 0);
        assertEq(pass.owner(), owner);
        assertEq(pass.totalSupply(), 0);
        assertFalse(pass.paused());
    }

    function test_ConstructorRevertsOnZeroRegistry() public {
        vm.expectRevert(AgentHavenPassV2.ZeroAddress.selector);
        new AgentHavenPassV2(address(0));
    }

    function test_SupportsInterface() public view {
        assertTrue(pass.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(pass.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(pass.supportsInterface(0x5b5e139f)); // ERC-721 Metadata
        assertFalse(pass.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------------
    // Happy-path claim (free tier)
    // ------------------------------------------------------------------

    function test_ClaimSucceedsForHolder() public {
        vm.prank(alice);
        uint256 tokenId = pass.claim();
        assertEq(tokenId, 1);
        assertEq(pass.ownerOf(1), alice);
        assertEq(pass.balanceOf(alice), 1);
        assertEq(pass.totalSupply(), 1);
        assertEq(pass.totalMinted(), 1);
        assertTrue(pass.claimed(alice));
        assertEq(pass.agentHandle(1), "alice");
    }

    function test_ClaimEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Claimed(alice, 1, "alice");
        vm.prank(alice);
        pass.claim();
    }

    function test_SecondClaimerGetsTokenId2() public {
        vm.prank(alice);
        pass.claim();
        vm.prank(bob);
        uint256 tokenId = pass.claim();
        assertEq(tokenId, 2);
        assertEq(pass.agentHandle(2), "bob123");
        assertEq(pass.totalSupply(), 2);
    }

    function test_FirstClaimIsFree() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        pass.claim();
        // No BNB moved: alice keeps her full balance and the contract holds nothing.
        assertEq(alice.balance, 1 ether);
        assertEq(address(pass).balance, 0);
    }

    // ------------------------------------------------------------------
    // Pricing: claimPrice() view
    // ------------------------------------------------------------------

    function test_ClaimPriceIsZeroAtStart() public view {
        assertEq(pass.totalMinted(), 0);
        assertEq(pass.claimPrice(), 0);
    }

    function test_ClaimPriceAtBoundaryValues() public {
        // totalMinted 1110 -> next claim is #1111, still free.
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1110)));
        assertEq(pass.totalMinted(), 1110);
        assertEq(pass.claimPrice(), 0);
        // totalMinted 1111 -> next claim is #1112, paid.
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1111)));
        assertEq(pass.totalMinted(), 1111);
        assertEq(pass.claimPrice(), 0.00005 ether);
        // totalMinted 1112 -> still paid.
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1112)));
        assertEq(pass.totalMinted(), 1112);
        assertEq(pass.claimPrice(), 0.00005 ether);
    }

    function test_ClaimPriceBoundaryEndToEnd() public {
        // Push totalMinted to 1110 via storage (slot 0, guarded by read-back).
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1110)));
        assertEq(pass.totalMinted(), 1110);
        assertEq(pass.claimPrice(), 0);
        // Claim #1111 is the last free one.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        assertEq(pass.claim(), 1111);
        assertEq(alice.balance, 1 ether);
        assertEq(address(pass).balance, 0);
        // Claim #1112 is the first paid one.
        assertEq(pass.claimPrice(), 0.00005 ether);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        assertEq(pass.claim{value: 0.00005 ether}(), 1112);
        assertEq(address(pass).balance, 0.00005 ether);
    }

    // ------------------------------------------------------------------
    // Pricing: exact-value enforcement
    // ------------------------------------------------------------------

    function test_PaidClaimMovesExactlyThePrice() public {
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1111)));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        pass.claim{value: 0.00005 ether}();
        assertEq(alice.balance, 1 ether - 0.00005 ether);
        assertEq(address(pass).balance, 0.00005 ether);
    }

    function test_PaidClaimRevertsWithZeroValue() public {
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1111)));
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.WrongValue.selector);
        pass.claim();
        // The failed claim changed nothing (totalMinted stays at the stored 1111).
        assertEq(pass.totalMinted(), 1111);
        assertEq(address(pass).balance, 0);
    }

    function test_FreeClaimWithValueReverts() public {
        // 0.00005 BNB attached to a free-tier claim must revert: the price
        // is exactly 0 while totalMinted < 1111.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.WrongValue.selector);
        pass.claim{value: 0.00005 ether}();
        assertEq(pass.totalSupply(), 0);
        assertEq(alice.balance, 1 ether);
    }

    function test_FreeClaimWithArbitraryValueReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.WrongValue.selector);
        pass.claim{value: 0.001 ether}();
        assertEq(pass.totalSupply(), 0);
    }

    function test_PaidClaimRevertsOnOverpay() public {
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1111)));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.WrongValue.selector);
        pass.claim{value: 0.00006 ether}();
        assertEq(pass.totalMinted(), 1111);
        assertEq(address(pass).balance, 0);
    }

    function test_PaidClaimRevertsOnUnderpay() public {
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1111)));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.WrongValue.selector);
        pass.claim{value: 0.00001 ether}();
        assertEq(pass.totalMinted(), 1111);
        assertEq(address(pass).balance, 0);
    }

    function test_FailedClaimDoesNotChangePriceOrSupply() public {
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1111)));
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert(AgentHavenPassV2.NotAgentIDHolder.selector);
        pass.claim{value: 0.00005 ether}();
        assertEq(pass.totalMinted(), 1111);
        assertEq(pass.claimPrice(), 0.00005 ether);
        assertEq(address(pass).balance, 0);
    }

    // ------------------------------------------------------------------
    // Claim reverts
    // ------------------------------------------------------------------

    function test_ClaimRevertsForNonHolder() public {
        vm.prank(carol);
        vm.expectRevert(AgentHavenPassV2.NotAgentIDHolder.selector);
        pass.claim();
    }

    function test_ClaimRevertsOnDoubleClaim() public {
        vm.prank(alice);
        pass.claim();
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.AlreadyClaimed.selector);
        pass.claim();
    }

    function test_DoubleClaimRevertsEvenWithPaidValue() public {
        // Alice claims free, then the supply crosses into the paid tier and
        // she tries again with the correct paid value: still AlreadyClaimed.
        vm.prank(alice);
        pass.claim();
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1111)));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.AlreadyClaimed.selector);
        pass.claim{value: 0.00005 ether}();
    }

    function test_ClaimRevertsWhenPaused() public {
        pass.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.ClaimPaused.selector);
        pass.claim();
        // Unpause restores claiming.
        pass.setPaused(false);
        vm.prank(alice);
        assertEq(pass.claim(), 1);
    }

    function test_PausedClaimRevertsBeforeValueCheck() public {
        // A paused claim with the wrong value reverts ClaimPaused, not
        // WrongValue: the pause is checked first.
        pass.setPaused(true);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.ClaimPaused.selector);
        pass.claim{value: 0.001 ether}();
    }

    function test_ClaimRevertsAtCap() public {
        // Push totalMinted to MAX_SUPPLY - 1 by writing storage slot 0
        // directly (totalMinted is the first storage variable: constants and
        // the immutable REGISTRY take no slots). The read-back assert below
        // guards against a future storage-layout reorder breaking this.
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(9999)));
        assertEq(pass.totalMinted(), 9999);
        // The 10,000th claim is in the paid tier: it costs 0.00005 BNB.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        assertEq(pass.claim{value: 0.00005 ether}(), 10000);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(AgentHavenPassV2.SoldOut.selector);
        pass.claim{value: 0.00005 ether}();
    }

    function test_ClaimRevertsWhenHandleRemovedAfterEligibility() public {
        // Holder loses their Agent ID between checks is impossible in one tx,
        // but a holder whose registry entry is cleared cannot claim at all.
        registry.setHandle(alice, "");
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.NotAgentIDHolder.selector);
        pass.claim();
    }

    // ------------------------------------------------------------------
    // Re-entrancy
    // ------------------------------------------------------------------

    function test_ReentrantClaimCannotDoubleMint() public {
        ReentrantClaimer attacker = new ReentrantClaimer(address(pass));
        registry.setHandle(address(attacker), "attacker");
        vm.prank(address(attacker));
        uint256 tokenId = pass.claim();
        assertEq(tokenId, 1);
        assertEq(pass.totalSupply(), 1);
        assertEq(pass.balanceOf(address(attacker)), 1);
    }

    // ------------------------------------------------------------------
    // Withdraw
    // ------------------------------------------------------------------

    function _makePaidClaims(uint256 n) internal {
        // Push into the paid tier, then make n paid claims from distinct
        // holders (alice, bob, dave, then generated holders).
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1111)));
        address[3] memory holders = [alice, bob, dave];
        for (uint256 i = 0; i < n; i++) {
            address holder;
            if (i < 3) {
                holder = holders[i];
            } else {
                holder = address(uint160(0x2000 + i));
                registry.setHandle(holder, string.concat("user", _toString(i)));
            }
            vm.deal(holder, 1 ether);
            vm.prank(holder);
            pass.claim{value: 0.00005 ether}();
        }
    }

    function test_WithdrawSendsFullBalance() public {
        _makePaidClaims(3);
        assertEq(address(pass).balance, 3 * 0.00005 ether);
        uint256 ownerBefore = owner.balance;
        pass.withdraw();
        assertEq(owner.balance, ownerBefore + 3 * 0.00005 ether);
        assertEq(address(pass).balance, 0);
    }

    function test_WithdrawEmitsEvent() public {
        _makePaidClaims(1);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(owner, 0.00005 ether);
        pass.withdraw();
    }

    function test_WithdrawOnlyOwner() public {
        _makePaidClaims(1);
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.NotOwner.selector);
        pass.withdraw();
        assertEq(address(pass).balance, 0.00005 ether);
    }

    function test_WithdrawRevertsWhenEmpty() public {
        // Nothing to withdraw: no paid claims have happened yet.
        vm.expectRevert(AgentHavenPassV2.NothingToWithdraw.selector);
        pass.withdraw();
    }

    function test_WithdrawRevertsWhenEmptyAfterDrain() public {
        _makePaidClaims(1);
        pass.withdraw();
        vm.expectRevert(AgentHavenPassV2.NothingToWithdraw.selector);
        pass.withdraw();
    }

    function test_WithdrawGoesToNewOwnerAfterTransfer() public {
        _makePaidClaims(2);
        pass.transferOwnership(alice);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        pass.withdraw();
        assertEq(alice.balance, aliceBefore + 2 * 0.00005 ether);
        assertEq(address(pass).balance, 0);
        // Old owner can no longer withdraw.
        vm.expectRevert(AgentHavenPassV2.NotOwner.selector);
        pass.withdraw();
    }

    function test_ClaimingContinuesAfterWithdraw() public {
        _makePaidClaims(1);
        pass.withdraw();
        assertEq(address(pass).balance, 0);
        // A new holder can still claim (paid tier) and fees accumulate again.
        address eve = address(0xE9E);
        registry.setHandle(eve, "eve");
        vm.deal(eve, 1 ether);
        vm.prank(eve);
        pass.claim{value: 0.00005 ether}();
        assertEq(address(pass).balance, 0.00005 ether);
    }

    function test_ContractRejectsDirectEther() public {
        // No receive/fallback: BNB can only enter through claim().
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, ) = address(pass).call{value: 0.1 ether}("");
        assertFalse(ok, "direct ETH transfer must fail");
        assertEq(address(pass).balance, 0);
    }

    // ------------------------------------------------------------------
    // Metadata
    // ------------------------------------------------------------------

    function test_TokenURIContainsHandleAndId() public {
        vm.prank(alice);
        pass.claim();
        string memory uri = pass.tokenURI(1);
        // data:application/json;base64, prefix
        assertEq(bytes(uri)[0], bytes1("d"));
        bytes memory uriBytes = bytes(uri);
        // The base64 payload is not human-readable on-chain; decode it in the
        // test via the JSON it encodes by checking the raw URI is long and
        // starts with the expected prefix.
        assertGt(uriBytes.length, 200);
        string memory prefix = "data:application/json;base64,";
        for (uint256 i = 0; i < bytes(prefix).length; i++) {
            assertEq(uriBytes[i], bytes(prefix)[i]);
        }
    }

    function test_TokenURIDecodesToValidJsonWithHandle() public {
        vm.prank(alice);
        pass.claim();
        string memory uri = pass.tokenURI(1);
        bytes memory json = _decodeBase64AfterPrefix(uri, "data:application/json;base64,");
        // The JSON must contain the handle, the token id, and the SVG image.
        assertTrue(_contains(string(json), "alice.ai"));
        assertTrue(_contains(string(json), "AgentHaven Pass #1"));
        assertTrue(_contains(string(json), "data:image/svg+xml;base64,"));
        assertTrue(_contains(string(json), '"trait_type":"Agent ID"'));
        // v2 description states the tiered pricing.
        assertTrue(_contains(string(json), "1,111"));
        assertTrue(_contains(string(json), "0.00005 BNB"));
        // And the embedded SVG must contain the handle too.
        bytes memory svg = _extractSvg(string(json));
        assertTrue(_contains(string(svg), "alice.ai"));
        assertTrue(_contains(string(svg), "PASS #1"));
        assertTrue(_contains(string(svg), "AGENTHAVEN"));
        // v2 subtitle is the neutral "AGENT PASS", not "FREE CLAIM PASS".
        assertTrue(_contains(string(svg), "AGENT PASS"));
        assertFalse(_contains(string(svg), "FREE CLAIM PASS"));
    }

    function test_TokenURILongHandleFits() public {
        // 20-char handle (registry max) + ".ai" must still render.
        registry.setHandle(bob, "abcdefghijklmnopqrst"); // 20 chars
        vm.prank(bob);
        pass.claim();
        bytes memory json = _decodeBase64AfterPrefix(pass.tokenURI(1), "data:application/json;base64,");
        assertTrue(_contains(string(json), "abcdefghijklmnopqrst.ai"));
        bytes memory svg = _extractSvg(string(json));
        // Long handle uses the smaller font size.
        assertTrue(_contains(string(svg), 'font-size="22"'));
    }

    function test_TokenURIShortHandleUsesLargeFont() public {
        registry.setHandle(bob, "bob"); // 3 chars + ".ai" = 6 chars
        vm.prank(bob);
        pass.claim();
        bytes memory json = _decodeBase64AfterPrefix(pass.tokenURI(1), "data:application/json;base64,");
        bytes memory svg = _extractSvg(string(json));
        assertTrue(_contains(string(svg), 'font-size="34"'));
    }

    function test_TokenURIRevertsForNonexistent() public {
        vm.expectRevert(AgentHavenPassV2.TokenDoesNotExist.selector);
        pass.tokenURI(1);
        vm.expectRevert(AgentHavenPassV2.TokenDoesNotExist.selector);
        pass.tokenURI(99999);
    }

    function test_AgentHandleRevertsForNonexistent() public {
        vm.expectRevert(AgentHavenPassV2.TokenDoesNotExist.selector);
        pass.agentHandle(1);
    }

    // ------------------------------------------------------------------
    // Owner permissions
    // ------------------------------------------------------------------

    function test_OnlyOwnerCanPause() public {
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.NotOwner.selector);
        pass.setPaused(true);
    }

    function test_PauseDoesNotAffectTransfers() public {
        vm.prank(alice);
        pass.claim();
        pass.setPaused(true);
        vm.prank(alice);
        pass.transferFrom(alice, bob, 1);
        assertEq(pass.ownerOf(1), bob);
    }

    function test_TransferOwnership() public {
        pass.transferOwnership(alice);
        assertEq(pass.owner(), alice);
        vm.prank(alice);
        pass.setPaused(true);
        assertTrue(pass.paused());
        // Old owner can no longer act.
        vm.expectRevert(AgentHavenPassV2.NotOwner.selector);
        pass.setPaused(false);
    }

    function test_TransferOwnershipRevertsOnZero() public {
        vm.expectRevert(AgentHavenPassV2.ZeroAddress.selector);
        pass.transferOwnership(address(0));
    }

    function test_RenounceOwnership() public {
        pass.renounceOwnership();
        assertEq(pass.owner(), address(0));
        vm.expectRevert(AgentHavenPassV2.NotOwner.selector);
        pass.setPaused(true);
        // Renouncing also gives up withdraw forever.
        vm.expectRevert(AgentHavenPassV2.NotOwner.selector);
        pass.withdraw();
    }

    // ------------------------------------------------------------------
    // ERC-721 transfers & approvals
    // ------------------------------------------------------------------

    function test_TransferFrom() public {
        vm.prank(alice);
        pass.claim();
        vm.prank(alice);
        pass.transferFrom(alice, bob, 1);
        assertEq(pass.ownerOf(1), bob);
        assertEq(pass.balanceOf(alice), 0);
        assertEq(pass.balanceOf(bob), 1);
        // The claimed flag stays with the claimer, not the token.
        assertTrue(pass.claimed(alice));
        assertFalse(pass.claimed(bob));
    }

    function test_TransferFromRevertsForNonOwner() public {
        vm.prank(alice);
        pass.claim();
        vm.prank(bob);
        vm.expectRevert(AgentHavenPassV2.NotTokenOwnerOrApproved.selector);
        pass.transferFrom(alice, bob, 1);
    }

    function test_TransferFromRevertsToZero() public {
        vm.prank(alice);
        pass.claim();
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.TransferToZeroAddress.selector);
        pass.transferFrom(alice, address(0), 1);
    }

    function test_ApproveAndTransferByApproved() public {
        vm.prank(alice);
        pass.claim();
        vm.prank(alice);
        pass.approve(bob, 1);
        assertEq(pass.getApproved(1), bob);
        vm.prank(bob);
        pass.transferFrom(alice, carol, 1);
        assertEq(pass.ownerOf(1), carol);
        // Approval is cleared on transfer.
        assertEq(pass.getApproved(1), address(0));
    }

    function test_SetApprovalForAll() public {
        vm.prank(alice);
        pass.claim();
        vm.prank(alice);
        pass.setApprovalForAll(bob, true);
        assertTrue(pass.isApprovedForAll(alice, bob));
        vm.prank(bob);
        pass.transferFrom(alice, carol, 1);
        assertEq(pass.ownerOf(1), carol);
    }

    function test_SafeTransferToAcceptingContract() public {
        AcceptingReceiver receiver = new AcceptingReceiver();
        vm.prank(alice);
        pass.claim();
        vm.prank(alice);
        pass.safeTransferFrom(alice, address(receiver), 1);
        assertEq(pass.ownerOf(1), address(receiver));
    }

    function test_SafeTransferToRejectingContractReverts() public {
        RejectingReceiver receiver = new RejectingReceiver();
        vm.prank(alice);
        pass.claim();
        vm.prank(alice);
        vm.expectRevert(AgentHavenPassV2.InvalidReceiver.selector);
        pass.safeTransferFrom(alice, address(receiver), 1);
        // Token stays with alice.
        assertEq(pass.ownerOf(1), alice);
    }

    function test_BalanceOfRevertsForZeroAddress() public {
        vm.expectRevert(AgentHavenPassV2.ZeroAddress.selector);
        pass.balanceOf(address(0));
    }

    function test_OwnerOfRevertsForNonexistent() public {
        vm.expectRevert(AgentHavenPassV2.TokenDoesNotExist.selector);
        pass.ownerOf(1);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_ClaimWithAnyHandle(string memory handle) public {
        // Handles are [a-z0-9], 3..20 chars on the real registry. Bound the
        // fuzz input to that shape.
        vm.assume(bytes(handle).length >= 3 && bytes(handle).length <= 20);
        for (uint256 i = 0; i < bytes(handle).length; i++) {
            bytes1 c = bytes(handle)[i];
            vm.assume((c >= "a" && c <= "z") || (c >= "0" && c <= "9"));
        }
        registry.setHandle(alice, handle);
        vm.prank(alice);
        pass.claim();
        assertEq(pass.agentHandle(1), handle);
        // Metadata must still render and contain the handle.
        bytes memory json =
            _decodeBase64AfterPrefix(pass.tokenURI(1), "data:application/json;base64,");
        assertTrue(_contains(string(json), string.concat(handle, ".ai")));
    }

    function testFuzz_ManyHoldersClaimInOrder(uint8 n) public {
        vm.assume(n > 0 && n <= 20);
        for (uint256 i = 0; i < n; i++) {
            address holder = address(uint160(0x1000 + i));
            registry.setHandle(holder, string.concat("user", _toString(i)));
            vm.prank(holder);
            assertEq(pass.claim(), i + 1);
        }
        assertEq(pass.totalSupply(), n);
    }

    // ------------------------------------------------------------------
    // Gas reporting (informational; asserts only that claiming is cheap)
    // ------------------------------------------------------------------

    function test_GasFreeClaimBelow300k() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        pass.claim();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("free claim gas", gasUsed);
        assertLt(gasUsed, 300_000);
    }

    function test_GasPaidClaimBelow300k() public {
        vm.store(address(pass), bytes32(uint256(0)), bytes32(uint256(1111)));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        pass.claim{value: 0.00005 ether}();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("paid claim gas", gasUsed);
        assertLt(gasUsed, 300_000);
    }

    function test_GasDeploy() public {
        uint256 gasBefore = gasleft();
        new AgentHavenPassV2(address(registry));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("deploy gas", gasUsed);
    }

    // ------------------------------------------------------------------
    // Helpers (test-only base64 decode + substring search)
    // ------------------------------------------------------------------

    function _decodeBase64AfterPrefix(string memory uri, string memory prefix)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory uriBytes = bytes(uri);
        bytes memory prefixBytes = bytes(prefix);
        uint256 start = prefixBytes.length;
        bytes memory b64 = new bytes(uriBytes.length - start);
        for (uint256 i = 0; i < b64.length; i++) {
            b64[i] = uriBytes[start + i];
        }
        return _base64Decode(b64);
    }

    function _extractSvg(string memory json) internal pure returns (bytes memory) {
        // Find "data:image/svg+xml;base64," then decode until the closing quote.
        bytes memory j = bytes(json);
        bytes memory marker = bytes("data:image/svg+xml;base64,");
        uint256 at = _indexOf(j, marker);
        require(at != type(uint256).max, "svg marker not found");
        uint256 start = at + marker.length;
        uint256 end = start;
        while (end < j.length && j[end] != '"') {
            end++;
        }
        bytes memory b64 = new bytes(end - start);
        for (uint256 i = 0; i < b64.length; i++) {
            b64[i] = j[start + i];
        }
        return _base64Decode(b64);
    }

    function _base64Decode(bytes memory data) internal pure returns (bytes memory) {
        uint256 len = data.length;
        require(len % 4 == 0, "bad b64 length");
        uint256 pad = 0;
        if (len > 0 && data[len - 1] == "=") pad++;
        if (len > 1 && data[len - 2] == "=") pad++;
        bytes memory out = new bytes((len / 4) * 3 - pad);
        uint256 oi = 0;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 n = (_b64val(data[i]) << 18) | (_b64val(data[i + 1]) << 12) | (_b64val(data[i + 2]) << 6)
                | _b64val(data[i + 3]);
            if (oi < out.length) out[oi++] = bytes1(uint8(n >> 16));
            if (oi < out.length) out[oi++] = bytes1(uint8(n >> 8));
            if (oi < out.length) out[oi++] = bytes1(uint8(n));
        }
        return out;
    }

    function _b64val(bytes1 c) internal pure returns (uint256) {
        if (c >= "A" && c <= "Z") return uint8(c) - uint8(bytes1("A"));
        if (c >= "a" && c <= "z") return uint8(c) - uint8(bytes1("a")) + 26;
        if (c >= "0" && c <= "9") return uint8(c) - uint8(bytes1("0")) + 52;
        if (c == "+") return 62;
        if (c == "/") return 63;
        return 0; // '=' padding
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        return _indexOf(bytes(hay), bytes(needle)) != type(uint256).max;
    }

    function _indexOf(bytes memory hay, bytes memory needle) internal pure returns (uint256) {
        if (needle.length == 0 || needle.length > hay.length) return type(uint256).max;
        for (uint256 i = 0; i <= hay.length - needle.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return i;
        }
        return type(uint256).max;
    }

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
