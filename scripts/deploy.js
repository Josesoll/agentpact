// Deploys AgentPact to BNB Chain mainnet.
// Usage: DEPLOYER_KEY=0x... node scripts/deploy.js
// The key is read from the environment only — never commit it, never log it.
// Prints the contract address and the deployment transaction hash.
const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');

const REGISTRY = '0x60B9262456De011F7d15a54CdD8C48baaA8b022F'; // SPACE ID Agent ID, BSC
const RPC = process.env.BSC_RPC || 'https://bsc-dataseed.binance.org';

async function main() {
  const key = process.env.DEPLOYER_KEY;
  if (!key) {
    console.error('DEPLOYER_KEY env var is required.');
    process.exit(1);
  }
  const artifact = JSON.parse(
    fs.readFileSync(path.join(__dirname, '..', 'build', 'AgentPact.json'), 'utf8')
  );
  const provider = new ethers.JsonRpcProvider(RPC, 56);
  const wallet = new ethers.Wallet(key, provider);
  const balance = await provider.getBalance(wallet.address);
  console.log('Deployer:', wallet.address);
  console.log('Balance:', ethers.formatEther(balance), 'BNB');
  if (balance === 0n) {
    console.error('Deployer has no BNB for gas. Aborting.');
    process.exit(1);
  }
  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
  const contract = await factory.deploy(REGISTRY);
  const tx = contract.deploymentTransaction();
  console.log('Deployment tx:', tx.hash);
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log('AgentPact deployed at:', address);
  console.log('Registry:', REGISTRY);
  console.log('Next: verify source on BscScan with build/standard-input.json,');
  console.log('then set PACT in docs/index.html and the README table to', address);
}

main().catch((e) => {
  console.error('ERROR:', e.message || e);
  process.exit(1);
});
