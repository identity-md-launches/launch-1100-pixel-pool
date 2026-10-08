// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PixelHook} from "../src/PixelHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline CREATE2 salt search. No environment reads, broadcasting, or filesystem access.
contract MineHook {
    error SaltNotFound();

    function run(address deployer, IPoolManager manager, address token, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 initHash = keccak256(abi.encodePacked(type(PixelHook).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (HookFlags.matches(predicted, HookFlags.PIXEL)) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
