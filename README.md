# Pixel Pool

Pixel Pool is an immutable Uniswap v4 canvas hook and its fixed-supply launch token. Every successful swap in the first initialized pool paints one of 1,024 dots. The hook charges no fee, returns zero swap delta, and never transfers, settles, approves, mints claims, or takes funds. The pool's separate LP fee remains in force; the intended launch fee is **12,500 (1.25%)**.

## Contracts and behavior

- `src/PixelToken.sol:PixelToken`: ERC-20 named **Pixel Pool**, symbol **PIXEL**, 18 decimals. Its no-argument constructor mints exactly **1,000,000,000 tokens (10^27 units)** to its caller, normally the launch factory. There are no subsequent mint, burn, fee, owner, pause, or upgrade functions.
- `src/PixelHook.sol:PixelHook`: implements `IHooks` directly. `beforeInitialize` and `afterSwap` are the only enabled permissions. Every callback checks the immutable PoolManager; disabled callbacks also revert for the manager. The constructor validates the deployed address against the declared permissions.
- `src/HookFlags.sol`: v4 flag helpers. The hook's low 14 address bits must equal **0x2040 / 8256**, for `beforeInitialize | afterSwap`.
- `script/MineHook.s.sol:MineHook`: a pure CREATE2 salt search using the actual creation bytecode and constructor arguments. It never broadcasts or reads configuration from the environment.
- `script/PoolParameters.s.sol:PoolParameters`: an offline, pure helper returning the ordered currencies, tick spacing and initial sqrt price for this launch. It takes the actual PIXEL and IMD addresses as arguments and rejects missing or identical currencies.

At initialization, the hook requires an ordered pair containing the supplied launch token and another deployed ERC-20. **The other currency is designated IMD.** It records its address, address order, and `10 ** decimals()` unit once, along with the complete PoolId. Decimals 0 through 74 are supported; a missing or reverting `decimals()` or a higher value rejects initialization. Native currency is not an IMD pair. The PoolManager validates fees, tick spacing and the initial price as usual. Initialization failure rolls back the hook's lock. A second initialization, even with different fee or spacing, is refused.

This design uses the launch factory's knowledge of the pair instead of a hardcoded IMD address or symbol check. The deployer **must verify that the other currency is the real IMD on the selected chain**. An ERC-20's name or symbol is not proof of its identity. No callback sender allowlist is imposed: deployment and initialization must occur atomically to prevent someone else from claiming the first pool.

Buy means IMD input and PIXEL output; sell means PIXEL input and IMD output. Direction uses `SwapParams.zeroForOne` and the recorded currency order. Brightness uses the absolute **executed IMD BalanceDelta**, rather than the requested amount or PIXEL amount. Thus exact-input, exact-output and partially filled swaps all use the same units. On buys this includes the IMD paid as LP fees; on sells it is the IMD actually received.

| Executed IMD amount | Buy code / SVG color | Sell code / SVG color |
| --- | --- | --- |
| Less than 5 | 1 / `#005500` | 5 / `#550000` |
| At least 5, less than 50 | 2 / `#008800` | 6 / `#880000` |
| At least 50, less than 500 | 3 / `#00bb00` | 7 / `#bb0000` |
| At least 500 | 4 / `#00ff00` | 8 / `#ff0000` |

Unpainted code 0 renders as `#111111`. A successful zero-fill callback paints the dimmest shade in its swap direction, since every successful callback paints. A zero requested swap rejected by the PoolManager and any reverted transaction leave the canvas unchanged.

## Canvas API

- `strokes()` is the total number of successful callbacks. It starts at 0.
- `pass()` is `strokes() / 1024`: completed passes, or equivalently the zero-based pass of the next stroke. It becomes 1 at stroke 1024.
- `pixelAt(i)` returns a `uint8` palette code for zero-based pixel `i`; it rejects `i >= 1024`.
- `canvas()` returns all `uint256[32]` words. Word `i / 32` stores a row; bits `8 * (i % 32)` through `8 * (i % 32) + 7` contain the color. Leftmost pixels occupy the least significant bytes.
- `render()` returns raw standalone SVG, not a data URI or base64 string: a 320×320 viewBox with 1,024 circles in row-major order. Each circle has radius 4 and a 10-unit grid spacing. This is a bounded view operation; swaps do not render SVG.
- `Painted(uint256 indexed stroke, uint256 indexed pixel, uint8 color, address indexed painter)` is emitted after each write. Stroke is **one-based**, pixel is **zero-based**, and painter is exactly `tx.origin` as requested. It is attribution only, not authentication or a reliable identity for smart-account users.
- `PoolLocked(PoolId indexed poolId, address indexed imd, bool imdIsCurrency0, uint8 decimals)` records the one-time configuration.

