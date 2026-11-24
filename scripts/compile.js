// Compiles contracts/AgentPact.sol into build/AgentPact.json (ABI + bytecode).
const solc = require('solc');
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, '..', 'contracts', 'AgentPact.sol'), 'utf8');
const input = {
  language: 'Solidity',
  sources: { 'AgentPact.sol': { content: src } },
  settings: {
    optimizer: { enabled: true, runs: 200 },
    // Target Paris: no PUSH0/MCOPY — maximum compatibility across EVM
    // environments (local test chains and BNB Chain alike).
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
const c = out.contracts['AgentPact.sol']['AgentPact'];
fs.mkdirSync(path.join(__dirname, '..', 'build'), { recursive: true });
fs.writeFileSync(
  path.join(__dirname, '..', 'build', 'AgentPact.json'),
  JSON.stringify({ abi: c.abi, bytecode: c.evm.bytecode.object }, null, 2)
);
console.log('AgentPact compiled OK, bytecode bytes:', c.evm.bytecode.object.length / 2);
