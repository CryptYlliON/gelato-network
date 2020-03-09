pragma solidity ^0.6.2;

import "./interfaces/IGelatoCore.sol";
import "./GelatoGasPriceOracle.sol";
import "./GelatoExecutor.sol";
import "./GelatoProvider.sol";
import "./GelatoUserProxyFactory.sol";
import "../external/Counters.sol";
import "./interfaces/IGnosisSafe.sol";

/// @title GelatoCore
/// @notice Execution Claim: minting, checking, execution, and cancellation
/// @dev Find all NatSpecs inside IGelatoCore
contract GelatoCore is
    IGelatoCore, GelatoGasPriceOracle, GelatoProvider, GelatoExecutor, GelatoUserProxyFactory
{
    // Library for unique ExecutionClaimIds
    using Counters for Counters.Counter;
    using Address for address payable;  /// for oz's sendValue method

    // ================  STATE VARIABLES ======================================
    Counters.Counter public override currentExecutionClaimId;
    // executionClaimId => userProxy
    mapping(uint256 => address) public override userProxyByExecutionClaimId;
    // executionClaimId => bytes32 executionClaimHash
    mapping(uint256 => bytes32) public override executionClaimHash;
    // The maximum gas an executor can consume on behalf of a provider
    uint256 public constant override MAXGAS = 6000000;

    // ========= Proxy Creation and Minting in 1 tx
    function createProxyAndMint(
        address _mastercopy,
        bytes calldata _initializer,
        address[2] calldata _selectedProviderAndExecutor,
        address[2] calldata _conditionAndAction,
        bytes calldata _conditionPayload,
        bytes calldata _actionPayload,
        uint256 _executionClaimExpiryDate
    )
        external
        payable
        override
        returns(address)  // address userProxy
    {
        createGelatoUserProxy(_mastercopy, _initializer);
        mintExecutionClaim(
            _selectedProviderAndExecutor,
            _conditionAndAction,
            _conditionPayload,
            _actionPayload,
            _executionClaimExpiryDate
        );
    }


    // ================  MINTING ==============================================
    function mintExecutionClaim(
        address[2] memory _selectedProviderAndExecutor,
        address[2] memory _conditionAndAction,
        bytes memory _conditionPayload,
        bytes memory _actionPayload,
        uint256 _executionClaimExpiryDate
    )
        public
        override
    {
        // Standard core checks
        _liquidProvider(_selectedProviderAndExecutor[0], gelatoGasPrice, MAXGAS);
        _registeredExecutor(_selectedProviderAndExecutor[1]);
        _maxExecutionClaimLifespan(_selectedProviderAndExecutor[1], _executionClaimExpiryDate);

        // Checks below will be separated onto provider module
        // msgSenderCheck();
        // @DEV add require later !
        isProvidedCondition[_selectedProviderAndExecutor[0]][_conditionAndAction[0]];
        isProvidedAction[_selectedProviderAndExecutor[0]][_conditionAndAction[1]];

        // We cut this after initial testing
        address userProxy;
        if (isGelatoProxyUser(msg.sender)) {
            userProxy = gelatoProxyByUser[msg.sender];
        } else if (isGelatoUserProxy(msg.sender)) {
            userProxy = msg.sender;
        } else {
            revert(
                "GelatoCore.mintExecutionClaim: caller must be registered user or proxy"
            );
        }

        // Mint new executionClaim
        currentExecutionClaimId.increment();
        uint256 executionClaimId = currentExecutionClaimId.current();
        userProxyByExecutionClaimId[executionClaimId] = userProxy;

        // ExecutionClaim Expiry Date defaults to executor's maximum allowance
        if (_executionClaimExpiryDate == 0) {
            _executionClaimExpiryDate = now.add(
                executorClaimLifespan[_selectedProviderAndExecutor[1]]
            );
        }

        // ExecutionClaim Hashing
        executionClaimHash[executionClaimId] = _computeExecutionClaimHash(
            _selectedProviderAndExecutor,
            executionClaimId,  // To avoid hash collisions
            userProxy,
            _conditionAndAction,
            _conditionPayload,
            _actionPayload,
            _executionClaimExpiryDate
        );

        emit LogExecutionClaimMinted(
            _selectedProviderAndExecutor,
            executionClaimId,
            userProxy,
            _conditionAndAction,
            _conditionPayload,
            _actionPayload,
            _executionClaimExpiryDate
        );
    }

    // ================  CAN EXECUTE EXECUTOR API ============================
    function canExecute(
        address[2] memory _selectedProviderAndExecutor,
        uint256 _executionClaimId,
        address _userProxy,
        address[2] memory _conditionAndAction,
        bytes memory _conditionPayload,
        bytes memory _actionPayload,
        uint256 _executionClaimExpiryDate
    )
        public
        view
        override
        returns (string memory canExecuteResult)
    {
        if (!isProviderLiquid(_selectedProviderAndExecutor[0], gelatoGasPrice, MAXGAS))
            return "ProviderIlliquidity";

        if (executionClaimHash[_executionClaimId] == bytes32(0)) {
            if (_executionClaimId <= currentExecutionClaimId.current())
                return "AlreadyExecutedOrCancelled";
            else return "NonExistant";
        }

        if (_executionClaimExpiryDate < now) return "Expired";

        bytes32 computedExecutionClaimHash = _computeExecutionClaimHash(
            _selectedProviderAndExecutor,
            _executionClaimId,
            _userProxy,
            _conditionAndAction,
            _conditionPayload,
            _actionPayload,
            _executionClaimExpiryDate
        );

        if (computedExecutionClaimHash != executionClaimHash[_executionClaimId])
            return "WrongCalldataOrMsgSender";

        // Self-Conditional Actions pass and return
        if (_conditionAndAction[0] == address(0)) return "ok";
        else {
            // Dynamic Checks needed for Conditional Actions
            (bool success, bytes memory returndata) = _conditionAndAction[0].staticcall(
                _conditionPayload
            );
            if (!success) return "UnhandledConditionError";
            else {
                bool conditionReached;
                string memory reason;
                (conditionReached, reason) = abi.decode(returndata, (bool, string));
                if (conditionReached) return "ok";
                return string(abi.encodePacked("ConditionNotOk: ", reason));
            }
        }
    }

    // ================  EXECUTE EXECUTOR API ============================
    enum ExecutorPayout {
        Reward,
        Refund
    }

    function execute(
        address[2] calldata _selectedProviderAndExecutor,
        uint256 _executionClaimId,
        address _userProxy,
        address[2] calldata _conditionAndAction,
        bytes calldata _conditionPayload,
        bytes calldata _actionPayload,
        uint256 _executionClaimExpiryDate
    )
        external
        override
    {
        uint256 startGas = gasleft();
        // CHECKS
        require(
            tx.gasprice == gelatoGasPrice,
            "GelatoCore.execute: tx.gasprice must be gelatoGasPrice"
        );
        require(
            startGas < MAXGAS,
            "GelatoCore.execute: too much gas sent"
        );
        require(
            startGas > MAXGAS - 100000,  // 100k overhead buffer
            "GelatoCore.execute: insufficient gas sent"
        );

        // canExecute()
        {
            string memory canExecuteResult  = canExecute(
                [_selectedProviderAndExecutor[0], msg.sender],
                _executionClaimId,
                _userProxy,
                _conditionAndAction,
                _conditionPayload,
                _actionPayload,
                _executionClaimExpiryDate
            );

            if (
                keccak256(abi.encodePacked(canExecuteResult)) ==
                keccak256(abi.encodePacked("ok"))
            ) {
                emit LogCanExecuteSuccess(
                    _selectedProviderAndExecutor,
                    _executionClaimId,
                    _userProxy,
                    _conditionAndAction,
                    canExecuteResult
                );
            } else {
                emit LogCanExecuteFailed(
                    _selectedProviderAndExecutor,
                    _executionClaimId,
                    _userProxy,
                    _conditionAndAction,
                    canExecuteResult
                );
                return;  // END OF EXECUTION
            }
        }

        // EFFECTS
        delete executionClaimHash[_executionClaimId];
        delete userProxyByExecutionClaimId[_executionClaimId];

        // INTERACTIONS
        string memory executionFailureReason;

        try IGnosisSafe(_userProxy).execTransactionFromModuleReturnData(
            _conditionAndAction[1],  // to
            0,  // value
            _actionPayload,  // data
            IGnosisSafe.Operation.DelegateCall
        ) returns (bool actionExecuted, bytes memory actionRevertReason) {
            // Success
            if (actionExecuted) {
                emit LogSuccessfulExecution(
                    _selectedProviderAndExecutor,
                    msg.sender,
                    _executionClaimId,
                    _userProxy,
                    _conditionAndAction
                );
                // Executor is REWARDED for SUCCESSFUL execution
                _executorPayout(
                    startGas,
                    ExecutorPayout.Reward,
                    _selectedProviderAndExecutor[0]
                );
            } else {
                // 68: 32-location, 32-length, 4-ErrorSelector, UTF-8 revertReason
                if (actionRevertReason.length % 32 == 4) {
                    bytes4 selector;
                    assembly { selector := actionRevertReason }
                    if (selector == 0x08c379a0) {  // Function selector for Error(string)
                        assembly { actionRevertReason := add(actionRevertReason, 68) }
                        executionFailureReason = string(actionRevertReason);
                    } else {
                        executionFailureReason = "NoErrorSelector";
                    }
                } else {
                    executionFailureReason = "UnexpectedReturndata";
                }
            }
        } catch Error(string memory gnosisSafeProxyRevertReason) {
            executionFailureReason = gnosisSafeProxyRevertReason;
        } catch {
            executionFailureReason = "UndefinedGnosisSafeProxyError";
        }

        // Executor is REFUNDED for FAILED attempt
        _executorPayout(startGas, ExecutorPayout.Refund, _selectedProviderAndExecutor[0]);

        // Failure
        emit LogExecutionFailure(
            _selectedProviderAndExecutor,
            msg.sender,  // executor
            _executionClaimId,
            _userProxy,
            _conditionAndAction,
            executionFailureReason
        );
    }

    function _executorPayout(
        uint256 _startGas,
        ExecutorPayout _payoutType,
        address _provider
    )
        private
    {
        // ExecutionCost (- consecutive state writes + gas refund from deletion)
        uint256 estExecutionCost = (_startGas - gasleft()).mul(gelatoGasPrice);

        if (_payoutType == ExecutorPayout.Reward) {
            // Provider refunds cost + 3% reward to executor
            providerFunds[_provider] = providerFunds[_provider].sub(
                estExecutionCost,
                "GelatoCore._executorPayout: providerFunds underflow"
            );
            executorBalance[msg.sender] = executorBalance[msg.sender] + SafeMath.div(
                estExecutionCost.mul(103),
                100,
                "GelatoCore._executorPayout: division error"
            );
        } else {
            // Provider refunds cost to executor
            providerFunds[_provider] = providerFunds[_provider].sub(
                estExecutionCost,
                "GelatoCore._executorPayout: providerFunds underflow"
            );
            executorBalance[msg.sender] = executorBalance[msg.sender] + estExecutionCost;
        }
    }

    // ================  CANCEL USER / EXECUTOR API ============================
    function cancelExecutionClaim(
        address[2] calldata _selectedProviderAndExecutor,
        uint256 _executionClaimId,
        address _userProxy,
        address[2] calldata _conditionAndAction,
        bytes calldata _conditionPayload,
        bytes calldata _actionPayload,
        uint256 _executionClaimExpiryDate
    )
        external
        override
    {
        // Checks
        bool executionClaimExpired = _executionClaimExpiryDate <= now;
        if (
            msg.sender != userByGelatoProxy[_userProxy] && msg.sender != _userProxy
        ) {
            require(
                executionClaimExpired,
                "GelatoCore.cancelExecutionClaim: msgSender problem"
            );
        }
        bytes32 computedExecutionClaimHash = _computeExecutionClaimHash(
            _selectedProviderAndExecutor,
            _executionClaimId,
            _userProxy,
            _conditionAndAction,
            _conditionPayload,
            _actionPayload,
            _executionClaimExpiryDate
        );

        require(
            computedExecutionClaimHash == executionClaimHash[_executionClaimId],
            "GelatoCore.cancelExecutionClaim: hash compare failed"
        );

        // Effects
        delete userProxyByExecutionClaimId[_executionClaimId];
        delete executionClaimHash[_executionClaimId];

        emit LogExecutionClaimCancelled(
            _selectedProviderAndExecutor,
            _executionClaimId,
            msg.sender,
            _userProxy,
            executionClaimExpired
        );
    }

    // ================ PRIVATE HELPERS ========================================
    function _computeExecutionClaimHash(
        address[2] memory _selectedProviderAndExecutor,
        uint256 _executionClaimId,
        address _userProxy,
        address[2] memory _conditionAndAction,
        bytes memory _conditionPayload,
        bytes memory _actionPayload,
        uint256 _executionClaimExpiryDate
    )
        private
        pure
        returns(bytes32)
    {
        return keccak256(
            abi.encodePacked(
                _selectedProviderAndExecutor,
                _executionClaimId,
                _userProxy,
                _conditionAndAction,
                _conditionPayload,
                _actionPayload,
                _executionClaimExpiryDate
            )
        );
    }
}