The first swap paints pixel 0, the 32nd pixel 31, the 33rd pixel 32, and the 1024th pixel 1023. The 1025th overwrites pixel 0. Existing dots remain until repainted; there is no whole-canvas clear or historical-canvas storage. Events allow reconstruction of prior passes. There is one dot per swap callback, including multiple swaps in one transaction.

## Build and verify

Install Foundry and Solidity **0.8.26**, then run:

```sh
forge build
forge test
forge fmt --check
```

The project pins Solidity 0.8.26, Cancun EVM, optimizer 200 runs, and `bytecode_hash = "none"`. It does not enable FFI or grant filesystem permissions. All imported Solidity sources and licenses are vendored as ordinary files under `lib/`, with exact upstream commits and included paths in `dependencies.lock.json`. There are no submodules or network-dependent imports. The verifier needs only its preinstalled pinned compiler and Foundry; no package installation is required.

The tests deploy an actual v4 PoolManager, mine and deploy production hook bytecode, seed liquidity, settle swaps and remove liquidity. Unit tests additionally impersonate the manager to exercise exact brightness thresholds and extreme signed values. Coverage includes both currency orders, all brightness boundaries, exact input/output, partial fills, token-only manager funding, failed settlement rollback, first-pool locking, callback access, packed row boundaries, multiple passes, palette rendering, token supply/transfers/allowances, disabled administration, runtime opcode checks, and fuzzed sequences compared with an unpacked reference canvas. Tests use no environment variables or external services.

## Deployment parameters and responsibilities

No deployment transaction is included or authorized. The launch system supplies these arguments:

| Contract | Constructor arguments | Source |
| --- | --- | --- |
| `PixelToken` | none | Factory deploys first and receives all supply |
| `PixelHook` | `IPoolManager manager`, `address token` | Manifest placeholders **`$poolManager`**, **`$token`** |

There is no owner, recipient, factory, chain-specific address, or mutable setting in the hook. The two constructor dependencies must already have code. The hook does not need an IMD constructor address because it records the non-PIXEL currency from the first PoolKey. The separate launch manifest is the launch system's responsibility; this project supplies the contracts and their parameter mapping, rather than guessed chain values.

### Resolved manifest pool inputs

The launch's **`pool.tickSpacing` is `60`**. Its **`pool.initialPrice` is 0.0000025 IMD per PIXEL**, from an opening market cap of **2,500 IMD** divided by **1,000,000,000 PIXEL**. Both currencies have **18 decimals**. This market cap specifies the initial price; it does not prescribe a liquidity deposit or promise a future valuation.

Currency0 is always the numerically lower address. Use the following exact integer `sqrtPriceX96` when initializing, where the v4 price is currency1 units per currency0 unit:

| Currency0 | Currency1 | Initial currency1 / currency0 price | `sqrtPriceX96` |
| --- | --- | --- | --- |
| PIXEL | IMD | 0.0000025 IMD / PIXEL | `125270724187523965593206901` |
| IMD | PIXEL | 400,000 PIXEL / IMD | `50108289675009586237282760313921` |

These are the requester-supplied Q96 encodings of the square root of the oriented price. The PIXEL-first integer is one unit above the mathematical floor; use the supplied value exactly. Preserve these large integers as decimal strings or arbitrary-precision integers in manifest tooling, never floating-point numbers. The existing LP fee remains **12500 (1.25%)**, separate from tick spacing.

