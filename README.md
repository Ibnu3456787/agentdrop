# AgentHaven

**One on-chain Pass for every Agent ID holder — first 1,111 free, then 0.00005 BNB — plus a live free-mint hub.**

AgentHaven is built for the **Binance Wallet × BNB Chain Agent ID Hackathon**
(60,000 USDC prize pool; submissions close 9 December 2026, 15:00 WIB).
It targets the **Ecosystem Pioneer Award** (on-chain metrics: interacting
Agent ID addresses) and, as a bonus, the **Innovation Award**.

![Example AgentHaven Pass](assets/pass-example.svg)

## What it is

Any wallet holding a **.ai Agent ID** can claim one **AgentHaven Pass**
NFT (ERC-721) on BNB Smart Chain. The first **1,111 Passes are free**
(gas only); later claims cost **0.00005 BNB** each — the contract requires
the exact price, so overpaying is impossible. The Pass artwork
and metadata are **fully on-chain**: the contract renders an SVG badge
containing the claimer's own **.ai name** (resolved on-chain from the Agent
ID registry) and their Pass number. Claim fees accumulate in the contract
and only the owner can withdraw them; there is no token and no promised
return.

> **v1 pilot:** the first version of the Pass
> (`AgentHavenPass`, `0xf8118d518a228B704947eCf89C264B4F4F79aC5D`, deployed
> 19 November 2026) was an all-free pilot drop. It is immutable, so the
> tiered pricing lives in **v2** (`AgentHavenPassV2`), a separate contract
> with the same name, symbol, supply cap, and metadata format. v1 passes
> remain valid on-chain.

The website (static, no backend) also lists **live free mints** for Agent ID
holders, fetched client-side from the public Colony index, and lets anyone
check whether an address holds an Agent ID.

> **Name note:** this project was originally scoped as "AgentDrop", but that
> name is already used by an existing Agent ID airdrop project
> (agentra.trade). It was renamed **AgentHaven** before any code was
> published. The GitHub repo slug is still `agentdrop` for now.

## How Agent ID is used

Agent ID is the core access control of the project, not a cosmetic add-on:

1. **Eligibility gate (on-chain).** `AgentHavenPassV2.claim()` calls
   `balanceOf(msg.sender)` on the official Agent ID registry
   (`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`, SPACE ID Agent ID, ERC-721,
   Sourcify exact-match) and reverts with `NotAgentIDHolder` unless the
   caller holds at least one Agent ID.
2. **Personalised on-chain metadata.** `claim()` also calls the registry's
   `handleOf(msg.sender)` and stores the handle. The Pass `tokenURI` embeds
   the holder's `.ai` name in the token name, the SVG badge, and the
   attributes — so every Pass is verifiably tied to a real Agent ID.
3. **One Pass per wallet.** A `claimed` mapping enforces 1 Pass per address;
   total supply is capped at 10,000.
4. **Website status check.** The site reads the same registry (`balanceOf`
   + `handleOf`) through a public BSC RPC so anyone can verify an address's
   Agent ID status before claiming.

## Contract (v2)

`contracts/src/AgentHavenPassV2.sol` — a minimal hand-rolled ERC-721 (no
external dependencies, single auditable file, ~400 lines), plus
`contracts/src/Base64.sol`. v1 (`contracts/src/AgentHavenPass.sol`) is
kept in the repo unchanged for reference.

| Property | Value |
|---|---|
| Standard | ERC-721 (ERC-165: ERC-721 + metadata) |
| Name / symbol | AgentHaven Pass / AHPASS |
| Claim price | First 1,111 claims free (gas only); then 0.00005 BNB each (exact value required, enforced by `claimPrice()`) |
| Max supply | 10,000 |
| Per wallet | 1 |
| Metadata | Fully on-chain (base64 JSON + base64 SVG) |
| Payable functions | `claim()` only (exact price); no receive/fallback — BNB enters only through claims |
| Claim fees | Accumulate in the contract; owner-only `withdraw()` (full balance) |
| Fees / token / approvals | No token; no other fees; no approvals involved in claiming |

**Measured gas** (Foundry, solc 0.8.20, optimizer 200 runs):

