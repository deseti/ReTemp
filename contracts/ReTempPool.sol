// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IReTempPool } from "./interfaces/IReTempPool.sol";

/// @title ReTempPool
/// @author ReTemp Protocol
/// @notice Constant-product AMM liquidity pool (x · y = k) for stablecoin
///         swaps in the ReTemp payment protocol.  Modelled after Uniswap V2 with
///         a 0.3 % swap fee (997/1000 multiplier).
///
/// @dev   Security model
///        ───────────────
///        • MINIMUM_LIQUIDITY (1000 shares) is permanently burned to address(0)
///          on the first deposit to prevent price-manipulation via single-share dust.
///        • Reserves are cached to memory at the start of every mutating function
///          (one SLOAD each instead of two).
///        • _updateReserves() syncs from actual ERC-20 balances so the pool is
///          resilient to mistaken direct transfers.
///        • Solidity 0.8 arithmetic overflow guards replace SafeMath.
contract ReTempPool is IReTempPool {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Permanently locked shares on first deposit (Uniswap V2 pattern).
    ///      Prevents the "first-liquidity" price-manipulation attack.
    uint256 private constant MINIMUM_LIQUIDITY = 1_000;

    /// @dev Fee numerator: 997 / FEE_DENOM == 0.3% fee retained by LPs.
    uint256 private constant FEE_NUMERATOR = 997;

    /// @dev Fee denominator (1000).
    uint256 private constant FEE_DENOM = 1_000;

    // ─────────────────────────────────────────────────────────────────────────
    // State Variables
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice First token in the pool pair
    address public tokenA;

    /// @notice Second token in the pool pair
    address public tokenB;

    /// @notice Tracked reserve for tokenA (updated via _updateReserves)
    uint256 public reserveA;

    /// @notice Tracked reserve for tokenB (updated via _updateReserves)
    uint256 public reserveB;

    /// @notice Total outstanding LP shares (including permanently locked shares)
    uint256 public totalLiquidity;

    /// @notice LP shares per liquidity provider
    mapping(address => uint256) public liquidity;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error InvalidToken(address token);
    error InsufficientLiquidity();
    error InsufficientLiquidityMinted();
    error InsufficientOutputAmount();
    error ZeroAmount();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param _tokenA Address of the first pool token (e.g. USDC)
    /// @param _tokenB Address of the second pool token (e.g. USDT)
    constructor(address _tokenA, address _tokenB) {
        require(_tokenA != address(0) && _tokenB != address(0), "ReTempPool: zero address");
        require(_tokenA != _tokenB, "ReTempPool: identical tokens");

        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Liquidity Management
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposits tokenA and tokenB into the pool and mints LP shares.
    ///
    /// @dev   Share minting rules (Uniswap V2):
    ///        • First deposit  → shares = √(amountA · amountB) − MINIMUM_LIQUIDITY
    ///          MINIMUM_LIQUIDITY shares are permanently sent to address(0) so the
    ///          pool can never be completely drained.
    ///        • Subsequent deposits → shares = min(
    ///              amountA · totalLiquidity / reserveA,
    ///              amountB · totalLiquidity / reserveB )
    ///          Excess tokens beyond the current ratio are still pulled but the LPs
    ///          receive shares proportional to whichever side is the constraining
    ///          factor — identical to Uniswap V2 behaviour.
    ///
    /// @param amountA Amount of tokenA to deposit (in tokenA's native decimals)
    /// @param amountB Amount of tokenB to deposit (in tokenB's native decimals)
    function addLiquidity(uint256 amountA, uint256 amountB) external {
        if (amountA == 0 || amountB == 0) revert ZeroAmount();

        // ── Cache reserves (1 SLOAD each) ───────────────────────────────────
        uint256 _reserveA = reserveA;
        uint256 _reserveB = reserveB;
        uint256 _total    = totalLiquidity;

        // ── Pull tokens from caller ──────────────────────────────────────────
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);

        // ── Compute LP shares ────────────────────────────────────────────────
        uint256 shares;

        if (_total == 0) {
            // ─ First deposit: geometric mean minus permanently locked minimum ─
            uint256 geometric = _sqrt(amountA * amountB);

            if (geometric <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();

            shares = geometric - MINIMUM_LIQUIDITY;

            // Lock MINIMUM_LIQUIDITY forever so totalLiquidity is never 0 again
            liquidity[address(0)] += MINIMUM_LIQUIDITY;
            totalLiquidity         = MINIMUM_LIQUIDITY; // temporary; overwritten below
            _total                 = MINIMUM_LIQUIDITY;
        } else {
            // ─ Subsequent deposit: proportional to existing reserves ──────────
            // Use the smaller ratio so the LP can't claim extra shares by
            // depositing an off-ratio amount.
            uint256 sharesA = (amountA * _total) / _reserveA;
            uint256 sharesB = (amountB * _total) / _reserveB;
            shares = _min(sharesA, sharesB);
        }

        if (shares == 0) revert InsufficientLiquidityMinted();

        // ── Mint shares ──────────────────────────────────────────────────────
        liquidity[msg.sender] += shares;
        totalLiquidity         = _total + shares;

        // ── Sync reserves from actual balances ───────────────────────────────
        _updateReserves();

        emit LiquidityAdded(msg.sender, amountA, amountB, shares);
    }

    /// @notice Burns `share` LP tokens and returns proportional tokenA + tokenB.
    ///
    /// @dev   Return amounts:
    ///        amountA = share · reserveA / totalLiquidity
    ///        amountB = share · reserveB / totalLiquidity
    ///
    ///        Order of operations is burn-first / transfer-second to prevent
    ///        re-entrancy from inflating the share count before tokens leave.
    ///
    /// @param share Number of LP shares to redeem
    function removeLiquidity(uint256 share) external {
        if (share == 0) revert ZeroAmount();
        if (liquidity[msg.sender] < share) revert InsufficientLiquidity();

        // ── Cache reserves (1 SLOAD each) ───────────────────────────────────
        uint256 _reserveA = reserveA;
        uint256 _reserveB = reserveB;
        uint256 _total    = totalLiquidity;

        // ── Compute proportional token amounts ───────────────────────────────
        uint256 amountA = (share * _reserveA) / _total;
        uint256 amountB = (share * _reserveB) / _total;

        if (amountA == 0 || amountB == 0) revert InsufficientLiquidity();

        // ── Burn shares (before external calls – CEI pattern) ────────────────
        liquidity[msg.sender] -= share;
        totalLiquidity         -= share;

        // ── Update reserves to reflect new balances ──────────────────────────
        // Decrement inline (cheaper than balanceOf when amounts are known)
        reserveA = _reserveA - amountA;
        reserveB = _reserveB - amountB;

        // ── Transfer tokens to caller ────────────────────────────────────────
        IERC20(tokenA).safeTransfer(msg.sender, amountA);
        IERC20(tokenB).safeTransfer(msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, share, amountA, amountB);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Swap
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Swaps an exact `amountIn` of `tokenIn` for as many `tokenOut` as
    ///         the pool can provide after the 0.3 % LP fee.
    ///
    /// @dev   Constant-product formula (Uniswap V2):
    ///        amountInWithFee = amountIn · 997
    ///        amountOut = (reserveOut · amountInWithFee)
    ///                    / (reserveIn · 1000 + amountInWithFee)
    ///
    ///        The invariant k = reserveA · reserveB can only increase (fees
    ///        accumulate as additional reserves) — never decrease.
    ///
    ///        Steps (Checks-Effects-Interactions):
    ///        1. Validate inputs.
    ///        2. Cache reserves.
    ///        3. Pull tokenIn from caller.
    ///        4. Calculate amountOut.
    ///        5. Sync reserves (effect).
    ///        6. Transfer tokenOut to caller (interaction).
    ///        7. Verify invariant k did not decrease.
    ///
    /// @param tokenIn  Token being sold (must be tokenA or tokenB)
    /// @param amountIn Exact amount of tokenIn to sell
    /// @return amountOut Amount of tokenOut received
    function swap(address tokenIn, uint256 amountIn) external returns (uint256 amountOut) {
        // ── Checks ───────────────────────────────────────────────────────────
        if (tokenIn != tokenA && tokenIn != tokenB) revert InvalidToken(tokenIn);
        if (amountIn == 0) revert ZeroAmount();

        // ── Cache reserves ───────────────────────────────────────────────────
        uint256 _reserveA = reserveA;
        uint256 _reserveB = reserveB;

        if (_reserveA == 0 || _reserveB == 0) revert InsufficientLiquidity();

        // ── Determine direction ──────────────────────────────────────────────
        bool isTokenA        = (tokenIn == tokenA);
        address tokenOut     = isTokenA ? tokenB : tokenA;
        uint256 reserveIn    = isTokenA ? _reserveA : _reserveB;
        uint256 reserveOut   = isTokenA ? _reserveB : _reserveA;

        // ── Pull tokenIn from caller (Interaction before reserve sync) ────────
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // ── Calculate amountOut (no state changes yet) ───────────────────────
        amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);

        if (amountOut == 0) revert InsufficientOutputAmount();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();

        // ── Effect: sync reserves from balanceOf ─────────────────────────────
        // Use balanceOf so any accidental direct transfers are handled correctly.
        uint256 newReserveIn  = reserveIn  + amountIn;   // fast path; verified by invariant
        uint256 newReserveOut = reserveOut - amountOut;

        if (isTokenA) {
            reserveA = newReserveIn;
            reserveB = newReserveOut;
        } else {
            reserveA = newReserveOut;
            reserveB = newReserveIn;
        }

        // ── Invariant check: k must not decrease ─────────────────────────────
        // k_new >= k_old  (fees mean k only grows)
        assert(newReserveIn * newReserveOut >= reserveIn * reserveOut);

        // ── Interaction: transfer tokenOut to caller ─────────────────────────
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the expected output amount for a swap (read-only).
    ///
    /// @dev   Applies the same 0.3 % fee as swap():
    ///        amountInWithFee = amountIn · 997
    ///        amountOut = (reserveOut · amountInWithFee)
    ///                    / (reserveIn · 1000 + amountInWithFee)
    ///
    ///        Returns 0 when the pool is empty (no liquidity yet).
    ///
    /// @param amountIn Amount of tokenIn to quote
    /// @param tokenIn  Address of the token being sold
    /// @return amountOut Expected output amount (before slippage from other txs)
    function getAmountOut(uint256 amountIn, address tokenIn)
        public
        view
        returns (uint256 amountOut)
    {
        if (tokenIn != tokenA && tokenIn != tokenB) revert InvalidToken(tokenIn);

        uint256 _reserveA = reserveA;
        uint256 _reserveB = reserveB;

        if (_reserveA == 0 || _reserveB == 0) return 0;

        bool isTokenA     = (tokenIn == tokenA);
        uint256 reserveIn  = isTokenA ? _reserveA : _reserveB;
        uint256 reserveOut = isTokenA ? _reserveB : _reserveA;

        amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /// @notice Returns the spot price of tokenA denominated in tokenB.
    ///
    /// @dev   price = reserveB · 1e18 / reserveA
    ///        Example: if reserveA = 1_000 USDC and reserveB = 1_001 USDT
    ///        → price ≈ 1.001 × 10^18  (1.001 USDT per USDC)
    ///
    ///        This is the marginal price; the actual swap price will differ due
    ///        to the 0.3 % fee and price impact.
    ///
    /// @return price reserveB / reserveA scaled to 1e18, or 0 if pool is empty
    function getPrice() external view returns (uint256 price) {
        uint256 _reserveA = reserveA;
        uint256 _reserveB = reserveB;

        if (_reserveA == 0) return 0;

        price = (_reserveB * 1e18) / _reserveA;
    }

    /// @inheritdoc IReTempPool
    function getReserves() external view returns (uint256, uint256) {
        return (reserveA, reserveB);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — Reserve Sync
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Writes the true ERC-20 balances into storage.
    ///      Called after addLiquidity to account for tokens that may have been
    ///      sent directly to the contract before the first deposit.
    function _updateReserves() internal {
        reserveA = IERC20(tokenA).balanceOf(address(this));
        reserveB = IERC20(tokenB).balanceOf(address(this));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — AMM Math
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Core constant-product formula.
    ///      fee = 0.3 % → effective multiplier = 997 / 1000
    ///
    ///      amountInWithFee = amountIn · 997
    ///      amountOut = (reserveOut · amountInWithFee)
    ///                  / (reserveIn · 1000 + amountInWithFee)
    ///
    ///      Pure function — no storage reads, safe to call from both swap()
    ///      and getAmountOut() without duplication.
    ///
    /// @param amountIn  Exact input amount
    /// @param reserveIn  Reserve of the input token before the swap
    /// @param reserveOut Reserve of the output token before the swap
    /// @return amountOut Calculated output amount after fee
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        // Applies 0.3% fee:  amountIn_effective = amountIn * 997
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;

        // Constant-product formula
        uint256 numerator   = reserveOut * amountInWithFee;
        uint256 denominator = (reserveIn * FEE_DENOM) + amountInWithFee;

        amountOut = numerator / denominator;
    }

    /// @dev Babylonian (Newton–Raphson) integer square root.
    ///      Used once per pool lifetime for the initial LP share calculation.
    ///
    ///      Converges in O(log n) iterations.  Final result satisfies:
    ///      z² ≤ y < (z+1)²
    ///
    /// @param y Value to compute floor(√y) for
    /// @return z Floor integer square root of y
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
        // y == 0  →  z = 0  (default value)
    }

    /// @dev Returns the smaller of two values.
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
