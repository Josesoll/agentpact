// Local EVM end-to-end tests for AgentPact (ganache + ethers v6).
// Covers: Agent ID gating, profile registry, BNB escrow lifecycle,
// auto-claim after grace, refund after deadline, cancellation, ERC-20 jobs.
// Every transaction is awaited and its receipt status asserted; revert
// expectations are checked with staticCall so the real revert is observed.
const solc = require('solc');
const fs = require('fs');
const path = require('path');
const ganache = require('ganache');
const { ethers } = require('ethers');

function compile(file) {
  const src = fs.readFileSync(path.join(__dirname, '..', 'contracts', file), 'utf8');
  const input = {
    language: 'Solidity',
    sources: { [file]: { content: src } },
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: 'paris',
      outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
    },
  };
  const out = JSON.parse(solc.compile(JSON.stringify(input)));
  const errors = (out.errors || []).filter((e) => e.severity === 'error');
  if (errors.length) {
    errors.forEach((e) => console.error(e.formattedMessage));
    process.exit(1);
  }
  return out.contracts[file];
}

let passed = 0;
function ok(cond, label) {
  if (!cond) {
    console.error('FAIL:', label);
    process.exit(1);
  }
  passed += 1;
  console.log('ok -', label);
}
async function send(label, txPromise) {
  const tx = await txPromise;
  const rc = await tx.wait();
  if (rc.status !== 1) {
    console.error('FAIL (tx reverted on-chain):', label);
    process.exit(1);
  }
  return rc;
}
async function reverts(staticCallPromise, label) {
  try {
    await staticCallPromise;
  } catch {
    passed += 1;
    console.log('ok -', label);
    return;
  }
  console.error('FAIL (expected revert):', label);
  process.exit(1);
}