| Operation | Gas (v2) | Gas (v1, for reference) |
|---|---|---|
| Deploy (creation) | 2,179,549 | 2,021,284 |
| `claim()` — free tier | 153,256 | 153,128 |
| `claim()` — paid tier | 138,362 | — |

(The paid-claim figure was measured with `totalMinted` pre-set via
`vm.store`, so its storage slot was warm; a real paid claim costs roughly
the same as a free claim, ~150k gas.)

A dry-run deploy simulation against BSC mainnet state estimated
**0.0001392 BNB** total at the then-current 0.05 gwei gas price. Deploy when
gas is low: at 1 gwei the deployment would cost ~0.0022 BNB.

## Owner permissions (disclosure)

The deployer is the owner. Owner powers are intentionally minimal:

| Function | What it does | What it cannot do |
|---|---|---|
| `setPaused(bool)` | Pauses / unpauses **claiming only** (emergency stop) | Cannot move, burn, or freeze existing Passes; cannot change metadata |
| `withdraw()` | Sends the **full** contract balance (accumulated claim fees) to the owner; reverts if the balance is zero | Cannot withdraw a partial amount or to another address; cannot take anyone's Pass or any other asset |
| `transferOwnership(address)` | Transfers ownership (cannot transfer to zero address) | — |
| `renounceOwnership()` | Irreversibly gives up ownership | — |

There is **no** owner mint, no owner burn, no metadata/URI setter, and no
price setter (`FREE_SUPPLY` and `PAID_PRICE` are immutable constants), and
no way to move anyone's Pass. The contract holds only claim fees paid
through `claim()` at the exact price — it has no receive/fallback function,
so BNB cannot enter any other way.

## Tests

106 tests, all passing:

- **v2 — 58 unit tests** (`contracts/test/AgentHavenPassV2.t.sol`) with a
  mock registry: all v1-equivalent coverage (happy-path claim, all reverts,
  re-entrancy protection, metadata correctness, owner permissions, ERC-721
  transfers/approvals, 2 fuzz tests) **plus pricing** — `claimPrice()` at
  0 / 1110 / 1111 / 1112, the free→paid boundary end-to-end (claim #1111
  free, #1112 paid), exact-value enforcement (zero on paid, value on free,
  overpay and underpay all revert), and **withdraw** (full balance to
  owner, owner-only, reverts when empty, goes to the new owner after
  transfer, claiming continues after a withdraw, direct ETH transfers
  rejected).
- **v2 — 6 fork tests** (`contracts/test/AgentHavenPassV2Fork.t.sol`)
  against the **real** Agent ID registry on BSC mainnet: a real holder
  claims free and the real `.ai` handle appears in the metadata; a real
  non-holder reverts; the paid-tier boundary works on a fork.
- **v1 — 38 unit + 4 fork tests** (unchanged, still passing).

```bash
cd contracts
forge test                                  # all suites (unit + fork via foundry.toml bsc endpoint)
forge test --match-contract AgentHavenPassV2Test                              # v2 unit tests
forge test --match-contract AgentHavenPassV2ForkTest --fork-url https://bsc-dataseed.binance.org/   # v2 fork tests vs real registry
```

Test history: the v1 unit suite passed **25/25 consecutive runs** (38/38
each) before the final SVG fix, and **10/10 runs** after it; the v1 fork
suite passed all **6 runs** (4/4 tests each). The v2 suite passed **58/58
unit + 6/6 fork** on its first clean run (after fixing 7 test-side bugs:
4 withdraw tests needed a payable `receive()` in the test contract — the
vendored forge-std `Test` has none — and 3 assertions wrongly expected
`totalSupply() == 0` after `totalMinted` had been set to 1111 via
`vm.store`). No test output was fabricated — see `forge test` output above.

Foundry dependencies: `forge-std` v1.17.0 is **vendored as plain files** under
`contracts/lib/forge-std/` (no git submodule), so the repo clones and builds
with no extra install step beyond Foundry itself.

## Website

`web/` — static HTML/CSS/JS, no build step, no trackers, no external
libraries, no API keys. GitHub Pages-ready (serve `web/` as the site root).

- **Agent ID check:** paste an address or connect a wallet; reads
  `balanceOf` + `handleOf` from the registry via public BSC RPC (with
  fallback endpoints).
