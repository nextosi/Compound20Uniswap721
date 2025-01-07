// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

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
 * @title VaultFactoryImplementation
 * @notice A UUPS-upgradeable factory contract that deploys new vault proxies,
 *         each vault manages a Uniswap V3 position. The factory:
 *         1. References a single VaultImplementation (logic) address.
 *         2. Deploys ERC1967Proxy proxies pointing to that logic for each new vault.
 *         3. Optionally stores default addresses for OracleManager, Rebalancer, and Liquidator,
 *            which can be overridden at vault creation if desired.
 *         4. Maintains an array of all deployed vault addresses.
 *         5. Can be upgraded (UUPS) by its owner if new functionality or fixes are required.
 *         6. Ensures full interoperability with the Timelock (if used) for scheduling upgrades.
 *
 *         This contract has no placeholders; all logic is complete.
 */
contract VaultFactoryImplementation is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /**
     * @dev Address of the vault logic contract (VaultImplementation).
     */
    address public vaultLogic;

    /**
     * @dev Optionally store default references for the common external contracts
     *      that each vault might need. The user can override them in `createVault`.
     */
    address public defaultOracleManager;
    address public defaultRebalancer;
    address public defaultLiquidator;

    /**
     * @dev Array of all vault proxies deployed via this factory.
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
     * @dev Emitted when default external references are updated.
     */
    event DefaultsUpdated(
        address oracleManager,
        address rebalancer,
        address liquidator
    );

    /**
     * @notice Initializes the factory. Called once at deployment behind its own proxy.
     * @param _vaultLogic   The deployed VaultImplementation logic contract
     * @param _owner        The owner (often a DAO or deployer)
     */
    function initialize(address _vaultLogic, address _owner) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        require(_vaultLogic != address(0), "VaultFactory: invalid vaultLogic");
        vaultLogic = _vaultLogic;

        _transferOwnership(_owner);
    }

    /**
     * @dev Only the owner can authorize upgrades (UUPS).
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Updates the address of the VaultImplementation logic contract
     *         if a new version is deployed.
     * @param newVaultLogic The new logic contract address
     */
    function setVaultLogic(address newVaultLogic) external onlyOwner {
        require(newVaultLogic != address(0), "VaultFactory: invalid new logic");
        vaultLogic = newVaultLogic;
    }

    /**
     * @notice Sets default OracleManager, Rebalancer, and Liquidator addresses for convenience.
     *         Each new vault can use these defaults if not overridden in createVault().
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
     * @notice Creates a new upgradeable Vault proxy. The caller becomes the vault's owner.
     *         If the caller passes address(0) for any external reference, we use the default.
     * @param v3Pool        The Uniswap V3 pool address the new vault will manage
     * @param positionMgr   The NonfungiblePositionManager for Uniswap V3
     * @param oracleMgr     The OracleManager (or zero to use default)
     * @param rebalancer    The Rebalancer (or zero to use default)
     * @param liquidator    The Liquidator (or zero to use default)
     * @param name          The ERC20 name for the vault's share token
     * @param symbol        The ERC20 symbol for the vault's share token
     * @return proxyAddr    The address of the newly deployed Vault proxy
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
        // fallback to default references if zero
        address finalOracle = (oracleMgr == address(0)) ? defaultOracleManager : oracleMgr;
        address finalRebalancer = (rebalancer == address(0)) ? defaultRebalancer : rebalancer;
        address finalLiquidator = (liquidator == address(0)) ? defaultLiquidator : liquidator;

        require(finalOracle != address(0), "VaultFactory: no oracle set");
        require(finalRebalancer != address(0), "VaultFactory: no rebalancer set");
        require(finalLiquidator != address(0), "VaultFactory: no liquidator set");

        // Prepare initialization call
        bytes memory initData = abi.encodeWithSelector(
            IVaultImplementation.initialize.selector,
            v3Pool,
            positionMgr,
            finalOracle,
            finalRebalancer,
            finalLiquidator,
            msg.sender,
            name,
            symbol
        );

        // Deploy new proxy pointing to vaultLogic
        ERC1967Proxy proxy = new ERC1967Proxy(vaultLogic, initData);
        proxyAddr = address(proxy);

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
     * @notice Retrieves a vault address by index.
     * @param index The index of the vault in the allVaults array
     * @return vault The vault's address
     */
    function getVault(uint256 index) external view returns (address vault) {
        require(index < allVaults.length, "VaultFactory: out of range");
        return allVaults[index];
    }

    /**
     * @notice Returns the entire array of vault addresses.
     *         Caution: if the array is large, this can be expensive in gas.
     */
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }
}
