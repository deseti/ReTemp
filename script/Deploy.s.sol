// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console2 } from "forge-std/Script.sol";
import { ReTempPool }   from "../contracts/ReTempPool.sol";
import { ReTempRouter } from "../contracts/ReTempRouter.sol";

/// @title Deploy
/// @notice Foundry broadcast + verification script for the ReTemp protocol on Tempo Testnet.
///
/// Required .env variables
/// ────────────────────────
///   PRIVATE_KEY       — deployer private key (with 0x prefix)
///   ALPHA_USD         — 0x20c0000000000000000000000000000000000001
///   BETA_USD          — 0x20c0000000000000000000000000000000000002
///   THETA_USD         — 0x20c0000000000000000000000000000000000003
///   PATH_USD          — 0x20c0000000000000000000000000000000000000
///   TREASURY_ADDRESS  — wallet that receives the 0.2% router fee
///
/// Deploy + verify (Tempo Testnet):
///   source .env
///   forge script script/Deploy.s.sol:Deploy \
///       --rpc-url $RPC_URL \
///       --private-key $PRIVATE_KEY \
///       --broadcast \
///       --verify \
///       --verifier-url $VERIFIER_URL \
///       --chain 42431 \
///       -vvvv
///
/// Deployment order
/// ─────────────────
///   1. ReTempPool(alphaUSD, betaUSD)   → poolAlphaBeta
///   2. ReTempPool(alphaUSD, thetaUSD)  → poolAlphaTheta
///   3. ReTempPool(alphaUSD, pathUSD)   → poolAlphaPath
///   4. ReTempRouter(alphaUSD, treasury)
///   5-7. router.registerPool() for each pair
contract Deploy is Script {

    ReTempPool   public poolAlphaBeta;
    ReTempPool   public poolAlphaTheta;
    ReTempPool   public poolAlphaPath;
    ReTempRouter public router;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address alphaUSD = vm.envAddress("ALPHA_USD");
        address betaUSD  = vm.envAddress("BETA_USD");
        address thetaUSD = vm.envAddress("THETA_USD");
        address pathUSD  = vm.envAddress("PATH_USD");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        console2.log("==============================================");
        console2.log(" ReTemp Protocol -- Tempo Testnet Deployment");
        console2.log("==============================================");
        console2.log("Deployer  :", deployer);
        console2.log("AlphaUSD  :", alphaUSD, " (hub)");
        console2.log("BetaUSD   :", betaUSD);
        console2.log("ThetaUSD  :", thetaUSD);
        console2.log("pathUSD   :", pathUSD);
        console2.log("Treasury  :", treasury);
        console2.log("----------------------------------------------");

        vm.startBroadcast(deployerKey);

        // 1. Deploy pools  ─────────────────────────────────────────────────────
        poolAlphaBeta  = new ReTempPool(alphaUSD, betaUSD);
        console2.log("poolAlphaBeta  :", address(poolAlphaBeta));

        poolAlphaTheta = new ReTempPool(alphaUSD, thetaUSD);
        console2.log("poolAlphaTheta :", address(poolAlphaTheta));

        poolAlphaPath  = new ReTempPool(alphaUSD, pathUSD);
        console2.log("poolAlphaPath  :", address(poolAlphaPath));

        // 2. Deploy router  (hub = AlphaUSD) ────────────────────────────────────
        router = new ReTempRouter(alphaUSD, treasury);
        console2.log("ReTempRouter   :", address(router));

        // 3. Register pools in router  ──────────────────────────────────────────
        router.registerPool(alphaUSD, betaUSD,  address(poolAlphaBeta));
        console2.log("Registered: AlphaUSD <-> BetaUSD");

        router.registerPool(alphaUSD, thetaUSD, address(poolAlphaTheta));
        console2.log("Registered: AlphaUSD <-> ThetaUSD");

        router.registerPool(alphaUSD, pathUSD,  address(poolAlphaPath));
        console2.log("Registered: AlphaUSD <-> pathUSD");

        vm.stopBroadcast();

        // Final summary  ─────────────────────────────────────────────────────
        console2.log("----------------------------------------------");
        console2.log("DEPLOYED ADDRESSES");
        console2.log("  poolAlphaBeta  :", address(poolAlphaBeta));
        console2.log("  poolAlphaTheta :", address(poolAlphaTheta));
        console2.log("  poolAlphaPath  :", address(poolAlphaPath));
        console2.log("  ReTempRouter   :", address(router));
        console2.log("Hub token        :", alphaUSD);
        console2.log("Treasury         :", treasury);
        console2.log("==============================================");
        console2.log(" Explorer: https://explore.tempo.xyz");
        console2.log("==============================================");
    }
}
