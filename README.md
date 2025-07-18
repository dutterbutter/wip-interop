# Interop Test Environment Setup

This project is a wip to begin playing around with various forms of interop.

## 1️⃣ Bootstrap Your Local Environment

Spin up ZK chains and services by running:

```bash
./scripts/bootstrap_interop.sh
```

This will start the following chains locally:

| Chain    | Chain ID | RPC Endpoint                                   | Logs                            |
| -------- | -------- | ---------------------------------------------- | ------------------------------- |
| Era      | `271`    | [http://localhost:3050](http://localhost:3050) | `zksync-era/zruns/era.log`      |
| Validium | `260`    | [http://localhost:3070](http://localhost:3070) | `zksync-era/zruns/validium.log` |
| Gateway  | `506`    | [http://localhost:3150](http://localhost:3150) | `zksync-era/zruns/gateway.log`  |
| L1       | `9`      | [http://localhost:8545](http://localhost:8545) | —                               |

## 2️⃣ Reproduce Locally

Assuming your environment is running, clone and install the test suite:

```bash
git clone https://github.com/dutterbutter/wip-interop  
cd wip-interop
forge install  
```

**Important:**
You may need to patch `lib/era-contracts` (INativeTokenVault.sol) to allow compiler version ranges:

```diff
- pragma solidity 0.8.28;  
+ pragma solidity ^0.8.28;  
```

## 3️⃣ Run Tests

Execute the tests:

```bash
forge test --zksync -vvvv
```