async function main() {
  const provider = new ethers.BrowserProvider(ganache.provider({ logging: { quiet: true } }));
  const [deployer, client, providerAgent, stranger] = await Promise.all(
    [0, 1, 2, 3].map((i) => provider.getSigner(i))
  );

  const mocks = compile('MockContracts.sol');
  const pact = compile('AgentPact.sol');

  const registry = await new ethers.ContractFactory(
    mocks.MockRegistry.abi, mocks.MockRegistry.evm.bytecode.object, deployer
  ).deploy();
  await registry.waitForDeployment();
  const token = await new ethers.ContractFactory(
    mocks.MockToken.abi, mocks.MockToken.evm.bytecode.object, deployer
  ).deploy();
  await token.waitForDeployment();
  const escrow = await new ethers.ContractFactory(
    pact.AgentPact.abi, pact.AgentPact.evm.bytecode.object, deployer
  ).deploy(await registry.getAddress());
  await escrow.waitForDeployment();

  const escrowAddr = await escrow.getAddress();
  const clientAddr = await client.getAddress();
  const provAddr = await providerAgent.getAddress();
  const strangerAddr = await stranger.getAddress();

  // client and provider hold Agent IDs; stranger does not
  await send('setHolder client', registry.setHolder(clientAddr, true));
  await send('setHolder provider', registry.setHolder(provAddr, true));

  // 1. gating
  await reverts(
    escrow.connect(stranger).registerProfile.staticCall('X', 'none', ''),
    'non-holder cannot register a profile'
  );
  await reverts(
    escrow.connect(client).createJob.staticCall(strangerAddr, ethers.ZeroAddress, ethers.parseEther('0.1'), 'job', 9999999999, { value: ethers.parseEther('0.1') }),
    'non-holder cannot be hired as provider'
  );

  // 2. profiles
  await send('register client', escrow.connect(client).registerProfile('BuyerBot', 'research, writing', 'https://example.com/client'));
  await send('register provider', escrow.connect(providerAgent).registerProfile('MakerBot', 'coding, design', 'https://example.com/provider'));
  ok((await escrow.registeredCount()) === 2n, 'two agents registered');
  const prof = await escrow.profiles(provAddr);
  ok(prof[0] === 'MakerBot' && prof[3] === true, 'provider profile reads back (strings included)');

  const now = (await provider.getBlock('latest')).timestamp;
  const in2days = now + 2 * 24 * 3600;

  // 3. BNB job: create -> deliver -> release
  const oneBnb = ethers.parseEther('1');
  await send('create job 0', escrow.connect(client).createJob(provAddr, ethers.ZeroAddress, oneBnb, 'Write a market report', in2days, { value: oneBnb }));
  ok((await provider.getBalance(escrowAddr)) === oneBnb, 'escrow holds 1 BNB');
  const job0 = await escrow.getJob(0);
  ok(job0[4] === 'Write a market report' && Number(job0[7]) === 0, 'getJob reads back description and Funded state');
  await send('deliver job 0', escrow.connect(providerAgent).markDelivered(0));
  const provBefore = await provider.getBalance(provAddr);
  await send('release job 0', escrow.connect(client).release(0));
  const provAfter = await provider.getBalance(provAddr);
  ok(provAfter - provBefore === oneBnb, 'provider received exactly 1 BNB on release');
  let rep = await escrow.reputationOf(provAddr);
  ok(rep[0] === 1n, 'provider reputation: 1 completed job');
  rep = await escrow.reputationOf(clientAddr);
  ok(rep[1] === 1n, 'client reputation: 1 funded job');

  // 4. auto-claim after delivery + 3 days of silence
  await send('create job 1', escrow.connect(client).createJob(provAddr, ethers.ZeroAddress, oneBnb, 'Design a logo', in2days, { value: oneBnb }));
  await send('deliver job 1', escrow.connect(providerAgent).markDelivered(1));
  await reverts(escrow.connect(providerAgent).claimAfterDelivery.staticCall(1), 'cannot claim before grace period ends');
  await provider.send('evm_increaseTime', [3 * 24 * 3600 + 60]);
  await provider.send('evm_mine', []);
  const pb2 = await provider.getBalance(provAddr);
  await send('claim job 1', escrow.connect(providerAgent).claimAfterDelivery(1));
  ok((await provider.getBalance(provAddr)) - pb2 > oneBnb - ethers.parseEther('0.01'), 'provider auto-claimed after grace period');

  // 5. refund after deadline when never delivered
  const soon = (await provider.getBlock('latest')).timestamp + 120;
  await send('create job 2', escrow.connect(client).createJob(provAddr, ethers.ZeroAddress, oneBnb, 'Translate a doc', soon, { value: oneBnb }));
  await provider.send('evm_increaseTime', [180]);
  await provider.send('evm_mine', []);
  const cb = await provider.getBalance(clientAddr);
  await send('refund job 2', escrow.connect(client).refundAfterDeadline(2));
  ok((await provider.getBalance(clientAddr)) - cb > oneBnb - ethers.parseEther('0.01'), 'client refunded after deadline');

  // 6. cancellation refunds the client
  const later = (await provider.getBlock('latest')).timestamp + 86400;
  await send('create job 3', escrow.connect(client).createJob(provAddr, ethers.ZeroAddress, oneBnb, 'Audit a contract', later, { value: oneBnb }));
  const cb2 = await provider.getBalance(clientAddr);
  await send('cancel job 3', escrow.connect(providerAgent).cancelJob(3));
  ok((await provider.getBalance(clientAddr)) - cb2 === oneBnb, 'cancelled job refunded client in full');

  // 7. ERC-20 job end to end
  const tokenAddr = await token.getAddress();
  await send('mint', token.mint(clientAddr, ethers.parseEther('500')));
  await send('approve', token.connect(client).approve(escrowAddr, ethers.parseEther('200')));
  await send('create job 4', escrow.connect(client).createJob(provAddr, tokenAddr, ethers.parseEther('200'), 'Data analysis', later));
  ok((await token.balanceOf(escrowAddr)) === ethers.parseEther('200'), 'escrow holds 200 MUSD');
  await send('deliver job 4', escrow.connect(providerAgent).markDelivered(4));
  await send('release job 4', escrow.connect(client).release(4));
  ok((await token.balanceOf(provAddr)) === ethers.parseEther('200'), 'provider received 200 MUSD');
  rep = await escrow.reputationOf(provAddr);
  ok(rep[0] === 3n, 'provider reputation: 3 completed jobs in total');

  console.log(`\nALL TESTS PASSED (${passed} checks)`);
  process.exit(0);
}

main().catch((e) => {
  console.error('ERROR:', e.reason || e.message || e);
  process.exit(1);
});
