import { BrowserProvider, Contract, parseUnits } from "ethers";
import addresses from "../contracts/addresses.json";
import tokenAbi from "../contracts/NexauraToken.json";
import stakingAbi from "../contracts/NexauraStaking.json";
import usdtAbi from "../contracts/MockUSDT.json";

export { addresses };

const CHAIN_PARAMS = {
  97: {
    chainId: "0x61",
    chainName: "BSC Testnet",
    nativeCurrency: { name: "tBNB", symbol: "tBNB", decimals: 18 },
    rpcUrls: ["https://data-seed-prebsc-1-s1.binance.org:8545"],
    blockExplorerUrls: ["https://testnet.bscscan.com"],
  },
  31337: {
    chainId: "0x7a69",
    chainName: "Hardhat Local",
    nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
    rpcUrls: ["http://127.0.0.1:8545"],
  },
};

export function getBrowserProvider() {
  if (!window.ethereum) {
    throw new Error("No wallet found — install MetaMask.");
  }
  return new BrowserProvider(window.ethereum);
}

export async function switchToTargetNetwork() {
  const params = CHAIN_PARAMS[addresses.chainId];
  if (!params) return;
  try {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: params.chainId }],
    });
  } catch (err) {
    // 4902 = chain not added to the wallet yet.
    if (err.code === 4902) {
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [params],
      });
    } else {
      throw err;
    }
  }
}

export function getContracts(signerOrProvider) {
  return {
    usdt: new Contract(addresses.usdt, usdtAbi, signerOrProvider),
    token: new Contract(addresses.token, tokenAbi, signerOrProvider),
    staking: new Contract(addresses.staking, stakingAbi, signerOrProvider),
  };
}

export function toUsdWei(amount) {
  return parseUnits(String(amount), 18);
}
