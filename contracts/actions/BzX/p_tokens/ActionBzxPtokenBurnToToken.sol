pragma solidity ^0.6.0;

import "../../GelatoActionsStandard.sol";
import "../../../external/IERC20.sol";
// import "../../external/SafeERC20.sol";
import "../../../dapp_interfaces/bZx/IBzxPtoken.sol";
import "../../../external/SafeMath.sol";
import "../../../external/Address.sol";

contract ActionBzxPtokenBurnToToken is GelatoActionsStandard {
    // using SafeERC20 for IERC20; <- internal library methods vs. try/catch
    using SafeMath for uint256;
    using Address for address;

    // actionSelector public state variable np due to this.actionSelector constant issue
    function actionSelector() external pure override returns(bytes4) {
        return this.action.selector;
    }
    uint256 public constant override actionGas = 4200000;

    function action(
        // Standard Action Params
        address _user,  // "receiver"
        address _userProxy,
        // Specific Action Params
        address _pTokenAddress,
        uint256 _burnAmount,
        address _burnTokenAddress,
        uint256 _minPriceAllowed
    )
        external
    {
        IERC20 pToken = IERC20(_pTokenAddress);

        try pToken.transferFrom(_user, address(this), _burnAmount) {} catch {
           revert("ActionBzxPtokenBurnToToken: ErrorTransferFromPToken");
        }

        // !! Dapp Interaction !!
        uint256 burnTokensReceivable;
        try IBzxPtoken(_pTokenAddress).burnToToken(
            _user,  // receiver
            _burnTokenAddress,
            _burnAmount,
            _minPriceAllowed
        ) {} catch {
           revert("ActionBzxPtokenBurnToToken: ErrorPtokenBurnToToken");
        }
    }


    // ============ API for FrontEnds ===========
    function getUsersSourceTokenBalance(bytes calldata _actionPayloadWithSelector)
        external
        view
        override
        returns(uint256)
    {
        (, bytes memory payload) = SplitFunctionSelector.split(
            _actionPayloadWithSelector
        );
        (address _user, address _userProxy, address _src,,) = abi.decode(
            payload,
            (address, address, address, uint256, address)
        );
        IERC20 srcERC20 = IERC20(_src);
        try srcERC20.balanceOf(_user) returns(uint256 userSrcBalance) {
            return userSrcBalance;
        } catch {
            revert(
                "Error: ActionBzxPtokenBurnToToken.getUsersSourceTokenBalance: balanceOf: balanceOf"
            );
        }
    }

    // ======= ACTION CONDITIONS CHECK =========
    // Overriding and extending GelatoActionsStandard's function (optional)
    function actionConditionsCheck(bytes calldata _actionPayloadWithSelector)
        external
        view
        override
        returns(string memory)  // actionCondition
    {
        return _actionConditionsCheck(_actionPayloadWithSelector);
    }

    function _actionConditionsCheck(bytes memory _actionPayloadWithSelector)
        internal
        view
        returns(string memory)  // actionCondition
    {
        (, bytes memory payload) = SplitFunctionSelector.split(
            _actionPayloadWithSelector
        );

        (address _user,
         address _userProxy,
         address _pTokenAddress,
         uint256 _burnAmount, , ) = abi.decode(
            payload,
            (address, address, address, uint256, address, uint256)
        );

        if(!_pTokenAddress.isContract())
            return "ActionBzxPtokenBurnToToken: NotOkPTokenAddress";

        IERC20 pToken = IERC20(_pTokenAddress);

        try pToken.balanceOf(_user) returns(uint256 userPtokenBalance) {
            if (userPtokenBalance < _burnAmount)
                return "ActionBzxPtokenBurnToToken: NotOkUserPtokenBalance";
        } catch {
            return "ActionBzxPtokenBurnToToken: ErrorBalanceOf";
        }

        try pToken.allowance(_user, _userProxy) returns(uint256 userProxyAllowance) {
            if (userProxyAllowance < _burnAmount)
                return "ActionBzxPtokenBurnToToken: NotOkUserProxyPtokenAllowance";
        } catch {
            return "ActionBzxPtokenBurnToToken: ErrorAllowance";
        }

        // STANDARD return string to signal actionConditions Ok
        return "ok";
    }
}