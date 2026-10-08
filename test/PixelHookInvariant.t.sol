// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PixelHookHandler} from "./helpers/PixelHookHandler.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Random sequences run against a real v4 manager and settle both currencies on every success.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PixelHookInvariantTest is HookFixture {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    PixelHookHandler private handler;
    PoolRouter private router;
    address[3] private actors;

    function setUp() public override {
        super.setUp();
        _initialize();
        router = new PoolRouter(manager);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        router.liquidity(key, 2_000_000 ether);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("canvas trader ", bytes1(uint8(i)))));
            token.transfer(actors[i], 2_000_000 ether);
            imd.transfer(actors[i], 2_000_000 ether);
        }
        handler = new PixelHookHandler(manager, hook, router, key, IERC20(address(imd)), actors);

        // Start close to a pass boundary using real swaps; random actions exercise byte replacement
        // over old colors, row boundaries, and rollover without requiring thousands of fuzz calls.
        for (uint256 i; i < 1016; ++i) {
            handler.swap(i, 1, i % 2 == 0, true);
        }

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = PixelHookHandler.swap.selector;
        selectors[1] = PixelHookHandler.changeLiquidity.selector;
        selectors[2] = PixelHookHandler.failSettlement.selector;
        selectors[3] = PixelHookHandler.unauthorizedCallback.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_canvasPoolLockAndConservationSurviveRandomSequences() public view {
        assertEq(hook.strokes(), handler.successfulSwaps());
        assertEq(hook.pass(), handler.completedPasses());
        assertEq(hook.strokes(), 1024 * handler.completedPasses() + handler.cursor());
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(Currency.unwrap(hook.imdCurrency()), address(imd));
        assertEq(hook.imdIsCurrency0(), address(imd) == Currency.unwrap(key.currency0));
        assertEq(hook.imdUnit(), 1 ether);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.launchToken(), address(token));
        (,,, uint24 lpFee) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(lpFee, 12_500);

        bytes memory expected = handler.expectedPixels();
        bytes memory encoded = abi.encode(hook.canvas());
        for (uint256 row; row < 32; ++row) {
            for (uint256 column; column < 32; ++column) {
                // ABI words are big-endian; the leftmost canvas dot is the low byte of each word.
                assertEq(encoded[row * 32 + 31 - column], expected[row * 32 + column]);
            }
        }
        _assertConserved(IERC20(address(token)));
        _assertConserved(IERC20(address(imd)));
        assertEq(address(hook).balance, 0);
        assertFalse(IPoolManager(manager).isUnlocked());
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
    }

    function _assertConserved(IERC20 currency) private view {
        Currency trackedCurrency = Currency.wrap(address(currency));
        uint256 total = currency.balanceOf(address(this)) + currency.balanceOf(address(manager));
        for (uint256 i; i < actors.length; ++i) {
            total += currency.balanceOf(actors[i]);
        }
        assertEq(total, currency.totalSupply(), "tokens left the actors and manager");
        assertEq(currency.balanceOf(address(hook)), 0, "hook collected tokens");
        assertEq(currency.balanceOf(address(router)), 0, "router retained settlement tokens");
        assertEq(currency.balanceOf(address(handler)), 0);
        assertEq(manager.balanceOf(address(hook), trackedCurrency.toId()), 0, "hook collected claims");
        assertEq(IPoolManager(manager).currencyDelta(address(hook), trackedCurrency), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(router), trackedCurrency), 0);
    }

    function test_handlerActionsExerciseBothSwapModesAndFailuresAcrossRollover() public {
        for (uint256 i; i < 12; ++i) {
            handler.swap(i, (i + 1) * 60 ether, i % 2 == 0, i % 4 < 2);
        }
        handler.changeLiquidity(0, 1000 ether, false);
        handler.changeLiquidity(1, 1000 ether, true);
        handler.failSettlement(0, true);
        handler.failSettlement(1, false);
        handler.unauthorizedCallback(0, true, type(int128).min, type(int128).max);
        handler.unauthorizedCallback(1, false, type(int128).max, type(int128).min);
        assertEq(handler.successfulSwaps(), 1028);
        assertEq(handler.completedPasses(), 1);
        assertEq(handler.liquidityChanges(), 2);
        assertEq(handler.extraLiquidity(), 0);
        assertEq(handler.refusedSettlements(), 2);
        assertEq(handler.refusedCallbacks(), 2);
        invariant_canvasPoolLockAndConservationSurviveRandomSequences();
    }
}
