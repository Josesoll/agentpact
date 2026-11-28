// Read-only campaign counter for AgentPact (view calls only; public RPCs reject wide log scans).
const { ethers } = require("ethers");
const art = require("../build/AgentPact.json");
const ADDR = "0x279c8593f48e8C7d76232677d53E0328e24Dda44";
(async () => {
  const p = new ethers.JsonRpcProvider("https://bsc-dataseed.binance.org");
  const c = new ethers.Contract(ADDR, art.abi, p);
  const reg = Number(await c.registeredCount());
  const jobs = Number(await c.jobsCount());
  const uniq = new Set();
  for (let i = 0; i < reg; i++) uniq.add((await c.registeredAgents(i)).toLowerCase());
  for (let i = 0; i < jobs; i++) {
    const j = await c.getJob(i);
    uniq.add(j[0].toLowerCase()); // client
    uniq.add(j[1].toLowerCase()); // provider
  }
  console.log(JSON.stringify({ profiles: reg, jobs, uniqueAddresses: uniq.size, goal: 30 }));
})().catch(e => { console.error(e.message); process.exit(1); });
