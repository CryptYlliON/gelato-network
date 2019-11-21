pragma solidity ^0.5.10;

import './GelatoUserProxyManager.sol';
import './GelatoCoreAccounting.sol';
import '@openzeppelin/contracts-ethereum-package/contracts/drafts/Counters.sol';

/**
 * @title GelatoCore
 * @notice minting, storing, cancelling, and execution of executionClaims
 * @dev deployable contract
 */
contract GelatoCore is GelatoUserProxyManager,
                       GelatoCoreAccounting
{
    using Address for address payable;  /// for oz's sendValue method

    /// @dev initializer fn must call the initializers of all the base contracts.
    ///       visibility must be public due to Reentrancy Guard overriding
    /// @notice GelatoCore's initializer function (constructor for upgradeable contracts)
    function initialize()
        public
        initializer
    {
        GelatoCoreAccounting._initialize();
    }

    // Unique ExecutionClaim Ids
    using Counters for Counters.Counter;
    Counters.Counter private executionClaimIds;
    /**
     * @dev get the current executionClaimId
     * @return uint256 current executionClaim Id
     */
    function getCurrentExecutionClaimId()
        external
        view
        returns(uint256 currentId)
    {
        currentId = executionClaimIds.current();
    }

    // executionClaimId => userProxyByExecutionClaimId
    mapping(uint256 => address) private userProxyByExecutionClaimId;
    /**
     * @dev api to read from the userProxyByExecutionClaimId state variable
     * @param _executionClaimId z
     * @return address of the userProxy behind _executionClaimId
     */
    function getUserProxyWithExecutionClaimId(uint256 _executionClaimId)
        external
        view
        returns(address)
    {
        return userProxyByExecutionClaimId[_executionClaimId];
    }

    function getUserWithExecutionClaimId(uint256 _executionClaimId)
        external
        view
        returns(address payable)
    {
        address userProxy = userProxyByExecutionClaimId[_executionClaimId];
        return proxyToUser[userProxy];
    }

    // executionClaimId => bytes32 executionClaimHash
    mapping(uint256 => bytes32) private hashedExecutionClaims;
    /**
     * @dev interface to read from the hashedExecutionClaims state variable
     * @param _executionClaimId z
     * @return the bytes32 hash of the executionClaim with _executionClaimId
     */
    function getHashedExecutionClaim(uint256 _executionClaimId)
        external
        view
        returns(bytes32)
    {
        return hashedExecutionClaims[_executionClaimId];
    }

    // $$$$$$$$$$$ mintExecutionClaim() API  $$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$
    event LogNewExecutionClaimMinted(address indexed selectedExecutor,
                                     uint256 indexed executionClaimId,
                                     address indexed userProxy,
                                     bytes actionPayload,
                                     uint256 userProxyExecGas,
                                     uint256 executionClaimExpiryDate,
                                     uint256 mintingDeposit
    );
    event LogTriggerActionMinted(uint256 indexed executionClaimId,
                                 address indexed trigger,
                                 bytes triggerPayload,
                                 address indexed action
    );
    /**
     * @dev API for minting execution claims on gelatoCore
     * @param _trigger: the address of the trigger
     * @param _triggerPayload: the encoded trigger params with function selector
     * @param _action: the address of the action
     * @param _actionPayload: the encoded action params with function selector
     * @param _selectedExecutor: the registered executor to service this claim
     * @notice re-entrancy guard because accounting ops are present inside fn
     * @notice msg.value is a refundable deposit - only a fee if executed
     * @notice minting event split into two, due to stack too deep issue
     */
    function mintExecutionClaim(address _trigger,
                                bytes calldata _triggerPayload,
                                address _action,
                                bytes calldata _actionPayload,
                                address payable _selectedExecutor

    )
        external
        payable
        onlyRegisteredExecutors(_selectedExecutor)
        nonReentrant
    {
        // ______ Authenticate msg.sender is proxied user or a proxy _______
        address userProxy;
        if (_isUser(msg.sender)) userProxy = userToProxy[msg.sender];
        else if (_isUserProxy(msg.sender)) userProxy = msg.sender;
        else revert("GelatoCore.mintExecutionClaim: msg.sender is not proxied");
        // =============
        // ______ Charge Minting Deposit _______________________________________
        uint256 actionGasStipend = IGelatoAction(_action).getActionGasStipend();
        {
            uint256 executionMinGas = _getMinExecutionGasRequirement(actionGasStipend);
            uint256 mintingDepositPayable
                = executionMinGas.mul(executorPrice[_selectedExecutor]);
            require(msg.value == mintingDepositPayable,
                "GelatoCore.mintExecutionClaim: msg.value failed"
            );
        }
        // =============
        // ______ Mint new executionClaim ______________________________________
        Counters.increment(executionClaimIds);
        uint256 executionClaimId = executionClaimIds.current();
        userProxyByExecutionClaimId[executionClaimId] = userProxy;
        // =============
        // ______ ExecutionClaim Hashing ______________________________________
        uint256 executionClaimExpiryDate
            = now.add(executorClaimLifespan[_selectedExecutor]);
        {
            /// @notice Include executionClaimId to avoid hash collisions
            bytes32 executionClaimHash
                = keccak256(abi.encodePacked(_trigger,
                                             _triggerPayload,
                                             userProxy,
                                             _actionPayload,
                                             executionClaimId,
                                             _selectedExecutor,
                                             userProxyExecGasOverhead.add(actionGasStipend),
                                             executionClaimExpiryDate,
                                             msg.value
            ));
            hashedExecutionClaims[executionClaimId] = executionClaimHash;
        }
        // =============
        emit LogNewExecutionClaimMinted(_selectedExecutor,
                                        executionClaimId,
                                        userProxy,
                                        _actionPayload,
                                        userProxyExecGasOverhead.add(actionGasStipend),
                                        executionClaimExpiryDate,
                                        msg.value
        );
        emit LogTriggerActionMinted(executionClaimId, _trigger, _triggerPayload, _action);
    }
    // $$$$$$$$$$$$$$$ mintExecutionClaim() API END


    // ********************* EXECUTE FUNCTION SUITE *********************
    //  checked by canExecute and returned as a uint256 from User
    enum CanExecuteCheck {
        WrongCalldataOrAlreadyDeleted,  // also returns if a not-selected executor calls fn
        NonExistantExecutionClaim,
        ExecutionClaimExpired,
        TriggerReverted,
        NotExecutable,
        Executable
    }

    /// @dev canExecute API forwards its calls to this private function
    function _canExecute(address _trigger,
                         bytes memory _triggerPayload,
                         address _userProxy,
                         bytes memory _actionPayload,
                         uint256 _userProxyExecGas,
                         uint256 _executionClaimId,
                         uint256 _executionClaimExpiryDate,
                         uint256 _mintingDeposit
    )
        private
        view
        returns (CanExecuteCheck)
    {
        // _____________ Static CHECKS __________________________________________
        // Compute executionClaimHash from calldata
        bytes32 computedExecutionClaimHash
            = keccak256(abi.encodePacked(_trigger,
                                         _triggerPayload,
                                         _userProxy,
                                         _actionPayload,
                                         _executionClaimId,
                                         msg.sender,  // selected? executor
                                         _userProxyExecGas,
                                         _executionClaimExpiryDate,
                                         _mintingDeposit
        ));
        // Check passed calldata and that msg.sender is selected executor
        if(computedExecutionClaimHash != hashedExecutionClaims[_executionClaimId]) {
            return CanExecuteCheck.WrongCalldataOrAlreadyDeleted;
        }
        // Require execution claim to exist / not be cancelled
        if (userProxyByExecutionClaimId[_executionClaimId] == address(0)) {
            return CanExecuteCheck.NonExistantExecutionClaim;
        }
        if (_executionClaimExpiryDate < now) {
            return CanExecuteCheck.ExecutionClaimExpired;
        }
        // =========
        // _____________ Dynamic CHECKS __________________________________________
        // Call to trigger view function (returns(bool))
        (bool success,
         bytes memory returndata) = (_trigger.staticcall
                                             .gas(canExecMaxGas)
                                             (_triggerPayload)
        );
        if (!success) {
            return CanExecuteCheck.TriggerReverted;
        } else {
            bool executable = abi.decode(returndata, (bool));
            if (executable) {
                return CanExecuteCheck.Executable;
            } else {
                return CanExecuteCheck.NotExecutable;
            }
        }
        // ==============
    }
    /**
     * @dev the API for executors to check whether a claim is executable
     * @param _trigger executors get this from LogTriggerActionMinted
     * @param _triggerPayload executors get this from LogTriggerActionMinted
     * @param _userProxy executors get this from LogExecutionClaimMinted
     * @param _actionPayload executors get this from LogExecutionClaimMinted
     * @param _userProxyExecGas executors get this from LogExecutionClaimMinted
     * @param _executionClaimId executors get this from LogExecutionClaimMinted
     * @param _executionClaimExpiryDate executors get this from LogExecutionClaimMinted
     * @param _mintingDeposit executors get this from LogExecutionClaimMinted
     * @return uint8 which converts to one of enum CanExecuteCheck values
     * @notice if return value == 6, the claim is executable
     */
    function canExecute(address _trigger,
                        bytes calldata _triggerPayload,
                        address _userProxy,
                        bytes calldata _actionPayload,
                        uint256 _userProxyExecGas,
                        uint256 _executionClaimId,
                        uint256 _executionClaimExpiryDate,
                        uint256 _mintingDeposit
    )
        external
        view
        returns (CanExecuteCheck)
    {
        return _canExecute(_trigger,
                           _triggerPayload,
                           _userProxy,
                           _actionPayload,
                           _userProxyExecGas,
                           _executionClaimId,
                           _executionClaimExpiryDate,
                           _mintingDeposit
        );
    }

    // ********************* EXECUTE FUNCTION SUITE *************************
    event LogCanExecuteFailed(uint256 indexed executionClaimId,
                              address payable indexed executor,
                              CanExecuteCheck indexed canExecuteResult
    );
    event LogExecutionResult(uint256 indexed executionClaimId,
                             ExecutionResult indexed executionResult,
                             address payable indexed executor
    );
    event LogClaimExecutedAndDeleted(uint256 indexed executionClaimId,
                                     address indexed userProxy,
                                     address payable indexed executor,
                                     uint256 gasCheck,
                                     uint256 gasPriceUsed,
                                     uint256 executionCostEstimate,
                                     uint256 executorPayout
    );
    event LogUserProxyExecuteGas(uint256 gasBefore, uint256 gasAfter, uint256 delta);

    enum ExecutionResult {
        Success,
        Failure,
        CanExecuteFailed
    }

    /**
     * @dev the API executors call when they execute an executionClaim
     * @param _trigger executors get this from LogTriggerActionMinted
     * @param _triggerPayload executors get this from LogTriggerActionMinted
     * @param _userProxy executors get this from LogExecutionClaimMinted
     * @param _actionPayload executors get this from LogExecutionClaimMinted
     * @param _action executors get this from LogTriggerActionMinted
     * @param _userProxyExecGas executors get this from LogExecutionClaimMinted
     * @param _executionClaimId executors get this from LogExecutionClaimMinted
     * @param _executionClaimExpiryDate executors get this from LogExecutionClaimMinted
     * @param _mintingDeposit executors get this from LogExecutionClaimMinted
     * @return uint8 which converts to one of enum ExecutionResult values
     * @notice if return value == 0, the claim got executed
     * @notice re-entrancy protection due to accounting operations and interactions
     */
    function execute(address _trigger,
                     bytes calldata _triggerPayload,
                     address _userProxy,
                     bytes calldata _actionPayload,
                     address _action,
                     uint256 _userProxyExecGas,
                     uint256 _executionClaimId,
                     uint256 _executionClaimExpiryDate,
                     uint256 _mintingDeposit

    )
        external
        nonReentrant
        returns(ExecutionResult executionResult)
    {
        // Ensure that executor sends enough gas for the execution
        uint256 startGas = gasleft();
        require(startGas >= _getMinExecutionGasRequirement(_userProxyExecGas.sub(userProxyExecGasOverhead)),
            "GelatoCore.execute: Insufficient gas sent"
        );
        // _______ canExecute() check ______________________________________________
        {
            CanExecuteCheck canExecuteResult = _canExecute(_trigger,
                                                           _triggerPayload,
                                                           _userProxy,
                                                           _actionPayload,
                                                           _userProxyExecGas,
                                                           _executionClaimId,
                                                           _executionClaimExpiryDate,
                                                           _mintingDeposit
            );
            if (canExecuteResult != CanExecuteCheck.Executable) {
                emit LogCanExecuteFailed(_executionClaimId,
                                         msg.sender,
                                         canExecuteResult
                );
                return ExecutionResult.CanExecuteFailed;
            }
        }
        // ========
        // _________________________________________________________________________
        /// @notice We are past the canExecute latency problem between executors
        ///  initial call to canExecute, and the internal call to canExecute we
        ///  performed above inside the execute fn. This means that there should
        ///  be no more reverts UNLESS 1) trigger and/or action are buggy,
        ///  2) user has insufficient funds at disposal at execution time (e.g.
        ///   has approved funds, but in the interim has transferred them elsewhere)

        // **** EFFECTS (checks - effects - interactions) ****
        delete hashedExecutionClaims[_executionClaimId];
        delete userProxyByExecutionClaimId[_executionClaimId];

        // _________  call to userProxy.execute => action  __________________________
        {
            uint256 gasBefore = gasleft();
            (bool success,) = (GelatoUserProxy(_userProxy).execute
                                                          .gas(_userProxyExecGas)
                                                          (_action, _actionPayload)
            );
            LogUserProxyExecuteGas(gasBefore, gasleft(), gasBefore - gasleft());
            if (success) executionResult = ExecutionResult.Success;
            // @dev if execution fails, no revert, because executor still paid out
            else executionResult = ExecutionResult.Failure;
            emit LogExecutionResult(_executionClaimId, executionResult, msg.sender);
        }
        // ========
        // Balance Updates (INTERACTIONS)
        executorBalance[msg.sender] = executorBalance[msg.sender].add(_mintingDeposit);
        // ====
        {
            uint256 gasCheck = startGas.sub(gasleft());
            // gasCheck does not have the initial gas and the emit LogClaimExec.. gas
            uint256 executionCostEstimate = gasCheck.mul(tx.gasprice).add(70000);
            emit LogClaimExecutedAndDeleted(_executionClaimId,
                                            _userProxy,
                                            msg.sender,  // executor
                                            gasCheck,
                                            tx.gasprice,
                                            executionCostEstimate,
                                            _mintingDeposit
            );
        }
    }
    // ************** execute() END
    // ********************* EXECUTE FUNCTION SUITE END


    // ********************* cancelExecutionClaim() *********************
    /**
     * @dev API for canceling executionClaims
     * @param _trigger callers get this from LogTriggerActionMinted
     * @param _triggerPayload callers get this from LogTriggerActionMinted
     * @param _userProxy callers get this from LogExecutionClaimMinted
     * @param _actionPayload callers get this from LogExecutionClaimMinted
     * @param _executionClaimId callers get this from LogExecutionClaimMinted
     * @param _selectedExecutor callers get this from LogExecutionClaimMinted
     * @param _userProxyExecGas callers get this from LogExecutionClaimMinted
     * @param _executionClaimExpiryDate callers get this from LogExecutionClaimMinted
     * @param _mintingDeposit callers get this from LogExecutionClaimMinted
     * @notice re-entrancy protection due to accounting operations and interactions
     * @notice prior to executionClaim expiry, only owner of _userProxy can cancel
        for a refund. Post executionClaim expiry, _selectedExecutor can also cancel,
        for a reward.
     * @notice .sendValue instead of .transfer due to IstanbulHF
     */
    function cancelExecutionClaim(address _trigger,
                                  bytes calldata _triggerPayload,
                                  address _userProxy,
                                  bytes calldata _actionPayload,
                                  uint256 _executionClaimId,
                                  address payable _selectedExecutor,
                                  uint256 _userProxyExecGas,
                                  uint256 _executionClaimExpiryDate,
                                  uint256 _mintingDeposit
    )
        external
        nonReentrant
    {
        {
            if (msg.sender != proxyToUser[_userProxy]) {
                require(_executionClaimExpiryDate <= now && msg.sender == _selectedExecutor,
                    "GelatoCore.cancelExecutionClaim: only selected executor post expiry"
                );
            }
        }
        {
            bytes32 computedExecutionClaimHash
                = keccak256(abi.encodePacked(_trigger,
                                             _triggerPayload,
                                             _userProxy,
                                             _actionPayload,
                                             _executionClaimId,
                                             _selectedExecutor,
                                             _userProxyExecGas,
                                             _executionClaimExpiryDate,
                                             _mintingDeposit
            ));
            require(computedExecutionClaimHash == hashedExecutionClaims[_executionClaimId],
                "GelatoCore.cancelExecutionClaim: hash compare failed"
            );
        }
        delete userProxyByExecutionClaimId[_executionClaimId];
        delete hashedExecutionClaims[_executionClaimId];
        emit LogExecutionClaimCancelled(_executionClaimId, _userProxy, msg.sender);
        msg.sender.sendValue(_mintingDeposit);
    }
    event LogExecutionClaimCancelled(uint256 indexed executionClaimId,
                                     address indexed userProxy,
                                     address indexed cancelor
    );
    // ********************* cancelExecutionClaim() END
}