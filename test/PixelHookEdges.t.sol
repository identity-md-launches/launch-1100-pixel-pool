// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {DecimalToken} from "./mocks/MockERC20.sol";
import {PixelHook} from "src/PixelHook.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Complements the existing examples with metadata failures, pool identity mutations,
/// decimal boundaries, and complete SVG/canvas agreement after a partial second pass.
contract PixelHookEdgesTest is HookFixture {
    event Painted(uint256 indexed stroke, uint256 indexed pixel, uint8 color, address indexed painter);
    event PoolLocked(PoolId indexed poolId, address indexed imd, bool imdIsCurrency0, uint8 decimals);

    function test_constructorRejectsZeroAndIdenticalDependencies() public {
        vm.expectRevert(PixelHook.InvalidDependency.selector);
        new PixelHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(PixelHook.InvalidDependency.selector);
        new PixelHook(manager, address(0));
        vm.expectRevert(PixelHook.InvalidDependency.selector);
        new PixelHook(manager, address(manager));
    }

    function test_invalidCurrencyOrderingCannotPartiallyLockHook() public {
        bytes32 initialState = _state();
        PoolKey memory invalid = key;
        invalid.currency0 = key.currency1;
        invalid.currency1 = key.currency0;
        _rejectInitialization(invalid, PixelHook.InvalidPool.selector);
        assertEq(_state(), initialState);

        invalid = key;
        invalid.currency0 = Currency.wrap(address(token));
        invalid.currency1 = Currency.wrap(address(token));
        _rejectInitialization(invalid, PixelHook.InvalidPool.selector);
        assertEq(_state(), initialState);

        invalid = _key(address(token), makeAddr("pair without code"), hook);
        _rejectInitialization(invalid, PixelHook.InvalidPool.selector);
        assertEq(_state(), initialState);
        _initialize();
        assertTrue(hook.initialized());
    }

    function test_revertingAndMalformedMetadataLeaveHookAvailable() public {
        bytes memory selector = abi.encodeCall(IERC20Metadata.decimals, ());
        bytes32 initialState = _state();
        vm.mockCallRevert(address(imd), selector, abi.encodeWithSignature("MetadataUnavailable()"));
        vm.expectRevert(abi.encodeWithSignature("MetadataUnavailable()"));
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), key, SQRT_PRICE);
        assertEq(_state(), initialState);

        // Empty, truncated and non-canonical uint8 responses must fail ABI decoding.
        bytes[3] memory malformed = [bytes(""), new bytes(31), abi.encode(uint256(256))];
        for (uint256 i; i < malformed.length; ++i) {
            vm.clearMockedCalls();
            vm.mockCall(address(imd), selector, malformed[i]);
            vm.expectRevert();
            vm.prank(address(manager));
            hook.beforeInitialize(address(this), key, SQRT_PRICE);
            assertEq(_state(), initialState);
        }
        vm.clearMockedCalls();
        _initialize();
        assertEq(hook.imdUnit(), 1 ether);
        assertEq(Currency.unwrap(hook.imdCurrency()), address(imd));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_unsupportedDecimalMetadataNeverLocks(uint8 rawDecimals) public {
        uint8 decimals = uint8(bound(rawDecimals, 75, 255));
        DecimalToken paired = new DecimalToken(decimals);
        PoolKey memory invalid = _key(address(token), address(paired), hook);
        bytes32 initialState = _state();
        _rejectInitialization(invalid, PixelHook.UnsupportedDecimals.selector);
        assertEq(_state(), initialState);
        _initialize();
        assertTrue(hook.initialized());
    }

    function test_initializationEmitsPoolIdentityAndCachesMetadata() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit PoolLocked(key.toId(), address(imd), address(imd) < address(token), 18);
        _initialize();

        // A swap must rely on initialization's recorded scale even if subsequent metadata reads fail.
        vm.mockCallRevert(
            address(imd), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encodeWithSignature("MetadataUnavailable()")
        );
        assertEq(_paint(true, 5 ether - 1), 1);
        assertEq(_paint(false, 5 ether), 6);
        assertEq(hook.imdUnit(), 1 ether);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
    }

    /// @dev 35 decimals is the highest scale at which all three boundaries fit in int128.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_thresholdNeighborsAcrossDecimalScales(uint8 rawDecimals) public {
        uint8 decimals = uint8(bound(rawDecimals, 0, 35));
        DecimalToken paired = new DecimalToken(decimals);
        key = _key(address(token), address(paired), hook);
        _initialize();
        uint256 unit = 10 ** uint256(decimals);
        assertEq(hook.imdUnit(), unit);
        uint256[3] memory thresholds = [5 * unit, 50 * unit, 500 * unit];
        for (uint256 i; i < thresholds.length; ++i) {
            assertEq(_paint(true, thresholds[i] - 1), i + 1);
            assertEq(_paint(true, thresholds[i]), i + 2);
            assertEq(_paint(true, thresholds[i] + 1), i + 2);
            assertEq(_paint(false, thresholds[i] - 1), i + 5);
            assertEq(_paint(false, thresholds[i]), i + 6);
            assertEq(_paint(false, thresholds[i] + 1), i + 6);
        }
        assertEq(hook.strokes(), 18);
    }

    function test_everyPoolIdentityFieldIsBoundAfterPainting() public {
        _initialize();
        _paint(true, 50 ether);
        _paint(false, 500 ether);
        bytes32 lockedState = _state();
        for (uint256 field; field < 5; ++field) {
            // Construct a fresh copy: Solidity memory assignment alone would alias the original.
            PoolKey memory other = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
            if (field == 0) other.currency0 = Currency.wrap(makeAddr("different currency0"));
            if (field == 1) other.currency1 = Currency.wrap(makeAddr("different currency1"));
            if (field == 2) other.fee = key.fee + 1;
            if (field == 3) other.tickSpacing = key.tickSpacing + 1;
            if (field == 4) other.hooks = IHooks(makeAddr("different hook"));

            _rejectInitialization(other, PixelHook.AlreadyInitialized.selector);
            vm.expectRevert(PixelHook.WrongPool.selector);
            vm.prank(address(manager));
            hook.afterSwap(address(this), other, SwapParams(true, -1, SQRT_PRICE), BalanceDelta.wrap(0), "");
            assertEq(_state(), lockedState, "a rejected pool changed the locked canvas");
        }
        assertEq(_paint(true, 5 ether), 2);
        assertEq(hook.strokes(), 3);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_managerOriginDoesNotAuthorizeCallback(address rawCaller, bytes memory hookData) public {
        _initialize();
        _paint(true, 1 ether);
        address caller = rawCaller == address(manager) ? address(this) : rawCaller;
        bytes32 lockedState = _state();
        SwapParams memory params = SwapParams(hook.imdIsCurrency0(), -5 ether, SQRT_PRICE);
        // Supplying the manager as sender and tx.origin must not substitute for msg.sender.
        vm.expectRevert(PixelHook.OnlyPoolManager.selector);
        vm.prank(caller, address(manager));
        hook.afterSwap(address(manager), key, params, toBalanceDelta(-5 ether, 5 ether), hookData);
        vm.expectRevert(PixelHook.OnlyPoolManager.selector);
        vm.prank(caller, address(manager));
        hook.beforeInitialize(address(manager), key, SQRT_PRICE);
        assertEq(_state(), lockedState);
    }

    function test_completeSVGAndPackedCanvasAfterSecondPassRowBoundary() public {
        _initialize();
        uint8[1024] memory expected;
        uint256[4] memory amounts = [uint256(1 ether), 5 ether, 50 ether, 500 ether];
        // All palette entries appear. Repainting spans one whole row and three dots of the next.
        for (uint256 stroke; stroke < 1059; ++stroke) {
            uint8 color = uint8(1 + (stroke < 1024 ? stroke % 8 : 7 - stroke % 8));
            if (stroke == 31 || stroke == 32 || stroke == 1023 || stroke == 1024 || stroke == 1056) {
                vm.expectEmit(true, true, true, true, address(hook));
                emit Painted(stroke + 1, stroke % 1024, color, tx.origin);
            }
            assertEq(_paint(color <= 4, amounts[(color - 1) % 4]), color);
            expected[stroke % 1024] = color;
        }
        uint256[32] memory packed = hook.canvas();
        bytes memory svg = bytes(hook.render());
        uint256 offset = _consume(svg, 0, bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320">'));
        string[9] memory palette =
            [string("#111111"), "#005500", "#008800", "#00bb00", "#00ff00", "#550000", "#880000", "#bb0000", "#ff0000"];
        for (uint256 pixel; pixel < 1024; ++pixel) {
            assertEq(hook.pixelAt(pixel), expected[pixel]);
            // Consume a row byte at a time, independently of the hook's masked update operation.
            assertEq(packed[pixel / 32] % 256, expected[pixel]);
            packed[pixel / 32] /= 256;
            offset = _consume(
                svg,
                offset,
                abi.encodePacked(
                    '<circle cx="',
                    Strings.toString(5 + 10 * (pixel % 32)),
                    '" cy="',
                    Strings.toString(5 + 10 * (pixel / 32)),
                    '" r="4" fill="',
                    palette[expected[pixel]],
                    '"/>'
                )
            );
        }
        offset = _consume(svg, offset, bytes("</svg>"));
        assertEq(offset, svg.length, "SVG has trailing data or duplicate dots");
        assertEq(hook.strokes(), 1059);
        assertEq(hook.pass(), 1);
    }

    function _rejectInitialization(PoolKey memory invalid, bytes4 reason) private {
        vm.expectRevert(reason);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), invalid, SQRT_PRICE);
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                hook.initialized(),
                hook.poolId(),
                hook.imdCurrency(),
                hook.imdIsCurrency0(),
                hook.imdUnit(),
                hook.strokes(),
                hook.pass(),
                hook.canvas()
            )
        );
    }

    function _consume(bytes memory svg, uint256 offset, bytes memory expected) private pure returns (uint256) {
        assertLe(offset + expected.length, svg.length, "truncated SVG");
        bytes32 actualHash;
        assembly ("memory-safe") {
            actualHash := keccak256(add(add(svg, 32), offset), mload(expected))
        }
        assertEq(actualHash, keccak256(expected), "SVG dot/coordinate/color mismatch");
        return offset + expected.length;
    }
}
