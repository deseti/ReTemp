// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReTempPool } from "../contracts/ReTempPool.sol";
import { IReTempPool } from "../contracts/interfaces/IReTempPool.sol";
import { ReTempRouter } from "../contracts/ReTempRouter.sol";

/// @notice Adds liquidity to all pools then tests routeSwap through the router
contract Seed is Script {
    // ─── New deployed addresses ─────────────────────────────────────────────
    address constant POOL_ALPHA_BETA  = 0x857F4F2dEF1a6A2C4c417ae2c5bb1A62F1A0950C;
    address constant POOL_ALPHA_THETA = 0x86ca17F2fe550E8B245cB23967343bc5C8DCfab9;
    address constant POOL_ALPHA_PATH  = 0x23b549AbaE9003ceBD95ac4fFe2BC948E7DcBfEd;
    address constant ROUTER           = 0x148ACa4DF102E7E4F94C8eFDF3A1710E41AFc093;

    // ─── Tempo native tokens ─────────────────────────────────────────────────
    address constant ALPHA_USD = 0x20C0000000000000000000000000000000000001;
    address constant BETA_USD  = 0x20C0000000000000000000000000000000000002;
    address constant THETA_USD = 0x20C0000000000000000000000000000000000003;
    address constant PATH_USD  = 0x20C0000000000000000000000000000000000000;

    uint256 constant LIQUIDITY = 8_000_000e6; // 8M units

    function run() external {
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("==============================================");
        console2.log(" ReTemp Seed + routeSwap Test");
        console2.log("==============================================");
        console2.log("Deployer :", deployer);

        vm.startBroadcast(pk);

        // ─── 1. Approve all tokens ────────────────────────────────────────────
        IERC20(ALPHA_USD).approve(POOL_ALPHA_BETA,  type(uint256).max);
        IERC20(BETA_USD).approve(POOL_ALPHA_BETA,   type(uint256).max);

        IERC20(ALPHA_USD).approve(POOL_ALPHA_THETA, type(uint256).max);
        IERC20(THETA_USD).approve(POOL_ALPHA_THETA, type(uint256).max);

        IERC20(ALPHA_USD).approve(POOL_ALPHA_PATH,  type(uint256).max);
        IERC20(PATH_USD).approve(POOL_ALPHA_PATH,   type(uint256).max);

        // ─── 2. Add liquidity ─────────────────────────────────────────────────
        ReTempPool(POOL_ALPHA_BETA).addLiquidity(LIQUIDITY, LIQUIDITY);
        console2.log("[OK] Liquidity added to poolAlphaBeta");

        ReTempPool(POOL_ALPHA_THETA).addLiquidity(LIQUIDITY, LIQUIDITY);
        console2.log("[OK] Liquidity added to poolAlphaTheta");

        ReTempPool(POOL_ALPHA_PATH).addLiquidity(LIQUIDITY, LIQUIDITY);
        console2.log("[OK] Liquidity added to poolAlphaPath");

        // ─── 3. Test routeSwap: BetaUSD -> AlphaUSD (direct) ─────────────────
        uint256 amountIn  = 1_000e6; // 1000 BetaUSD
        IERC20(BETA_USD).approve(ROUTER, type(uint256).max);

        uint256 balBefore = IERC20(ALPHA_USD).balanceOf(deployer);
        uint256 amountOut = ReTempRouter(ROUTER).routeSwap(BETA_USD, ALPHA_USD, amountIn);
        uint256 balAfter  = IERC20(ALPHA_USD).balanceOf(deployer);

        console2.log("----------------------------------------------");
        console2.log("[TEST] routeSwap BetaUSD -> AlphaUSD");
        console2.log("  amountIn   :", amountIn);
        console2.log("  amountOut  :", amountOut);
        console2.log("  balDelta   :", balAfter - balBefore);
        require(amountOut > 0, "routeSwap: output is zero");
        console2.log("[PASS] routeSwap direct hop succeeded!");

        // ─── 4. Test routeSwap: BetaUSD -> ThetaUSD (2-hop via AlphaUSD) ─────
        uint256 balTheta = IERC20(THETA_USD).balanceOf(deployer);
        uint256 out2hop  = ReTempRouter(ROUTER).routeSwap(BETA_USD, THETA_USD, amountIn);
        uint256 deltaTheta = IERC20(THETA_USD).balanceOf(deployer) - balTheta;

        console2.log("----------------------------------------------");
        console2.log("[TEST] routeSwap BetaUSD -> ThetaUSD (2-hop)");
        console2.log("  amountIn   :", amountIn);
        console2.log("  amountOut  :", out2hop);
        console2.log("  balDelta   :", deltaTheta);
        require(out2hop > 0, "routeSwap 2-hop: output is zero");
        console2.log("[PASS] routeSwap 2-hop succeeded!");

        vm.stopBroadcast();

        console2.log("==============================================");
        console2.log(" ALL TESTS PASSED ON-CHAIN");
        console2.log("==============================================");
        console2.log("  Router     :", ROUTER);
        console2.log("  Explorer   : https://explore.tempo.xyz");
    }
}
