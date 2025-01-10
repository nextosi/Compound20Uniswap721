
## Overview

Welcome to the **CompUni** repository! Here you’ll find a set of Solidity smart contracts. This project consists of multiple upgradeable contracts, each serving a different function to make it more streamlined for turning NFT positions into ERC20 to better work with DeFi:

1. **VaultImplementation**
   - A UUPS-upgradeable vault contract that:
     - Accepts one or more Uniswap V3 NFT positions from a single pool.
     - Issues ERC20 shares proportional to the vault’s total underlying value (measured via oracle prices).
     - Allows deposit/withdrawal of NFTs, partial liquidity operations, and forced share seizures (used by the Liquidator).
     - Integrates with an external **Rebalancer** for compounding positions, adjusting pool ranges, or other strategies.
     - Integrates with a **Liquidator** for margin calls / forced liquidation logic.

2. **VaultFactoryImplementation**
   - A factory that deploys new vault proxies (UUPS/ERC1967) pointing to the `VaultImplementation`.
   - Maintains a list of all deployed vaults.
   - Allows configuration of default addresses for OracleManager, Rebalancer, and Liquidator if not specified at vault creation.

3. **OracleManager**
   - Maintains references to price aggregators (e.g., Chainlink) for both normal ERC20 tokens and special “vault tokens.”
   - Can calculate a vault token’s price by inspecting its underlying Uniswap V3 NFT (liquidity amounts, owed tokens, etc.).
   - Supports fallback aggregators if the primary aggregator fails or is missing data.

4. **Rebalancer** (stub/interface in some repos)
   - An external contract that the vault calls to “rebalance” its NFT positions. 
   - Could be used to:
     - Shift liquidity ranges in Uniswap V3.
     - Auto-compound earned fees.
     - Mint or burn shares to keep a specific strategy.

5. **Liquidator** (stub/interface in some repos)
   - Used for forcibly seizing user shares if they become undercollateralized or fail a margin requirement.
   - The vault can call `liquidatePosition()` or the Liquidator can seize user shares.

## How It Works

- **Vault Creation**  
  1. Deploy or upgrade the `VaultFactoryImplementation`.  
  2. Call `factory.setVaultLogic(...)` to point to your chosen `VaultImplementation` logic contract.  
  3. (Optional) Call `factory.setDefaultReferences(...)` to set default OracleManager, Rebalancer, Liquidator.  
  4. Call `factory.createVault(...)` to deploy a new vault proxy.  
  5. The vault uses the references (OracleManager, Rebalancer, Liquidator) either from defaults or from the parameters you pass.

- **Depositing an NFT**  
  1. A user calls `safeTransferFrom(address from, address to, uint256 tokenId)` on Uniswap’s `NonfungiblePositionManager`.  
  2. They transfer the NFT to the vault’s address.  
  3. `VaultImplementation.onERC721Received(...)` mints shares to the depositor, based on the NFT’s computed value.  

- **Withdrawing an NFT**  
  1. The user calls `vault.withdrawNFT(tokenId, to)`.  
  2. The contract burns exactly the shares that were originally minted for that NFT.  
  3. The NFT is transferred back to the user.  

- **OracleManager**  
  - Maintains Chainlink aggregator addresses for normal tokens.  
  - For “vault tokens” (i.e., the vault’s own shares or nested vault shares), it looks up the underlying NFT data to compute a total value.  
  - Returns prices in 1e8 format (like Chainlink).  

- **Rebalancer**  
  - The vault can call `rebalanceVault(tokenId, data)`.  
  - This triggers `rebalancer.rebalance(...)` passing the vault address and any strategy-specific data.  
  - The rebalancer can do various Uniswap V3 operations, or mint shares, etc.  

- **Liquidator**  
  - A separate system that decides when a user is undercollateralized.  
  - Calls `vault.liquidatePosition(user, data)` or instructs the vault to seize shares from the user.  
  - The vault performs forced share burns or reassignments.  

## Repository Structure


```
contracts/
  VaultImplementation.sol        // The upgradeable vault logic
  VaultFactoryImplementation.sol // The factory for creating new vaults
  OracleManager.sol              // Manages aggregator references & custom vault logic
  Rebalancer.sol                 // External contract (or interface) for rebalancing strategies
  Liquidator.sol                 // External contract (or interface) for liquidation logic

```

## Setup & Installation

1. **Clone this repo**  

2. **Install dependencies** (if using Hardhat or Truffle)  
   ```bash
   npm install
   ```
3. **Compile**  
   ```bash
   npx hardhat compile
   ```
4. **Test** (if you have test scripts)  
   ```bash
   npx hardhat test
   ```

## Deployment

1. **Deploy `VaultImplementation`**  
   - Use your preferred script or manually in Remix.  
2. **Deploy `VaultFactoryImplementation`**  
   - Set it to reference the `VaultImplementation` as its logic contract.  
3. **Deploy `OracleManager`** or any other external references.  
4. **Set defaults** in `VaultFactoryImplementation` if needed:
   ```solidity
   factory.setDefaultReferences(
     address(oracleManager),
     address(rebalancer),
     address(liquidator),
     ...
   );
   ```
5. **Create a vault**:
   ```solidity
   address newVault = factory.createVault(
       uniswapFactory,    // e.g., 0x1F98431c8aD98523631AE4a59f267346ea31F984
       requiredPool,      // The Uniswap V3 pool address for the vault
       positionManager,    // NFPM
       oracleMgr,         // or zero => fallback
       rebalancer,        // or zero => fallback
       liquidator,        // or zero => fallback
       "Vault Name",
       "VAULT",
       300                // e.g. 3% slippage
   );
   ```
6. **Deposit NFT** by calling `safeTransferFrom` on the NFPM or `vault.onERC721Received(...)`.

## Security Considerations

- **UUPS Upgrades**: Only the vault/factory owner can upgrade logic.  
- **Rebalancer**: Has significant control (it can move assets around). Ensure only trusted addresses are used or put behind a timelock.  
- **Liquidations**: The Liquidator can seize user shares, so ensure you have robust logic for deciding when to liquidate.  
- **Oracle**: If Chainlink feed is down or manipulated, it can affect vault share pricing. Use fallback aggregator if possible.  


---

**Thank you for checking out our project!** If you have questions, suggestions, or want to contribute, please open an issue or submit a pull request.




For launching the frontend, if you are not doing direct interactions in Terminal or Remix, make sure you create a folder structure where the index.html is the top level with the server file. Than have a folder called ABI, than the next folders need the chainID, than the ABI's in a .JSON format.
