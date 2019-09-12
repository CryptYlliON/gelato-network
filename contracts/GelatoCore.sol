pragma solidity ^0.5.10;

// Imports:
import './base/GelatoClaim.sol';
import "@openzeppelin/contracts/drafts/Counters.sol";
import '@openzeppelin/contracts/ownership/Ownable.sol';

contract GelatoCore is GelatoClaim, Ownable {
    // Libraries inherited from Claim:
    // using Counters for Counters.Counter;
    // using SafeMath for uint256;

    // **************************** Events **********************************
    event LogNewExecutionClaimMinted(address triggerAddress,
                                     bytes triggerPayload,
                                     address actionAddress,
                                     bytes actionPayload,
                                     uint256 actionMaxGas,
                                     address dappInterface,
                                     uint256 executionClaimId,
                                     bytes32 executionClaimHash,
                                     address executionClaimOwner
    );
    // Update
    // - Gelato Params
    event LogMinInterfaceBalanceUpdated(uint256 minInterfaceBalance, uint256 newMinInterfaceBalance);
    event LogExecutorProfitUpdated(uint256 executorProfit, uint256 newExecutorProfit);
    event LogExecutorGasPriceUpdated(uint256 executorGasPrice, uint256 newExecutorGasPrice);
    event LogCanExecFNMaxGasUpdated(uint256 canExecFNMaxGas, uint256 newCanExecFNMaxGas);
    event LogExecFNGas1Updated(uint256 execFNGas1, uint256 newExecFNGas1);
    event LogExecFNGas2Updated(uint256 execFNGas2, uint256 newExecFNGas2);
    event LogExecFNRefundedGasUpdated(uint256 execFNRefundedGas, uint256 newExecFNRefundedGas);
    event LogRecommendedGasPriceForInterfacesUpdated(uint256 recommendedGasPriceForInterfaces,
                                                     uint256 newRecommendedGasPriceForInterfaces
    );
    // - Interface Params
    event LogInterfaceBalanceAdded(address indexed dappInterface,
                                   uint256 oldBalance,
                                   uint256 addedAmount,
                                   uint256 newBalance
    );
    event LogInterfaceBalanceWithdrawal(address indexed dappInterface,
                                        uint256 oldBalance,
                                        uint256 withdrawnAmount,
                                        uint256 newBalance
    );
    // Execute Suite
    event LogCanExecuteFailed(address indexed executor, uint256 indexed executionClaimId);
    event LogClaimExecutedBurnedAndDeleted(address indexed dappInterface,
                                           uint256 indexed executionClaimId,
                                           address indexed executionClaimOwner,
                                           address payable executor,
                                           uint256 executorPayout,
                                           uint256 executorProfit,
                                           uint256 gasUsedEstimate,
                                           uint256 cappedGasPriceUsed,
                                           uint256 executionCostEstimate
    );
    event LogExecuteResult(bool indexed status,
                        address indexed executor,
                        uint256 indexed executionClaimId,
                        uint256 executionGas
    );
    // Delete
    event LogExecutionClaimCancelled(address indexed dappInterface,
                                     uint256 indexed executionClaimId,
                                     address indexed executionClaimOwner
    );

    // DELETE LATER
    event LogGasConsumption(uint256 indexed gasConsumed, uint256 indexed num);
    // **************************** Events END **********************************

    // **************************** State Variables **********************************
    // Gelato Version
    string public version = "0.0.3";

    // Counter for execution Claims
    Counters.Counter private _executionClaimIds;

    // executionClaimId => bytes32 executionClaimHash
    mapping(uint256 => bytes32) public executionClaims;

    // Balance of interfaces which pay for claim execution
    mapping(address => uint256) public interfaceBalances;
    // The minimum balance for an interface to mint/execute claims
    uint256 public minInterfaceBalance;

    //_____________ Gelato Execution Economics ________________
    // @DEV: every parameter should have its own UPDATE function
    // Flat number
    uint256 public executorProfit;

    // The gas price that executors must take - this must be continually set
    uint256 public executorGasPrice;
    // The gasPrice core provides as a default for interface as a basis to charge users
    uint256 public recommendedGasPriceForInterfaces;

    // Gas stipends for acceptRelayedCall, preRelayedCall and postRelayedCall
    // 50000 - set in migrate.js
    uint256 public canExecFNMaxGas;

    // Cost after first gas left and before last gas left
    // 100000 - set in migrate.js
    uint256 public execFNGas1;
    // Gas cost of all execute() instructions after endGas => 19633
    // Gas cost to initialize transaction = 21781
    // 41414 - set in migrate.js
    uint256 public execFNGas2;
    // Executor min gas refunds
    // 50000 - set in migrate.js
    uint256 public execFNRefundedGas;
    //_____________ Gelato Execution Economics END ________________

    // Execution claim is exeutable should always return 1
    uint256 constant isNotExecutable = 1;
    // **************************** State Variables END ******************************


    // **************************** Gelato Core constructor() ******************************
    constructor(uint256 _minInterfaceBalance,
                uint256 _executorProfit,
                uint256 _executorGasPrice,
                uint256 _execFNGas1,
                uint256 _execFNGas2,
                uint256 _execFNRefundedGas,
                uint256 _recommendedGasPriceForInterfaces
    )
        GelatoClaim("gelato", "GEL")  // ERC721Metadata constructor(name, symbol)
        public
    {
        minInterfaceBalance = _minInterfaceBalance;
        executorProfit = _executorProfit;
        executorGasPrice = _executorGasPrice;
        canExecFNMaxGas = _canExecFNMaxGas;
        execFNGas1 = _execFNGas1;
        execFNGas2 = _execFNGas2;
        execFNRefundedGas = _execFNRefundedGas;
        recommendedGasPriceForInterfaces = _recommendedGasPriceForInterfaces;
    }
    // **************************** Gelato Core constructor() END *****************************

    // Fallback function needed for arbitrary funding additions to Gelato Core's balance by owner
    // @DEV: possibly no need, as sent Ether reverts are built-in features of new EVM contracts
    function() external payable {
        require(isOwner(),
            "GelatoCore.fallback function: only the owner should send ether to Gelato Core without selecting a payable function."
        );
    }

    // CREATE
    // **************************** mintExecutionClaim() ******************************
    function mintExecutionClaim(address _triggerAddress,
                                bytes calldata _triggerPayload,
                                address _actionAddress,
                                bytes calldata _actionPayload,
                                uint256 _actionMaxGas,
                                address _executionClaimOwner
    )
        payable
        external
    {
        // CHECKS
        // All checks are done interface side. If interface sets wrong _payload, its not the core's fault.
        //  We could check that the bytes param is not == 0x, but this would require 2 costly keccak calls

        // Only staked interfaces can mint claims
        require(interfaceBalances[msg.sender] >= minEthBalance,
            "Only interfaces with over 0.5 ether can mint new execution claims"
        );

        // ****** Mint new executionClaim ERC721 token ******
        // Increment the current token id
        Counters.increment(_executionClaimIds);
        // Get a new, unique token id for the newly minted ERC721
        uint256 executionClaimId = _executionClaimIds.current();

        // Create executionClaimHash (we include executionClaimId to avoid hash collisions).
        //  We exclude _executionClaimOwner as this might change over the lifecycle of the executionClaim
        bytes32 executionClaimHash = keccak256(abi.encodePacked(_triggerAddress,
                                                                _triggerPayload,
                                                                _actionAddress,
                                                                _actionPayload,
                                                                _actionMaxGas,
                                                                msg.sender,  // dappInterface
                                                                executionClaimId
        ));

        // Mint new ERC721 Token representing one childOrder
        _mint(_executionClaimOwner, executionClaimId);
        // ****** Mint new executionClaim ERC721 token END ******

        // ExecutionClaims tracking state variable update
        // ERC721(executionClaimId) => ExecutionClaim(struct)
        executionClaims[executionClaimId] = executionClaimHash;

        // Step4: Emit event to notify executors that a new sub order was created
        emit LogNewExecutionClaimMinted(_triggerAddress,
                                        _triggerPayload,
                                        _actionAddress,
                                        _actionPayload,
                                        _actionMaxGas,
                                        msg.sender,  // dappInterface
                                        executionClaimId,
                                        executionClaimHash,
                                        _executionClaimOwner
        );
    }
    // **************************** mintExecutionClaim() END ******************************

    // READ
    // **************************** ExecutionClaim Getters ***************************
    function getExecutionClaimHash(uint256 _executionClaimId)
        public
        view
        returns(bytes32)
    {
        bytes32 executionClaimHash = executionClaims[_executionClaimId];
        return executionClaimHash;
    }

    // To get executionClaimOwner call ownerOf(executionClaimId)

    function getCurrentExecutionClaimId()
        public
        view
        returns(uint256)
    {
        uint256 currentId = _executionClaimIds.current();
        return currentId;
    }
    // **************************** ExecutionClaim Getters END ***************************

    // Update
    // **************************** Core Updateability ******************************
    // *** Gelato Params Governance ****
    // Updating the min ether balance of interfaces
    function updateMinInterfaceBalance(uint256 _newMinInterfaceBalance)
        public
        onlyOwner
    {
        emit LogMinInterfaceBalanceUpdated(minInterfaceBalance, _newMinInterfaceBalance);
        minInterfaceBalance = _newMinInterfaceBalance;
    }

    // Set the global fee an executor can receive in the gelato system
    function updateExecutorProfit(uint256 _newExecutorProfit)
        public
        onlyOwner
    {
        emit LogExecutorProfitUpdated(executorProfit, _newExecutorProfit);
        executorProfit = _newExecutorProfit;
    }

    // Set the global max gas price an executor can receive in the gelato system
    function updateExecutorGasPrice(uint256 _newExecutorGasPrice)
        public
        onlyOwner
    {
        emit LogExecutorGasPriceUpdated(executorGasPrice, _newExecutorGasPrice);
        executorGasPrice = _newExecutorGasPrice;
    }

    function updateCanExecFNMaxGas(uint256 _newCanExecFNMaxGas)
        public
        onlyOwner
    {
        emit LogCanExecFNMaxGasUpdated(canExecFNMaxGas, _newCanExecFNMaxGas);
        canExecFNMaxGas = _newCanExecFNMaxGas;
    }

    function updateExecFNGas1(uint256 _newExecFNGas1)
        public
        onlyOwner
    {
        emit LogExecFNGas1Updated(execFNGas1, _newExecFNGas1);
        execFNGas1 = _newExecFNGas1;
    }

    function updateExecFNGas2(uint256 _newExecFNGas2)
        public
        onlyOwner
    {
        emit LogExecFNGas2Updated(execFNGas2, _newExecFNGas2);
        execFNGas2 = _newExecFNGas2;
    }

    // Update GAS_REFUND
    function updateExecFNRefundedGas(uint256 _newExecFNRefundedGas)
        public
        onlyOwner
    {
        emit LogExecFNRefundedGasUpdated(execFNRefundedGas, _newExecFNRefundedGas);
        execFNRefundedGas = _newExecFNRefundedGas;
    }

    // Update gas price recommendation for interfaces
    function updateRecommendedGasPriceForInterfaces(uint256 _newRecommendedGasPrice)
        public
        onlyOwner
    {
        emit LogRecommendedGasPriceForInterfacesUpdated(recommendedGasPriceForInterfaces, _newRecommendedGasPrice);
        recommendedGasPriceForInterfaces = _newRecommendedGasPrice;
    }
    // *** Gelato Params Governance END ****

    // *** Interface Params Governance ****
    // Enable interfaces to add a balance to Gelato to pay for transaction executions
    function addInterfaceBalance()
        public
        payable
    {
        require(msg.value > 0, "GelatoCore.addInterfaceBalance(): Msg.value must be greater than zero");
        uint256 currentInterfaceBalance = interfaceBalances[msg.sender];
        uint256 newBalance = currentInterfaceBalance.add(msg.value);
        interfaceBalances[msg.sender] = newBalance;
        emit LogInterfaceBalanceAdded(msg.sender,
                                      currentInterfaceBalance,
                                      msg.value,
                                      newBalance
        );
    }

    // Enable interfaces to withdraw some of their added balances
    function withdrawInterfaceBalance(uint256 _withdrawAmount)
        external
    {
        require(_withdrawAmount > 0, "WithdrawAmount must be greater than zero");
        uint256 currentInterfaceBalance = interfaceBalances[msg.sender];
        require(_withdrawAmount <= currentInterfaceBalance,
            "GelatoCore.withdrawInterfaceBalance(): WithdrawAmount must be smaller or equal to the interfaces current balance"
        );
        interfaceBalances[msg.sender] = currentInterfaceBalance.sub(_withdrawAmount);
        msg.sender.transfer(_withdrawAmount);
        emit LogInterfaceBalanceWithdrawal(msg.sender,
                                           currentInterfaceBalance,
                                           _withdrawAmount,
                                           interfaceBalances[msg.sender]
        );
    }
    // *** Interface Params Governance END ****
    // **************************** Core Updateability END ******************************


    // **************************** EXECUTE FUNCTION SUITE ******************************
    // Preconditions for execution, checked by canExecute and returned as an uint256 from interface
    enum PreExecutionCheck {
        IsExecutable,                         // All checks passed, the executionClaim can be executed
        AcceptExecCallReverted,  // The interfaces reverted when calling acceptExecutionRequest
        WrongReturnValue, // The Interface returned an error code and not 0 for is executable
        InsufficientBalance, // The interface has insufficient balance on gelato core
        ClaimDoesNotExist,
        WrongCalldata
    }

    // Preconditions for execution, checked by canExecute and returned as an uint256 from interface
    enum PostExecutionStatus {
        Success, // Interface call succeeded
        Failure,  // Interface call reverted
        InterfaceBalanceChanged  // The transaction was relayed and reverted due to the recipient's balance changing

    }

    // Function for executors to verify that execution claim is executable
    // Must return 0 as first return value in order to be seen as 'executable' by executor nodes
    function canExecute(address _triggerAddress,
                        bytes memory _triggerPayload,
                        address _actionAddress,
                        bytes memory _actionPayload,
                        uint256 _actionMaxGas,
                        address _dappInterface,
                        uint256 _executionClaimId)
        public
        view
        returns (uint256, address executionClaimOwner)
    {
         // Compute executionClaimHash from calldata
        bytes32 computedExecutionClaimHash = keccak256(abi.encodePacked(_triggerAddress,
                                                                        _triggerPayload,
                                                                        _actionAddress,
                                                                        _actionPayload,
                                                                        _actionMaxGas,
                                                                        _dappInterface,
                                                                        _executionClaimId
        ));
        bytes32 storedExecutionClaimHash = executionClaims[_executionClaimId];

        executionClaimOwner = ownerOf(_executionClaimId);

        // Check that passed calldata is correct
        if(computedExecutionClaimHash != storedExecutionClaimHash)
        {
            return (uint256(PreExecutionCheck.WrongCalldata), executionClaimOwner);
        }

        // Require execution claim to exist and / or not be burned
        if (executionClaimOwner == address(0))
        {
            return (uint256(PreExecutionCheck.ClaimDoesNotExist), executionClaimOwner);
        }

        // **** CHECKS ****
        // Check if Interface has sufficient balance on core
        // @DEV, Lets change to maxPossibleCharge calcs like in GSN
        if (interfaceBalances[_dappInterface] < minEthBalance)
        {
            // If insufficient balance, return 3
            return (uint256(PreExecutionCheck.InsufficientBalance), executionClaimOwner);
        }
        // **** CHECKS END ****;

        // Call 'acceptExecutionRequest' in interface contract
        (bool success, bytes memory returndata) = _triggerAddress.staticcall.gas(canExecFNMaxGas)(_triggerPayload);

        // Check dappInterface return value
        if (!success) {
            // Return 1 in case of error
            return (uint256(PreExecutionCheck.AcceptExecCallReverted), executionClaimOwner);
        }
        else
        {
            // Decode return value from interface
            bool executable = abi.decode(returndata, (bool));
            // Decoded returndata should return 0 for the executor to deem execution claim executable
            if (executable)
            {
                return (uint256(PreExecutionCheck.IsExecutable), executionClaimOwner);
            }
            // If not 0, return 2 (internal error code)
            else
            {
                return (uint256(PreExecutionCheck.WrongReturnValue), executionClaimOwner);
            }

        }

    }

    // ************** execute() -> safeExecute() **************
    function execute(address _triggerAddress,
                     bytes calldata _triggerPayload,
                     address _actionAddress,
                     bytes calldata _actionPayload,
                     uint256 _actionMaxGas,
                     address _dappInterface,
                     uint256 _executionClaimId)
        external
        returns (uint256 safeExecuteStatus)
    {
        // // Calculate start GAS, set by the executor.
        uint256 startGas = gasleft();

        // 1: Exeutor must be registered and have stake // OR permissionless

        // 3: Start gas should be equal or greater to the interface maxGas, gas overhead plus maxGases of canExecute and the internal operations of conductAtomicCall
        require(startGas >= getExecFNGas(_actionMaxGas),
            "GelatoCore.execute: Insufficient gas sent"
        );

        // 4: Interface has sufficient funds  staked to pay for the maximum possible charge
        // We don't yet know how much gas will be used by the recipient, so we make sure there are enough funds to pay
        // If tx Gas Price is higher than executorGasPrice, use executorGasPrice
        uint256 cappedGasPriceUsed;
        tx.gasprice > executorGasPrice ? cappedGasPriceUsed = executorGasPrice : cappedGasPriceUsed = tx.gasprice;

        // Make sure that interfaces have enough funds staked on core for the maximum possible charge.
        require((getExecFNGas(_actionMaxGas).mul(cappedGasPriceUsed)).add(executorProfit) <= interfaceBalances[_dappInterface],
            "GelatoCore.execute: Insufficient interface balance on gelato core"
        );

        // Call canExecute to verify that transaction can be executed
        {
            (uint256 canExecuteResult, address executionClaimOwner) = canExecute(_triggerAddress,
                                                                                 _triggerPayload,
                                                                                 _actionAddress,
                                                                                 _actionPayload,
                                                                                 _actionMaxGas,
                                                                                 _dappInterface,
                                                                                 _executionClaimId
            );
            // if canExecuteResult is not equal 0, we return 1 or 2, based on the received preExecutionCheck value;
            if (canExecuteResult != 0) {
                emit LogCanExecuteFailed(msg.sender, _executionClaimId);
                // Change to returning error message instead of reverting
                revert("GelatoCore.execute: canExec func did not return 0");
                // return canExecuteResult;
            }
        }

        // !!! From this point on, this transaction SHOULD not revert nor run out of gas, and the recipient will be charged
        // for the gas spent.

        // **** EFFECTS ****
        // @DEV MAYBE ADD LATER; PROBABLY NOT FOR ONE STATE VARIABLE Delete the ExecutionClaim struct
        // delete executionClaims[_executionClaimId];
        // ******** EFFECTS END ****

        // Calls to the interface are performed atomically inside an inner transaction which may revert in case of
        // errors in the interface contract or malicious behaviour. In either case (revert or regular execution) the return data encodes the
        // RelayCallStatus value.
        {

            bytes memory payloadWithSelector = abi.encodeWithSelector(this.safeExecute.selector,
                                                                      _actionAddress,
                                                                      _actionPayload,
                                                                      _actionMaxGas,
                                                                      _executionClaimId,
                                                                      msg.sender
            );

            // Call conductAtomicCall func
            (, bytes memory returnData) = address(this).call(payloadWithSelector);
            safeExecuteStatus = abi.decode(returnData, (uint256));
        }

        // **** EFFECTS 2 ****
        // Burn Claim. Should be done here to we done have to store the claim Owner on the interface.
        //  Deleting the struct on the core should suffice, as an exeuctionClaim Token without the associated struct is worthless.
        //  => Discuss
        _burn(_executionClaimId);

        // ******** EFFECTS 2 END ****

        // Calc executor payout
        // How much gas we have left in this tx
        {
            uint256 endGas = gasleft();
            // Calaculate how much gas we used up in this function. Subtract the certain gas refunds the executor will receive for nullifying values
            // Gas Overhead corresponds to the actions occuring before and after the gasleft() calcs
            // @DEV UPDATE WITH NEW FUNC
            uint256 gasUsedEstimate = startGas.sub(endGas).add(execFNGas2).sub(executorGasRefund);
            // Calculate Total Cost
            uint256 executionCostEstimate = gasUsedEstimate.mul(cappedGasPriceUsed);
            // Calculate Executor Payout (including a fee set by GelatoCore.sol)
            // uint256 executorPayout= executionCostEstimate.mul(100 + executorProfit).div(100);
            // @DEV Think about it
            uint256 executorPayout = executionCostEstimate.add(executorProfit);
        }

        // Effects 2: Reduce interface balance by executorPayout
        interfaceBalances[_dappInterface] = interfaceBalances[_dappInterface].sub(executorPayout);

        // Emit event now before deletion of struct
        emit LogClaimExecutedBurnedAndDeleted(dappInterface,
                                              _executionClaimId,
                                              executionClaimOwner,
                                              msg.sender,  // executor
                                              executorPayout,
                                              executorProfit,
                                              gasUsedEstimate,
                                              cappedGasPriceUsed,
                                              executionCostEstimate
        );

        // Conduct the payout to the executor
        // Transfer the prepaid fee to the executor as reward
        // @DEV change to withdraw pattern
        msg.sender.transfer(executorPayout);
    }

    // To protect from interfaceBalance drain re-entrancy attack
    function safeExecute(address _dappInterface,
                         bytes calldata _actionPayload,
                         uint256 _actionMaxGas,
                         uint256 _executionClaimId,
                         address _executor
    )
        external
        returns(uint256)
    {
        require(msg.sender == address(this),
            "GelatoCore.safeExecute: Only Gelato Core can call this function"
        );

        // Interfaces are not allowed to withdraw their balance while an executionClaim is being executed. They can however increase their balance
        uint256 interfaceBalanceBefore = interfaceBalances[_dappInterface];

        // Interactions
        // emit LogGasConsumption(gasleft(), 3);
        // Current tx gas cost:
        // gelatoDutchX depositAnd sell: 465.597
        (bool executedClaimStatus,) = _dappInterface.call.gas(_actionMaxGas)(_actionPayload); // .gas(_actionMaxGas)
        emit LogExecuteResult(executedClaimStatus, _executor, _executionClaimId, _actionMaxGas);

        // If interface withdrew some balance, revert transaction
        require(interfaceBalances[_dappInterface] >= interfaceBalanceBefore,
            "GelatoCore.safeExecute: Interface withdrew some balance during the transaction"
        );

        // return if .call succeeded or failed
        return executedClaimStatus ? uint256(PostExecutionStatus.Success) : uint256(PostExecutionStatus.Failure);
    }
    // ************** execute() -> safeExecute() END **************

    function getExecFNGas(uint256 _actionMaxGas)
        internal
        pure
        returns (uint256)
    {
        // Only use .add for last, user inputted value to avoid over - underflow
        return canExecFNMaxGas + execFNGas1 + execFNGas2.add(_actionMaxGas);
    }
    // **************************** EXECUTE FUNCTION SUITE END ******************************

    // **************************** cancelExecutionClaim() ***************************
    function cancelExecutionClaim(address _triggerAddress,
                                  bytes calldata _triggerPayload,
                                  address _actionAddress,
                                  bytes calldata _actionPayload,
                                  uint256 _actionMaxGas,
                                  address _dappInterface,
                                  uint256 _executionClaimId
    )
        external
    {
        // Compute executionClaimHash from calldata
        bytes32 computedExecutionClaimHash = keccak256(abi.encodePacked(_triggerAddress,
                                                                        _triggerPayload,
                                                                        _actionAddress,
                                                                        _actionPayload,
                                                                        _actionMaxGas,
                                                                        _dappInterface,
                                                                        _executionClaimId
        ));
        bytes32 storedExecutionClaimHash = executionClaims[_executionClaimId];

        // CHECKS
        require(computedExecutionClaimHash == storedExecutionClaimHash,
            "Computed execution hash does not equal stored execution hash"
        );
        // Local variables needed for Checks, Effects -> Interactions pattern
        address executionClaimOwner = ownerOf(_executionClaimId);
        // Check that execution claim exists
        require(executionClaimOwner != address(0));
        // Only the interface can cancel the executionClaim
        require(_dappInterface == msg.sender);

        // EFFECTS
        emit LogExecutionClaimCancelled(executionClaim.dappInterface,
                                        _executionClaimId,
                                        executionClaimOwner
        );
        _burn(_executionClaimId);
        delete executionClaims[_executionClaimId];

    }
    // **************************** cancelExecutionClaim() END ***************************
}


