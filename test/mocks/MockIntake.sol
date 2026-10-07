// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake, Attestation} from "../../src/interfaces/IIntake.sol";
import {CabalGate} from "../../src/CabalGate.sol";

contract MockIntake is IIntake {
    uint256 public price = 3 ether;
    uint256 public nonce;
    bytes public lastBody;
    bytes32 public lastAction;
    address public lastToken;
    Callback public lastCallback;
    uint256 public observedAllowance;
    bool public failRequest;
    bool public reuseId;
    bool public skipPayment;
    bool public tryReenter;
    bool public reentrySucceeded;

    function setPrice(uint256 value) external {
        price = value;
    }

    function setFailure(bool value) external {
        failRequest = value;
    }

    function setReuse(bool value) external {
        reuseId = value;
    }

    function setSkipPayment(bool value) external {
        skipPayment = value;
    }

    function setReenter(bool value) external {
        tryReenter = value;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address token, uint256 paid)
        external
        returns (bytes32 id)
    {
        require(!failRequest, "intake failed");
        require(paid == price, "wrong price");
        observedAllowance = IERC20(token).allowance(msg.sender, address(this));
        if (!skipPayment) require(IERC20(token).transferFrom(msg.sender, address(this), price));
        lastBody = body;
        lastAction = action;
        lastToken = token;
        lastCallback = callback;
        if (tryReenter) {
            (reentrySucceeded,) = msg.sender.call(abi.encodeCall(CabalGate.submitBuyRequest, (1 ether, "reentry")));
        }
        id = bytes32(reuseId ? 1 : ++nonce);
    }

    function deliver(CabalGate gate, bytes32 id, Attestation calldata a, bytes calldata signature) external {
        gate.onOracleResult(id, a, signature);
    }

    function deliverWithGas(CabalGate gate, bytes32 id, Attestation calldata a, bytes calldata signature)
        external
        returns (uint256 used)
    {
        uint256 start = gasleft();
        gate.onOracleResult{gas: 199999}(id, a, signature);
        used = start - gasleft();
    }
}
