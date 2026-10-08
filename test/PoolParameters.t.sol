// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolParameters} from "../script/PoolParameters.s.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract PoolParametersTest is HookFixture {
    using StateLibrary for IPoolManager;

    PoolParameters internal parameters;

    function setUp() public override {
        super.setUp();
        parameters = new PoolParameters();
    }

    function test_initializesLaunchWithPIXELCurrency0() public {
        _initializeAndCheck(_prepare(true));
    }

    function test_initializesLaunchWithIMDCurrency0() public {
        _initializeAndCheck(_prepare(false));
    }

    function testFuzz_priceRepresentsOpeningMarketCapForEitherOrder(address pixel, address paired) public view {
        vm.assume(pixel != address(0) && paired != address(0) && pixel != paired);
        PoolParameters.Parameters memory params = parameters.run(pixel, paired);
        bool pixelFirst = pixel < paired;
        assertEq(params.currency0, pixelFirst ? pixel : paired);
        assertEq(params.currency1, pixelFirst ? paired : pixel);
        assertTrue(params.currency0 < params.currency1);
        assertEq(params.tickSpacing, 60);
        assertEq(
            params.sqrtPriceX96,
            pixelFirst ? uint160(125270724187523965593206901) : uint160(50108289675009586237282760313921)
        );

        // Independently derive currency1/currency0 from market cap and actual PIXEL supply.
        // Both currencies have 18 decimals, so the decimal factors cancel.
        uint256 supply = token.totalSupply() / 1 ether;
        uint256 priceX192 = pixelFirst ? (uint256(2500) << 192) / supply : (supply << 192) / 2500;
        uint256 floorSqrt = Math.sqrt(priceX192);
        // The requester-supplied PIXEL-first value rounds up by one Q96 unit; preserve it exactly.
        assertEq(uint256(params.sqrtPriceX96), floorSqrt + (pixelFirst ? 1 : 0));
        uint256 encodedPriceX192 = uint256(params.sqrtPriceX96) * params.sqrtPriceX96;
        uint256 errorX192 = encodedPriceX192 > priceX192 ? encodedPriceX192 - priceX192 : priceX192 - encodedPriceX192;
        assertLe(errorX192, 2 * uint256(params.sqrtPriceX96) + 1);
    }

    function test_rejectsMissingOrIdenticalCurrencies() public {
        vm.expectRevert(PoolParameters.InvalidCurrencies.selector);
        parameters.run(address(0), address(imd));
        vm.expectRevert(PoolParameters.InvalidCurrencies.selector);
        parameters.run(address(token), address(0));
        vm.expectRevert(PoolParameters.InvalidCurrencies.selector);
        parameters.run(address(token), address(token));
    }

    function test_parametersDoNotDependOnCaller() public {
        PoolParameters.Parameters memory expected = parameters.run(address(token), address(imd));
        vm.prank(makeAddr("launch operator"));
        PoolParameters.Parameters memory actual = parameters.run(address(token), address(imd));
        assertEq(abi.encode(actual), abi.encode(expected));
    }

    function testFuzz_rejectedPriceRollsBackLockAndAllowsCorrectLaunch(bool pixelFirst) public {
        uint160 price = _prepare(pixelFirst);
        uint160 invalidPrice = TickMath.MIN_SQRT_PRICE - 1;
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, invalidPrice));
        manager.initialize(key, invalidPrice);
        assertFalse(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), bytes32(0));
        assertEq(hook.imdUnit(), 0);
        (uint160 storedPrice,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(storedPrice, 0);
        _initializeAndCheck(price);
    }

    function test_reversedCurrenciesRejectedBeforeHookLocks() public {
        uint160 price = _prepare(true);
        PoolKey memory reversed = key;
        (reversed.currency0, reversed.currency1) = (key.currency1, key.currency0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoolManager.CurrenciesOutOfOrderOrEqual.selector,
                Currency.unwrap(reversed.currency0),
                Currency.unwrap(reversed.currency1)
            )
        );
        manager.initialize(reversed, price);
        assertFalse(hook.initialized());
        _initializeAndCheck(price);
    }

    function _prepare(bool pixelFirst) private returns (uint160 price) {
        // Use deployed local ERC-20s for both orders; no production address is guessed.
        for (uint256 i; (address(token) < address(imd)) != pixelFirst && i < 256; ++i) {
            imd = new MockERC20("Identity test currency", "IMD", 1_000_000_000 ether);
        }
        assertEq(address(token) < address(imd), pixelFirst);
        assertEq(token.decimals(), 18);
        assertEq(imd.decimals(), 18);
        PoolParameters.Parameters memory params = parameters.run(address(token), address(imd));
        key = PoolKey(
            Currency.wrap(params.currency0),
            Currency.wrap(params.currency1),
            12_500,
            params.tickSpacing,
            IHooks(address(hook))
        );
        price = params.sqrtPriceX96;
        assertEq(key.tickSpacing, 60);
    }

    function _initializeAndCheck(uint160 price) private {
        int24 tick = manager.initialize(key, price);
        (uint160 storedPrice, int24 storedTick,, uint24 fee) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(storedPrice, price);
        assertEq(storedTick, tick);
        assertEq(storedTick, TickMath.getTickAtSqrtPrice(price));
        assertEq(fee, 12_500);
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(Currency.unwrap(hook.imdCurrency()), address(imd));
        assertEq(hook.imdIsCurrency0(), address(imd) < address(token));
        assertEq(hook.imdUnit(), 1 ether);
        assertEq(hook.strokes(), 0);
    }
}
