// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Offline launch inputs for PIXEL/IMD, assuming both currencies have 18 decimals.
/// @dev Use authoritative factory values instead if the launch factory sets these inputs itself.
///      This helper neither deploys nor initializes anything and does not authenticate token addresses.
contract PoolParameters {
    error InvalidCurrencies();

    int24 public constant TICK_SPACING = 60;
    uint160 public constant PIXEL_CURRENCY0_SQRT_PRICE_X96 = 125270724187523965593206901;
    uint160 public constant IMD_CURRENCY0_SQRT_PRICE_X96 = 50108289675009586237282760313921;

    struct Parameters {
        address currency0;
        address currency1;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
    }

    /// @param pixel The actual launch PIXEL address, regardless of address order.
    /// @param imd The verified IMD address on the launch chain.
    function run(address pixel, address imd) external pure returns (Parameters memory params) {
        if (pixel == address(0) || imd == address(0) || pixel == imd) revert InvalidCurrencies();
        bool pixelFirst = pixel < imd;
        params = Parameters({
            currency0: pixelFirst ? pixel : imd,
            currency1: pixelFirst ? imd : pixel,
            tickSpacing: TICK_SPACING,
            sqrtPriceX96: pixelFirst ? PIXEL_CURRENCY0_SQRT_PRICE_X96 : IMD_CURRENCY0_SQRT_PRICE_X96
        });
    }
}
