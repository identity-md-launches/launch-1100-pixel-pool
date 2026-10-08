// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice An immutable, fee-free observer that paints one pixel per successful swap.
/// @dev The launch factory must deploy and initialize atomically with PIXEL paired with real IMD.
contract PixelHook is IHooks {
    error OnlyPoolManager();
    error InvalidDependency();
    error AlreadyInitialized();
    error InvalidPool();
    error WrongPool();
    error NotInitialized();
    error UnsupportedDecimals();
    error PixelOutOfBounds();
    error CallbackNotEnabled();

    event PoolLocked(PoolId indexed poolId, address indexed imd, bool imdIsCurrency0, uint8 decimals);
    event Painted(uint256 indexed stroke, uint256 indexed pixel, uint8 color, address indexed painter);

    IPoolManager public immutable poolManager;
    address public immutable launchToken;
    bool public initialized;
    bool public imdIsCurrency0;
    Currency public imdCurrency;
    PoolId public poolId;
    uint256 public imdUnit;
    uint256 public strokes;

    // One row per word, 32 palette bytes per row, leftmost pixel in the least significant byte.
    uint256[32] private _canvas;

    constructor(IPoolManager manager, address token) {
        if (
            address(manager) == address(0) || token == address(0) || address(manager).code.length == 0
                || token.code.length == 0 || token == address(manager)
        ) {
            revert InvalidDependency();
        }
        poolManager = manager;
        launchToken = token;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterSwap = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (initialized) revert AlreadyInitialized();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (address(key.hooks) != address(this) || c0 >= c1 || (c0 != launchToken && c1 != launchToken)) {
            revert InvalidPool();
        }
        address imd = c0 == launchToken ? c1 : c0;
        if (imd.code.length == 0) revert InvalidPool();

        // A metadata read is a STATICCALL. The manager remains the sole authority for callbacks.
        uint8 decimals = IERC20Metadata(imd).decimals();
        // 500 * 10**74 fits uint256. Larger metadata values cannot represent these thresholds.
        if (decimals > 74) revert UnsupportedDecimals();
        imdUnit = 10 ** uint256(decimals);
        imdCurrency = Currency.wrap(imd);
        imdIsCurrency0 = imd == c0;
        poolId = key.toId();
        initialized = true;
        emit PoolLocked(poolId, imd, imdIsCurrency0, decimals);
        return IHooks.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!initialized) revert NotInitialized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();

        // Widen before negation: even int128.min is safe. Use executed amounts, including partial fills.
        int256 imdDelta = imdIsCurrency0 ? int256(delta.amount0()) : int256(delta.amount1());
        // The absolute value of an int128 widened to int256 is nonnegative and fits uint256.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(imdDelta < 0 ? -imdDelta : imdDelta);
        uint256 unit = imdUnit;
        uint8 shade = amount < 5 * unit ? 0 : amount < 50 * unit ? 1 : amount < 500 * unit ? 2 : 3;
        bool buy = params.zeroForOne == imdIsCurrency0;
        uint8 color = (buy ? 1 : 5) + shade;

        uint256 stroke = strokes;
        uint256 pixel = stroke % 1024;
        uint256 row = pixel / 32;
        uint256 shift = (pixel % 32) * 8;
        _canvas[row] = (_canvas[row] & ~(uint256(255) << shift)) | (uint256(color) << shift);
        strokes = stroke + 1;
        // Attribution only. tx.origin never authorizes an operation or receives value.
        emit Painted(stroke + 1, pixel, color, tx.origin);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice Zero-based pass of the next stroke; also the count of fully completed passes.
    function pass() external view returns (uint256) {
        return strokes / 1024;
    }

    /// @notice Palette code: 0 blank, 1..4 increasingly bright green, 5..8 increasingly bright red.
    function pixelAt(uint256 i) public view returns (uint8) {
        if (i >= 1024) revert PixelOutOfBounds();
        // Intentionally extract only the selected packed byte.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(_canvas[i / 32] >> ((i % 32) * 8));
    }

    function canvas() external view returns (uint256[32] memory) {
        return _canvas;
    }

    /// @notice Raw standalone SVG with 1024 circles, including unpainted dots.
    function render() external view returns (string memory) {
        bytes memory svg = new bytes(128 + 56 * 1024);
        uint256 length = _append(svg, 0, bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320">'));
        string[9] memory palette =
            [string("#111111"), "#005500", "#008800", "#00bb00", "#00ff00", "#550000", "#880000", "#bb0000", "#ff0000"];
        for (uint256 row; row < 32; ++row) {
            uint256 colors = _canvas[row];
            string memory y = Strings.toString(row * 10 + 5);
            for (uint256 col; col < 32; ++col) {
                // Intentionally extract the next palette byte from the row.
                // forge-lint: disable-next-line(unsafe-typecast)
                uint8 color = uint8(colors);
                length = _append(
                    svg,
                    length,
                    // Text concatenation, not a hash or an authorization encoding.
                    // forge-lint: disable-next-line(encode-packed-collision)
                    abi.encodePacked(
                        '<circle cx="',
                        Strings.toString(col * 10 + 5),
                        '" cy="',
                        y,
                        '" r="4" fill="',
                        palette[color],
                        '"/>'
                    )
                );
                colors >>= 8;
            }
        }
        length = _append(svg, length, bytes("</svg>"));
        assembly ("memory-safe") {
            mstore(svg, length)
        }
        return string(svg);
    }

    function _append(bytes memory target, uint256 offset, bytes memory part) private pure returns (uint256 end) {
        end = offset + part.length;
        assert(end <= target.length);
        assembly ("memory-safe") {
            mcopy(add(add(target, 32), offset), add(part, 32), mload(part))
        }
    }

    // All disabled callbacks explicitly fail, including when invoked by the manager.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert CallbackNotEnabled();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert CallbackNotEnabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert CallbackNotEnabled();
    }
}
