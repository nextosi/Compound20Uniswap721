// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title VaultFactoryImplementation
 * @notice A UUPS-upgradeable factory contract that deploys new Vault proxies,
 *         each vault manages a Uniswap V3 position. The factory:
 *         1. References a single VaultImplementation (logic) address.
 *         2. Deploys ERC1967Proxy proxies pointing to that logic for each new vault.
 *         3. Optionally stores default addresses for OracleManager, Rebalancer, and Liquidator,
 *            which can be overridden at vault creation if desired.
 *         4. Maintains an array of all deployed vault addresses.
 *         5. Can be upgraded (UUPS) by its owner if new functionality or fixes are required.
 */

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @dev Minimal interface for the logic contract (VaultImplementation).
 *      Used by the factory to call `initialize(...)` upon proxy creation.
 */
interface IVaultImplementation {
    function initialize(
        address _v3Pool,
        address _positionManager,
        address _oracleMgr,
        address _rebalancer,
        address _liquidator,
        address _owner,
        string memory _name,
        string memory _symbol
    ) external;
}

/**
 * @dev Minimal interface for the vault so we can read `requiredPool()`.
 */
interface IVaultReceiver {
    function requiredPool() external view returns (address);
}

/**
 * @dev Minimal interface for a Uniswap V3 pool to read `factory()`.
 */
interface ILocalUniswapV3Pool {
    function factory() external view returns (address);
}

/**
 * @dev Minimal interface for a Uniswap V3 factory to getPool(token0, token1, fee).
 */
interface ILocalUniswapV3FactorySimple {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/**
 * @dev Minimal interface for the NonfungiblePositionManager to read positions(...) and do safeTransferFrom(...).
 */
interface IMinimalNonfungiblePositionManager {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/**
 * @title VaultFactoryImplementation
 * @dev A UUPS-upgradeable factory for creating new vault proxies.
 */
contract VaultFactoryImplementation is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /**
     * @dev The address of the deployed VaultImplementation (logic) contract.
     */
    address public vaultLogic;

    /**
     * @dev Default references for external contracts if the user doesn't specify them.
     */
    address public defaultOracleManager;
    address public defaultRebalancer;
    address public defaultLiquidator;

    /**
     * @dev Array of all vault proxies created by this factory.
     */
    address[] public allVaults;

    /**
     * @dev Emitted when a new vault proxy is created.
     */
    event VaultCreated(
        address indexed vaultProxy,
        address indexed creator,
        address indexed v3Pool
    );

    /**
     * @dev Emitted when the factory's default references are updated.
     */
    event DefaultsUpdated(
        address oracleManager,
        address rebalancer,
        address liquidator
    );

    /**
     * @notice Initializes the factory. Called once at deployment behind its own proxy.
     *
     * @param _vaultLogic   The deployed VaultImplementation logic contract.
     * @param _owner        The owner (often a DAO or deployer).
     */
    function initialize(address _vaultLogic, address _owner) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        require(_vaultLogic != address(0), "VaultFactory: invalid vaultLogic");
        vaultLogic = _vaultLogic;
    }

    /**
     * @dev Required by the UUPS pattern. Only the contract owner can authorize an upgrade.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Sets a new logic contract address for future vaults (if you want to upgrade).
     * @param newVaultLogic The new VaultImplementation logic contract
     */
    function setVaultLogic(address newVaultLogic) external onlyOwner {
        require(newVaultLogic != address(0), "VaultFactory: invalid logic");
        vaultLogic = newVaultLogic;
    }

    /**
     * @notice Sets the default OracleManager, Rebalancer, and Liquidator addresses for the factory.
     *         Users can override these when creating a new vault by passing non-zero addresses.
     * @param _oracleManager   Address of the default OracleManager
     * @param _rebalancer      Address of the default Rebalancer
     * @param _liquidator      Address of the default Liquidator
     */
    function setDefaultReferences(
        address _oracleManager,
        address _rebalancer,
        address _liquidator
    ) external onlyOwner {
        require(_oracleManager != address(0), "VaultFactory: invalid oracle");
        require(_rebalancer != address(0), "VaultFactory: invalid rebalancer");
        require(_liquidator != address(0), "VaultFactory: invalid liquidator");

        defaultOracleManager = _oracleManager;
        defaultRebalancer = _rebalancer;
        defaultLiquidator = _liquidator;

        emit DefaultsUpdated(_oracleManager, _rebalancer, _liquidator);
    }

