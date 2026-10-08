// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelHook} from "../../src/PixelHook.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev All generated successful actions have sufficient balances and base liquidity.
/// Unexpected reverts therefore fail the invariant campaign instead of silently discarding calls.
contract PixelHookHandler is Test {
    using StateLibrary for IPoolManager;

    struct Balances {
        uint256 actor0;
        uint256 actor1;
        uint256 pool0;
        uint256 pool1;
    }

    IPoolManager public immutable manager;
    PixelHook public immutable hook;
    PoolRouter public immutable router;
    IERC20 public immutable imd;
    IERC20 private immutable _currency0;
    IERC20 private immutable _currency1;
    PoolKey private _key;
    address[3] public actors;

    // The oracle uses a flat array and a moving cursor, independent of the hook's packed-row update.
    bytes private _pixels = new bytes(1024);
    uint256 public successfulSwaps;
    uint256 public cursor;
    uint256 public completedPasses;
    uint256 public extraLiquidity;
    uint256 public liquidityChanges;
    uint256 public refusedSettlements;
    uint256 public refusedCallbacks;

    constructor(
        IPoolManager manager_,
        PixelHook hook_,
        PoolRouter router_,
        PoolKey memory key_,
        IERC20 imd_,
        address[3] memory actors_
    ) {
        manager = manager_;
        hook = hook_;
        router = router_;
        _key = key_;
        imd = imd_;
        _currency0 = IERC20(Currency.unwrap(key_.currency0));
        _currency1 = IERC20(Currency.unwrap(key_.currency1));
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            vm.startPrank(actors_[i]);
            _currency0.approve(address(router_), type(uint256).max);
            _currency1.approve(address(router_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function expectedPixels() external view returns (bytes memory) {
        return _pixels;
    }

    function swap(uint256 actorSeed, uint256 amountSeed, bool buy, bool exactInput) external {
        uint256 amount = _bound(amountSeed, 1, 750 ether);
        _swap(actors[actorSeed % actors.length], buy, exactInput ? -int256(amount) : int256(amount));
    }

    function changeLiquidity(uint256 actorSeed, uint256 amountSeed, bool remove) external {
        address actor = actors[actorSeed % actors.length];
        // The initial position remains available so every later swap has executable liquidity.
        bool removing = remove && extraLiquidity != 0;
        uint256 maximum = removing ? extraLiquidity : 50_000 ether;
        uint256 amount = _bound(amountSeed, 1, maximum);
        Balances memory beforeBalances = _balances(actor);
        vm.prank(actor);
        BalanceDelta delta = router.liquidity(_key, removing ? -int256(amount) : int256(amount));
        if (removing) extraLiquidity -= amount;
        else extraLiquidity += amount;
        ++liquidityChanges;
        _checkSettlement(actor, beforeBalances, delta);
        assertEq(hook.strokes(), successfulSwaps, "liquidity operation painted a dot");
    }

    function failSettlement(uint256 actorSeed, bool buy) external {
        address actor = actors[actorSeed % actors.length];
        IERC20 input = buy ? imd : IERC20(hook.launchToken());
        bytes32 canvasBefore = keccak256(abi.encode(hook.canvas()));
        (uint160 priceBefore,,,) = manager.getSlot0(_key.toId());
        Balances memory beforeBalances = _balances(actor);
        vm.prank(actor);
        input.approve(address(router), 0);
        vm.prank(actor);
        (bool ok, bytes memory reason) =
            address(router).call(abi.encodeCall(PoolRouter.swap, (_key, _params(buy, -10 ether))));
        assertFalse(ok, "unapproved input settled");
        assertEq(bytes4(reason), bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)")));
        vm.prank(actor);
        input.approve(address(router), type(uint256).max);
        ++refusedSettlements;
        assertEq(keccak256(abi.encode(hook.canvas())), canvasBefore, "failed settlement changed canvas");
        assertEq(hook.strokes(), successfulSwaps, "failed settlement retained its stroke");
        (uint160 priceAfter,,,) = manager.getSlot0(_key.toId());
        assertEq(priceAfter, priceBefore, "failed settlement changed pool price");
        _checkSettlement(actor, beforeBalances, toBalanceDelta(0, 0));
    }

    function unauthorizedCallback(uint256 actorSeed, bool initialize, int128 amount0, int128 amount1) external {
        bytes memory data = initialize
            ? abi.encodeCall(PixelHook.beforeInitialize, (address(manager), _key, uint160(1 << 96)))
            : abi.encodeCall(
                PixelHook.afterSwap,
                (address(manager), _key, _params(true, -1), toBalanceDelta(amount0, amount1), bytes(""))
            );
        vm.prank(actors[actorSeed % actors.length]);
        (bool ok, bytes memory reason) = address(hook).call(data);
        assertFalse(ok, "actor drove a manager-only callback");
        assertEq(bytes4(reason), PixelHook.OnlyPoolManager.selector);
        ++refusedCallbacks;
    }

    function _swap(address actor, bool buy, int256 amount) private {
        Balances memory beforeBalances = _balances(actor);
        uint256 imdBefore = imd.balanceOf(actor);
        vm.prank(actor);
        BalanceDelta delta = router.swap(_key, _params(buy, amount));
        _checkSettlement(actor, beforeBalances, delta);

        // The color oracle reads tokens actually spent/received by the actor, not hook state or delta.
        uint256 imdAfter = imd.balanceOf(actor);
        uint256 executed;
        if (buy) {
            assertLe(imdAfter, imdBefore);
            executed = imdBefore - imdAfter;
        } else {
            assertGe(imdAfter, imdBefore);
            executed = imdAfter - imdBefore;
        }
        uint8[4] memory colors = buy ? [uint8(1), 2, 3, 4] : [uint8(5), 6, 7, 8];
        uint256 shade;
        uint256[3] memory thresholds = [uint256(5 ether), 50 ether, 500 ether];
        while (shade < thresholds.length && executed >= thresholds[shade]) ++shade;
        _pixels[cursor] = bytes1(colors[shade]);
        assertEq(hook.pixelAt(cursor), colors[shade], "pixel does not reflect executed IMD");
        ++successfulSwaps;
        ++cursor;
        if (cursor == _pixels.length) {
            cursor = 0;
            ++completedPasses;
        }
    }

    function _params(bool buy, int256 amount) private view returns (SwapParams memory) {
        bool zeroForOne = buy == (address(imd) == Currency.unwrap(_key.currency0));
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _balances(address actor) private view returns (Balances memory) {
        return Balances(
            _currency0.balanceOf(actor),
            _currency1.balanceOf(actor),
            _currency0.balanceOf(address(manager)),
            _currency1.balanceOf(address(manager))
        );
    }

    function _checkSettlement(address actor, Balances memory beforeBalances, BalanceDelta delta) private view {
        Balances memory afterBalances = _balances(actor);
        assertEq(int256(afterBalances.actor0) - int256(beforeBalances.actor0), int256(delta.amount0()));
        assertEq(int256(afterBalances.actor1) - int256(beforeBalances.actor1), int256(delta.amount1()));
        assertEq(afterBalances.actor0 + afterBalances.pool0, beforeBalances.actor0 + beforeBalances.pool0);
        assertEq(afterBalances.actor1 + afterBalances.pool1, beforeBalances.actor1 + beforeBalances.pool1);
    }
}
