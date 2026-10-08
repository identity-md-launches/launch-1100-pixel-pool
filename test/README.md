# Pixel Pool tests

Run the complete suite offline with the repository's existing dependencies:

```sh
forge build
forge test
```

The existing `PixelHook.t.sol`, `PixelHookIntegration.t.sol`, and `PixelToken.t.sol`
cover palette examples, address ordering, brightness, packing, passes, callback
permissions, real swaps, settlement, and token metadata.

The additional suites extend that coverage:

| Suite | Properties checked |
| --- | --- |
| `PoolParameters.t.sol` | Launch spacing 60 and both exact supplied sqrt prices; sorted currencies; independent market-cap calculation and Q96 rounding; real PoolManager initialization with both 18-decimal currency orders; rejection of missing/identical or reversed currencies; invalid-price rollback and successful retry; caller-independent offline configuration. |
| `PixelHookEdges.t.sol` | Invalid dependencies and pool ordering; reverting/malformed metadata and initialization recovery; cached IMD scale; threshold neighbors at decimal scales 0–35; unsupported scales 75–255; all five pool identity fields; caller versus origin authorization; complete SVG and packed canvas after second-pass row rollover. |
| `PixelHookInvariant.t.sol` | Real PoolManager swaps with three funded actors, both directions and amount modes, liquidity changes, failed settlements, and unauthorized callbacks. Every sequence preserves pool identity, the fixed LP fee, the canvas model, supply conservation, settled deltas, and zero hook funds or claims. |
| `PixelTokenInvariant.t.sol` | Four actors transfer, approve, spend allowances, attempt invalid transfers, and probe forbidden administration. Every actor balance and allowance matches an independent ledger; supply stays fixed; failures roll back allowance spending. |

Run counts and sequence depths are declared inline in the Solidity test files.
Both handlers explicitly target action selectors and enable `fail-on-revert`, so an
unexpected handler failure fails the campaign. Expected failures check revert data
and state preservation. Deterministic scenarios exercise full balances, zero
transfers, infinite approvals, revocation, and each pool handler action.

The hook handler starts from 1,016 settled swaps so randomized sequences reach
the 1,024-dot pass boundary. Its color model uses the actor's actual IMD balance
change, and its canvas uses a flat byte array and independent cursor. The token
model updates from requested successful operations and checks every tracked
owner/spender allowance pair.

All contracts and external currencies are deployed locally. Unit callback tests
impersonate PoolManager to isolate failure paths; integration and hook invariant
tests execute swaps through the real manager and settlement router. No fork,
network, FFI, environment mutation, or additional dependency is required.
