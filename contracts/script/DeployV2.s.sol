// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentHavenPassV2.sol";

/// @notice Deploys AgentHavenPassV2 to BNB Smart Chain (chain ID 56).
/// @dev DO NOT RUN without the deployer's explicit go-ahead. This script only
///      exists so deployment is a single reviewed command.
///
///      v2 replaces v1 as the project's Pass contract: the first 1,111 claims
///      are free, later claims cost 0.00005 BNB each, and the owner can
///      withdraw accumulated claim fees. v1
///      (0xf8118d518a228B704947eCf89C264B4F4F79aC5D) stays deployed and its
///      passes remain valid on-chain — v2 is a separate contract, not an
///      upgrade (v1 is immutable and has no upgrade path).
///
///      Dry-run (no broadcast, no funds):
///        forge script script/DeployV2.s.sol --rpc-url bsc
///
///      Real deploy (deployer pays gas; needs a funded key):
///        forge script script/DeployV2.s.sol --rpc-url bsc --broadcast \
///          --private-key $DEPLOYER_PRIVATE_KEY
///      (Never put a real private key in a file or in chat. Prefer a hardware
///      wallet or the deployer's own signer.)
///
///      Verify on BscScan afterwards (needs a BscScan API key):
///        forge verify-contract <DEPLOYED_ADDRESS> src/AgentHavenPassV2.sol:AgentHavenPassV2 \
///          --chain-id 56 --constructor-args $(cast abi-encode "constructor(address)" 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F)
contract DeployV2 is Script {
    /// @notice The official Agent ID registry on BNB Smart Chain.
    address public constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    function run() external returns (AgentHavenPassV2 pass) {
        require(block.chainid == 56, "DeployV2: BSC mainnet (chain 56) only");
        vm.startBroadcast();
        pass = new AgentHavenPassV2(REGISTRY);
        vm.stopBroadcast();
        console2.log("AgentHavenPassV2 deployed at:", address(pass));
        console2.log("Registry:", REGISTRY);
        console2.log("Owner (deployer):", pass.owner());
        console2.log("MAX_SUPPLY:", pass.MAX_SUPPLY());
        console2.log("FREE_SUPPLY:", pass.FREE_SUPPLY());
        console2.log("PAID_PRICE (wei):", pass.PAID_PRICE());
        console2.log("claimPrice() (wei):", pass.claimPrice());
    }
}
