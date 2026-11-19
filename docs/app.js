// AgentHaven — vanilla JS, zero dependencies, no trackers, no API keys.
// Reads go through public BSC RPC endpoints; writes go through the user's own
// injected wallet (MetaMask / Binance Wallet). This site never asks for a
// seed phrase or private key.
(function () {
  "use strict";

  // ---------------------------------------------------------------------------
  // CONFIG — fill in PASS_CONTRACT after deployment (see README).
  // ---------------------------------------------------------------------------
  var CONFIG = {
    REGISTRY: "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F", // official Agent ID registry (BSC)
    // >>> DEPLOYMENT: replace the zero address below with the deployed
    // AgentHavenPass contract address (BSC mainnet, chain ID 56). <<<
    PASS_CONTRACT: "0xf8118d518a228B704947eCf89C264B4F4F79aC5D",
    CHAIN_ID: 56,
    RPCS: [
      "https://bsc-dataseed.binance.org/",
      "https://bsc-dataseed1.defibit.io/",
      "https://bsc-dataseed1.ninicoin.io/"
    ],
    PROJECTS_URL: "https://mints-bnb.pages.dev/projects.json",
    // Function selectors (keccak256(signature)[0:4]):
    SEL_BALANCE_OF: "0x70a08231", // balanceOf(address)
    SEL_HANDLE_OF: "0xc50a1514",  // handleOf(address)
    SEL_CLAIM: "0x4e71d92d",      // claim()
    SEL_CLAIMED: "0xc884ef83"     // claimed(address) — verified via cast
  };

  var ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
  var isDeployed = CONFIG.PASS_CONTRACT.toLowerCase() !== ZERO_ADDRESS;

  var $ = function (id) { return document.getElementById(id); };
  var connectedAccount = null;

  // ---------------------------------------------------------------------------
  // Small helpers
  // ---------------------------------------------------------------------------
  function isAddress(s) {
    return typeof s === "string" && /^0x[0-9a-fA-F]{40}$/.test(s.trim());
  }
  function shortAddr(a) {
    return a.slice(0, 6) + "…" + a.slice(-4);
  }
  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function bscscan(addr) {
    return "https://bscscan.com/address/" + addr;
  }

  // ABI-encode a single address argument.
  function encodeAddressArg(selector, addr) {
    return selector + addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  }
  // Decode a uint256 return value.
  function decodeUint(hex) {
    if (!hex || hex === "0x") return 0;
    return parseInt(hex.slice(-64), 16);
  }
  // Decode a string return value (offset, length, bytes).
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

  // eth_call against the RPC list, rotating on failure.
  async function ethCall(to, data) {
    var lastErr = null;
    for (var i = 0; i < CONFIG.RPCS.length; i++) {
      try {
        var res = await fetch(CONFIG.RPCS[i], {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            jsonrpc: "2.0", id: 1, method: "eth_call",
            params: [{ to: to, data: data }, "latest"]
          })
        });
        var json = await res.json();
        if (json.error) throw new Error(json.error.message || "RPC error");
        if (typeof json.result !== "string") throw new Error("Empty RPC result");
        return json.result;
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr || new Error("All RPC endpoints failed");
  }

  async function checkAgentId(address) {
    var balHex = await ethCall(CONFIG.REGISTRY, encodeAddressArg(CONFIG.SEL_BALANCE_OF, address));
    var balance = decodeUint(balHex);
    var handle = "";
    if (balance > 0) {
      var handleHex = await ethCall(CONFIG.REGISTRY, encodeAddressArg(CONFIG.SEL_HANDLE_OF, address));
      handle = decodeString(handleHex);
    }
    return { balance: balance, handle: handle };
  }

  async function hasClaimed(address) {
    if (!isDeployed) return null;
    var hex = await ethCall(CONFIG.PASS_CONTRACT, encodeAddressArg(CONFIG.SEL_CLAIMED, address));
    return decodeUint(hex) > 0;
  }

  // ---------------------------------------------------------------------------
  // Agent ID status check
  // ---------------------------------------------------------------------------
  var checkResult = $("checkResult");

  async function runCheck(address) {
    checkResult.innerHTML = '<span class="pending">Checking the registry on-chain…</span>';
    try {
      var info = await checkAgentId(address);
      var claimed = null;
      if (info.balance > 0 && isDeployed) {
        try { claimed = await hasClaimed(address); } catch (e) { claimed = null; }
      }
      if (info.balance > 0) {
        var name = info.handle ? esc(info.handle) + ".ai" : "(name not resolved)";
        var extra = "";
        if (claimed === true) extra = " · <span class=\"ok\">Pass already claimed ✓</span>";
        else if (claimed === false) extra = " · Pass not claimed yet — you can claim below.";
        checkResult.innerHTML =
          '<span class="ok">✓ Agent ID holder</span> — <strong>' + name + "</strong> " +
          "(<a href=\"" + bscscan(address) + "\" target=\"_blank\" rel=\"noopener\">" + esc(shortAddr(address)) + "</a>)" + extra;
      } else {
        checkResult.innerHTML =
          '<span class="bad">✗ No Agent ID</span> — this address holds no .ai Agent ID, so it cannot claim a Pass. ' +
          "Claim a free Agent ID first in the Binance app (Wallet → Agent ID banner).";
      }
    } catch (e) {
      checkResult.innerHTML =
        '<span class="bad">Could not reach the BSC network.</span> ' +
        "Please check your connection and try again. (" + esc(e.message || "RPC error") + ")";
    }
  }

  $("checkBtn").addEventListener("click", function () {
    var addr = $("addrInput").value.trim();
    if (!isAddress(addr)) {
      checkResult.innerHTML = '<span class="bad">Please enter a valid BSC address (0x…40 hex characters).</span>';
      return;
    }
    runCheck(addr);
  });
  $("addrInput").addEventListener("keydown", function (e) {
    if (e.key === "Enter") $("checkBtn").click();
  });

  // ---------------------------------------------------------------------------
  // Wallet connect + claim
  // ---------------------------------------------------------------------------
  var claimBtn = $("claimBtn");
  var claimResult = $("claimResult");

  function renderDeployState() {
    var passAddr = $("passAddr");
    var passLinks = $("passLinks");
    var note = $("deployNote");
    if (!isDeployed) {
      passAddr.textContent = "not deployed yet";
      note.textContent =
        "The Pass contract has not been deployed yet, so claiming is not open. " +
        "The Agent ID check above already works against the live registry. " +
        "Check back after deployment — the contract address will appear here.";
      claimBtn.disabled = true;
      claimBtn.textContent = "Claim opens after deployment";
      return;
    }
    passAddr.textContent = CONFIG.PASS_CONTRACT;
    passLinks.innerHTML =
      ' (<a href="' + bscscan(CONFIG.PASS_CONTRACT) + '" target="_blank" rel="noopener">BscScan</a>)';
    note.textContent = "";
    refreshClaimButton();
  }

  function refreshClaimButton() {
    if (!isDeployed) return;
    if (!connectedAccount) {
      claimBtn.disabled = true;
      claimBtn.textContent = "Connect wallet to claim";
    } else {
      claimBtn.disabled = false;
      claimBtn.textContent = "Claim free Pass (" + shortAddr(connectedAccount) + ")";
    }
  }

  async function connectWallet() {
    if (!window.ethereum) {
      claimResult.innerHTML =
        '<span class="bad">No wallet found.</span> Install MetaMask or open this page in the Binance Wallet browser, then try again.';
      checkResult.innerHTML = claimResult.innerHTML;
      return null;
    }
    try {
      var accounts = await window.ethereum.request({ method: "eth_requestAccounts" });
      if (!accounts || !accounts.length) return null;
      connectedAccount = accounts[0];
      $("addrInput").value = connectedAccount;
      refreshClaimButton();
      runCheck(connectedAccount);
      return connectedAccount;
    } catch (e) {
      claimResult.innerHTML =
        '<span class="bad">Wallet connection was rejected.</span> Nothing was sent.';
      return null;
    }
  }

  $("connectBtn").addEventListener("click", connectWallet);

  if (window.ethereum) {
    window.ethereum.on("accountsChanged", function (accounts) {
      connectedAccount = accounts && accounts.length ? accounts[0] : null;
      if (connectedAccount) $("addrInput").value = connectedAccount;
      refreshClaimButton();
    });
    window.ethereum.on("chainChanged", function () { window.location.reload(); });
  }

  claimBtn.addEventListener("click", async function () {
    if (!isDeployed) return;
    var account = connectedAccount || (await connectWallet());
    if (!account) return;
    claimResult.innerHTML = '<span class="pending">Preparing your claim…</span>';
    try {
      var chainId = await window.ethereum.request({ method: "eth_chainId" });
      if (parseInt(chainId, 16) !== CONFIG.CHAIN_ID) {
        try {
          await window.ethereum.request({
            method: "wallet_switchEthereumChain",
            params: [{ chainId: "0x38" }] // 56 = BSC mainnet
          });
        } catch (e) {
          claimResult.innerHTML =
            '<span class="bad">Please switch your wallet to BNB Smart Chain (chain ID 56) and try again.</span>';
          return;
        }
      }
      // Re-verify eligibility right before sending.
      var info = await checkAgentId(account);
      if (info.balance === 0) {
        claimResult.innerHTML =
          '<span class="bad">This wallet holds no Agent ID, so the claim would revert.</span> ' +
          "Claim a free Agent ID first, then come back.";
        return;
      }
      var already = await hasClaimed(account);
      if (already) {
        claimResult.innerHTML =
          '<span class="ok">You already claimed your Pass ✓</span> — one per wallet.';
        return;
      }
      // Single claim() call, value 0. The wallet shows the exact transaction
      // for the user to confirm; nothing is signed without confirmation.
      var txHash = await window.ethereum.request({
        method: "eth_sendTransaction",
        params: [{
          from: account,
          to: CONFIG.PASS_CONTRACT,
          value: "0x0",
          data: CONFIG.SEL_CLAIM
        }]
      });
      claimResult.innerHTML =
        '<span class="ok">Transaction sent ✓</span> — <a href="https://bscscan.com/tx/' +
        esc(txHash) + '" target="_blank" rel="noopener">' + esc(txHash) + "</a><br>" +
        '<span class="pending">Waiting for confirmation…</span>';
      pollReceipt(txHash);
    } catch (e) {
      var msg = (e && e.message) || "Transaction failed";
      if (/rejected|denied|user/i.test(msg)) {
        claimResult.innerHTML = '<span class="bad">Transaction rejected in your wallet.</span> Nothing was sent.';
      } else {
        claimResult.innerHTML = '<span class="bad">Claim failed:</span> ' + esc(msg);
      }
    }
  });

  async function pollReceipt(txHash) {
    for (var i = 0; i < 30; i++) {
      await new Promise(function (r) { setTimeout(r, 3000); });
      try {
        var receipt = await window.ethereum.request({
          method: "eth_getTransactionReceipt", params: [txHash]
        });
        if (receipt) {
          if (receipt.status === "0x1") {
            claimResult.innerHTML =
              '<span class="ok">✓ Pass claimed!</span> — <a href="https://bscscan.com/tx/' +
              esc(txHash) + '" target="_blank" rel="noopener">View on BscScan</a>. ' +
              "Your Pass shows your .ai name on-chain.";
          } else {
            claimResult.innerHTML =
              '<span class="bad">Transaction reverted on-chain.</span> No Pass was minted. ' +
              'See <a href="https://bscscan.com/tx/' + esc(txHash) +
              '" target="_blank" rel="noopener">BscScan</a> for details.';
          }
          return;
        }
      } catch (e) { /* keep polling */ }
    }
    claimResult.innerHTML += "<br><span class=\"pending\">Still pending after ~90s — check the BscScan link above.</span>";
  }

  // ---------------------------------------------------------------------------
  // Live free-mint list
  // ---------------------------------------------------------------------------
  var mintsList = $("mintsList");
  var mintsMeta = $("mintsMeta");
  var mintsError = $("mintsError");
  var mintsRetry = $("mintsRetry");
  var allProjects = [];
  var currentFilter = "free_live";

  function badgeFor(status) {
    if (status === "free_live") return '<span class="badge badge-free">Free live</span>';
    if (status === "paid") return '<span class="badge badge-paid">Paid</span>';
    if (status === "sold_out") return '<span class="badge badge-other">Sold out</span>';
    return '<span class="badge badge-other">' + esc(status || "Unknown") + "</span>";
  }

  function renderMints() {
    var list = currentFilter === "free_live"
      ? allProjects.filter(function (p) { return p.status === "free_live"; })
      : allProjects.slice();
    list.sort(function (a, b) { return (a.rank || 9999) - (b.rank || 9999); });
    if (!list.length) {
      mintsList.innerHTML = '<div class="skeleton">No projects in this view right now.</div>';
      return;
    }
    mintsList.innerHTML = list.map(function (p) {
      var links = "";
      if (p.contract) {
        links += '<a href="' + bscscan(p.contract) + '" target="_blank" rel="noopener">' +
          esc(shortAddr(p.contract)) + " ↗</a>";
      }
      if (p.website) {
        links += ' <a href="' + esc(p.website) + '" target="_blank" rel="noopener">Website ↗</a>';
      }
      var terms = p.mint_terms ? esc(p.mint_terms) : "See the project page for mint terms.";
      var kind = [p.kind, p.standard].filter(Boolean).join(" · ");
      return '<div class="mint"><h3>' + esc(p.name || "Unnamed") +
        ' <span class="rank">#' + esc(String(p.rank || "?")) + "</span></h3>" +
        "<div>" + badgeFor(p.status) + "</div>" +
        '<p class="terms">' + terms + "</p>" +
        '<div class="meta"><span>' + esc(kind) + "</span><span>" + links + "</span></div></div>";
    }).join("");
  }

  async function loadMints() {
    mintsList.innerHTML = '<div class="skeleton">Loading the live free-mint index…</div>';
    mintsError.classList.add("hidden");
    mintsRetry.classList.add("hidden");
    try {
      var res = await fetch(CONFIG.PROJECTS_URL, { cache: "no-store" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      var data = await res.json();
      allProjects = Array.isArray(data.projects) ? data.projects : [];
      var freeCount = allProjects.filter(function (p) { return p.status === "free_live"; }).length;
      mintsMeta.textContent =
        allProjects.length + " listed · " + freeCount + " free live" +
        (data.updated_at ? " · updated " + data.updated_at : "");
      renderMints();
    } catch (e) {
      mintsList.innerHTML = "";
      mintsError.classList.remove("hidden");
      mintsError.innerHTML =
        '<span class="bad">Could not load the free-mint index.</span> ' +
        "The list is fetched live from the public Colony index — it may be temporarily unreachable. " +
        "Try again in a moment.";
      mintsRetry.classList.remove("hidden");
    }
  }

  document.querySelectorAll(".chip").forEach(function (chip) {
    chip.addEventListener("click", function () {
      document.querySelectorAll(".chip").forEach(function (c) { c.classList.remove("active"); });
      chip.classList.add("active");
      currentFilter = chip.getAttribute("data-filter");
      renderMints();
    });
  });
  mintsRetry.addEventListener("click", loadMints);

  // ---------------------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------------------
  renderDeployState();
  loadMints();
})();
