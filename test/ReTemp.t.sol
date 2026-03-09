// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { ERC20 }         from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReTempPool }    from "../contracts/ReTempPool.sol";
import { ReTempRouter }  from "../contracts/ReTempRouter.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Minimal ERC-20 with public mint (test only)
// ──────────────────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    uint8 private _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// ──────────────────────────────────────────────────────────────────────────────
// ReTempTest
// ──────────────────────────────────────────────────────────────────────────────

/// @title ReTempTest
/// @notice Integration tests for ReTempPool (AMM) and the multi-pool ReTempRouter.
///
/// Hub-token topology used in router tests:
///
///   alphaUSD  ←──────────────────────────── (hub)
///      │          poolAB                poolAC
///   betaUSD  ←────────── alphaUSD ─────────── gammaUSD
///
///   Direct swap : betaUSD  → alphaUSD  (poolAB, direct)
///   2-hop swap  : betaUSD  → gammaUSD (poolAB → poolAC via alphaUSD)
///
/// Run all tests:   forge test -vv
/// Focus tests:     forge test --match-test test_routeSwap -vvv
contract ReTempTest is Test {

    // Re-declared so vm.expectEmit can match it in Solidity 0.8.20
    // (ContractName.Event syntax requires >=0.8.21)
    event PoolRegistered(address indexed tokenA, address indexed tokenB, address indexed pool);

    // ── Actors ─────────────────────────────────────────────────────────────────
    address internal alice    = makeAddr("alice");    // LP
    address internal bob      = makeAddr("bob");      // LP
    address internal charlie  = makeAddr("charlie");  // merchant
    address internal dana     = makeAddr("dana");     // buyer / payer
    address internal treasury = makeAddr("treasury"); // fee recipient

    // ── Tokens ─────────────────────────────────────────────────────────────────
    MockERC20 internal alphaUSD; // hub token  (6 dec)
    MockERC20 internal betaUSD;  // peer token (6 dec)
    MockERC20 internal gammaUSD; // peer token (6 dec)  — used for 2-hop tests

    // Legacy aliases kept so pool AMM tests stay readable
    MockERC20 internal usdc; // = alphaUSD
    MockERC20 internal usdt; // = betaUSD

    // ── Contracts ──────────────────────────────────────────────────────────────
    ReTempPool   internal poolAB;  // alphaUSD ↔ betaUSD
    ReTempPool   internal poolAC;  // alphaUSD ↔ gammaUSD
    ReTempRouter internal router;

    // ── Seed amounts ───────────────────────────────────────────────────────────
    uint256 constant INITIAL_A = 1_000_000e6;
    uint256 constant INITIAL_B = 1_000_000e6;

    // ──────────────────────────────────────────────────────────────────────────
    // Setup
    // ──────────────────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy tokens
        alphaUSD = new MockERC20("AlphaUSD", "ALPHA", 6);
        betaUSD  = new MockERC20("BetaUSD",  "BETA",  6);
        gammaUSD = new MockERC20("GammaUSD", "GAMMA", 6);

        // Legacy aliases (pool AMM tests use usdc/usdt)
        usdc = alphaUSD;
        usdt = betaUSD;

        // Deploy pools
        poolAB = new ReTempPool(address(alphaUSD), address(betaUSD));
        poolAC = new ReTempPool(address(alphaUSD), address(gammaUSD));

        // Deploy router (hub = alphaUSD)
        router = new ReTempRouter(address(alphaUSD), treasury);

        // Register pools
        router.registerPool(address(alphaUSD), address(betaUSD),  address(poolAB));
        router.registerPool(address(alphaUSD), address(gammaUSD), address(poolAC));

        // Fund actors
        alphaUSD.mint(alice,   10_000_000e6);
        betaUSD.mint(alice,    10_000_000e6);
        gammaUSD.mint(alice,   10_000_000e6);

        alphaUSD.mint(bob,      5_000_000e6);
        betaUSD.mint(bob,       5_000_000e6);

        alphaUSD.mint(dana,       500_000e6);
        betaUSD.mint(dana,        500_000e6);
        gammaUSD.mint(dana,       500_000e6);

        alphaUSD.mint(charlie,    100_000e6);

        // Pool approvals (alice, bob → poolAB)
        vm.startPrank(alice);
        alphaUSD.approve(address(poolAB), type(uint256).max);
        betaUSD.approve(address(poolAB),  type(uint256).max);
        alphaUSD.approve(address(poolAC), type(uint256).max);
        gammaUSD.approve(address(poolAC), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        alphaUSD.approve(address(poolAB), type(uint256).max);
        betaUSD.approve(address(poolAB),  type(uint256).max);
        vm.stopPrank();

        // Dana approves router for all tokens
        vm.startPrank(dana);
        alphaUSD.approve(address(router), type(uint256).max);
        betaUSD.approve(address(router),  type(uint256).max);
        gammaUSD.approve(address(router), type(uint256).max);
        // Direct pool approvals for pool-level tests
        alphaUSD.approve(address(poolAB), type(uint256).max);
        betaUSD.approve(address(poolAB),  type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ──────────────────────────────────────────────────────────────────────────

    function _seedPool() internal {
        vm.prank(alice);
        poolAB.addLiquidity(INITIAL_A, INITIAL_B);
    }

    function _seedBothPools() internal {
        vm.startPrank(alice);
        poolAB.addLiquidity(INITIAL_A, INITIAL_B);
        poolAC.addLiquidity(INITIAL_A, INITIAL_B);
        vm.stopPrank();
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y / 2 + 1; while (x < z) { z = x; x = (y / x + x) / 2; } }
        else if (y != 0) { z = 1; }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }

    // ═════════════════════════════════════════════════════════════════════════
    // POOL: Deployment
    // ═════════════════════════════════════════════════════════════════════════

    function test_pool_tokens_are_set() public view {
        assertEq(poolAB.tokenA(), address(alphaUSD));
        assertEq(poolAB.tokenB(), address(betaUSD));
    }

    function test_pool_initial_state() public view {
        assertEq(poolAB.reserveA(),       0);
        assertEq(poolAB.reserveB(),       0);
        assertEq(poolAB.totalLiquidity(), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // POOL: addLiquidity
    // ═════════════════════════════════════════════════════════════════════════

    function test_addLiquidity_first_deposit_mints_shares() public {
        vm.prank(alice);
        poolAB.addLiquidity(INITIAL_A, INITIAL_B);

        uint256 expected = _sqrt(INITIAL_A * INITIAL_B) - 1_000;
        assertEq(poolAB.liquidity(alice),      expected);
        assertEq(poolAB.liquidity(address(0)), 1_000);
    }

    function test_addLiquidity_first_deposit_updates_reserves() public {
        vm.prank(alice);
        poolAB.addLiquidity(INITIAL_A, INITIAL_B);
        assertEq(poolAB.reserveA(), INITIAL_A);
        assertEq(poolAB.reserveB(), INITIAL_B);
    }

    function test_addLiquidity_subsequent_deposit() public {
        vm.prank(alice);
        poolAB.addLiquidity(INITIAL_A, INITIAL_B);
        uint256 total = poolAB.totalLiquidity();

        vm.prank(bob);
        poolAB.addLiquidity(500_000e6, 500_000e6);

        uint256 exp = _min(
            (500_000e6 * total) / INITIAL_A,
            (500_000e6 * total) / INITIAL_B
        );
        assertApproxEqAbs(poolAB.liquidity(bob), exp, 1);
    }

    function test_revert_addLiquidity_zero_amount() public {
        vm.prank(alice);
        vm.expectRevert(ReTempPool.ZeroAmount.selector);
        poolAB.addLiquidity(0, INITIAL_B);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // POOL: removeLiquidity
    // ═════════════════════════════════════════════════════════════════════════

    function test_removeLiquidity_returns_tokens() public {
        vm.prank(alice);
        poolAB.addLiquidity(INITIAL_A, INITIAL_B);

        uint256 shares  = poolAB.liquidity(alice);
        uint256 total   = poolAB.totalLiquidity();
        uint256 expA    = (shares * INITIAL_A) / total;
        uint256 preBal  = alphaUSD.balanceOf(alice);

        vm.prank(alice);
        poolAB.removeLiquidity(shares);

        assertApproxEqAbs(alphaUSD.balanceOf(alice) - preBal, expA, 1);
        assertEq(poolAB.liquidity(alice), 0);
    }

    function test_revert_removeLiquidity_zero() public {
        vm.prank(alice);
        vm.expectRevert(ReTempPool.ZeroAmount.selector);
        poolAB.removeLiquidity(0);
    }

    function test_revert_removeLiquidity_exceeds_balance() public {
        vm.prank(alice);
        poolAB.addLiquidity(INITIAL_A, INITIAL_B);
        vm.prank(bob);
        vm.expectRevert(ReTempPool.InsufficientLiquidity.selector);
        poolAB.removeLiquidity(1);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // POOL: swap
    // ═════════════════════════════════════════════════════════════════════════

    function test_swap_tokenA_for_tokenB() public {
        _seedPool();
        uint256 amtIn   = 1_000e6;
        uint256 preview = poolAB.getAmountOut(amtIn, address(alphaUSD));
        uint256 pre     = betaUSD.balanceOf(dana);

        vm.prank(dana);
        uint256 got = poolAB.swap(address(alphaUSD), amtIn);

        assertEq(got, preview);
        assertEq(betaUSD.balanceOf(dana), pre + got);
        assertGt(got, 0);
    }

    function test_swap_tokenB_for_tokenA() public {
        _seedPool();
        uint256 amtIn   = 1_000e6;
        uint256 preview = poolAB.getAmountOut(amtIn, address(betaUSD));
        uint256 pre     = alphaUSD.balanceOf(dana);

        vm.prank(dana);
        uint256 got = poolAB.swap(address(betaUSD), amtIn);

        assertEq(got, preview);
        assertEq(alphaUSD.balanceOf(dana), pre + got);
    }

    function test_swap_updates_reserves() public {
        _seedPool();
        uint256 amtIn = 1_000e6;
        vm.prank(dana);
        uint256 out = poolAB.swap(address(alphaUSD), amtIn);
        assertEq(poolAB.reserveA(), INITIAL_A + amtIn);
        assertEq(poolAB.reserveB(), INITIAL_B - out);
    }

    function test_swap_maintains_k_invariant() public {
        _seedPool();
        uint256 kBefore = poolAB.reserveA() * poolAB.reserveB();
        vm.prank(dana);
        poolAB.swap(address(alphaUSD), 1_000e6);
        assertGe(poolAB.reserveA() * poolAB.reserveB(), kBefore);
    }

    function test_revert_swap_zero_amount() public {
        _seedPool();
        vm.prank(dana);
        vm.expectRevert(ReTempPool.ZeroAmount.selector);
        poolAB.swap(address(alphaUSD), 0);
    }

    function test_revert_swap_invalid_token() public {
        _seedPool();
        vm.prank(dana);
        vm.expectRevert(abi.encodeWithSelector(ReTempPool.InvalidToken.selector, address(0x9999)));
        poolAB.swap(address(0x9999), 1_000e6);
    }

    function test_revert_swap_empty_pool() public {
        vm.prank(dana);
        vm.expectRevert(ReTempPool.InsufficientLiquidity.selector);
        poolAB.swap(address(alphaUSD), 1_000e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // POOL: price & reserves
    // ═════════════════════════════════════════════════════════════════════════

    function test_getPrice_equal_reserves() public {
        _seedPool();
        assertEq(poolAB.getPrice(), 1e18);
    }

    function test_getPrice_zero_on_empty() public view {
        assertEq(poolAB.getPrice(), 0);
    }

    function test_getPrice_updates_after_swap() public {
        _seedPool();
        uint256 before = poolAB.getPrice();
        vm.prank(dana);
        poolAB.swap(address(alphaUSD), 100_000e6);
        assertLt(poolAB.getPrice(), before);
    }

    function test_getReserves() public {
        _seedPool();
        (uint256 rA, uint256 rB) = poolAB.getReserves();
        assertEq(rA, INITIAL_A);
        assertEq(rB, INITIAL_B);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: Deployment & configuration
    // ═════════════════════════════════════════════════════════════════════════

    function test_router_hub_token() public view {
        assertEq(router.hubToken(), address(alphaUSD), "hub token mismatch");
    }

    function test_router_treasury_address() public view {
        assertEq(router.treasury(), treasury, "treasury mismatch");
    }

    function test_router_fee_constant() public view {
        assertEq(router.ROUTER_FEE(), 20);
    }

    function test_router_initial_invoice_count() public view {
        assertEq(router.invoiceCount(), 0);
    }

    function test_revert_router_zero_hub() public {
        vm.expectRevert("ReTempRouter: zero hubToken");
        new ReTempRouter(address(0), treasury);
    }

    function test_revert_router_zero_treasury() public {
        vm.expectRevert("ReTempRouter: zero treasury address");
        new ReTempRouter(address(alphaUSD), address(0));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: registerPool
    // ═════════════════════════════════════════════════════════════════════════

    function test_registerPool_stores_both_directions() public view {
        assertEq(router.pools(address(alphaUSD), address(betaUSD)),  address(poolAB));
        assertEq(router.pools(address(betaUSD),  address(alphaUSD)), address(poolAB));
    }

    function test_registerPool_second_pair() public view {
        assertEq(router.pools(address(alphaUSD), address(gammaUSD)), address(poolAC));
        assertEq(router.pools(address(gammaUSD), address(alphaUSD)), address(poolAC));
    }

    function test_registerPool_emits_event() public {
        ReTempPool newPool = new ReTempPool(address(betaUSD), address(gammaUSD));
        vm.expectEmit(true, true, true, false);
        emit PoolRegistered(address(betaUSD), address(gammaUSD), address(newPool));
        router.registerPool(address(betaUSD), address(gammaUSD), address(newPool));
    }

    function test_revert_registerPool_zero_token() public {
        vm.expectRevert("ReTempRouter: zero token");
        router.registerPool(address(0), address(betaUSD), address(poolAB));
    }

    function test_revert_registerPool_zero_pool() public {
        vm.expectRevert("ReTempRouter: zero pool");
        router.registerPool(address(alphaUSD), address(betaUSD), address(0));
    }

    function test_revert_registerPool_identical_tokens() public {
        vm.expectRevert("ReTempRouter: identical tokens");
        router.registerPool(address(alphaUSD), address(alphaUSD), address(poolAB));
    }

    function test_getPool_view_helper() public view {
        assertEq(router.getPool(address(alphaUSD), address(betaUSD)), address(poolAB));
        assertEq(router.getPool(address(betaUSD),  address(alphaUSD)), address(poolAB));
        assertEq(router.getPool(address(betaUSD),  address(gammaUSD)), address(0)); // unregistered direct
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: createInvoice
    // ═════════════════════════════════════════════════════════════════════════

    function test_createInvoice() public {
        vm.prank(charlie);
        uint256 id = router.createInvoice(address(alphaUSD), 100e6);

        ReTempRouter.Invoice memory inv = router.getInvoice(id);
        assertEq(inv.merchant, charlie);
        assertEq(inv.token,    address(alphaUSD));
        assertEq(inv.amount,   100e6);
        assertFalse(inv.paid);
    }

    function test_createInvoice_increments_count() public {
        vm.startPrank(charlie);
        router.createInvoice(address(alphaUSD), 1e6);
        router.createInvoice(address(alphaUSD), 2e6);
        vm.stopPrank();
        assertEq(router.invoiceCount(), 2);
    }

    function test_revert_createInvoice_zero_amount() public {
        vm.prank(charlie);
        vm.expectRevert(ReTempRouter.ZeroAmount.selector);
        router.createInvoice(address(alphaUSD), 0);
    }

    function test_revert_createInvoice_zero_token() public {
        vm.prank(charlie);
        vm.expectRevert(ReTempRouter.ZeroAddress.selector);
        router.createInvoice(address(0), 1e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: payInvoice — Direct path (same token)
    // ═════════════════════════════════════════════════════════════════════════

    function test_payInvoice_direct_net_to_merchant() public {
        uint256 face = 100e6;
        vm.prank(charlie);
        uint256 id = router.createInvoice(address(alphaUSD), face);

        uint256 pre = alphaUSD.balanceOf(charlie);

        vm.prank(dana);
        router.payInvoice(id, address(alphaUSD));

        uint256 fee = (face * 20) / 10_000;
        assertEq(alphaUSD.balanceOf(charlie), pre + face - fee, "merchant net");
    }

    function test_payInvoice_direct_marks_paid() public {
        vm.prank(charlie);
        uint256 id = router.createInvoice(address(alphaUSD), 100e6);
        vm.prank(dana);
        router.payInvoice(id, address(alphaUSD));
        assertTrue(router.getInvoice(id).paid);
    }

    function test_payInvoice_direct_fee_sent_to_treasury() public {
        uint256 face = 100e6;
        vm.prank(charlie);
        uint256 id = router.createInvoice(address(alphaUSD), face);

        uint256 tPre = alphaUSD.balanceOf(treasury);
        uint256 rPre = alphaUSD.balanceOf(address(router));

        vm.prank(dana);
        router.payInvoice(id, address(alphaUSD));

        uint256 fee = (face * 20) / 10_000;
        assertEq(alphaUSD.balanceOf(treasury),        tPre + fee, "treasury received fee");
        assertEq(alphaUSD.balanceOf(address(router)),  rPre,      "router unchanged");
    }

    function test_payInvoice_direct_pulls_from_payer() public {
        uint256 face = 100e6;
        vm.prank(charlie);
        uint256 id = router.createInvoice(address(alphaUSD), face);

        uint256 pre = alphaUSD.balanceOf(dana);
        vm.prank(dana);
        router.payInvoice(id, address(alphaUSD));
        assertEq(alphaUSD.balanceOf(dana), pre - face, "payer debited");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: payInvoice — Cross-token (single hop: beta → alpha)
    // ═════════════════════════════════════════════════════════════════════════

    function test_payInvoice_cross_token_direct_pool() public {
        _seedPool(); // seed poolAB (alpha ↔ beta)

        uint256 face = 100e6;
        vm.prank(charlie);
        // Merchant wants alphaUSD; Dana pays with betaUSD
        uint256 id = router.createInvoice(address(alphaUSD), face);

        uint256 pre = alphaUSD.balanceOf(charlie);
        vm.prank(dana);
        router.payInvoice(id, address(betaUSD));

        uint256 received = alphaUSD.balanceOf(charlie) - pre;
        assertGt(received, 0, "merchant got nothing");

        uint256 fee = (face * 20) / 10_000;
        assertApproxEqAbs(received, face - fee, face / 100, "merchant net ~ face - fee");
    }

    function test_payInvoice_cross_token_marks_paid() public {
        _seedPool();
        vm.prank(charlie);
        uint256 id = router.createInvoice(address(alphaUSD), 100e6);
        vm.prank(dana);
        router.payInvoice(id, address(betaUSD));
        assertTrue(router.getInvoice(id).paid);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: payInvoice — Reverts
    // ═════════════════════════════════════════════════════════════════════════

    function test_revert_payInvoice_not_found() public {
        vm.prank(dana);
        vm.expectRevert(abi.encodeWithSelector(ReTempRouter.InvoiceNotFound.selector, 999));
        router.payInvoice(999, address(alphaUSD));
    }

    function test_revert_payInvoice_already_paid() public {
        vm.prank(charlie);
        uint256 id = router.createInvoice(address(alphaUSD), 100e6);
        vm.prank(dana);
        router.payInvoice(id, address(alphaUSD));
        vm.prank(dana);
        vm.expectRevert(abi.encodeWithSelector(ReTempRouter.InvoiceAlreadyPaid.selector, id));
        router.payInvoice(id, address(alphaUSD));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: routeSwap — Direct pool (alpha ↔ beta)
    // ═════════════════════════════════════════════════════════════════════════

    function test_routeSwap_direct_pool_alpha_to_beta() public {
        _seedPool();
        uint256 amtIn   = 1_000e6;
        uint256 preview = poolAB.getAmountOut(amtIn, address(alphaUSD));
        uint256 pre     = betaUSD.balanceOf(dana);

        vm.prank(dana);
        uint256 got = router.routeSwap(address(alphaUSD), address(betaUSD), amtIn);

        assertEq(got, preview, "output mismatch");
        assertEq(betaUSD.balanceOf(dana), pre + got, "dana betaUSD balance");
    }

    function test_routeSwap_direct_pool_beta_to_alpha() public {
        _seedPool();
        uint256 amtIn   = 1_000e6;
        uint256 preview = poolAB.getAmountOut(amtIn, address(betaUSD));
        uint256 pre     = alphaUSD.balanceOf(dana);

        vm.prank(dana);
        uint256 got = router.routeSwap(address(betaUSD), address(alphaUSD), amtIn);

        assertEq(got, preview);
        assertEq(alphaUSD.balanceOf(dana), pre + got);
    }

    function test_routeSwap_direct_debits_payer() public {
        _seedPool();
        uint256 amtIn = 1_000e6;
        uint256 pre   = alphaUSD.balanceOf(dana);

        vm.prank(dana);
        router.routeSwap(address(alphaUSD), address(betaUSD), amtIn);

        assertEq(alphaUSD.balanceOf(dana), pre - amtIn, "payer debited");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: routeSwap — 2-hop (beta → alpha → gamma, no direct pool)
    // ═════════════════════════════════════════════════════════════════════════

    function test_routeSwap_two_hop_beta_to_gamma() public {
        _seedBothPools(); // seed poolAB and poolAC

        uint256 amtIn = 1_000e6;
        uint256 pre   = gammaUSD.balanceOf(dana);

        // betaUSD → alphaUSD (poolAB) → gammaUSD (poolAC)  — no direct pool
        vm.prank(dana);
        uint256 got = router.routeSwap(address(betaUSD), address(gammaUSD), amtIn);

        assertGt(got, 0, "two-hop produced nothing");
        assertEq(gammaUSD.balanceOf(dana), pre + got, "dana gammaUSD balance");
    }

    function test_routeSwap_two_hop_debits_payer() public {
        _seedBothPools();
        uint256 amtIn = 1_000e6;
        uint256 pre   = betaUSD.balanceOf(dana);

        vm.prank(dana);
        router.routeSwap(address(betaUSD), address(gammaUSD), amtIn);

        assertEq(betaUSD.balanceOf(dana), pre - amtIn, "payer debited");
    }

    function test_routeSwap_two_hop_no_intermediate_hub_balance_leak() public {
        _seedBothPools();

        // Router should hold zero hubToken after a 2-hop completes
        vm.prank(dana);
        router.routeSwap(address(betaUSD), address(gammaUSD), 1_000e6);

        assertEq(alphaUSD.balanceOf(address(router)), 0, "hub token leaked into router");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: routeSwap — Reverts
    // ═════════════════════════════════════════════════════════════════════════

    function test_revert_routeSwap_zero_amount() public {
        vm.prank(dana);
        vm.expectRevert(ReTempRouter.ZeroAmount.selector);
        router.routeSwap(address(alphaUSD), address(betaUSD), 0);
    }

    function test_revert_routeSwap_zero_tokenIn() public {
        vm.prank(dana);
        vm.expectRevert(ReTempRouter.ZeroAddress.selector);
        router.routeSwap(address(0), address(betaUSD), 1_000e6);
    }

    function test_revert_routeSwap_zero_tokenOut() public {
        vm.prank(dana);
        vm.expectRevert(ReTempRouter.ZeroAddress.selector);
        router.routeSwap(address(alphaUSD), address(0), 1_000e6);
    }

    function test_revert_routeSwap_no_route() public {
        // betaUSD → gammaUSD: no direct pool, and pools are unseeded so
        // hub route exists in registry but is present — use a completely
        // unregistered token to force NoRouteFound
        MockERC20 unknown = new MockERC20("Unknown", "UNK", 6);
        unknown.mint(dana, 1_000e6);
        vm.prank(dana);
        unknown.approve(address(router), type(uint256).max);

        vm.prank(dana);
        vm.expectRevert(
            abi.encodeWithSelector(ReTempRouter.NoRouteFound.selector, address(unknown), address(gammaUSD))
        );
        router.routeSwap(address(unknown), address(gammaUSD), 1_000e6);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ROUTER: quotePayment
    // ═════════════════════════════════════════════════════════════════════════

    function test_quotePayment_direct_returns_face_value() public {
        vm.prank(charlie);
        uint256 id = router.createInvoice(address(alphaUSD), 100e6);
        assertEq(router.quotePayment(id, address(alphaUSD)), 100e6);
    }

    function test_quotePayment_cross_token_nonzero() public {
        _seedPool();
        vm.prank(charlie);
        uint256 id    = router.createInvoice(address(alphaUSD), 100e6);
        uint256 quote = router.quotePayment(id, address(betaUSD));
        assertGt(quote, 0, "cross-token quote should be > 0");
    }

    function test_revert_quotePayment_not_found() public {
        vm.expectRevert(abi.encodeWithSelector(ReTempRouter.InvoiceNotFound.selector, 42));
        router.quotePayment(42, address(alphaUSD));
    }
}