For a factory that accepts these pool inputs, call `PoolParameters.run(pixel, imd)` with the actual launch addresses. Copy the returned `currency0`, `currency1` and `tickSpacing` into the PoolKey (with the launch hook and fee 12500), and pass the returned `sqrtPriceX96` to `PoolManager.initialize`. The helper performs no transactions or metadata reads; the launch operator must verify both token identities and their 18 decimals. A different decimal scale requires corrected launch inputs before initialization.

**If the launch factory sets tick spacing or initial price itself, use its authoritative value for that parameter.** The launch operator must inspect the actual factory implementation/configuration, record its effective values in the manifest, and check the resulting PoolKey and initialization price. No factory implementation, address or ABI is supplied in this repository, so the helper cannot discover factory values and must not override them. This resolves the missing economic choices without inventing chain addresses or a manifest schema.

The hook remains unchanged and does not enforce these economics. Existing generic hook fixtures intentionally use a 1:1 price (`79228162514264337593543950336`) to exercise swaps; that value is **not this launch's opening price**. `test/PoolParameters.t.sol` checks the launch values, both currency orders, the market-cap calculation, real PoolManager initialization and failure recovery.

Deployment procedure:

1. Select the chain's real PoolManager and real IMD contract. Confirm the IMD contract is a standard, stable-decimal ERC-20 suitable for v4 with 18 decimals, and confirm PIXEL has 18 decimals. Confirm Cancun support. Determine whether the factory sets the pool inputs itself and record the effective values as described above.
2. Determine the actual factory/CREATE2 deployer and the PIXEL address from the factory's deployment plan. Mine against these actual addresses and the final compiler settings. `MineHook.run(deployer, manager, token, start, attempts)` returns a salt and predicted hook address, or `SaltNotFound`; continue with the next range if exhausted. Tests call this function directly and verify the CREATE2 result. A salt mined for another deployer, token, manager, or bytecode is invalid.
3. For the original launch, the factory deploys PIXEL, deploys the hook at the mined address, and initializes the intended PIXEL/IMD pool **in the same transaction**. Use the approved LP fee 12500, tick spacing **60** and the correctly oriented sqrt price from the table above, subject to authoritative factory values. The hook itself sets or overrides none of those economics. The factory supplies liquidity according to the launch policy; liquidity tick bounds must be multiples of the effective spacing and cover the opening price to be active. This follow-up performs no deployment and never redeploys, replaces or re-mints an existing PIXEL token.
4. Verify `getHookPermissions()`, the address mask, immutable dependencies, `poolId()`, `imdCurrency()`, `imdIsCurrency0()`, and `imdUnit()` against the intended launch. Check the PoolManager's `Initialize` event for the ordered currencies, fee, tick spacing and exact opening sqrt price; later swaps can change the current price. Verify deployed bytecode and publish the source.

The initializer callback also causes initialization at the predicted hook address to fail while that address has no code. It does not reserve a separately deployed but uninitialized hook against other callers. Atomic deployment and initialization are essential; the first successful pool cannot be changed later.

## After launch

There are **no setters, administrators, upgrades, keepers, fee claims, or maintenance transactions**. Monitor `Painted` and `PoolLocked`; consumers may call `canvas()` or `render()` without permission. Users and routers remain responsible for swap slippage limits. Transaction ordering determines dot order, so traders and block builders can influence the art through trading; the art is not a source of randomness, ownership, rewards, or price information.

Do not send assets directly to the hook. It has no recovery function, and accidental ERC-20 transfers or forced native funds cannot be withdrawn. This preserves the requested rule that the hook never moves funds.

## Security review scope

The supplied Ethereum and v4 checklists were applied to callback authorization, permission/address agreement, pool isolation, signed delta arithmetic, token decimals, bounded execution, and absence of administration or value movement. All return-delta flags are disabled; `afterSwap` always returns zero. It makes no external calls, so no settlement or callback reentrancy mechanism is needed. Initialization's only external metadata read is a static call. SVG rendering is a bounded read with no external interactions.

Local Foundry tests and fuzzing are the delivered verification. A launch-chain fork rehearsal, independent adversarial review, explorer verification, and production monitoring remain deployment responsibilities. No chain fork, Slither, Mythril, or external audit is claimed here. There are no unresolved requester-only values embedded as stand-ins in deployable contracts.
