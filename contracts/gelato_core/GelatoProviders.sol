pragma solidity ^0.6.4;
pragma experimental ABIEncoderV2;

import { IGelatoProviders } from "./interfaces/IGelatoProviders.sol";
import { GelatoSysAdmin } from "./GelatoSysAdmin.sol";
import { Address } from "../external/Address.sol";
import { SafeMath } from "../external/SafeMath.sol";
import { Math } from "../external/Math.sol";
import { IGelatoProviderModule } from "./interfaces/IGelatoProviderModule.sol";
import { EnumerableAddressSet } from "../external/EnumerableAddressSet.sol";
import { ExecClaim } from "./interfaces/IGelatoCore.sol";
import { GelatoString } from "../libraries/GelatoString.sol";

/// @title GelatoProviders
/// @notice APIs for GelatoCore Owner and execClaimTenancy
/// @dev Find all NatSpecs inside IGelatoCoreAccounting
abstract contract GelatoProviders is IGelatoProviders, GelatoSysAdmin {

    using Address for address payable;  /// for sendValue method
    using EnumerableAddressSet for EnumerableAddressSet.AddressSet;
    using SafeMath for uint256;
    using GelatoString for string;

    uint256 public constant override NO_CEIL = 10**18;

    mapping(address => uint256) public override providerFunds;
    mapping(address => uint256) public override executorStake;
    mapping(address => address) public override executorByProvider;
    mapping(address => uint256) public override executorProvidersCount;
    mapping(address => mapping(address => bool)) public override isConditionProvided;
    mapping(address => mapping(address => uint256)) public override actionGasPriceCeil;
    mapping(address => EnumerableAddressSet.AddressSet) internal _providerModules;

    // GelatoCore: mintExecClaim/collectExecClaimRent Gate
    function isConditionActionProvided(ExecClaim memory _execClaim)
        public
        view
        override
        returns(string memory)
    {
        if (!isConditionProvided[_execClaim.provider][_execClaim.condition])
            return "ConditionNotProvided";
        if (actionGasPriceCeil[_execClaim.provider][_execClaim.action] == 0)
            return "ActionNotProvided";
        return "Ok";
    }

    // IGelatoProviderModule: GelatoCore mintExecClaim/canExec Gate
    function providerModuleChecks(ExecClaim memory _execClaim)
        public
        view
        override
        returns(string memory)
    {
        if (!isProviderModule(_execClaim.provider, _execClaim.providerModule))
            return "InvalidProviderModule";

        IGelatoProviderModule providerModule = IGelatoProviderModule(
            _execClaim.providerModule
        );

        try providerModule.isProvided(_execClaim)
        returns(string memory providerModuleMessage)
        {
            return providerModuleMessage;
        } catch {
            return "Error in Provider Module";
        }
    }

    // GelatoCore: combined mintExecClaim Gate
    function isExecClaimProvided(ExecClaim memory _execClaim)
        public
        view
        override
        returns(string memory res)
    {
        res = isConditionActionProvided(_execClaim);
        if (res.startsWithOk()) return providerModuleChecks(_execClaim);
    }

    // GelatoCore canExec Gate
    function providerCanExec(ExecClaim memory _execClaim, uint256 _gelatoGasPrice)
        public
        view
        override
        returns(string memory)
    {
        // Will only return if a) action is not whitelisted & b) gelatoGasPrice is higher than gasPriceCeiling
        if (_gelatoGasPrice > actionGasPriceCeil[_execClaim.provider][_execClaim.action])
            return "GelatoGasPriceTooHigh";

        // 3. Check if condition is whitelisted by provider
        if (!isConditionProvided[_execClaim.provider][_execClaim.condition])
            return "ConditionNotProvided";

        return providerModuleChecks(_execClaim);
    }

    // Provider Funding
    function provideFunds(address _provider) public payable override {
        require(msg.value > 0, "GelatoProviders.provideFunds: zero value");
        uint256 newProviderFunds = providerFunds[_provider].add(msg.value);
        emit LogProvideFunds(_provider, providerFunds[_provider], newProviderFunds);
        providerFunds[_provider] = newProviderFunds;
    }

    function unprovideFunds(uint256 _withdrawAmount)
        public
        override
        returns (uint256 realWithdrawAmount)
    {
        address currentExecutor = executorByProvider[msg.sender];

        require(currentExecutor == address(0), "GelatoProviders.unprovideFunds: Providers have to un-assign executor first");

        uint256 previousProviderFunds = providerFunds[msg.sender];

        realWithdrawAmount = Math.min(_withdrawAmount, previousProviderFunds);

        uint256 newProviderFunds = previousProviderFunds - realWithdrawAmount;

        // Effects
        providerFunds[msg.sender] = previousProviderFunds - newProviderFunds;

        // Interaction
        msg.sender.sendValue(realWithdrawAmount);

        emit LogUnprovideFunds(msg.sender, previousProviderFunds, newProviderFunds);
    }

    // Called by Providers
    function providerAssignsExecutor(address _newExecutor) public override {
        address currentExecutor = executorByProvider[msg.sender];

        // CHECKS
        require(
            currentExecutor != _newExecutor,
            "GelatoProviders.providerAssignsExecutor: already assigned."
        );
        require(
            isExecutorMinStaked(_newExecutor),
            "GelatoProviders.providerAssignsExecutor: isExecutorMinStaked()"
        );
        require(
            isProviderLiquid(msg.sender),
            "GelatoProviders.providerAssignsExecutor: isProviderLiquid()"
        );

        // EFFECTS: Provider reassigns from currentExecutor to newExecutor (or no executor)
        if (currentExecutor != address(0)) executorProvidersCount[currentExecutor]--;
        executorByProvider[msg.sender] = _newExecutor;
        if (_newExecutor != address(0)) executorProvidersCount[_newExecutor]++;

        emit LogProviderAssignsExecutor(msg.sender, currentExecutor, _newExecutor);
    }

    // Called by Executors
    function executorAssignsExecutor(address _provider, address _newExecutor) public override {
        address currentExecutor = executorByProvider[_provider];

        // CHECKS
        require(
            currentExecutor == msg.sender,
            "GelatoProviders.executorAssignsExecutor: msg.sender is not assigned executor"
        );
        require(
            currentExecutor != _newExecutor,
            "GelatoProviders.executorAssignsExecutor: already assigned."
        );
        // Checks at the same time if _nexExecutor != address(0)
        require(
            isExecutorMinStaked(_newExecutor),
            "GelatoProviders.executorAssignsExecutor: isExecutorMinStaked()"
        );

        // EFFECTS: currentExecutor reassigns to newExecutor
        executorProvidersCount[currentExecutor]--;
        executorByProvider[_provider] = _newExecutor;
        executorProvidersCount[_newExecutor]++;

        emit LogExecutorAssignsExecutor(_provider, currentExecutor, _newExecutor);
    }

    // (Un-)provide Conditions
    function provideConditions(address[] memory _conditions) public override {
        for (uint i; i < _conditions.length; i++) {
            require(
                !isConditionProvided[msg.sender][_conditions[i]],
                "GelatProviders.provideConditions: redundant"
            );
            isConditionProvided[msg.sender][_conditions[i]] = true;
            emit LogProvideCondition(msg.sender, _conditions[i]);
        }
    }

    function unprovideConditions(address[] memory _conditions) public override {
        for (uint i; i < _conditions.length; i++) {
            require(
                isConditionProvided[msg.sender][_conditions[i]],
                "GelatProviders.unprovideConditions: redundant"
            );
            delete isConditionProvided[msg.sender][_conditions[i]];
            emit LogUnprovideCondition(msg.sender, _conditions[i]);
        }
    }

    // (Un-)provide Actions at different gasPrices
    function provideActions(ActionWithGasPriceCeil[] memory _actions) public override {
        for (uint i; i < _actions.length; i++) {
            if (_actions[i].gasPriceCeil == 0) _actions[i].gasPriceCeil = NO_CEIL;
            uint256 currentGasPriceCeil = actionGasPriceCeil[msg.sender][_actions[i]._address];
            require(
                currentGasPriceCeil != _actions[i].gasPriceCeil,
                "GelatoProviders.provideActions: redundant"
            );
            actionGasPriceCeil[msg.sender][_actions[i]._address] = _actions[i].gasPriceCeil;
            emit LogProvideAction(
                msg.sender,
                _actions[i]._address,
                currentGasPriceCeil,
                _actions[i].gasPriceCeil
            );
        }
    }

    function unprovideActions(address[] memory _actions) public override {
        for (uint i; i < _actions.length; i++) {
            require(
                actionGasPriceCeil[msg.sender][_actions[i]] != 0,
                "GelatoProviders.unprovideActions: redundant"
            );
            delete actionGasPriceCeil[msg.sender][_actions[i]];
            emit LogUnprovideAction(msg.sender, _actions[i]);
        }
    }

    // Provider Module
    function addProviderModules(address[] memory _modules) public override {
        for (uint i; i < _modules.length; i++) {
            require(
                !isProviderModule(msg.sender, _modules[i]),
                "GelatoProviders.addProviderModules: redundant"
            );
            _providerModules[msg.sender].add(_modules[i]);
            emit LogAddProviderModule(msg.sender, _modules[i]);
        }
    }

    function removeProviderModules(address[] memory _modules) public override {
        for (uint i; i < _modules.length; i++) {
            require(
                isProviderModule(msg.sender, _modules[i]),
                "GelatoProviders.removeProviderModules: redundant"
            );
            _providerModules[msg.sender].remove(_modules[i]);
            emit LogRemoveProviderModule(msg.sender, _modules[i]);
        }
    }

    // Batch (un-)provide
    function batchProvide(
        address _executor,
        address[] memory _conditions,
        ActionWithGasPriceCeil[] memory _actions,
        address[] memory _modules
    )
        public
        payable
        override
    {
        if (msg.value != 0) provideFunds(msg.sender);
        if (_executor != address(0)) providerAssignsExecutor(_executor);
        provideConditions(_conditions);
        provideActions(_actions);
        addProviderModules(_modules);
    }

    function batchUnprovide(
        uint256 _withdrawAmount,
        address[] memory _conditions,
        address[] memory _actions,
        address[] memory _modules
    )
        public
        override
    {
        if (_withdrawAmount != 0) unprovideFunds(_withdrawAmount);
        unprovideConditions(_conditions);
        unprovideActions(_actions);
        removeProviderModules(_modules);
    }

    // Provider Liquidity
    function isProviderLiquid(address _provider) public view override returns(bool) {
        return minProviderStake <= providerFunds[_provider] ? true : false;
    }

    // An Executor qualifies and remains registered for as long as he has minExecutorStake
    function isExecutorMinStaked(address _executor) public view override returns(bool) {
        return executorStake[_executor] >= minExecutorStake;
    }

    // Providers' Executor Assignment
    function isExecutorAssigned(address _executor) public view override returns(bool) {
        return executorProvidersCount[_executor] != 0;
    }

    // Providers' Module Getters
    function isProviderModule(address _provider, address _module)
        public
        view
        override
        returns(bool)
    {
        return _providerModules[_provider].contains(_module);
    }

    function numOfProviderModules(address _provider) external view override returns(uint256) {
        return _providerModules[_provider].length();
    }

    function providerModules(address _provider)
        external
        view
        override
        returns(address[] memory)
    {
        return _providerModules[_provider].enumerate();
    }

}