// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentHavenPass.sol";

/// @notice Deploys AgentHavenPass to BNB Smart Chain (chain ID 56).
/// @dev DO NOT RUN without the deployer's explicit go-ahead. This script only
///      exists so deployment is a single reviewed command.
///
///      Dry-run (no broadcast, no funds):
///        forge script script/Deploy.s.sol --rpc-url bsc
///
///      Real deploy (deployer pays gas; needs a funded key):
///        forge script script/Deploy.s.sol --rpc-url bsc --broadcast \
///          --private-key $DEPLOYER_PRIVATE_KEY
///      (Never put a real private key in a file or in chat. Prefer a hardware
///      wallet or the deployer's own signer.)
///
///      Verify on BscScan afterwards (needs a BscScan API key):
///        forge verify-contract <DEPLOYED_ADDRESS> src/AgentHavenPass.sol:AgentHavenPass \
///          --chain-id 56 --constructor-args $(cast abi-encode "constructor(address)" 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F)
contract Deploy is Script {
    /// @notice The official Agent ID registry on BNB Smart Chain.
    address public constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    function run() external returns (AgentHavenPass pass) {
        require(block.chainid == 56, "Deploy: BSC mainnet (chain 56) only");
        vm.startBroadcast();
        pass = new AgentHavenPass(REGISTRY);
        vm.stopBroadcast();
        console2.log("AgentHavenPass deployed at:", address(pass));
        console2.log("Registry:", REGISTRY);
        console2.log("Owner (deployer):", pass.owner());
        console2.log("MAX_SUPPLY:", pass.MAX_SUPPLY());
    }
}
