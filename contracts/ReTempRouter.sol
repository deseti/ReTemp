// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IReTempPool } from "./interfaces/IReTempPool.sol";

/// @title ReTempRouter
/// @author ReTemp Protocol
/// @notice Payment router supporting a hub-token multi-pool architecture.
///
///         Pool registry
///         ─────────────
///         Pools are registered as (tokenA, tokenB) → pool address pairs.
///         Any pair registered covers both swap directions.
///
///         Swap routing (two-level)
///         ─────────────────────────
///         1. Direct  : pools[tokenIn][tokenOut] exists → single-hop swap
///         2. 2-hop   : pools[tokenIn][hubToken] + pools[hubToken][tokenOut]
///                      → tokenIn → hubToken → tokenOut
///
///         Payment paths
///         ──────────────
///         A. Same token   : pull → deduct 0.2% fee to treasury → forward net to merchant
///         B. Cross token  : pull paymentToken → route swap → deduct fee → forward to merchant
///
///         Security
///         ─────────
///         • CEI pattern: inv.paid written before any external token call.
///         • forceApprove to 0 after every pool interaction.
///         • Surplus guard: revert if swap yields < invoice face value.
contract ReTempRouter {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A merchant payment request
    struct Invoice {
        address merchant; // receives net settlement
        address token;    // expected token
        uint256 amount;   // face value in token decimals
        bool    paid;     // settled flag
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Router fee in basis points (20 = 0.20%)
    uint256 public constant ROUTER_FEE = 20;

    /// @dev Basis-point denominator
    uint256 private constant FEE_DENOMINATOR = 10_000;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Hub token used as intermediate for 2-hop swaps (e.g. AlphaUSD)
    address public immutable hubToken;

    // ─────────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pool registry: pools[tokenA][tokenB] = pool address (both directions stored)
    mapping(address => mapping(address => address)) public pools;

    /// @notice Treasury that receives the 0.2% router fee on every invoice settlement
    address public treasury;

    /// @notice Auto-incrementing invoice ID counter
    uint256 public invoiceCount;

    /// @notice Invoice storage
    mapping(uint256 => Invoice) public invoices;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed merchant,
        address token,
        uint256 amount
    );

    event InvoicePaid(
        uint256 indexed invoiceId,
        address indexed payer,
        address paymentToken,
        uint256 amountPaid
    );

    /// @notice Emitted on every swap routed through this contract
    event SwapRouted(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when a pool is added to the registry
    event PoolRegistered(address indexed tokenA, address indexed tokenB, address indexed pool);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error InvoiceNotFound(uint256 invoiceId);
    error InvoiceAlreadyPaid(uint256 invoiceId);
    error ZeroAmount();
    error ZeroAddress();
    error SwapOutputInsufficient(uint256 got, uint256 required);
    error NoRouteFound(address tokenIn, address tokenOut);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param _hubToken  Hub token address (AlphaUSD); used as 2-hop intermediate
    /// @param _treasury  Address that collects the 0.2% router fee
    constructor(address _hubToken, address _treasury) {
        require(_hubToken  != address(0), "ReTempRouter: zero hubToken");
        require(_treasury  != address(0), "ReTempRouter: zero treasury address");
        hubToken = _hubToken;
        treasury = _treasury;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pool Registry
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Registers a pool for a token pair.
    ///         Both directions are stored so lookups are O(1) in either direction.
    /// @param tokenA First token of the pair
    /// @param tokenB Second token of the pair
    /// @param pool   Address of the ReTempPool contract for this pair
    /// @dev   No access control — add `onlyOwner` before deploying to mainnet.
    function registerPool(address tokenA, address tokenB, address pool) external {
        require(tokenA != address(0) && tokenB != address(0), "ReTempRouter: zero token");
        require(pool   != address(0),                         "ReTempRouter: zero pool");
        require(tokenA != tokenB,                             "ReTempRouter: identical tokens");

        pools[tokenA][tokenB] = pool;
        pools[tokenB][tokenA] = pool;

        emit PoolRegistered(tokenA, tokenB, pool);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Invoice Lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Creates a new payment invoice.
    /// @param token  ERC-20 token the merchant expects to receive
    /// @param amount Face-value amount (in token decimals)
    /// @return invoiceId Monotonically increasing invoice ID
    function createInvoice(address token, uint256 amount) external returns (uint256 invoiceId) {
        if (token  == address(0)) revert ZeroAddress();
        if (amount == 0)          revert ZeroAmount();

        invoiceId = invoiceCount++;
        invoices[invoiceId] = Invoice({
            merchant: msg.sender,
            token:    token,
            amount:   amount,
            paid:     false
        });

        emit InvoiceCreated(invoiceId, msg.sender, token, amount);
    }

    /// @notice Pays an invoice in any registered ERC-20 token.
    ///
    /// @dev   Payment flow:
    ///        ┌─────────┐  paymentToken         ┌────────┐  invoiceToken (net)  ┌──────────┐
    ///        │  payer  │ ─────────────────────► │ router │ ──────────────────►  │ merchant │
    ///        └─────────┘                        └────┬───┘                      └──────────┘
    ///                                               fee (0.2%) ──────────────►  treasury
    ///
    ///        Cross-token: router pulls paymentToken, executes _executeSwap(),
    ///        accumulates invoiceToken, then distributes net + fee.
    ///
    /// @param invoiceId    ID of the invoice to settle
    /// @param paymentToken Token the payer wants to spend
    function payInvoice(uint256 invoiceId, address paymentToken) external {
        // ── 1. Load & validate (memory cache = 1 SLOAD) ──────────────────────
        Invoice memory inv = invoices[invoiceId];
        if (inv.merchant == address(0)) revert InvoiceNotFound(invoiceId);
        if (inv.paid)                   revert InvoiceAlreadyPaid(invoiceId);

        // ── 2. Mark paid — CEI: before any external call ─────────────────────
        invoices[invoiceId].paid = true;

        uint256 grossAmount;

        if (paymentToken == inv.token) {
            // ── Path A: Direct (same token) ───────────────────────────────────
            IERC20(inv.token).safeTransferFrom(msg.sender, address(this), inv.amount);
            grossAmount = inv.amount;

        } else {
            // ── Path B: Cross-token — route through pool(s) ───────────────────
            // Compute how much paymentToken the payer must supply so that after
            // routing we receive at least inv.amount of inv.token.
            uint256 amountIn = _quoteIn(inv.amount, paymentToken, inv.token);

            // Pull paymentToken from payer
            IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), amountIn);

            // Execute swap — returns inv.token to this router
            uint256 received = _executeSwap(paymentToken, inv.token, amountIn);

            // Guard: must cover the invoice face value
            if (received < inv.amount) revert SwapOutputInsufficient(received, inv.amount);

            grossAmount = received;
        }

        // ── 3. Fee split: net → merchant, fee → treasury ──────────────────────
        uint256 fee         = (grossAmount * ROUTER_FEE) / FEE_DENOMINATOR;
        uint256 merchantAmt = grossAmount - fee;

        IERC20(inv.token).safeTransfer(inv.merchant, merchantAmt);
        if (fee > 0) IERC20(inv.token).safeTransfer(treasury, fee);

        emit InvoicePaid(invoiceId, msg.sender, paymentToken, grossAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Swap Routing — Public
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Routes a swap through the registry on behalf of msg.sender.
    ///         Tries a direct pool first; falls back to a 2-hop via hubToken.
    ///         No router fee is charged on raw swaps (fee-free passthrough).
    ///
    /// @param tokenIn  Token to sell
    /// @param tokenOut Token to receive
    /// @param amountIn Exact amount of tokenIn to sell
    /// @return amountOut Amount of tokenOut received by msg.sender
    function routeSwap(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint256 amountOut)
    {
        if (tokenIn  == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (amountIn == 0)                                     revert ZeroAmount();

        // Pull tokenIn from caller into the router
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Execute routing (single or 2-hop); tokenOut lands in this router
        amountOut = _executeSwap(tokenIn, tokenOut, amountIn);

        // Forward tokenOut to caller
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit SwapRouted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the invoice struct for a given ID.
    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        return invoices[invoiceId];
    }

    /// @notice Returns the pool address for a token pair (zero if unregistered).
    function getPool(address tokenA, address tokenB) external view returns (address) {
        return pools[tokenA][tokenB];
    }

    /// @notice Estimates how much `paymentToken` a payer must supply to settle an invoice.
    ///         Direct path  → returns face value.
    ///         Cross-token  → uses inverse AMM formula (single or 2-hop).
    /// @param invoiceId    ID of the invoice to quote
    /// @param paymentToken Token the payer intends to spend
    /// @return requiredIn  Estimated input amount (includes 0.1% buffer; add slippage on top)
    function quotePayment(uint256 invoiceId, address paymentToken)
        external
        view
        returns (uint256 requiredIn)
    {
        Invoice memory inv = invoices[invoiceId];
        if (inv.merchant == address(0)) revert InvoiceNotFound(invoiceId);

        if (paymentToken == inv.token) {
            requiredIn = inv.amount; // fee deducted on the output side
        } else {
            requiredIn = _quoteIn(inv.amount, paymentToken, inv.token);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — Routing Engine
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Executes a swap of `amountIn` tokenIn → tokenOut, routing via the
    ///      registry.  The caller must have already transferred `amountIn` into
    ///      this contract before calling.
    ///
    ///      Routing strategy:
    ///      1. Direct pool   : pools[tokenIn][tokenOut] → single pool.swap()
    ///      2. 2-hop via hub : pools[tokenIn][hub] + pools[hub][tokenOut]
    ///                         → pool1.swap() then pool2.swap()
    ///      3. No route      : revert NoRouteFound
    ///
    ///      tokenOut is transferred to this router by each pool (pool sends to
    ///      msg.sender which is the router).
    function _executeSwap(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        // ── Try direct pool ───────────────────────────────────────────────────
        address directPool = pools[tokenIn][tokenOut];
        if (directPool != address(0)) {
            amountOut = _singleSwap(directPool, tokenIn, amountIn);
            return amountOut;
        }

        // ── Try 2-hop: tokenIn → hub → tokenOut ───────────────────────────────
        address poolA = pools[tokenIn][hubToken];  // tokenIn → hub
        address poolB = pools[hubToken][tokenOut]; // hub → tokenOut

        if (poolA == address(0) || poolB == address(0)) {
            revert NoRouteFound(tokenIn, tokenOut);
        }

        // Hop 1: tokenIn → hubToken
        uint256 hubAmount = _singleSwap(poolA, tokenIn, amountIn);

        // Hop 2: hubToken → tokenOut
        amountOut = _singleSwap(poolB, hubToken, hubAmount);
    }

    /// @dev Executes a single pool swap: transfer `amountIn` of `tokenIn` directly
    ///      to the pool, then call pool.swapDirect() which skips the transferFrom pull.
    ///      Falls back to approve+swap if swapDirect is not available.
    ///
    ///      WHY NOT forceApprove:
    ///      On Tempo, every TIP-20 method call (incl. approve) deducts a fee in the
    ///      token being called.  forceApprove() = approve(0) + approve(amount) = 2 fees.
    ///      Using a direct push (transfer to pool) + pool.swapDirect avoids all approve
    ///      calls entirely, saving ~2× TIP-20 fees per hop.
    ///
    ///      Returns `amountOut` (tokenOut is sent to this router by the pool).
    function _singleSwap(address pool, address tokenIn, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        // Push tokenIn directly to pool (no approve needed)
        IERC20(tokenIn).safeTransfer(pool, amountIn);
        // Call pool's push-based swap (no transferFrom inside pool)
        amountOut = IReTempPool(pool).swapDirect(tokenIn, amountIn);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — Quoting
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Computes how much `tokenIn` is needed to receive at least `amountOut`
    ///      of `tokenOut`, using the inverse constant-product AMM formula.
    ///      Applies a 0.1% surplus buffer to absorb rounding.
    ///
    ///      Routing mirrors _executeSwap:
    ///      1. Direct pool  → single inverse quote
    ///      2. 2-hop via hub → chain two inverse quotes (tokenOut first, then hub)
    ///      3. No route     → returns 0 (caller's pool.swap will revert naturally)
    ///
    ///      Inverse formula:
    ///        amountIn = (reserveIn × amountRequired × 1000)
    ///                   / ((reserveOut − amountRequired) × 997)  + 1
    function _quoteIn(uint256 amountRequired, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 amountIn)
    {
        // ── Direct pool ───────────────────────────────────────────────────────
        address directPool = pools[tokenIn][tokenOut];
        if (directPool != address(0)) {
            return _inverseQuote(directPool, tokenIn, tokenOut, amountRequired);
        }

        // ── 2-hop: tokenIn → hub → tokenOut ──────────────────────────────────
        address poolA = pools[tokenIn][hubToken];
        address poolB = pools[hubToken][tokenOut];

        if (poolA == address(0) || poolB == address(0)) {
            return 0; // no route; swap will revert; caller is responsible
        }

        // Work backwards: how much hub do we need to get `amountRequired` tokenOut?
        uint256 hubRequired = _inverseQuote(poolB, hubToken, tokenOut, amountRequired);

        // How much tokenIn do we need to get `hubRequired` hubToken?
        amountIn = _inverseQuote(poolA, tokenIn, hubToken, hubRequired);
    }

    /// @dev Pure inverse of constant-product formula for a single pool.
    ///      Reads reserves from the pool, maps in/out relative to tokenIn,
    ///      applies 0.1% surplus buffer.
    ///
    ///      Formula:  amountIn = (reserveIn × amountRequired × 1000)
    ///                           / ((reserveOut − amountRequired) × 997) + 1
    ///
    ///      Returns type(uint256).max if amountRequired >= reserveOut (would drain pool).
    function _inverseQuote(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 amountRequired
    )
        internal
        view
        returns (uint256 amountIn)
    {
        (uint256 rA, uint256 rB) = IReTempPool(pool).getReserves();
        address tA = IReTempPool(pool).tokenA();

        uint256 reserveIn  = (tokenIn  == tA) ? rA : rB;
        uint256 reserveOut = (tokenOut == tA) ? rA : rB;

        if (reserveIn == 0 || reserveOut == 0) return 0;
        if (amountRequired >= reserveOut)       return type(uint256).max;

        // Inverse constant-product with 0.3% fee (997/1000 multiplier)
        amountIn = (reserveIn * amountRequired * 1_000)
                   / ((reserveOut - amountRequired) * 997) + 1;

        // 0.1% surplus buffer against rounding / minor price movement
        amountIn = amountIn + amountIn / 1_000;
    }
}
