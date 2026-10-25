# Ajo Protocol

Rotating savings circles (ajo / esusu / jam'iya) onchain, built for the Arbitrum Open House Dubai buildathon.

- **Members** lock one round's contribution as collateral to join, then pay in every round.
- **Idle money earns yield** in an ERC-4626 vault (a mock on testnet, a real USDC vault on mainnet).
- **Payout slots are auctioned.** Need the pot early? Bid the discount you'll give up. The highest bid wins, and the discount is shared by everyone else, so the circle becomes a small peer credit market.
- **Missed payments are slashed** from collateral; anything collateral can't cover becomes debt taken from that member's own payout.
- **AjoScore** records every on-time payment, miss and completed circle in a non-transferable registry any app can read.

## Contracts

| File | What it does |
|---|---|
| `src/CircleFactory.sol` | Creates circles that share one token, vault and AjoScore; registers each with AjoScore |
| `src/Circle.sol` | One circle: `join`, `leave`, `contribute`, `bid`, `closeRound` (slash + payout), `topUpCollateral`, `claim` |
| `src/AjoScore.sol` | Score registry. 0 = no history, else 500 base, +10 per on-time payment, +50 per completed circle, -100 per miss (0..1000) |
| `src/mocks/MockYieldVault.sol` | The testnet yield adapter: an OpenZeppelin ERC-4626 vault with `simulateYield` for demos |
| `src/mocks/MockUSDC.sol` | 6-decimal test USDC with an open faucet (`mint`, max 10,000 per call) |

## How a round works

1. Every member calls `contribute()` before `roundDeadline`.
2. Members who haven't been paid yet may `bid(discount)`; they must have paid this round, beat the current bid, and stay under `maxDiscount()`.
3. After the deadline anyone calls `closeRound()`: missers are slashed, the winner gets `pot - discount`, the discount becomes `claimable` for everyone else, and the next round opens.
4. No bids? The first unpaid member in join order who paid this round wins.
5. After the last round, collateral comes back and vault yield plus penalties go to members with a clean record. Everyone calls `claim()`.

## Run it

```bash
# 1. install Foundry (once)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 2. from the ajo-protocol folder, install the libraries
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts

# 3. build and test
forge build
forge test            # 26 tests, including a fuzz test that money is never created or lost
forge test -vvv --match-test test_DemoStory   # watch the Lagos-Dubai story
forge coverage        # optional
```

### Try it on a local chain

```bash
anvil                                   # terminal 1
forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast                           # terminal 2 (anvil's public test key)
```

### Deploy to Arbitrum Sepolia

```bash
cp .env.example .env && source .env     # add an Arbiscan key for verification
cast wallet import deployer --interactive   # paste your testnet private key once, encrypted locally
forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --account deployer --broadcast --verify
```

## Known limits (v0.1)

- Circles are open to anyone with the address; invite-only allowlists come with the app.
- Bids are public (no sealed auction yet).
- Rounding dust of a few base units can stay in a finished circle.
- Not audited. Testnet only.
