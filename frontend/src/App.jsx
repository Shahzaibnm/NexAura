import { useCallback, useEffect, useState } from "react";
import { formatUnits } from "ethers";
import {
  addresses,
  getBrowserProvider,
  getContracts,
  switchToTargetNetwork,
  toUsdWei,
} from "./lib/contracts";
import "./App.css";

function shortAddr(addr) {
  return addr ? `${addr.slice(0, 6)}...${addr.slice(-4)}` : "";
}

export default function App() {
  const [account, setAccount] = useState(null);
  const [chainId, setChainId] = useState(null);
  const [status, setStatus] = useState(null); // { joined, referral, lastStake, usdtBalance, allowance }
  const [referralInput, setReferralInput] = useState("");
  const [stakeAmount, setStakeAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState(null); // { kind: 'error' | 'success' | 'info', text }

  const onCorrectNetwork = chainId === addresses.chainId;

  const refreshStatus = useCallback(async (addr) => {
    if (!addr || !onCorrectNetwork) {
      setStatus(null);
      return;
    }
    const provider = getBrowserProvider();
    const { usdt, staking } = getContracts(provider);
    const [info, usdtBalance, allowance] = await Promise.all([
      staking.userInfos(addr),
      usdt.balanceOf(addr),
      usdt.allowance(addr, addresses.staking),
    ]);
    setStatus({
      joined: info.joined,
      referral: info.referral,
      lastStake: formatUnits(info.lastStake, 18),
      usdtBalance: formatUnits(usdtBalance, 18),
      allowance: formatUnits(allowance, 18),
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chainId, onCorrectNetwork]);

  useEffect(() => {
    if (account) refreshStatus(account);
  }, [account, refreshStatus]);

  useEffect(() => {
    if (!window.ethereum) return;
    const handleAccountsChanged = (accs) => setAccount(accs[0] ?? null);
    const handleChainChanged = (hexChainId) => setChainId(parseInt(hexChainId, 16));
    window.ethereum.on("accountsChanged", handleAccountsChanged);
    window.ethereum.on("chainChanged", handleChainChanged);
    return () => {
      window.ethereum.removeListener("accountsChanged", handleAccountsChanged);
      window.ethereum.removeListener("chainChanged", handleChainChanged);
    };
  }, []);

  async function connectWallet() {
    setMessage(null);
    try {
      const provider = getBrowserProvider();
      const accounts = await provider.send("eth_requestAccounts", []);
      const network = await provider.getNetwork();
      setAccount(accounts[0]);
      setChainId(Number(network.chainId));
    } catch (err) {
      setMessage({ kind: "error", text: err.message });
    }
  }

  async function handleSwitchNetwork() {
    setMessage(null);
    try {
      await switchToTargetNetwork();
    } catch (err) {
      setMessage({ kind: "error", text: err.message });
    }
  }

  async function handleRegister(e) {
    e.preventDefault();
    setMessage(null);
    setBusy(true);
    try {
      const provider = getBrowserProvider();
      const signer = await provider.getSigner();
      const { staking } = getContracts(signer);
      const tx = await staking.regUser(referralInput.trim());
      setMessage({ kind: "info", text: "Registering..." });
      await tx.wait();
      setMessage({ kind: "success", text: "Registered." });
      await refreshStatus(account);
    } catch (err) {
      setMessage({ kind: "error", text: err.reason || err.message });
    } finally {
      setBusy(false);
    }
  }

  async function handleStake(e) {
    e.preventDefault();
    setMessage(null);
    setBusy(true);
    try {
      const provider = getBrowserProvider();
      const signer = await provider.getSigner();
      const { usdt, staking } = getContracts(signer);
      const amountWei = toUsdWei(stakeAmount);

      const currentAllowance = await usdt.allowance(account, addresses.staking);
      if (currentAllowance < amountWei) {
        setMessage({ kind: "info", text: "Approving USDT..." });
        const approveTx = await usdt.approve(addresses.staking, amountWei);
        await approveTx.wait();
      }

      setMessage({ kind: "info", text: "Staking..." });
      const stakeTx = await staking.makeStake(amountWei);
      await stakeTx.wait();
      setMessage({ kind: "success", text: `Staked ${stakeAmount} USDT.` });
      setStakeAmount("");
      await refreshStatus(account);
    } catch (err) {
      setMessage({ kind: "error", text: err.reason || err.message });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="app">
      <header>
        <h1>NEXAURA</h1>
        {account ? (
          <div className="account-pill">{shortAddr(account)}</div>
        ) : (
          <button onClick={connectWallet}>Connect Wallet</button>
        )}
      </header>

      {account && !onCorrectNetwork && (
        <div className="banner banner-warn">
          Wrong network (connected to chain {chainId ?? "?"}). Expected chain{" "}
          {addresses.chainId} ({addresses.network}).
          <button onClick={handleSwitchNetwork}>Switch Network</button>
        </div>
      )}

      {message && <div className={`banner banner-${message.kind}`}>{message.text}</div>}

      {account && onCorrectNetwork && (
        <main>
          <section className="card">
            <h2>Status</h2>
            {status ? (
              <ul>
                <li>Registered: {status.joined ? "yes" : "no"}</li>
                {status.joined && <li>Referral: {shortAddr(status.referral)}</li>}
                <li>Last package: {status.lastStake} USDT</li>
                <li>USDT balance: {status.usdtBalance}</li>
              </ul>
            ) : (
              <p>Loading...</p>
            )}
          </section>

          {status && !status.joined && (
            <section className="card">
              <h2>Register</h2>
              <form onSubmit={handleRegister}>
                <label>
                  Referral address
                  <input
                    type="text"
                    placeholder="0x..."
                    value={referralInput}
                    onChange={(e) => setReferralInput(e.target.value)}
                    required
                  />
                </label>
                <button type="submit" disabled={busy}>
                  Register
                </button>
              </form>
            </section>
          )}

          {status && status.joined && (
            <section className="card">
              <h2>Stake a Package</h2>
              <p className="hint">
                $10–$1000, in multiples of $10. Must be ≥ your last package (
                {status.lastStake} USDT).
              </p>
              <form onSubmit={handleStake}>
                <label>
                  Amount (USDT)
                  <input
                    type="number"
                    step="10"
                    min="10"
                    max="1000"
                    placeholder="100"
                    value={stakeAmount}
                    onChange={(e) => setStakeAmount(e.target.value)}
                    required
                  />
                </label>
                <button type="submit" disabled={busy}>
                  Approve &amp; Stake
                </button>
              </form>
            </section>
          )}
        </main>
      )}

      {!account && <p className="hint">Connect a wallet to register and stake.</p>}
    </div>
  );
}
