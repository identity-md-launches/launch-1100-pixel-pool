// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Test-only router for exercising actual v4 settlement, including revert rollback.
contract PoolRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    struct Action {
        PoolKey key;
        address payer;
        bool isSwap;
        SwapParams params;
        int256 liquidityDelta;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function liquidity(PoolKey memory key, int256 amount) external returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(abi.encode(Action(key, msg.sender, false, SwapParams(false, 0, 0), amount))), (BalanceDelta)
        );
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(Action(key, msg.sender, true, params, 0))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        Action memory action = abi.decode(data, (Action));
        BalanceDelta delta;
        if (action.isSwap) {
            delta = manager.swap(action.key, action.params, "");
        } else {
            (delta,) = manager.modifyLiquidity(
                action.key, ModifyLiquidityParams(-600, 600, action.liquidityDelta, bytes32(0)), ""
            );
        }
        _settle(action.key.currency0, delta.amount0(), action.payer);
        _settle(action.key.currency1, delta.amount1(), action.payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount, address payer) private {
        if (amount < 0) {
            manager.sync(currency);
            require(
                IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-int256(amount))),
                "transfer failed"
            );
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint128(amount));
        }
    }
}
