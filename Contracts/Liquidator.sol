// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @dev Minimal interface for a Vault that supports forcibly reassigning user shares 
 *      to a recipient during liquidation. The Liquidator calls:
 *        1. balanceOf(user) - checks user share balance
 *        2. totalSupply()   - used for ratio-based calculations
 *        3. getUnderlyingPrice() - to compute user's share value in the chosen unit (e.g. USD)
 *        4. seizeShares(...) - forcibly remove shares from one user and assign them to a recipient
 */
interface IVaultLiquidation {
    function balanceOf(address user) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals);

    /**
     * @notice Forcibly removes `shares` from `from` and transfers them to `recipient`.
     *         Used by the Liquidator for undercollateralized positions.
     */
    function seizeShares(address from, uint256 shares, address recipient) external;
}

/**
 * @title Liquidator
 * @notice A contract that can forcibly seize user shares from an undercollateralized position
 *         in a vault. The seized shares are transferred to this contract's owner (the deployer),
 *         who can then decide how to handle them (e.g., distribute to a hired liquidator,
 *         return partially to a pool, penalize the user, etc.).
 *
 *         Key parameters:
 *         - minCollateralValue: The required value below which a user is undercollateralized.
 *         - liquidationFeeBps: A fee in basis points added on top of the seizeAmount, 
 *           also sent to the owner (deployer).
 *         - maxLiquidationBps: The maximum fraction (in BPS) of a user's shares 
 *           that can be seized in one call.
 *
 *         This contract calls `seizeShares(user, totalSeize, owner())` on the vault, 
 *         transferring forcibly removed shares to the contract's owner.
 */