    /**
     * @notice Deploys a new vault proxy pointing to `vaultLogic`. The caller becomes the vault's owner.
     *
     * @param v3Pool        The Uniswap V3 pool address for the vault
     * @param positionMgr   The NonfungiblePositionManager used by the vault
     * @param oracleMgr     OracleManager (or zero for default)
     * @param rebalancer    Rebalancer (or zero for default)
     * @param liquidator    Liquidator (or zero for default)
     * @param name          The ERC20 name for the vault shares
     * @param symbol        The ERC20 symbol for the vault shares
     * @return proxyAddr    The address of the newly deployed vault proxy
     */
    function createVault(
        address v3Pool,
        address positionMgr,
        address oracleMgr,
        address rebalancer,
        address liquidator,
        string calldata name,
        string calldata symbol
    ) external returns (address proxyAddr) {
        require(v3Pool != address(0), "VaultFactory: invalid v3Pool");
        require(positionMgr != address(0), "VaultFactory: invalid positionMgr");

        // If zero is passed, fallback to defaults
        address finalOracle = (oracleMgr == address(0)) ? defaultOracleManager : oracleMgr;
        address finalRebalancer = (rebalancer == address(0)) ? defaultRebalancer : rebalancer;
        address finalLiquidator = (liquidator == address(0)) ? defaultLiquidator : liquidator;

        require(finalOracle != address(0), "VaultFactory: no oracle");
        require(finalRebalancer != address(0), "VaultFactory: no rebalancer");
        require(finalLiquidator != address(0), "VaultFactory: no liquidator");

        // Prepare initializer data for the vault
        bytes memory initData = abi.encodeWithSelector(
            IVaultImplementation.initialize.selector,
            v3Pool,
            positionMgr,
            finalOracle,
            finalRebalancer,
            finalLiquidator,
            msg.sender, // the vault owner
            name,
            symbol
        );

        // Deploy a new ERC1967Proxy with the above init data
        ERC1967Proxy proxy = new ERC1967Proxy(vaultLogic, initData);
        proxyAddr = address(proxy);

        // Track it
        allVaults.push(proxyAddr);

        emit VaultCreated(proxyAddr, msg.sender, v3Pool);
    }

    /**
     * @notice Returns the number of vaults created by this factory.
     */
    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /**
     * @notice Retrieve a vault address by index in the `allVaults` array.
     */
    function getVault(uint256 index) external view returns (address) {
        require(index < allVaults.length, "VaultFactory: out of range");
        return allVaults[index];
    }

    /**
     * @notice Returns the entire list of vault addresses. 
     *         Use with care if the array is large.
     */
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }

    /**
     * @dev The vault must implement onERC721Received in a non-reverting manner 
     *      for matched or mismatched pools.
     * @param vault       The vault address that implements onERC721Received
     * @param tokenId     The NFT to deposit
     * @param positionMgr The NFPM address holding the positions
     */
    function depositNftForVault(
        address vault,
        uint256 tokenId,
        address positionMgr
    ) external {
        require(vault != address(0), "VaultFactory: invalid vault");
        require(positionMgr != address(0), "VaultFactory: invalid positionMgr");

        // read vault.requiredPool()
        address rPool = IVaultReceiver(vault).requiredPool();
    

        IMinimalNonfungiblePositionManager(positionMgr).positions(tokenId);

        IMinimalNonfungiblePositionManager(positionMgr).safeTransferFrom(msg.sender, vault, tokenId);

        // done => vault’s onERC721Received triggers => minted=0 if mismatch
    }
}
