# Valen

### Agent Credit Infrastructure for the Onchain Economy

Valen is an onchain credit infrastructure designed to help autonomous AI agents build access to capital through verifiable economic activity.

Rather than relying solely on traditional credit assessments, Valen uses onchain activity and completed agentic transactions to establish a verifiable foundation for agent creditworthiness.

## The Problem

Autonomous agents are increasingly capable of performing economic activities, executing transactions, and providing services. However, they lack established mechanisms for building financial credibility and accessing credit.

Traditional credit systems are designed around human borrowers and conventional financial histories. They do not adequately account for the economic activity of autonomous agents.

## The Solution

Valen introduces a credit framework that connects verified agent activity with credit eligibility.

Its approach uses:

- **ERC-8004:** Agent identity and reputation infrastructure.
- **ERC-8183:** Agentic commerce and verifiable job execution.
- **Onchain payment evidence:** Completed and settled transactions as evidence of economic activity.
- **Credit records:** Verified activity contributes to an agent's credit profile.

## How It Works

1. An agent establishes its identity through the agent identity infrastructure.
2. The agent performs work through an agentic commerce workflow.
3. Completed jobs generate verifiable payment events.
4. Valen verifies qualifying economic activity.
5. Verified activity is recorded against the agent's credit profile.
6. Credit eligibility can increase as the agent demonstrates a history of successful economic activity.

## Technology

Valen builds around the following technologies and standards:

| Technology | Purpose |
|---|---|
| Solidity | Smart contract development |
| Foundry | Contract development and testing |
| ERC-8004 | Agent identity and reputation |
| ERC-8183 | Agentic commerce |
| USDC | Payment and settlement asset |
| Arc | Onchain execution environment |

## Getting Started

### Prerequisites

- Git
- Foundry
- Node.js, if required by the application tooling

### Clone the repository

```bash
git clone https://github.com/Web3smallie/valen.git
cd valen
```

### Build the contracts

```bash
forge build
```

### Run the tests

```bash
forge test
```

## Project Status

Valen is under active development. Refer to the repository's source code and deployment configurations for the current implementation details.

## Contributing

Contributions are welcome.

1. Fork the repository.
2. Create a branch for your changes.
3. Make your changes.
4. Submit a pull request describing what you changed and why.

## License

See the repository for licensing information.
