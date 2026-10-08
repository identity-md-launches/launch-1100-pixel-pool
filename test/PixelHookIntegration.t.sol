// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract PixelHookIntegrationTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    PoolRouter internal router;

    function setUp() public override {
        super.setUp();
        router = new PoolRouter(manager);
        token.approve(address(router), 100_000_000 ether);
        imd.approve(address(router), 100_000_000 ether);
    }

    function _seed() private {
        _initialize();
        router.liquidity(key, 1_000_000 ether);
        assertEq(hook.strokes(), 0);
    }

    function _params(bool buy, int256 amount) private view returns (SwapParams memory) {
        bool zeroForOne = buy == hook.imdIsCurrency0();
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _swapAndCheck(bool buy, int256 amount) private returns (BalanceDelta delta) {
        IERC20 c0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 c1 = IERC20(Currency.unwrap(key.currency1));
        uint256 user0 = c0.balanceOf(address(this));
        uint256 user1 = c1.balanceOf(address(this));
        uint256 pool0 = c0.balanceOf(address(manager));
        uint256 pool1 = c1.balanceOf(address(manager));
        uint256 priorStrokes = hook.strokes();
        delta = router.swap(key, _params(buy, amount));
        assertEq(int256(c0.balanceOf(address(this))) - int256(user0), int256(delta.amount0()));
        assertEq(int256(c1.balanceOf(address(this))) - int256(user1), int256(delta.amount1()));
        assertEq(c0.balanceOf(address(manager)) + c0.balanceOf(address(this)), pool0 + user0);
        assertEq(c1.balanceOf(address(manager)) + c1.balanceOf(address(this)), pool1 + user1);
        assertEq(c0.balanceOf(address(hook)), 0);
        assertEq(c1.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency1), 0);
        assertEq(hook.strokes(), priorStrokes + 1);
        int256 imdDelta = hook.imdIsCurrency0() ? int256(delta.amount0()) : int256(delta.amount1());
        assertEq(imdDelta < 0, buy);
        uint256 executed = uint256(imdDelta < 0 ? -imdDelta : imdDelta);
        uint8 expected = buy ? 1 : 5;
        if (executed >= 5 ether) ++expected;
        if (executed >= 50 ether) ++expected;
        if (executed >= 500 ether) ++expected;
        assertEq(hook.pixelAt(priorStrokes % 1024), expected);
    }

    function test_realBuySellExactInputAndExactOutput() public {
        _seed();
        _swapAndCheck(true, -1 ether);
        _swapAndCheck(false, -10 ether);
        _swapAndCheck(true, 100 ether);
        _swapAndCheck(false, 600 ether);
        assertEq(hook.strokes(), 4);
        assertEq(address(manager).balance, 0); // Pool seeded with tokens only.
        assertEq(address(hook).balance, 0);
        (,,, uint24 fee) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(fee, 12_500);
        router.liquidity(key, -1_000_000 ether);
        assertEq(hook.strokes(), 4); // Liquidity operations never paint or get blocked by the hook.
    }

    function test_realSwapsWithIMDAsCurrency0() public {
        _realOrder(true);
    }

    function test_realSwapsWithIMDAsCurrency1() public {
        _realOrder(false);
    }

    function _realOrder(bool first) private {
        for (uint256 i; (address(imd) < address(token)) != first && i < 256; ++i) {
            imd = new MockERC20("IMD test currency", "IMD", 1_000_000_000 ether);
        }
        assertEq(address(imd) < address(token), first);
        imd.approve(address(router), 100_000_000 ether);
        key = _key(address(token), address(imd), hook);
        _seed();
        assertEq(hook.imdIsCurrency0(), first);
        _swapAndCheck(true, -10 ether);
        _swapAndCheck(false, -10 ether);
        _swapAndCheck(true, 100 ether);
        _swapAndCheck(false, 100 ether);
    }

    function testFuzz_realSwaps(bool buy, bool exactInput, uint96 rawAmount) public {
        _seed();
        int256 amount = int256(bound(rawAmount, 1 ether, 1000 ether));
        _swapAndCheck(buy, exactInput ? -amount : amount);
    }

    function test_partialFillBrightnessUsesExecutedIMD() public {
        _seed();
        bool zeroForOne = hook.imdIsCurrency0();
        // A tiny price move fills less than 5 IMD out of a requested 1000 IMD.
        uint160 limit = zeroForOne ? SQRT_PRICE - SQRT_PRICE / 1_000_000 : SQRT_PRICE + SQRT_PRICE / 1_000_000;
        BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, -1000 ether, limit));
        int256 d = hook.imdIsCurrency0() ? int256(delta.amount0()) : int256(delta.amount1());
        assertGt(-d, 0);
        assertLt(-d, 5 ether);
        assertEq(hook.pixelAt(0), 1);
        assertEq(hook.strokes(), 1);
    }

    function test_settlementFailureRollsBackStrokeAndPool() public {
        _seed();
        (uint160 priceBefore,,,) = IPoolManager(manager).getSlot0(key.toId());
        imd.approve(address(router), 0);
        SwapParams memory params = _params(true, -10 ether);
        vm.expectRevert();
        router.swap(key, params);
        assertEq(hook.strokes(), 0);
        assertEq(hook.pixelAt(0), 0);
        (uint160 priceAfter,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
    }

    function test_zeroRequestedSwapRevertsWithoutPainting() public {
        _seed();
        SwapParams memory params = _params(true, 0);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(key, params);
        assertEq(hook.strokes(), 0);
    }

    function test_successfulZeroFillStillPaintsOneDimDot() public {
        _initialize(); // No liquidity, so the swap moves price but trades no tokens.
        BalanceDelta delta = router.swap(key, _params(true, -1 ether));
        assertEq(BalanceDelta.unwrap(delta), 0);
        assertEq(hook.strokes(), 1);
        assertEq(hook.pixelAt(0), 1);
    }

    function test_uninitializedPredictedHookCannotOpenPool() public {
        vm.etch(address(hook), "");
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE);
    }
}
