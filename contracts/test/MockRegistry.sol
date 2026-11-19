// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test double for the Agent ID registry. Mimics the real registry's
///         two functions AgentHavenPass relies on: balanceOf and handleOf.
contract MockRegistry {
    mapping(address => string) private _handles;

    /// @notice Give `who` the Agent ID `handle` (empty string removes it).
    function setHandle(address who, string calldata handle) external {
        _handles[who] = handle;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return bytes(_handles[owner]).length == 0 ? 0 : 1;
    }

    function handleOf(address owner) external view returns (string memory) {
        return _handles[owner];
    }
}

/// @notice A receiver that accepts ERC-721 safe transfers.
contract AcceptingReceiver {
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0x150b7a02; // IERC721Receiver.onERC721Received.selector
    }
}

/// @notice A receiver that rejects ERC-721 safe transfers.
contract RejectingReceiver {
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xdeadbeef;
    }
}

/// @notice A receiver that tries to re-enter claim() during the safe-mint
///         callback. Used to prove re-entrancy cannot double-claim.
contract ReentrantClaimer {
    address public immutable pass;

    constructor(address pass_) {
        pass = pass_;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        // Attempt to claim again from inside the mint callback. Must revert.
        // We swallow the revert: the point is that the outer claim must still
        // succeed exactly once and this inner call must fail.
        (bool ok, ) = pass.call(abi.encodeWithSignature("claim()"));
        require(!ok, "reentrant claim unexpectedly succeeded");
        return 0x150b7a02;
    }
}
