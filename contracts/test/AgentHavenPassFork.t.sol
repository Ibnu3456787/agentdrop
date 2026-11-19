// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentHavenPass.sol";

/// @notice Fork tests against the REAL Agent ID registry on BSC mainnet.
/// @dev Requires network access to a BSC RPC. Run with:
///      forge test --match-contract AgentHavenPassForkTest --fork-url https://bsc-dataseed.binance.org/
///      (or set the fork URL via foundry.toml [rpc_endpoints] bsc)
///      These tests impersonate real addresses via vm.prank; nothing is
///      broadcast and no funds move.
contract AgentHavenPassForkTest is Test {
    address public constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    // Habib's BSC wallet, holder of Agent ID "idawati.ai" (verified on-chain
    // 19 Nov 2026: balanceOf == 1, handleOf == "idawati").
    address public constant IDAWATI = 0xd2Da02e0B4e871256415CD110EAbC0387Acf3Ca1;

    // A wallet with no Agent ID (verified on-chain 19 Nov 2026).
    address public constant NO_ID = 0x538e7E6b0fFEa20864d7f6b3e944ddC07c4bb39E;

    AgentHavenPass public pass;

    function setUp() public {
        // Fork BSC mainnet at the latest block.
        vm.createSelectFork("bsc");
        pass = new AgentHavenPass(REGISTRY);
    }

    function test_ForkRegistryIsReal() public view {
        IAgentIDRegistry registry = IAgentIDRegistry(REGISTRY);
        assertEq(registry.balanceOf(IDAWATI), 1);
        assertEq(registry.handleOf(IDAWATI), "idawati");
        assertEq(registry.balanceOf(NO_ID), 0);
        assertEq(bytes(registry.handleOf(NO_ID)).length, 0);
    }

    function test_ForkClaimByRealHolder() public {
        vm.prank(IDAWATI);
        uint256 tokenId = pass.claim();
        assertEq(tokenId, 1);
        assertEq(pass.ownerOf(1), IDAWATI);
        assertEq(pass.agentHandle(1), "idawati");
    }

    function test_ForkMetadataEmbedsRealHandle() public {
        vm.prank(IDAWATI);
        pass.claim();
        string memory uri = pass.tokenURI(1);
        bytes memory json = _decodeBase64AfterPrefix(uri, "data:application/json;base64,");
        assertTrue(_contains(string(json), "idawati.ai"));
        assertTrue(_contains(string(json), "AgentHaven Pass #1"));
        bytes memory svg = _extractSvg(string(json));
        assertTrue(_contains(string(svg), "idawati.ai"));
        assertTrue(_contains(string(svg), "PASS #1"));
    }

    function test_ForkClaimRevertsForRealNonHolder() public {
        vm.prank(NO_ID);
        vm.expectRevert(AgentHavenPass.NotAgentIDHolder.selector);
        pass.claim();
    }

    // -- test-only helpers (duplicated from the unit suite so the fork file
    //    stays self-contained) --

    function _decodeBase64AfterPrefix(string memory uri, string memory prefix)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory uriBytes = bytes(uri);
        uint256 start = bytes(prefix).length;
        bytes memory b64 = new bytes(uriBytes.length - start);
        for (uint256 i = 0; i < b64.length; i++) {
            b64[i] = uriBytes[start + i];
        }
        return _base64Decode(b64);
    }

    function _extractSvg(string memory json) internal pure returns (bytes memory) {
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
}
