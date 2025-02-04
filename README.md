# AI Agent Vault Protocol

This protocol allows users to deposit assets into vaults managed by AI agents for automated trading and yield generation.

## Key Components

- `AIVault.sol`: Main vault contract that handles user deposits, withdrawals, and share management
- Performance fee calculation and distribution
- Secure trading authorization system
- Share token system for tracking user positions

## Setup

1. Install dependencies:
```bash
npm install
```

2. Compile contracts:
```bash
npx hardhat compile
```

## Security Features

- Only authorized AI agents can execute trades
- User funds are protected from unauthorized withdrawals
- Performance fees are automatically calculated and distributed
