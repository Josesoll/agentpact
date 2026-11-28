#!/bin/bash
# Despliega AgentPact desde la wallet 1 del gestor (wallet-manager).
# La llave se lee del archivo protegido en tiempo de ejecucion; nunca se imprime ni se guarda aqui.
set -e
cd /home/hatch/workspace/agentpact
KEY=$(python3 -c "import json; d=json.load(open('/home/hatch/workspace/wallet-manager/private_wallets.json')); w=[x for x in d if x['wallet']==1][0]; print(w['private_keys']['ethereum_bnb_polygon_hex'])")
BSC_RPC=https://bsc-dataseed.binance.org DEPLOYER_KEY="$KEY" node scripts/deploy.js
