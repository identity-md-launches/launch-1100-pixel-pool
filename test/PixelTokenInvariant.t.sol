// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PixelToken} from "src/PixelToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Only these four actors receive tokens. The ledger is updated from successful
/// requested transfers, never copied back from the token's balance/allowance getters.
contract PixelTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    PixelToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor() {
        actors[0] = address(this); // The actual token deployer is part of the actor set.
        actors[1] = makeAddr("pixel-holder-one");
        actors[2] = makeAddr("pixel-holder-two");
        actors[3] = makeAddr("pixel-holder-three");
        token = new PixelToken();
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = SUPPLY / actors.length;
            if (i != 0) assertTrue(token.transfer(actors[i], SUPPLY / actors.length));
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, uint8 edge) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[from], edge);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer failed");
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint8 edge) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = edge % 3 == 0 ? 0 : edge % 3 == 1 ? type(uint256).max : amountSeed;
        _approve(owner, spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed, uint8 edge)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner] < allowance ? expectedBalance[owner] : allowance;
        uint256 amount = _amount(amountSeed, limit, edge);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "approved transfer failed");
        _move(owner, to, amount);
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function rejectOverspend(uint256 ownerSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        uint256 balance = expectedBalance[owner];
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1)
        );
        vm.prank(owner);
        token.transfer(_actor(toSeed), balance + 1);
    }

    function rejectUnapprovedSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 allowanceSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowance = bound(allowanceSeed, 0, SUPPLY);
        _approve(owner, spender, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, allowance + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, _actor(ownerSeed % 4 + 1), allowance + 1);
    }

    /// @dev An allowance deduction must roll back if the later balance check fails.
    function rejectApprovedOverspend(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 balance = expectedBalance[owner];
        _approve(owner, spender, SUPPLY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, _actor(ownerSeed % 4 + 1), balance + 1);
    }

    function rejectZeroReceiver(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[owner]);
        if (delegated) _approve(owner, spender, amount);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(delegated ? spender : owner);
        if (delegated) token.transferFrom(owner, address(0), amount);
        else token.transfer(address(0), amount);
    }

    function rejectZeroSpender(uint256 ownerSeed, uint256 amount) external {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(_actor(ownerSeed));
        token.approve(address(0), amount);
    }

    function rejectAdministration(uint256 actorSeed, uint256 selectorSeed, uint256 amount) external {
        bytes[6] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", _actor(actorSeed), amount),
            abi.encodeWithSignature("burn(uint256)", amount),
            abi.encodeWithSignature("transferOwnership(address)", _actor(actorSeed)),
            abi.encodeWithSignature("upgradeTo(address)", _actor(actorSeed)),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("setFee(uint256)", amount)
        ];
        vm.prank(_actor(actorSeed));
        (bool success,) = address(token).call(calls[selectorSeed % calls.length]);
        assertFalse(success, "token exposed a forbidden administration or supply operation");
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approval failed");
        expectedAllowance[owner][spender] = amount;
    }

    function _move(address from, address to, uint256 amount) internal {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Exercise zero, one wei, the whole balance/allowance, and ordinary amounts.
    function _amount(uint256 seed, uint256 limit, uint8 edge) internal pure returns (uint256) {
        if (edge % 4 == 0 || limit == 0) return 0;
        if (edge % 4 == 1) return 1;
        if (edge % 4 == 2) return limit;
        return bound(seed, 0, limit);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PixelTokenInvariantTest is Test {
    PixelTokenHandler internal handler;
    PixelToken internal token;

    function setUp() public {
        handler = new PixelTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverspend.selector;
        selectors[4] = handler.rejectUnapprovedSpend.selector;
        selectors[5] = handler.rejectApprovedOverspend.selector;
        selectors[6] = handler.rejectZeroReceiver.selector;
        selectors[7] = handler.rejectZeroSpender.selector;
        selectors[8] = handler.rejectAdministration.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice ERC20 conservation and exact transfers, including failed-call atomicity.
    function invariant_supplyAndAllBalancesMatchTransferLedger() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "actor balance differs from transferred amount");
            sum += balance;
        }
        assertEq(sum, 1_000_000_000 ether, "transfers created, destroyed, or leaked supply");
        assertEq(token.totalSupply(), sum, "total supply disagrees with all holders");
        assertEq(token.balanceOf(address(0)), 0, "tokens reached the zero address");
    }

    /// @notice Approvals are isolated per owner/spender; unsuccessful spending consumes nothing.
    function invariant_allAllowancesMatchApprovalsAndSuccessfulSpending() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    function test_fullBalanceSelfTransferAndZeroBalanceTransfer() public {
        handler.transfer(0, 0, 0, 2); // Full-balance self transfer.
        invariant_supplyAndAllBalancesMatchTransferLedger();
        handler.transfer(0, 1, 0, 2); // Empty the deployer completely.
        assertEq(token.balanceOf(handler.actors(0)), 0);
        handler.transfer(0, 1, 0, 0); // Zero tokens can be transferred with no balance.
        handler.rejectOverspend(0, 1);
        invariant_supplyAndAllBalancesMatchTransferLedger();
    }

    function test_infiniteApprovalSurvivesSpendingAndRevocationTakesEffect() public {
        address owner = handler.actors(0);
        address spender = handler.actors(1);
        address recipient = handler.actors(2);
        handler.approve(0, 1, 0, 1);
        handler.transferFrom(0, 1, 2, 0, 1); // Spend exactly one wei.
        handler.transferFrom(0, 1, 2, 0, 2); // Spend the rest of the owner's balance.
        assertEq(token.allowance(owner, spender), type(uint256).max);
        handler.transfer(2, 0, 0, 1); // Refill so rejection cannot be explained by no balance.
        handler.approve(0, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, recipient, 1);
        invariant_supplyAndAllBalancesMatchTransferLedger();
        invariant_allAllowancesMatchApprovalsAndSuccessfulSpending();
    }

    function test_finiteAllowanceRollsBackWhenTransferFails() public {
        handler.rejectApprovedOverspend(0, 1);
        handler.rejectZeroReceiver(0, 1, 1, true);
        handler.rejectZeroReceiver(0, 1, 0, true);
        handler.rejectZeroSpender(0, type(uint256).max);
        invariant_supplyAndAllBalancesMatchTransferLedger();
        invariant_allAllowancesMatchApprovalsAndSuccessfulSpending();
    }
}
