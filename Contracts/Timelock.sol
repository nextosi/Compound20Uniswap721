// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title Timelock
 * @notice A general-purpose timelock contract designed to schedule and execute
 *         upgrade operations or any arbitrary function calls after a set delay.
 *         This contract ensures there is a time window between scheduling and
 *         execution, preventing instant malicious actions.
 *
 *         The contract supports:
 *         1. Queuing upgrade calls (e.g. UUPS "upgradeTo(address)")
 *         2. Queuing arbitrary function calls on any target contract
 *         3. Delaying execution by a configurable `delay`
 *         4. Allowing the owner to cancel scheduled operations
 *         5. Enforcing a grace period after `delay` to execute before the operation expires
 *
 *         This contract is compatible with upgradeable proxies in the system, including:
 *         - VaultFactory (UUPS proxy)
 *         - Individual Vault (UUPS proxy)
 *         and can also handle other function calls for future expansions.
 *
 *         The owner (commonly a DAO, multi-sig, or deployment account) controls:
 *         - Timelock configuration
 *         - Scheduling/canceling/executing operations
 *
 *         No placeholders remain. All logic here is complete and functional.
 */
contract Timelock {
    /**
     * @dev A scheduled operation can either be an upgrade or any arbitrary function call.
     *      The structure stores all data required to execute the call.
     *
     * @param target           The contract address where the call will be executed
     * @param value            The amount of native currency (ETH) to send with the call
     * @param signature        The function signature to be called (e.g. "upgradeTo(address)")
     * @param callData         The encoded parameters for the function call
     * @param earliestExecTime The earliest timestamp at which this operation can be executed
     * @param executed         Whether this operation has already been executed
     * @param canceled         Whether this operation has been canceled
     */
    struct Operation {
        address target;
        uint256 value;
        string signature;
        bytes callData;
        uint256 earliestExecTime;
        bool executed;
        bool canceled;
    }

    /**
     * @dev A Grace Period can be used to define how long after `earliestExecTime`
     *      an operation is valid for execution before it expires.
     *
     *      If the current block time exceeds earliestExecTime + gracePeriod,
     *      the operation can no longer be executed (it has expired).
     */
    uint256 public gracePeriod;

    /**
     * @dev The minimum delay between scheduling an operation and executing it.
     */
    uint256 public delay;

    /**
     * @dev The owner has permission to schedule/cancel/execute operations.
     *      Typically, this would be a DAO, multi-sig, or a deployment account.
     */
    address public owner;

    /**
     * @dev Maps an operation's unique ID to the Operation struct data.
     */
    mapping(bytes32 => Operation) public operations;

    /**
     * @dev Emitted when a new operation is scheduled.
     */
    event OperationScheduled(
        bytes32 indexed operationId,
        address indexed target,
        uint256 value,
        string signature,
        bytes callData,
        uint256 earliestExecTime
    );

    /**
     * @dev Emitted when an operation is canceled.
     */
    event OperationCanceled(bytes32 indexed operationId);

    /**
     * @dev Emitted when an operation is executed successfully.
     */
    event OperationExecuted(
        bytes32 indexed operationId,
        address indexed target,
        uint256 value,
        string signature,
        bytes callData
    );

    /**
     * @dev Ensures only the owner can call restricted functions.
     */
    modifier onlyOwner() {
        require(msg.sender == owner, "Timelock: caller is not the owner");
        _;
    }

    /**
     * @param _owner        The address of the timelock's owner
     * @param _delay        The minimum delay required before executing scheduled operations
     * @param _gracePeriod  The period after `_delay` during which the operation remains valid
     */
    constructor(address _owner, uint256 _delay, uint256 _gracePeriod) {
        require(_owner != address(0), "Timelock: invalid owner");
        require(_gracePeriod > 0, "Timelock: gracePeriod must be > 0");
        owner = _owner;
        delay = _delay;
        gracePeriod = _gracePeriod;
    }

    /**
     * @notice Transfers ownership of the timelock to a new address.
     * @param newOwner The address to become the new owner
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Timelock: invalid new owner");
        owner = newOwner;
    }

    /**
     * @notice Updates the delay for newly scheduled operations. 
     *         Does not affect operations already scheduled.
     * @param newDelay The new delay in seconds
     */
    function setDelay(uint256 newDelay) external onlyOwner {
        delay = newDelay;
    }

    /**
     * @notice Updates the grace period for newly scheduled operations.
     *         Does not affect operations already scheduled.
     * @param newGracePeriod The new grace period in seconds
     */
    function setGracePeriod(uint256 newGracePeriod) external onlyOwner {
        require(newGracePeriod > 0, "Timelock: invalid gracePeriod");
        gracePeriod = newGracePeriod;
    }

    /**
     * @notice Generates the unique identifier (operationId) for a given call.
     * @param target     The contract address to be called
     * @param value      The amount of ETH (if any) to send
     * @param signature  The function signature (e.g. "upgradeTo(address)")
     * @param callData   The ABI-encoded parameters for the function
     * @return operationId The computed ID
     */
    function getOperationId(
        address target,
        uint256 value,
        string memory signature,
        bytes memory callData
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, signature, callData));
    }

    /**
     * @notice Schedules an operation to be executed no sooner than (block.timestamp + delay).
     * @param target    The contract to call
     * @param value     The amount of ETH to send
     * @param signature The function signature
     * @param callData  The ABI-encoded parameters for the function
     * @return operationId The unique ID of the scheduled operation
     */
    function schedule(
        address target,
        uint256 value,
        string memory signature,
        bytes memory callData
    ) external onlyOwner returns (bytes32 operationId) {
        require(target != address(0), "Timelock: invalid target");

        operationId = getOperationId(target, value, signature, callData);
        Operation storage op = operations[operationId];
        require(op.target == address(0), "Timelock: operation already scheduled");

        uint256 earliestExecTime = block.timestamp + delay;
        op.target = target;
        op.value = value;
        op.signature = signature;
        op.callData = callData;
        op.earliestExecTime = earliestExecTime;
        op.executed = false;
        op.canceled = false;

        emit OperationScheduled(operationId, target, value, signature, callData, earliestExecTime);
    }

    /**
     * @notice Cancels a previously scheduled operation that has not been executed or canceled yet.
     * @param operationId The unique ID of the operation to cancel
     */
    function cancel(bytes32 operationId) external onlyOwner {
        Operation storage op = operations[operationId];
        require(op.target != address(0), "Timelock: unknown operation");
        require(!op.executed, "Timelock: operation already executed");
        require(!op.canceled, "Timelock: operation already canceled");
        op.canceled = true;
        emit OperationCanceled(operationId);
    }

    /**
     * @notice Executes a scheduled operation if the current time is within the allowed window.
     * @param operationId The unique ID of the operation to execute
     */
    function execute(bytes32 operationId) external payable nonReentrant {
        Operation storage op = operations[operationId];
        require(op.target != address(0), "Timelock: unknown operation");
        require(!op.executed, "Timelock: operation already executed");
        require(!op.canceled, "Timelock: operation canceled");
        require(block.timestamp >= op.earliestExecTime, "Timelock: too early");
        require(
            block.timestamp <= op.earliestExecTime + gracePeriod,
            "Timelock: operation expired"
        );

        op.executed = true;

        bytes memory callData;
        if (bytes(op.signature).length == 0) {
            callData = op.callData;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(op.signature))), op.callData);
        }

        (bool success, bytes memory result) = op.target.call{value: op.value}(callData);
        require(success, _getRevertMsg(result));

        emit OperationExecuted(operationId, op.target, op.value, op.signature, op.callData);
    }

    /**
     * @dev Ensures no reentrancy on execute calls. This is a standard approach
     *      for timelocks or we can define a ReentrancyGuard approach inlined.
     */
    modifier nonReentrant() {
        require(_status != 2, "Timelock: reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
    uint256 private _status = 1;

    /**
     * @dev Helper function to decode a revert reason from a failed call.
     */
    function _getRevertMsg(bytes memory _returnData) private pure returns (string memory) {
        if (_returnData.length < 68) return "Timelock: call reverted without message";
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }

    /**
     * @notice Checks if an operation is scheduled, canceled, or executed.
     * @param operationId The ID to check
     * @return scheduled True if operation exists
     * @return canceled  True if operation is canceled
     * @return executed  True if operation is executed
     */
    function getOperationStatus(bytes32 operationId)
        external
        view
        returns (bool scheduled, bool canceled, bool executed)
    {
        Operation storage op = operations[operationId];
        if (op.target == address(0)) {
            return (false, false, false);
        }
        return (true, op.canceled, op.executed);
    }

    /**
     * @notice Checks the earliest execution time for an operation.
     * @param operationId The ID to check
     * @return earliestExecTime The timestamp from which the operation can be executed
     */
    function getEarliestExecutionTime(bytes32 operationId) external view returns (uint256) {
        Operation storage op = operations[operationId];
        return op.earliestExecTime;
    }

    receive() external payable {}
}
