// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PixelHook} from "../src/PixelHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {DecimalToken} from "./mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract PixelHookTest is HookFixture {
    event Painted(uint256 indexed stroke, uint256 indexed pixel, uint8 color, address indexed painter);

    function test_initializationRecordsPoolAndIMD() public {
        _initialize();
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(Currency.unwrap(hook.imdCurrency()), address(imd));
        assertEq(hook.imdIsCurrency0(), address(imd) < address(token));
        assertEq(hook.imdUnit(), 1 ether);
        assertEq(hook.strokes(), 0);
        assertEq(hook.pass(), 0);
    }

    function test_exactPermissionsAndMinedAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.afterSwap = true;
        assertEq(abi.encode(p), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0x2040);
        assertLt(address(hook).code.length, 24_576);
    }

    function test_wrongAddressPermissionsRejectDeployment() public {
        vm.expectRevert();
        new PixelHook(manager, address(token));
    }

    function test_constructorRejectsMissingDependencies() public {
        vm.expectRevert(PixelHook.InvalidDependency.selector);
        new PixelHook(IPoolManager(makeAddr("no manager code")), address(token));
        vm.expectRevert(PixelHook.InvalidDependency.selector);
        new PixelHook(manager, makeAddr("no token code"));
    }

    function test_brightnessEveryBoundaryBothDirections() public {
        _initialize();
        uint256[9] memory amounts =
            [uint256(0), 1, 5 ether - 1, 5 ether, 50 ether - 1, 50 ether, 500 ether - 1, 500 ether, 5000 ether];
        uint8[9] memory colors = [uint8(1), 1, 1, 2, 2, 3, 3, 4, 4];
        for (uint256 i; i < amounts.length; ++i) {
            assertEq(_paint(true, amounts[i]), colors[i]);
            assertEq(_paint(false, amounts[i]), colors[i] + 4);
        }
        assertEq(hook.strokes(), 18);
    }

    function test_buysAndSellsWithReversedCurrencyOrder() public {
        _initialize();
        bool oldOrder = hook.imdIsCurrency0();
        assertEq(_paint(true, 50 ether), 3);
        assertEq(_paint(false, 500 ether), 8);
        // Swap the roles of two actual deployed ERC20s to cover the other address order.
        hook = _deploy(address(imd));
        key = _key(address(imd), address(token), hook);
        _initialize();
        assertEq(hook.imdIsCurrency0(), !oldOrder);
        assertEq(Currency.unwrap(hook.imdCurrency()), address(token));
        assertEq(_paint(true, 50 ether), 3);
        assertEq(_paint(false, 500 ether), 8);
    }

    function test_recordsNon18DecimalIMD() public {
        DecimalToken sixDecimals = new DecimalToken(6);
        key = _key(address(token), address(sixDecimals), hook);
        _initialize();
        assertEq(hook.imdUnit(), 1e6);
        assertEq(_paint(true, 5e6 - 1), 1);
        assertEq(_paint(true, 5e6), 2);
        assertEq(_paint(false, 50e6), 7);
        assertEq(_paint(false, 500e6), 8);
    }

    function test_rejectsUnrepresentableDecimalsWithoutLocking() public {
        DecimalToken bad = new DecimalToken(75);
        PoolKey memory badKey = _key(address(token), address(bad), hook);
        vm.expectRevert();
        manager.initialize(badKey, SQRT_PRICE);
        assertFalse(hook.initialized());
        _initialize();
        assertTrue(hook.initialized());
    }

    function test_maximumSupportedDecimalsDoNotOverflow() public {
        DecimalToken high = new DecimalToken(74);
        key = _key(address(token), address(high), hook);
        _initialize();
        assertEq(hook.imdUnit(), 1e74);
        assertEq(_paint(true, uint128(type(int128).max)), 1);
    }

    function test_minInt128DeltaSafe() public {
        _initialize();
        BalanceDelta delta =
            hook.imdIsCurrency0() ? toBalanceDelta(type(int128).min, 1) : toBalanceDelta(1, type(int128).min);
        assertEq(_paintDelta(true, delta), 4);
    }

    function test_rowOrderAndBytePacking() public {
        _initialize();
        uint256[32] memory expected;
        for (uint256 i; i < 65; ++i) {
            uint8 color = _paint(i % 2 == 0, 1 ether);
            expected[i / 32] |= uint256(color) << (8 * (i % 32));
        }
        assertEq(abi.encode(hook.canvas()), abi.encode(expected));
        for (uint256 i; i < 1024; ++i) {
            assertEq(hook.pixelAt(i), i < 65 ? (i % 2 == 0 ? 1 : 5) : 0);
        }
    }

    function test_secondPassOverwritesOnlyNextDotAndPreservesNeighbors() public {
        _initialize();
        for (uint256 i; i < 1023; ++i) {
            _paint(true, 1 ether);
        }
        assertEq(hook.strokes(), 1023);
        assertEq(hook.pass(), 0);
        assertEq(hook.pixelAt(1023), 0);
        _paint(true, 1 ether);
        assertEq(hook.strokes(), 1024);
        assertEq(hook.pass(), 1);
        _paint(false, 500 ether);
        assertEq(hook.pixelAt(0), 8);
        for (uint256 i = 1; i < 1024; ++i) {
            assertEq(hook.pixelAt(i), 1);
        }
        for (uint256 i = 1; i < 1024; ++i) {
            _paint(false, 500 ether);
        }
        assertEq(hook.strokes(), 2048);
        assertEq(hook.pass(), 2);
        _paint(true, 5 ether);
        assertEq(hook.pixelAt(0), 2); // Clears the previous byte rather than OR-ing colors together.
        assertEq(hook.pixelAt(1), 8);
        assertEq(hook.pixelAt(1023), 8);
    }

    function test_emitsStrokePixelPaletteAndOrigin() public {
        _initialize();
        address origin = makeAddr("painter origin");
        address router = makeAddr("router");
        BalanceDelta delta =
            hook.imdIsCurrency0() ? toBalanceDelta(-5 ether, 3 ether) : toBalanceDelta(3 ether, -5 ether);
        SwapParams memory params = SwapParams(hook.imdIsCurrency0(), 3 ether, SQRT_PRICE);
        vm.expectEmit(true, true, true, true, address(hook));
        emit Painted(1, 0, 2, origin);
        vm.prank(address(manager), origin);
        hook.afterSwap(router, key, params, delta, abi.encode(router));
    }

    function test_amountUsesIMDDeltaNotSpecifiedOrTokenAmount() public {
        _initialize();
        BalanceDelta delta =
            hook.imdIsCurrency0() ? toBalanceDelta(-4 ether, 600 ether) : toBalanceDelta(600 ether, -4 ether);
        SwapParams memory params = SwapParams(hook.imdIsCurrency0(), 600 ether, SQRT_PRICE);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, params, delta, "");
        assertEq(hook.pixelAt(0), 1);
    }

    function testFuzz_brightnessAndDirection(bool buy, uint128 rawAmount) public {
        _initialize();
        uint256 amount = bound(rawAmount, 0, uint128(type(int128).max));
        uint8 expected = buy ? 1 : 5;
        if (amount >= 5 ether) ++expected;
        if (amount >= 50 ether) ++expected;
        if (amount >= 500 ether) ++expected;
        assertEq(_paint(buy, amount), expected);
        assertEq(hook.strokes(), 1);
        assertEq(hook.pixelAt(1), 0);
    }

    function testFuzz_sequenceMatchesUnpackedCanvas(uint256 seed) public {
        _initialize();
        uint8[1024] memory expected;
        for (uint256 i; i < 1100; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool buy = seed & 1 == 0;
            uint256 amount = (seed % 1000) * 1 ether;
            uint8 shade = amount < 5 ether ? 0 : amount < 50 ether ? 1 : amount < 500 ether ? 2 : 3;
            expected[i % 1024] = (buy ? 1 : 5) + shade;
            _paint(buy, amount);
        }
        for (uint256 i; i < 1024; ++i) {
            assertEq(hook.pixelAt(i), expected[i]);
        }
        assertEq(hook.strokes(), 1100);
        assertEq(hook.pass(), 1);
    }

    function test_allCallbacksRejectNonManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        SwapParams memory swap = SwapParams(true, -1, SQRT_PRICE);
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes[10] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), key, SQRT_PRICE)),
            abi.encodeCall(IHooks.afterInitialize, (address(this), key, SQRT_PRICE, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, lp, "")),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, lp, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeSwap, (address(this), key, swap, "")),
            abi.encodeCall(IHooks.afterSwap, (address(this), key, swap, zero, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(PixelHook.OnlyPoolManager.selector));
            if (i != 0 && i != 7) {
                vm.prank(address(manager));
                (ok, reason) = address(hook).call(calls[i]);
                assertFalse(ok);
                assertEq(reason, abi.encodeWithSelector(PixelHook.CallbackNotEnabled.selector));
            }
        }
        assertEq(hook.strokes(), 0);
        assertFalse(hook.initialized());
    }

    function test_swapBeforeInitializationRejected() public {
        vm.expectRevert(PixelHook.NotInitialized.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, SwapParams(true, -1, SQRT_PRICE), BalanceDelta.wrap(0), "");
    }

    function test_duplicateInitializationAndSecondPoolRejected() public {
        _initialize();
        vm.expectRevert(PixelHook.AlreadyInitialized.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), key, SQRT_PRICE);
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
    }

    function test_otherPoolCannotPaint() public {
        _initialize();
        PoolKey memory other = key;
        other.tickSpacing = 120;
        vm.expectRevert(PixelHook.WrongPool.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(this), other, SwapParams(true, -1, SQRT_PRICE), BalanceDelta.wrap(0), "");
        assertEq(hook.strokes(), 0);
    }

    function test_invalidPoolAndFailedInitializationDoNotLock() public {
        PoolKey memory other = key;
        other.hooks = IHooks(address(this));
        vm.expectRevert(PixelHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), other, SQRT_PRICE);
        other = _key(address(imd), address(new DecimalToken(18)), hook);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE);
        assertFalse(hook.initialized());
        vm.expectRevert();
        manager.initialize(key, 0); // Hook executes, then manager rejects the price: all hook state rolls back.
        assertFalse(hook.initialized());
        _initialize();
    }

    function test_nativePairRejected() public {
        PoolKey memory nativeKey = _key(address(token), address(0), hook);
        vm.expectRevert();
        manager.initialize(nativeKey, SQRT_PRICE);
        assertFalse(hook.initialized());
    }

    function test_outOfRangePixelRejected() public {
        vm.expectRevert(PixelHook.PixelOutOfBounds.selector);
        hook.pixelAt(1024);
        vm.expectRevert(PixelHook.PixelOutOfBounds.selector);
        hook.pixelAt(type(uint256).max);
    }

    function test_svgBlankAndPaintedDotsInRowOrder() public {
        string memory blank = hook.render();
        assertEq(_count(bytes(blank), bytes("<circle ")), 1024);
        assertEq(_count(bytes(blank), bytes("#111111")), 1024);
        _initialize();
        for (uint256 i; i < 8; ++i) {
            _paint(i < 4, i % 4 == 0 ? 1 ether : i % 4 == 1 ? 5 ether : i % 4 == 2 ? 50 ether : 500 ether);
        }
        bytes memory svg = bytes(hook.render());
        assertEq(_count(svg, bytes("<circle ")), 1024);
        assertEq(_count(svg, bytes("#111111")), 1016);
        assertEq(_count(svg, bytes('<circle cx="5" cy="5" r="4" fill="#005500"/>')), 1);
        assertEq(_count(svg, bytes('<circle cx="75" cy="5" r="4" fill="#ff0000"/>')), 1);
        assertEq(_count(svg, bytes('<circle cx="5" cy="15" r="4" fill="#111111"/>')), 1);
        assertEq(_count(svg, bytes('<circle cx="315" cy="315" r="4" fill="#111111"/>')), 1);
        assertEq(_count(svg, bytes("</svg>")), 1);
        assertEq(hook.strokes(), 8);
    }

    function test_noAdminOrFundMovementEntrypoints() public {
        bytes[6] memory calls = [
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("withdraw()"),
            abi.encodeWithSignature("setFee(uint256)", 1),
            abi.encodeWithSignature("rescue(address,address,uint256)", address(token), address(this), 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok);
        }
    }

    function test_runtimesHaveNoEscapeHatchOpcodes() public view {
        _checkCode(address(hook).code);
        _checkCode(address(token).code);
    }

    function _checkCode(bytes memory code) private pure {
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            require(op != 0xff && op != 0xf4 && op != 0xf2, "forbidden opcode");
        }
    }

    function _count(bytes memory haystack, bytes memory needle) private pure returns (uint256 count) {
        for (uint256 i; i + needle.length <= haystack.length; ++i) {
            if (haystack[i] != needle[0]) continue;
            bool matches = true;
            for (uint256 j = 1; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) ++count;
        }
    }
}
