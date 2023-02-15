# LiquidityBoosting

Solidity contracts used in [Pawnfi](https://www.pawnfi.com/) private liquidity boosting.

## Overview

The LiquidityBoosting contract facilitates the raising of both PToken and ETH to provide liquidity to Uni V3 on the Ethereum blockchain. Additionally, it employs a mechanism for distributing liquidity rewards, platform PAWN incentives, and interest income generated from the lending market.

## Audits

- PeckShield ( - ) : [report](./audits/audits.pdf) (Also available in Chinese in the same folder)

## Contracts

### Installation

- To run liquidity boosting, pull the repository from GitHub and install its dependencies. You will need [npm](https://docs.npmjs.com/cli/install) installed.

```bash
git clone https://github.com/PawnFi/LiquidityBoosting.git
cd LiquidityBoosting
npm install 
```
- Create an enviroment file named `.env` and fill the next enviroment variables

```
# Import private key
PRIVATEKEY= your private key  

# Add Infura provider keys
MAINNET_NETWORK=https://mainnet.infura.io/v3/YOUR_API_KEY
GOERLI_NETWORK=https://goerli.infura.io/v3/YOUR_API_KEY

```

### Compile

```
npx hardhat compile
```



### Local deployment

In order to deploy this code to a local testnet, you should install the npm package `@pawnfi/liquidityboosting` and import the LB bytecode located at
`@pawnfi/liquidityboosting/artifacts/contracts/LB.sol/LB.json`.
For example:

```typescript
import {
  abi as LB_ABI,
  bytecode as LB_BYTECODE,
} from '@pawnfi/liquidityboosting/artifacts/contracts/LB.sol/LB.json'

// deploy the bytecode
```

This will ensure that you are testing against the same bytecode that is deployed to
mainnet and public testnets, and all Pawnfi code will correctly interoperate with
your local deployment.

### Using solidity interfaces

The Pawnfi liquidityboosting interfaces are available for import into solidity smart contracts
via the npm artifact `@pawnfi/liquidityboosting`, e.g.:

```solidity
import '@pawnfi/liquidityboosting/contracts/interfaces/LBInterface.sol';

contract MyContract {
  LBInterface lb;

  function doSomethingWithLb() {
    // lb.raiseFundsToken(...);
  }
}

```

## Discussion

For any concerns with the protocol, open an issue or visit us on [Discord](https://discord.com/invite/pawnfi) to discuss.

For security concerns, please email [support@security.pawnfi.com](mailto:support@security.pawnfi.com).

_© Copyright 2023, Pawnfi Ltd._

