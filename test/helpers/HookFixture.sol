// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelToken} from "../../src/PixelToken.sol";
import {PixelHook} from "../../src/PixelHook.sol";
import {MineHook} from "../../script/MineHook.s.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

abstract contract HookFixture is Test {
    uint160 internal constant SQRT_PRICE = 1 << 96;
    PoolManager internal manager;
    PixelToken internal token;
    MockERC20 internal imd;
    PixelHook internal hook;
    PoolKey internal key;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        token = new PixelToken();
        imd = new MockERC20("Identity test currency", "IMD", 1_000_000_000 ether);
        hook = _deploy(address(token));
        key = _key(address(token), address(imd), hook);
    }

    function _deploy(address launchToken) internal returns (PixelHook deployed) {
        MineHook miner = new MineHook();
        (bytes32 salt, address predicted) = miner.run(address(this), manager, launchToken, 0, 200_000);
        deployed = new PixelHook{salt: salt}(manager, launchToken);
        assertEq(address(deployed), predicted);
    }

    function _key(address launchToken, address paired, PixelHook observer) internal pure returns (PoolKey memory) {
        (address c0, address c1) = launchToken < paired ? (launchToken, paired) : (paired, launchToken);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(address(observer)));
    }

    function _initialize() internal {
        manager.initialize(key, SQRT_PRICE);
    }

    function _paint(bool buy, uint256 amount) internal returns (uint8) {
        int128 d = buy ? -int128(int256(amount)) : int128(int256(amount));
        BalanceDelta delta = hook.imdIsCurrency0() ? toBalanceDelta(d, -d) : toBalanceDelta(-d, d);
        return _paintDelta(buy, delta);
    }

    function _paintDelta(bool buy, BalanceDelta delta) internal returns (uint8) {
        SwapParams memory params = SwapParams(buy == hook.imdIsCurrency0(), -1, SQRT_PRICE);
        vm.prank(address(manager));
        (bytes4 selector, int128 fee) = hook.afterSwap(address(this), key, params, delta, "untrusted ignored data");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(fee, 0);
        return hook.pixelAt((hook.strokes() - 1) % 1024);
    }
}
