// AgentHaven Market — vanilla JS, zero dependencies, no trackers, no API keys.
// Reads go through public BSC RPC endpoints; writes go through the user's own
// injected wallet (MetaMask / Binance Wallet). This site never asks for a
// seed phrase or private key.
(function () {
  "use strict";

  // ---------------------------------------------------------------------------
  // CONFIG — MARKET_CONTRACT is the zero address until the market contract is
  // deployed. After deployment, set it to the deployed address and the market
  // goes live (the page detects this and enables buying/listing).
  // ---------------------------------------------------------------------------
  var CONFIG = {
    // AgentHavenMarket (BSC mainnet, chain ID 56) — NOT DEPLOYED YET.
    // Deploy with contracts/script/DeployMarket.s.sol, then set this.
    MARKET_CONTRACT: "0xd7cab4f410dF1afce3eE84F61D0874e1eC009915",
    PASS_V1: "0xf8118d518a228B704947eCf89C264B4F4F79aC5D", // all-free pilot drop
    PASS_V2: "0xFa4ad465FDff3b9b6d8cbd1bb31613a466aFfA0e", // 1,111 free, then 0.00005 BNB
    USDT: "0x55d398326f99059fF775485246999027B3197955", // BSC USDT (BEP-20, 18 decimals)
    CHAIN_ID: 56,
    RPCS: [
      "https://bsc-dataseed.binance.org/",
      "https://bsc-dataseed1.defibit.io/",
      "https://bsc-dataseed1.ninicoin.io/"
    ],
    // First block to scan for Pass transfers (before both Pass deploys, 19 Nov 2026).
    DEPLOY_BLOCK: 134440000,
    LOG_CHUNK: 5000, // eth_getLogs range per request (public RPCs cap ranges)
    // Function selectors (keccak256(signature)[0:4], verified via cast):
    SEL_LIST: "0x18a23423",            // list(address,uint256,uint256,uint8)
    SEL_CANCEL: "0x305a67a8",          // cancelListing(uint256)
    SEL_BUY: "0x4884f459",             // buyListing(uint256)
    SEL_GET_LISTING: "0x107a274a",     // getListing(uint256)
    SEL_ACTIVE_IDS: "0xf7776490",      // getActiveListingIds(uint256,uint256)
    SEL_ACTIVE_COUNT: "0x4331ed1f",    // activeCount()
    SEL_FEE_BPS: "0x24a9d853",         // feeBps()
    SEL_BALANCE_OF: "0x70a08231",      // balanceOf(address)
    SEL_OWNER_OF: "0x6352211e",        // ownerOf(uint256)
    SEL_TOKEN_URI: "0xc87b56dd",       // tokenURI(uint256)
    SEL_APPROVE: "0x095ea7b3",         // approve(address,uint256)
    SEL_GET_APPROVED: "0x081812fc",    // getApproved(uint256)
    SEL_ALLOWANCE: "0xdd62ed3e",       // allowance(address,address)
    TOPIC_TRANSFER: "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  };

  var ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
  var isDeployed = CONFIG.MARKET_CONTRACT.toLowerCase() !== ZERO_ADDRESS;

  var $ = function (id) { return document.getElementById(id); };
  var connectedAccount = null;
  var allListings = [];   // {id, collection, tokenId, seller, price(BigInt), currency, active, meta}
  var metaCache = {};     // "collection:tokenId" -> {name, image, handle}
  var myPasses = [];      // {collection, tokenId, meta}

  // ---------------------------------------------------------------------------
  // Small helpers
  // ---------------------------------------------------------------------------
  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function shortAddr(a) {
    return a.slice(0, 6) + "…" + a.slice(-4);
  }
  function bscscan(addr) {
    return "https://bscscan.com/address/" + addr;
  }
  function collectionName(addr) {
    var lower = addr.toLowerCase();
    if (lower === CONFIG.PASS_V1.toLowerCase()) return "Pass v1";
    if (lower === CONFIG.PASS_V2.toLowerCase()) return "Pass v2";
    return "Pass"; // unreachable in production: the market only lists v1/v2
  }
  function collectionKey(addr) {
    var lower = addr.toLowerCase();
    if (lower === CONFIG.PASS_V1.toLowerCase()) return "v1";
    if (lower === CONFIG.PASS_V2.toLowerCase()) return "v2";
    return "unknown"; // unreachable in production (see above)
  }

  // --- BigInt wei helpers (prices can exceed Number.MAX_SAFE_INTEGER) ---
  function word(hex, i) {
    return hex.slice(2 + i * 64, 2 + (i + 1) * 64);
  }
  function wordToBigInt(hex, i) {
    var w = word(hex, i);
    return w ? BigInt("0x" + w) : 0n;
  }
  function wordToAddress(hex, i) {
    return "0x" + word(hex, i).slice(-40);
  }
  function decodeUintArray(hex) {
    // Dynamic uint256[]: word0 = offset, word1 = length, then items.
    if (!hex || hex === "0x" || hex.length < 130) return [];
    var len = Number(wordToBigInt(hex, 1));
    var out = [];
    for (var i = 0; i < len; i++) out.push(wordToBigInt(hex, 2 + i));
    return out;
  }
  function decodeListing(hex) {
    // Static tuple: id, collection, tokenId, seller, price, currency, active.
    return {
      id: wordToBigInt(hex, 0),
      collection: wordToAddress(hex, 1),
      tokenId: wordToBigInt(hex, 2),
      seller: wordToAddress(hex, 3),
      price: wordToBigInt(hex, 4),
      currency: Number(wordToBigInt(hex, 5)), // 0 = BNB, 1 = USDT
      active: wordToBigInt(hex, 6) !== 0n
    };
  }
  function decodeString(hex) {
    if (!hex || hex === "0x" || hex.length < 130) return "";
    var body = hex.slice(2);
    var offset = parseInt(body.slice(0, 64), 16) * 2;
    var len = parseInt(body.slice(offset, offset + 64), 16);
    var data = body.slice(offset + 64, offset + 64 + len * 2);
    var out = "";
    for (var i = 0; i < data.length; i += 2) {
      out += String.fromCharCode(parseInt(data.slice(i, i + 2), 16));
    }
    return out;
  }
  function formatUnits(value, maxDecimals) {
    // value: BigInt in the smallest unit (18 decimals). Trims trailing zeros.
    var s = value.toString().padStart(19, "0");
    var whole = s.slice(0, -18) || "0";
    var frac = s.slice(-18).replace(/0+$/, "").slice(0, maxDecimals);
    return frac ? whole + "." + frac : whole;
  }
  function formatPrice(price, currency) {
    if (currency === 0) return formatUnits(price, 5) + " BNB";
    return formatUnits(price, 2) + " USDT";
  }
  function parsePrice(str) {
    // Human price ("0.05", "50") -> BigInt smallest units (18 decimals).
    // Returns null on invalid input.
    if (!/^\d+(\.\d{1,18})?$/.test(str.trim())) return null;
    var parts = str.trim().split(".");
    var whole = BigInt(parts[0]) * (10n ** 18n);
    var frac = parts[1] ? BigInt(parts[1].padEnd(18, "0")) : 0n;
    var value = whole + frac;
    return value > 0n ? value : null;
  }
  function hexPadUint(value) {
    return value.toString(16).padStart(64, "0");
  }
  function hexPadAddress(addr) {
    return addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  }

  // ---------------------------------------------------------------------------
  // RPC helpers (rotating public endpoints, like app.js)
  // ---------------------------------------------------------------------------
  async function rpcCall(method, params) {
    var lastErr = null;
    for (var i = 0; i < CONFIG.RPCS.length; i++) {
      try {
        var res = await fetch(CONFIG.RPCS[i], {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: method, params: params })
        });
        var json = await res.json();
        if (json.error) throw new Error(json.error.message || "RPC error");
        if (json.result === undefined || json.result === null) throw new Error("Empty RPC result");
        return json.result;
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr || new Error("All RPC endpoints failed");
  }
  function ethCall(to, data) {
    return rpcCall("eth_call", [{ to: to, data: data }, "latest"]);
  }
  async function ethBlockNumber() {
    var hex = await rpcCall("eth_blockNumber", []);
    return parseInt(hex, 16);
  }

  // ---------------------------------------------------------------------------
  // Token metadata (fully on-chain: data-URI JSON with an SVG image)
  // ---------------------------------------------------------------------------
  async function fetchMeta(collection, tokenId) {
    var key = collection.toLowerCase() + ":" + tokenId.toString();
    if (metaCache[key]) return metaCache[key];
    var fallback = { name: "AgentHaven Pass #" + tokenId.toString(), image: "", handle: "" };
    try {
      var hex = await ethCall(collection, CONFIG.SEL_TOKEN_URI + hexPadUint(tokenId));
      var uri = decodeString(hex);
      var prefix = "data:application/json;base64,";
      if (uri.indexOf(prefix) !== 0) return fallback;
      var json = JSON.parse(atob(uri.slice(prefix.length)));
      var handle = "";
      (json.attributes || []).forEach(function (a) {
        if (a.trait_type === "Agent ID") handle = a.value;
      });
      var meta = {
        name: json.name || fallback.name,
        image: json.image || "",
        handle: handle
      };
      metaCache[key] = meta;
      return meta;
    } catch (e) {
      return fallback;
    }
  }

  // ---------------------------------------------------------------------------
  // Listings: load + render
  // ---------------------------------------------------------------------------
  var listingsGrid = $("listingsGrid");
  var listingsMeta = $("listingsMeta");
  var buyResult = $("buyResult");

  async function loadListings() {
    if (!isDeployed) {
      listingsGrid.innerHTML = '<div class="skeleton">The market opens after the market contract is deployed.</div>';
      listingsMeta.textContent = "";
      return;
    }
    listingsGrid.innerHTML = '<div class="skeleton">Loading live listings from BSC…</div>';
    try {
      var countHex = await ethCall(CONFIG.MARKET_CONTRACT, CONFIG.SEL_ACTIVE_COUNT);
      var count = Number(wordToBigInt(countHex, 0));
      if (count === 0) {
        allListings = [];
        listingsMeta.textContent = "0 active listings";
        renderListings();
        return;
      }
      var idsHex = await ethCall(
        CONFIG.MARKET_CONTRACT,
        CONFIG.SEL_ACTIVE_IDS + hexPadUint(0n) + hexPadUint(BigInt(Math.min(count, 200)))
      );
      var ids = decodeUintArray(idsHex);
      var listings = await Promise.all(ids.map(async function (id) {
        var hex = await ethCall(CONFIG.MARKET_CONTRACT, CONFIG.SEL_GET_LISTING + hexPadUint(id));
        var l = decodeListing(hex);
        l.meta = await fetchMeta(l.collection, l.tokenId);
        return l;
      }));
      allListings = listings.filter(function (l) { return l.active; });
      listingsMeta.textContent = allListings.length + " active listing" + (allListings.length === 1 ? "" : "s");
      renderListings();
      renderMyListings();
    } catch (e) {
      listingsGrid.innerHTML = "";
      listingsMeta.textContent = "";
      buyResult.innerHTML =
        '<span class="bad">Could not load listings.</span> ' +
        "The BSC network may be temporarily unreachable — try Refresh. (" + esc(e.message || "RPC error") + ")";
    }
  }

  function filteredListings() {
    var colFilter = $("filterCollection").value;
    var curFilter = $("filterCurrency").value;
    var sort = $("sortOrder").value;
    var list = allListings.filter(function (l) {
      if (colFilter !== "all" && collectionKey(l.collection) !== colFilter) return false;
      if (curFilter !== "all") {
        if (curFilter === "BNB" && l.currency !== 0) return false;
        if (curFilter === "USDT" && l.currency !== 1) return false;
      }
      return true;
    });
    list.sort(function (a, b) {
      if (sort === "newest") return Number(b.id - a.id);
      // Price sort: group by currency first (BNB and USDT amounts are not
      // directly comparable), then by price within each currency.
      if (a.currency !== b.currency) {
        return sort === "price-asc" ? a.currency - b.currency : b.currency - a.currency;
      }
      if (a.price === b.price) return 0;
      var cmp = a.price < b.price ? -1 : 1;
      return sort === "price-asc" ? cmp : -cmp;
    });
    return list;
  }

  function listingCard(l, opts) {
    opts = opts || {};
    var isOwn = connectedAccount && l.seller.toLowerCase() === connectedAccount.toLowerCase();
    var img = l.meta.image
      ? '<img class="listing-img" src="' + esc(l.meta.image) + '" alt="' + esc(l.meta.name) + '">'
      : '<div class="listing-img listing-img-empty">AGENTHAVEN</div>';
    var handle = l.meta.handle ? "<div>" + esc(l.meta.handle) + "</div>" : "";
    var action = "";
    if (opts.cancel) {
      action = '<button class="btn btn-danger small" type="button" data-cancel="' +
        l.id.toString() + '">Cancel listing</button>';
    } else if (isOwn) {
      action = '<span class="tiny muted">Your listing</span>';
    } else if (isDeployed) {
      action = '<button class="btn btn-gold small" type="button" data-buy="' +
        l.id.toString() + '">Buy</button>';
    }
    return '<div class="listing-card">' + img +
      '<h3>' + esc(l.meta.name) + "</h3>" +
      '<div class="listing-meta"><span class="badge ' +
      (collectionKey(l.collection) === "v1" ? "badge-other" : "badge-free") + '">' +
      esc(collectionName(l.collection)) + "</span>" + handle +
      '<span>Seller <a href="' + bscscan(l.seller) + '" target="_blank" rel="noopener">' +
      esc(shortAddr(l.seller)) + "</a></span></div>" +
      '<div class="listing-price">' + esc(formatPrice(l.price, l.currency)) + "</div>" +
      '<div class="listing-actions">' + action + "</div></div>";
  }

  function renderListings() {
    var list = filteredListings();
    if (!list.length) {
      listingsGrid.innerHTML = '<div class="skeleton">' +
        (allListings.length === 0
          ? "No Passes listed yet — be the first to list one below."
          : "No listings match these filters.") + "</div>";
      return;
    }
    listingsGrid.innerHTML = list.map(function (l) { return listingCard(l); }).join("");
  }

  ["filterCollection", "filterCurrency", "sortOrder"].forEach(function (id) {
    $(id).addEventListener("change", renderListings);
  });
  $("refreshBtn").addEventListener("click", function () {
    buyResult.innerHTML = "";
    loadListings();
  });

  // Buy / cancel buttons are rendered dynamically — delegate clicks.
  document.addEventListener("click", function (e) {
    var buyBtn = e.target.closest("[data-buy]");
    if (buyBtn) { buyListing(BigInt(buyBtn.getAttribute("data-buy"))); return; }
    var cancelBtn = e.target.closest("[data-cancel]");
    if (cancelBtn) { cancelListing(BigInt(cancelBtn.getAttribute("data-cancel"))); }
  });

  // ---------------------------------------------------------------------------
  // Wallet connect + chain handling (same pattern as app.js)
  // ---------------------------------------------------------------------------
  var sellResult = $("sellResult");
  var cancelResult = $("cancelResult");

  function refreshConnectButton() {
    var btn = $("connectBtn");
    var findBtn = $("findBtn");
    if (connectedAccount) {
      btn.textContent = "Connected: " + shortAddr(connectedAccount);
      findBtn.disabled = !isDeployed;
    } else {
      btn.textContent = "Connect wallet";
      findBtn.disabled = true;
    }
  }

  async function connectWallet() {
    if (!window.ethereum) {
      sellResult.innerHTML =
        '<span class="bad">No wallet found.</span> Install MetaMask or open this page in the Binance Wallet browser, then try again.';
      return null;
    }
    try {
      var accounts = await window.ethereum.request({ method: "eth_requestAccounts" });
      if (!accounts || !accounts.length) return null;
      connectedAccount = accounts[0];
      refreshConnectButton();
      renderListings();
      renderMyListings();
      return connectedAccount;
    } catch (e) {
      sellResult.innerHTML =
        '<span class="bad">Wallet connection was rejected.</span> Nothing was sent.';
      return null;
    }
  }

  $("connectBtn").addEventListener("click", connectWallet);

  if (window.ethereum) {
    window.ethereum.on("accountsChanged", function (accounts) {
      connectedAccount = accounts && accounts.length ? accounts[0] : null;
      myPasses = [];
      $("myPasses").innerHTML = "";
      refreshConnectButton();
      renderListings();
      renderMyListings();
    });
    window.ethereum.on("chainChanged", function () { window.location.reload(); });
  }

  async function ensureChain(resultEl) {
    var chainId = await window.ethereum.request({ method: "eth_chainId" });
    if (parseInt(chainId, 16) === CONFIG.CHAIN_ID) return true;
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: "0x38" }] // 56 = BSC mainnet
      });
      return true;
    } catch (e) {
      resultEl.innerHTML =
        '<span class="bad">Please switch your wallet to BNB Smart Chain (chain ID 56) and try again.</span>';
      return false;
    }
  }

  async function pollReceipt(txHash, resultEl, doneText, onConfirmed) {
    for (var i = 0; i < 30; i++) {
      await new Promise(function (r) { setTimeout(r, 3000); });
      try {
        var receipt = await window.ethereum.request({
          method: "eth_getTransactionReceipt", params: [txHash]
        });
        if (receipt) {
          if (receipt.status === "0x1") {
            resultEl.innerHTML = doneText;
            if (onConfirmed) onConfirmed();
          } else {
            resultEl.innerHTML =
              '<span class="bad">Transaction reverted on-chain.</span> Nothing changed. ' +
              'See <a href="https://bscscan.com/tx/' + esc(txHash) +
              '" target="_blank" rel="noopener">BscScan</a> for details.';
          }
          return receipt.status === "0x1";
        }
      } catch (e) { /* keep polling */ }
    }
    resultEl.innerHTML += "<br><span class=\"pending\">Still pending after ~90s — check the BscScan link above.</span>";
    return false;
  }

  function txErrorHtml(e, what) {
    var msg = (e && e.message) || "Transaction failed";
    if (/rejected|denied|user/i.test(msg)) {
      return '<span class="bad">Transaction rejected in your wallet.</span> Nothing was sent.';
    }
    return '<span class="bad">' + esc(what) + " failed:</span> " + esc(msg);
  }

  // ---------------------------------------------------------------------------
  // Buying
  // ---------------------------------------------------------------------------
  async function buyListing(listingId) {
    if (!isDeployed) return;
    var l = allListings.find(function (x) { return x.id === listingId; });
    if (!l) return;
    var account = connectedAccount || (await connectWallet());
    if (!account) return;
    if (l.seller.toLowerCase() === account.toLowerCase()) {
      buyResult.innerHTML = '<span class="bad">You cannot buy your own listing.</span>';
      return;
    }
    buyResult.innerHTML = '<span class="pending">Preparing your purchase…</span>';
    try {
      if (!(await ensureChain(buyResult))) return;
      // Re-read the listing right before buying: it may have sold already.
      var hex = await ethCall(CONFIG.MARKET_CONTRACT, CONFIG.SEL_GET_LISTING + hexPadUint(listingId));
      var fresh = decodeListing(hex);
      if (!fresh.active) {
        buyResult.innerHTML = '<span class="bad">This listing is no longer active.</span> Refreshing…';
        loadListings();
        return;
      }
      if (fresh.price !== l.price || fresh.currency !== l.currency) {
        buyResult.innerHTML = '<span class="bad">The listing changed since the page loaded.</span> Refreshing…';
        loadListings();
        return;
      }

      if (l.currency === 1) {
        // USDT: two steps. Step 1 — approve EXACTLY the listed amount
        // (no unlimited approvals), but only if the current allowance is short.
        var allowHex = await ethCall(
          CONFIG.USDT,
          CONFIG.SEL_ALLOWANCE + hexPadAddress(account) + hexPadAddress(CONFIG.MARKET_CONTRACT)
        );
        var allowance = wordToBigInt(allowHex, 0);
        if (allowance < l.price) {
          buyResult.innerHTML =
            '<span class="pending">Step 1 of 2: approve exactly ' + esc(formatPrice(l.price, 1)) +
            " for the market contract…</span> (your wallet will ask you to confirm)";
          var approveTx = await window.ethereum.request({
            method: "eth_sendTransaction",
            params: [{
              from: account,
              to: CONFIG.USDT,
              value: "0x0",
              data: CONFIG.SEL_APPROVE + hexPadAddress(CONFIG.MARKET_CONTRACT) + hexPadUint(l.price)
            }]
          });
          buyResult.innerHTML =
            '<span class="pending">Approval sent — waiting for confirmation…</span> ' +
            '(<a href="https://bscscan.com/tx/' + esc(approveTx) + '" target="_blank" rel="noopener">BscScan</a>)';
          var approved = await pollReceipt(approveTx, buyResult,
            '<span class="ok">Approval confirmed ✓</span> — now confirm the purchase in your wallet.',
            null);
          if (!approved) return;
        }
      }

      // Step 2 (or the only step for BNB): buy. BNB sends exactly the price;
      // USDT sends 0 BNB (the price is pulled from the approval).
      var valueHex = l.currency === 0 ? "0x" + l.price.toString(16) : "0x0";
      buyResult.innerHTML = '<span class="pending">Confirm the purchase in your wallet…</span>';
      var txHash = await window.ethereum.request({
        method: "eth_sendTransaction",
        params: [{
          from: account,
          to: CONFIG.MARKET_CONTRACT,
          value: valueHex,
          data: CONFIG.SEL_BUY + hexPadUint(listingId)
        }]
      });
      buyResult.innerHTML =
        '<span class="ok">Purchase sent ✓</span> — <a href="https://bscscan.com/tx/' +
        esc(txHash) + '" target="_blank" rel="noopener">' + esc(txHash) + "</a><br>" +
        '<span class="pending">Waiting for confirmation…</span>';
      await pollReceipt(txHash, buyResult,
        '<span class="ok">✓ Purchase confirmed!</span> The Pass is now in your wallet. ' +
        'Fee paid to the project: 2.5% of the sale price (from the seller).',
        function () { loadListings(); });
    } catch (e) {
      buyResult.innerHTML = txErrorHtml(e, "Purchase");
    }
  }

  // ---------------------------------------------------------------------------
  // Cancelling
  // ---------------------------------------------------------------------------
  async function cancelListing(listingId) {
    if (!isDeployed) return;
    var account = connectedAccount || (await connectWallet());
    if (!account) return;
    cancelResult.innerHTML = '<span class="pending">Preparing the cancellation…</span>';
    try {
      if (!(await ensureChain(cancelResult))) return;
      var txHash = await window.ethereum.request({
        method: "eth_sendTransaction",
        params: [{
          from: account,
          to: CONFIG.MARKET_CONTRACT,
          value: "0x0",
          data: CONFIG.SEL_CANCEL + hexPadUint(listingId)
        }]
      });
      cancelResult.innerHTML =
        '<span class="ok">Cancellation sent ✓</span> — <a href="https://bscscan.com/tx/' +
        esc(txHash) + '" target="_blank" rel="noopener">' + esc(txHash) + "</a><br>" +
        '<span class="pending">Waiting for confirmation…</span>';
      await pollReceipt(txHash, cancelResult,
        '<span class="ok">✓ Listing cancelled.</span> Your Pass is back in your wallet.',
        function () { loadListings(); });
    } catch (e) {
      cancelResult.innerHTML = txErrorHtml(e, "Cancellation");
    }
  }

  function renderMyListings() {
    var grid = $("myListingsGrid");
    if (!connectedAccount) {
      grid.innerHTML = '<div class="skeleton">Connect your wallet to see your listings.</div>';
      return;
    }
    var mine = allListings.filter(function (l) {
      return l.seller.toLowerCase() === connectedAccount.toLowerCase();
    });
    if (!mine.length) {
      grid.innerHTML = '<div class="skeleton">You have no active listings.</div>';
      return;
    }
    grid.innerHTML = mine.map(function (l) { return listingCard(l, { cancel: true }); }).join("");
  }

  // ---------------------------------------------------------------------------
  // Finding owned Passes (log scan + ownership verification)
  // ---------------------------------------------------------------------------
  var myPassesEl = $("myPasses");

  async function scanOwnedPasses() {
    // Find every Pass ever transferred TO this wallet (mints and purchases),
    // then keep only the ones it still owns (a Pass could have been sold on).
    var latest = await ethBlockNumber();
    var paddedUser = hexPadAddress(connectedAccount);
    var chunks = [];
    for (var from = CONFIG.DEPLOY_BLOCK; from <= latest; from += CONFIG.LOG_CHUNK) {
      chunks.push([from, Math.min(from + CONFIG.LOG_CHUNK - 1, latest)]);
    }
    var found = {}; // "collection:tokenId" -> collection
    var failedChunks = 0;
    // Run chunks in small parallel batches so the scan stays fast without
    // hammering the RPC.
    for (var i = 0; i < chunks.length; i += 6) {
      var batch = chunks.slice(i, i + 6).map(function (c) {
        return Promise.all([
          rpcCall("eth_getLogs", [{
            fromBlock: "0x" + c[0].toString(16),
            toBlock: "0x" + c[1].toString(16),
            address: CONFIG.PASS_V1,
            topics: [CONFIG.TOPIC_TRANSFER, null, "0x" + paddedUser]
          }]),
          rpcCall("eth_getLogs", [{
            fromBlock: "0x" + c[0].toString(16),
            toBlock: "0x" + c[1].toString(16),
            address: CONFIG.PASS_V2,
            topics: [CONFIG.TOPIC_TRANSFER, null, "0x" + paddedUser]
          }])
        ]).catch(function () { failedChunks++; return [[], []]; });
      });
      var results = await Promise.all(batch);
      results.forEach(function (pair) {
        [CONFIG.PASS_V1, CONFIG.PASS_V2].forEach(function (collection, idx) {
          (pair[idx] || []).forEach(function (log) {
            var tokenId = BigInt(log.topics[3]);
            found[collection.toLowerCase() + ":" + tokenId.toString()] = {
              collection: collection, tokenId: tokenId
            };
          });
        });
      });
      sellResult.innerHTML = '<span class="pending">Scanning on-chain history… ' +
        Math.min(100, Math.round(((i + 6) / chunks.length) * 100)) + "%</span>";
    }
    var candidates = Object.keys(found).map(function (k) { return found[k]; });
    // Verify current ownership (a Pass may have been transferred away since).
    var owned = [];
    for (var j = 0; j < candidates.length; j += 10) {
      var slice = candidates.slice(j, j + 10);
      var owners = await Promise.all(slice.map(function (c) {
        return ethCall(c.collection, CONFIG.SEL_OWNER_OF + hexPadUint(c.tokenId))
          .then(function (hex) { return wordToAddress(hex, 0); })
          .catch(function () { return null; });
      }));
      owners.forEach(function (o, k) {
        if (o && o.toLowerCase() === connectedAccount.toLowerCase()) owned.push(slice[k]);
      });
    }
    return { owned: owned, partial: failedChunks > 0 };
  }

  async function findMyPasses() {
    if (!isDeployed || !connectedAccount) return;
    myPassesEl.innerHTML = "";
    sellResult.innerHTML = '<span class="pending">Checking your Pass balances…</span>';
    try {
      var balV1 = wordToBigInt(
        await ethCall(CONFIG.PASS_V1, CONFIG.SEL_BALANCE_OF + hexPadAddress(connectedAccount)), 0);
      var balV2 = wordToBigInt(
        await ethCall(CONFIG.PASS_V2, CONFIG.SEL_BALANCE_OF + hexPadAddress(connectedAccount)), 0);
      if (balV1 === 0n && balV2 === 0n) {
        sellResult.innerHTML =
          '<span class="pending">This wallet holds no AgentHaven Pass.</span> ' +
          'Claim one on the <a href="index.html#claim">Claim page</a> first, or buy one above.';
        return;
      }
      var scan = await scanOwnedPasses();
      myPasses = scan.owned;
      if (!myPasses.length) {
        sellResult.innerHTML =
          '<span class="bad">Could not identify your Pass token IDs from the on-chain history.</span> ' +
          "Use the manual entry below with the token ID from your wallet or BscScan.";
        return;
      }
      for (var i = 0; i < myPasses.length; i++) {
        myPasses[i].meta = await fetchMeta(myPasses[i].collection, myPasses[i].tokenId);
      }
      sellResult.innerHTML = scan.partial
        ? '<span class="pending">Found ' + myPasses.length + " Pass(es) — the history scan was partial (some RPC ranges failed), so a Pass could be missing. Use manual entry if one is missing.</span>"
        : '<span class="ok">Found ' + myPasses.length + " Pass(es) ✓</span>";
      renderMyPasses();
    } catch (e) {
      sellResult.innerHTML =
        '<span class="bad">Could not scan the on-chain history.</span> ' +
        "Use the manual entry below with the token ID from your wallet or BscScan. (" + esc(e.message || "RPC error") + ")";
    }
  }

  $("findBtn").addEventListener("click", findMyPasses);

  function renderMyPasses() {
    myPassesEl.innerHTML = myPasses.map(function (p) {
      var key = collectionKey(p.collection) + "-" + p.tokenId.toString();
      var img = p.meta.image
        ? '<img class="listing-img" src="' + esc(p.meta.image) + '" alt="' + esc(p.meta.name) + '">'
        : '<div class="listing-img listing-img-empty">AGENTHAVEN</div>';
      return '<div class="listing-card">' + img +
        "<h3>" + esc(p.meta.name) + "</h3>" +
        '<div class="listing-meta"><span class="badge ' +
        (collectionKey(p.collection) === "v1" ? "badge-other" : "badge-free") + '">' +
        esc(collectionName(p.collection)) + "</span>" +
        (p.meta.handle ? "<span>" + esc(p.meta.handle) + "</span>" : "") + "</div>" +
        '<div class="row list-form">' +
        '<input type="text" id="price-' + key + '" inputmode="decimal" placeholder="Price (e.g. 0.05)">' +
        '<select id="cur-' + key + '" aria-label="Currency"><option value="0">BNB</option><option value="1">USDT</option></select>' +
        '<button class="btn btn-gold small" type="button" data-list="' + key + '">List for sale</button>' +
        "</div>" +
        '<p class="tiny muted">Fee on sale: 2.5% · You receive 97.5% of the price.</p>' +
        "</div>";
    }).join("");
  }

  // List buttons are rendered dynamically — delegate clicks.
  document.addEventListener("click", function (e) {
    var listBtn = e.target.closest("[data-list]");
    if (listBtn) {
      var parts = listBtn.getAttribute("data-list").split("-");
      listPass(parts[0], BigInt(parts[1]));
    }
  });

  async function listPass(collectionKeyStr, tokenId) {
    if (!isDeployed) return;
    var key = collectionKeyStr + "-" + tokenId.toString();
    var priceInput = $("price-" + key);
    var currency = Number($("cur-" + key).value);
    var price = parsePrice(priceInput.value);
    if (price === null) {
      sellResult.innerHTML =
        '<span class="bad">Enter a valid price greater than 0</span> (up to 18 decimal places).';
      return;
    }
    var collection = collectionKeyStr === "v1" ? CONFIG.PASS_V1 : CONFIG.PASS_V2;
    var account = connectedAccount || (await connectWallet());
    if (!account) return;
    sellResult.innerHTML = '<span class="pending">Preparing your listing…</span>';
    try {
      if (!(await ensureChain(sellResult))) return;
      // Re-verify ownership right before listing.
      var ownerHex = await ethCall(collection, CONFIG.SEL_OWNER_OF + hexPadUint(tokenId));
      if (wordToAddress(ownerHex, 0).toLowerCase() !== account.toLowerCase()) {
        sellResult.innerHTML =
          '<span class="bad">This wallet does not own that Pass right now.</span> ' +
          "It may already be listed (see My listings) or transferred away.";
        return;
      }
      // Approve the market for THIS token only (single-token approval —
      // no blanket operator approval), if not already approved.
      var approvedHex = await ethCall(collection, CONFIG.SEL_GET_APPROVED + hexPadUint(tokenId));
      if (wordToAddress(approvedHex, 0).toLowerCase() !== CONFIG.MARKET_CONTRACT.toLowerCase()) {
        sellResult.innerHTML =
          '<span class="pending">Step 1 of 2: approve the market contract for this one Pass…</span> ' +
          "(your wallet will ask you to confirm)";
        var approveTx = await window.ethereum.request({
          method: "eth_sendTransaction",
          params: [{
            from: account,
            to: collection,
            value: "0x0",
            data: CONFIG.SEL_APPROVE + hexPadAddress(CONFIG.MARKET_CONTRACT) + hexPadUint(tokenId)
          }]
        });
        sellResult.innerHTML =
          '<span class="pending">Approval sent — waiting for confirmation…</span> ' +
          '(<a href="https://bscscan.com/tx/' + esc(approveTx) + '" target="_blank" rel="noopener">BscScan</a>)';
        var approved = await pollReceipt(approveTx, sellResult,
          '<span class="ok">Approval confirmed ✓</span> — now confirm the listing in your wallet.',
          null);
        if (!approved) return;
      }
      sellResult.innerHTML = '<span class="pending">Confirm the listing in your wallet…</span>';
      var txHash = await window.ethereum.request({
        method: "eth_sendTransaction",
        params: [{
          from: account,
          to: CONFIG.MARKET_CONTRACT,
          value: "0x0",
          data: CONFIG.SEL_LIST + hexPadAddress(collection) + hexPadUint(tokenId) +
            hexPadUint(price) + hexPadUint(BigInt(currency))
        }]
      });
      sellResult.innerHTML =
        '<span class="ok">Listing sent ✓</span> — <a href="https://bscscan.com/tx/' +
        esc(txHash) + '" target="_blank" rel="noopener">' + esc(txHash) + "</a><br>" +
        '<span class="pending">Waiting for confirmation…</span>';
      await pollReceipt(txHash, sellResult,
        '<span class="ok">✓ Your Pass is listed!</span> It now shows in the listings above.',
        function () { loadListings(); findMyPasses(); });
    } catch (e) {
      sellResult.innerHTML = txErrorHtml(e, "Listing");
    }
  }

  // ---------------------------------------------------------------------------
  // Manual token-ID entry
  // ---------------------------------------------------------------------------
  $("manualBtn").addEventListener("click", async function () {
    var manualResult = $("manualResult");
    var account = connectedAccount || (await connectWallet());
    if (!account) return;
    var collection = $("manualCollection").value === "v1" ? CONFIG.PASS_V1 : CONFIG.PASS_V2;
    var tokenIdStr = $("manualTokenId").value.trim();
    if (!/^\d+$/.test(tokenIdStr) || BigInt(tokenIdStr) === 0n) {
      manualResult.innerHTML = '<span class="bad">Enter a valid token ID (a positive number).</span>';
      return;
    }
    var tokenId = BigInt(tokenIdStr);
    manualResult.innerHTML = '<span class="pending">Checking ownership on-chain…</span>';
    try {
      var ownerHex = await ethCall(collection, CONFIG.SEL_OWNER_OF + hexPadUint(tokenId));
      var tokenOwner = wordToAddress(ownerHex, 0);
      if (tokenOwner.toLowerCase() === CONFIG.MARKET_CONTRACT.toLowerCase()) {
        manualResult.innerHTML =
          '<span class="pending">That Pass is currently listed in the market.</span> See My listings below.';
        return;
      }
      if (tokenOwner.toLowerCase() !== account.toLowerCase()) {
        manualResult.innerHTML =
          '<span class="bad">This wallet does not own that Pass.</span> Owner: ' +
          esc(shortAddr(tokenOwner)) + ".";
        return;
      }
      var meta = await fetchMeta(collection, tokenId);
      var already = myPasses.some(function (p) {
        return p.collection === collection && p.tokenId === tokenId;
      });
      if (!already) {
        myPasses.push({ collection: collection, tokenId: tokenId, meta: meta });
        renderMyPasses();
      }
      manualResult.innerHTML =
        '<span class="ok">✓ Verified — ' + esc(meta.name) + ' is yours.</span> Set a price above to list it.';
    } catch (e) {
      manualResult.innerHTML =
        '<span class="bad">Could not verify ownership.</span> The token may not exist, or the BSC network is unreachable. (' +
        esc(e.message || "RPC error") + ")";
    }
  });

  // ---------------------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------------------
  function renderDeployState() {
    var note = $("deployNote");
    var marketAddr = $("marketAddr");
    var marketLinks = $("marketLinks");
    var feeLine = $("feeLine");
    if (!isDeployed) {
      marketAddr.textContent = "not deployed yet";
      feeLine.textContent = "2.5% (at launch)";
      note.innerHTML =
        "<strong>The market opens soon.</strong> The market contract has not been deployed yet, " +
        "so buying and listing are not open. This page already shows how it will work — " +
        "check back after deployment.";
      $("findBtn").disabled = true;
      loadListings();
      renderMyListings();
      return;
    }
    marketAddr.textContent = CONFIG.MARKET_CONTRACT;
    marketLinks.innerHTML =
      ' (<a href="' + bscscan(CONFIG.MARKET_CONTRACT) + '" target="_blank" rel="noopener">BscScan</a>)';
    note.textContent = "";
    ethCall(CONFIG.MARKET_CONTRACT, CONFIG.SEL_FEE_BPS)
      .then(function (hex) {
        var bps = Number(wordToBigInt(hex, 0));
        feeLine.textContent = (bps / 100).toFixed(2).replace(/\.?0+$/, "") + "%";
      })
      .catch(function () { feeLine.textContent = "2.5%"; });
    refreshConnectButton();
    loadListings();
    renderMyListings();
  }

  renderDeployState();
})();