contract Liquidator is Ownable {
    /**
     * @dev The minimum value (in the same unit as the vault's price feed) 
     *      a user must maintain. If their share value < minCollateralValue, 
     *      they can be liquidated.
     */
    uint256 public minCollateralValue;

    /**
     * @dev A liquidation fee in basis points (e.g., 500 => 5%). 
     *      This is added on top of `seizeAmount` and also transferred 
     *      to the contract owner upon liquidation.
     */
    uint256 public liquidationFeeBps;

    /**
     * @dev The maximum proportion of a user's total shares that can be seized 
     *      in one liquidation call, in basis points (e.g., 5000 => 50%).
     */
    uint256 public maxLiquidationBps;

    /**
     * @dev Emitted when the minCollateralValue is updated.
     */
    event MinCollateralValueUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @dev Emitted when the liquidation fee is updated.
     */
    event LiquidationFeeBpsUpdated(uint256 oldFee, uint256 newFee);

    /**
     * @dev Emitted when the maximum liquidation ratio is updated.
     */
    event MaxLiquidationBpsUpdated(uint256 oldMaxBps, uint256 newMaxBps);

    /**
     * @dev Emitted after a successful liquidation.
     * @param vault          The vault being liquidated.
     * @param liquidator     The caller who triggered the liquidation action.
     * @param userLiquidated The user whose shares were seized.
     * @param seizedShares   The base amount of shares seized from the user.
     * @param feeShares      The fee portion of shares, also seized and given to owner.
     * @param recipient      The address that receives the seized shares (the contract owner).
     */
    event LiquidationExecuted(
        address indexed vault,
        address indexed liquidator,
        address indexed userLiquidated,
        uint256 seizedShares,
        uint256 feeShares,
        address recipient
    );

    /**
     * @notice Constructor calls the Ownable base constructor with `initialOwner` 
     *         and initializes the liquidation parameters.
     * @param initialOwner         The address that will own this Liquidator contract.
     * @param _minCollateralValue  The minimum user share value required to avoid liquidation.
     * @param _liquidationFeeBps   A fee in basis points added on top of `seizeAmount`.
     * @param _maxLiquidationBps   The maximum fraction of user shares seizable in one call.
     */
    constructor(
        address initialOwner,
        uint256 _minCollateralValue,
        uint256 _liquidationFeeBps,
        uint256 _maxLiquidationBps
    ) Ownable(initialOwner) {
        require(_maxLiquidationBps <= 10000, "Liquidator: maxLiquidationBps > 100%");
        require(_liquidationFeeBps <= 5000, "Liquidator: feeBps too large"); 
        minCollateralValue = _minCollateralValue;
        liquidationFeeBps = _liquidationFeeBps;
        maxLiquidationBps = _maxLiquidationBps;
    }

    /**
     * @notice Updates the minimum collateral value (onlyOwner).
     * @param newValue The new minCollateralValue.
     */
    function setMinCollateralValue(uint256 newValue) external onlyOwner {
        uint256 oldVal = minCollateralValue;
        minCollateralValue = newValue;
        emit MinCollateralValueUpdated(oldVal, newValue);
    }

    /**
     * @notice Updates the liquidation fee in basis points (onlyOwner).
     * @param newFeeBps The new liquidation fee.
     */
    function setLiquidationFeeBps(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 5000, "Liquidator: fee too large");
        uint256 oldFee = liquidationFeeBps;
        liquidationFeeBps = newFeeBps;
        emit LiquidationFeeBpsUpdated(oldFee, newFeeBps);
    }

    /**
     * @notice Updates the max fraction of user shares that can be seized in one call (onlyOwner).
     * @param newMaxBps The new ratio in basis points.
     */
    function setMaxLiquidationBps(uint256 newMaxBps) external onlyOwner {
        require(newMaxBps <= 10000, "Liquidator: maxLiquidationBps > 100%");
        uint256 oldMax = maxLiquidationBps;
        maxLiquidationBps = newMaxBps;
        emit MaxLiquidationBpsUpdated(oldMax, newMaxBps);
    }

    /**
     * @dev Checks if a user is undercollateralized by computing their share value 
     *      from the vault's price feed and comparing it to `minCollateralValue`.
     * @param vault The vault implementing IVaultLiquidation.
     * @param user  The user to check.
     * @return isUnderCollateral True if user's share value < minCollateralValue.
     * @return userValue         The user's computed share value (in the feed's unit).
     */
    function checkUnderCollateral(address vault, address user)
        public
        view
        returns (bool isUnderCollateral, uint256 userValue)
    {
        IVaultLiquidation v = IVaultLiquidation(vault);
        uint256 userShares = v.balanceOf(user);
        if (userShares == 0) {
            // If user has no shares, they effectively have no position.
            // Return false, value=0, not undercollateralized in the sense of a negative condition.
            return (false, 0);
        }

        uint256 _totalSupply = v.totalSupply();
        (uint256 price, ) = v.getUnderlyingPrice();
        // userValue = (price * userShares) / totalSupply
        userValue = (price * userShares) / (_totalSupply == 0 ? 1 : _totalSupply);

        isUnderCollateral = (userValue < minCollateralValue);
    }

    /**
     * @notice Liquidates a user if they are undercollateralized by seizing a specified 
     *         number of shares (plus a fee) and transferring them to this contract's owner.
     * @param vault       The vault address implementing IVaultLiquidation.
     * @param user        The undercollateralized user to liquidate.
     * @param seizeAmount The base number of shares to seize (excluding fee).
     */
    function liquidate(
        address vault,
        address user,
        uint256 seizeAmount
    ) external {
        require(vault != address(0), "Liquidator: invalid vault");
        require(user != address(0), "Liquidator: invalid user");
        require(seizeAmount > 0, "Liquidator: zero seizeAmount");

        (bool underCollateral, ) = checkUnderCollateral(vault, user);
        require(underCollateral, "Liquidator: user not undercollateralized");

        IVaultLiquidation v = IVaultLiquidation(vault);
        uint256 userShares = v.balanceOf(user);
        require(userShares >= seizeAmount, "Liquidator: user has fewer shares than seizeAmount");

        // Enforce max liquidation ratio
        uint256 maxSeizable = (userShares * maxLiquidationBps) / 10000;
        require(seizeAmount <= maxSeizable, "Liquidator: exceed max liquidation ratio");

        // Compute fee in shares
        uint256 feeShares = (seizeAmount * liquidationFeeBps) / 10000;
        uint256 totalSeize = seizeAmount + feeShares;
        require(userShares >= totalSeize, "Liquidator: totalSeize > userShares");

        // Forcibly remove shares from the user and assign them to this contract's owner 
        // the owner can decide how to handle them (reward a third-party, penalize user, lock to an address etc.).
        v.seizeShares(user, totalSeize, owner());

        emit LiquidationExecuted(vault, msg.sender, user, seizeAmount, feeShares, owner());
    }
}