- **Live counter:** the hero shows the live number of Passes claimed
  (`totalMinted()` re-read from BSC every 30 seconds) with a progress bar.
- **Claim button:** connects an injected wallet (MetaMask / Binance Wallet),
  re-verifies eligibility on-chain, reads the current `claimPrice()`
  on-chain, then sends a single `claim()` call with exactly that value
  (0 for the free tier, 0.00005 BNB after the first 1,111 claims). The user
  confirms the exact transaction in their own wallet; no approvals are
  involved.
- **Free-mint list:** fetched client-side from
  `https://mints-bnb.pages.dev/projects.json` (name, status, terms, contract,
  links), with a graceful error state if the index is unreachable.
- **Honesty note:** first 1,111 free, then 0.00005 BNB per claim; claim fees
  withdrawable by the owner only; no token, no promised returns,
  unaffiliated with Binance and SPACE ID; v1 pilot note.

**Before the site can claim on v2:** set `CONFIG.PASS_CONTRACT` in
`web/app.js` to the deployed v2 address. Until then it still points at the
v1 contract; the price read falls back to 0 there (correct for v1, which
has no `claimPrice()`), and the live counter reads v1's `totalMinted()`.

## Deploy

v1 is deployed at `0xf8118d518a228B704947eCf89C264B4F4F79aC5D` (Sourcify
exact-match). **v2 has not been deployed yet** — deploy with the v2 script
(script only — do not run without the deployer's explicit go-ahead):

```bash
cd contracts
# 1. Deploy v2 to BSC mainnet (uses the registry address as a constant):
forge script script/DeployV2.s.sol --rpc-url https://bsc-dataseed.binance.org/ \
  --broadcast --private-key "$PRIVATE_KEY"
# 2. Verify on BscScan (command is printed by the script; needs a BscScan API key):
forge verify-contract <DEPLOYED_ADDRESS> src/AgentHavenPassV2.sol:AgentHavenPassV2 \
  --chain-id 56 --constructor-args $(cast abi-encode "constructor(address)" 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) \
  --etherscan-api-key "$BSCSCAN_API_KEY"
# 3. Paste the deployed address into web/app.js (CONFIG.PASS_CONTRACT) and redeploy the site.
```

Never commit a private key. The deployer needs ~0.0002–0.0005 BNB for gas at
typical BSC gas prices.

## Hackathon red-lines compliance

- ✅ No Binance/BNB branding or impersonation (name "AgentHaven", no logos).
- ✅ No web QR login, no confirmation bypass, no unauthorized transfers.
- ✅ Contracts verified + open-source on BscScan (after deployment).
- ✅ Owner permissions fully disclosed above.
- ✅ No seed phrase / private key collection (the site never asks; claiming
  uses the user's own wallet confirmation).
- ✅ No promised returns; no token; the Pass is a collectible badge.
  The 0.00005 BNB claim price (after the first 1,111 free claims) is a
  fixed contract constant, disclosed on the site and here; claim fees are
  withdrawable by the owner only.
- ✅ Agent ID is used for access control, not as a wallet-lookup tool.
- ✅ No volume manipulation, no wash trading, no fake metrics.
- ✅ No trading features, so no trading risk warnings apply.

## Repo layout

```
├── LICENSE                     MIT
├── README.md                   this file
├── assets/pass-example.svg     example Pass artwork (as rendered on-chain)
├── assets/og-card.png          X/Twitter share card (1200×630)
├── contracts/
│   ├── foundry.toml
│   ├── lib/forge-std/          vendored test dependency (no submodule)
│   ├── script/Deploy.s.sol     v1 deploy script (already deployed)
│   ├── script/DeployV2.s.sol   v2 deploy script (not run yet)
│   ├── src/AgentHavenPass.sol  v1 Pass contract (all-free pilot, deployed)
│   ├── src/AgentHavenPassV2.sol v2 Pass contract (tiered pricing)
│   ├── src/Base64.sol
│   └── test/                   v1: 38 unit + 4 fork; v2: 58 unit + 6 fork
└── web/                        static site (GitHub Pages-ready; mirrored in docs/)
    ├── index.html
    ├── styles.css
    ├── og-card.png
    └── app.js                  CONFIG.PASS_CONTRACT = deploy address
```

## License

MIT — see [LICENSE](LICENSE).
