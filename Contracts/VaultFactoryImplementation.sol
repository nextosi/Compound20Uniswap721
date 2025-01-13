// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// ---------------------------------------------------------------------
// 1) Standard OpenZeppelin imports for UUPS, Ownable, etc.
// ---------------------------------------------------------------------
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @dev Minimal interface for your vault logic. 
 *      We assume you call `initialize(...)` on it.
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
 * @dev Minimal interface for reading from a vault. Shown for context.
 */
interface IVaultReceiver {
    function requiredPool() external view returns (address);
}

/**
 * @title VaultFactoryImplementation
 * @notice A UUPS-upgradeable factory 
 *
 * 
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
     * @dev Default references for OracleManager, Rebalancer, and Liquidator.
     */
    address public defaultOracleManager;
    address public defaultRebalancer;
    address public defaultLiquidator;

    /**
     * @dev Stores addresses of all vault proxies created by this factory.
     */
    address[] public allVaults;

    /**
     * @dev Emitted when a new vault is created.
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
     * @notice Initializes the factory. Called once at deployment behind a proxy.
     *         This is UUPS-upgradeable, so we call the usual OpenZeppelin inits.
     *
     * @param _vaultLogic The deployed VaultImplementation logic contract.
     * @param _owner      The owner (e.g., DAO or deployer).
     */
    function initialize(address _vaultLogic, address _owner) external initializer {
        // OpenZeppelin's recommended pattern
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
     * @notice Sets a new logic contract for future vaults, if you want to upgrade logic references.
     */
    function setVaultLogic(address newVaultLogic) external onlyOwner {
        require(newVaultLogic != address(0), "VaultFactory: invalid logic");
        vaultLogic = newVaultLogic;
    }

    /**
     * @notice Sets default references for OracleManager, Rebalancer, and Liquidator addresses.
     *         If the user doesn't specify these in createVault, they fallback to these defaults.
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
     * @notice Deploys a new vault proxy, passing init data to the vault logic. The caller becomes the vault's owner.
     *
     * @param v3Pool      The Uniswap V3 pool address for the vault
     * @param positionMgr The NonfungiblePositionManager used by the vault
     * @param oracleMgr   OracleManager (or zero to use default)
     * @param rebalancer  Rebalancer (or zero to use default)
     * @param liquidator  Liquidator (or zero to use default)
     * @param name        ERC20 name for the vault's share token
     * @param symbol      ERC20 symbol for the vault's share token
     * @return proxyAddr  The address of the newly deployed vault proxy
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

        // Fallback to defaults
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
            msg.sender, // the vault's owner
            name,
            symbol
        );

        // Deploy a new proxy pointing to vaultLogic
        ERC1967Proxy proxy = new ERC1967Proxy(vaultLogic, initData);
        proxyAddr = address(proxy);

        // Track it
        allVaults.push(proxyAddr);
        emit VaultCreated(proxyAddr, msg.sender, v3Pool);
    }

    /**
     * @notice Returns the total number of vaults created by this factory.
     */
    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /**
     * @notice Returns a vault address by index in the allVaults array.
     */
    function getVault(uint256 index) external view returns (address) {
        require(index < allVaults.length, "VaultFactory: out of range");
        return allVaults[index];
    }

    /**
     * @notice Returns the entire list of vault addresses. 
     *         Use with caution if the list is large.
     */
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }
}
