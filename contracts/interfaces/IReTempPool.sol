// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IReTempPool
/// @notice Interface for the ReTempPool AMM liquidity pool contract
interface IReTempPool {
    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when liquidity is added to the pool
    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);

    /// @notice Emitted when liquidity is removed from the pool
    event LiquidityRemoved(address indexed provider, uint256 shares, uint256 amountA, uint256 amountB);

    /// @notice Emitted on a successful token swap
    event Swap(address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    // ─────────────────────────────────────────────────────────────────────────
    // Core Functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Executes a token swap
    /// @param tokenIn  Address of the input token (must be tokenA or tokenB)
    /// @param amountIn Amount of tokenIn to swap
    /// @return amountOut Amount of output token received
    function swap(address tokenIn, uint256 amountIn) external returns (uint256 amountOut);

    /// @notice Returns the expected output for a given input (read-only)
    /// @param amountIn  Amount of tokenIn
    /// @param tokenIn   Address of the input token
    /// @return amountOut Expected output amount before fees
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut);

    // ─────────────────────────────────────────────────────────────────────────
    // View Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the address of the first pool token
    function tokenA() external view returns (address);

    /// @notice Returns the address of the second pool token
    function tokenB() external view returns (address);

    /// @notice Returns the spot price of tokenA in terms of tokenB (1e18 precision)
    function getPrice() external view returns (uint256 price);

    /// @notice Returns current reserves for both tokens
    function getReserves() external view returns (uint256 reserveA, uint256 reserveB);
}
