// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentHavenMarket.sol";

/// @notice Deploys AgentHavenMarket to BNB Smart Chain (chain ID 56).
/// @dev DO NOT RUN with --broadcast without the deployer's explicit
///      go-ahead. This script only exists so deployment is a single reviewed
///      command.
///
///      The market is an escrow marketplace for the two AgentHaven Pass
///      collections (v1 + v2), settling in BNB or USDT (BSC USDT, 18
///      decimals). Fee: 2.5% (250 bps) to the owner, changeable up to a
///      hard cap of 10% (1000 bps). Listing is free (gas only).
///
///      Dry-run (no broadcast, no funds):
///        forge script script/DeployMarket.s.sol --rpc-url bsc
///
///      Real deploy (deployer pays gas; needs a funded key):
///        forge script script/DeployMarket.s.sol --rpc-url bsc --broadcast \
///          --private-key $DEPLOYER_PRIVATE_KEY
///      (Never put a real private key in a file or in chat. Prefer a hardware
///      wallet or the deployer's own signer.)
///
///      After deploying, set MARKET_CONTRACT in docs/market.js to the
///      deployed address, then verify on BscScan (needs a BscScan API key):
///        forge verify-contract <DEPLOYED_ADDRESS> src/AgentHavenMarket.sol:AgentHavenMarket \
///          --chain-id 56 --constructor-args $(cast abi-encode "constructor(address,address,address,address,uint256)" \
///          0x538e7E6b0fFEa20864d7f6b3e944ddC07c4bb39E \
///          0x55d398326f99059fF775485246999027B3197955 \
///          0xf8118d518a228B704947eCf89C264B4F4F79aC5D \
///          0xFa4ad465FDff3b9b6d8cbd1bb31613a466aFfA0e 250)
contract DeployMarket is Script {
    /// @notice Market owner / fee recipient (the Pass deployer wallet).
    address public constant OWNER = 0x538e7E6b0fFEa20864d7f6b3e944ddC07c4bb39E;

    /// @notice USDT on BNB Smart Chain (BEP-20, 18 decimals).
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    /// @notice AgentHaven Pass v1 (all-free pilot drop).
    address public constant PASS_V1 = 0xf8118d518a228B704947eCf89C264B4F4F79aC5D;

    /// @notice AgentHaven Pass v2 (1,111 free, then 0.00005 BNB per claim).
    address public constant PASS_V2 = 0xFa4ad465FDff3b9b6d8cbd1bb31613a466aFfA0e;

    /// @notice Marketplace fee: 2.5% (250 basis points).
    uint256 public constant FEE_BPS = 250;

    function run() external returns (AgentHavenMarket market) {
        require(block.chainid == 56, "DeployMarket: BSC mainnet (chain 56) only");
        vm.startBroadcast();
        market = new AgentHavenMarket(OWNER, USDT, PASS_V1, PASS_V2, FEE_BPS);
        vm.stopBroadcast();
        console2.log("AgentHavenMarket deployed at:", address(market));
        console2.log("Owner (fee recipient):", market.owner());
        console2.log("USDT:", market.USDT());
        console2.log("PASS_V1:", market.PASS_V1());
        console2.log("PASS_V2:", market.PASS_V2());
        console2.log("feeBps:", market.feeBps());
        console2.log("MAX_FEE_BPS:", market.MAX_FEE_BPS());
    }
}
