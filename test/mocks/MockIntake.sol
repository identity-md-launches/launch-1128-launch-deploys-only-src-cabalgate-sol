// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake, Attestation} from "../../src/interfaces/IIntake.sol";
import {CabalGate} from "../../src/CabalGate.sol";

/// @dev Mirrors the live Intake's observable behaviour: exact price pull, keccak-derived ids and a callback made
///      as `target.call{gas: callbackGas}(selector ++ abi.encode(requestId, attestation, signature))`.
contract MockIntake is IIntake {
    uint256 public price = 3 ether;
    uint256 public callbackGas = 200000;
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
    mapping(bytes32 => bytes) public bodyOf;

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
        id = reuseId
            ? keccak256(abi.encode(block.chainid, address(this), uint256(1)))
            : keccak256(abi.encode(block.chainid, address(this), ++nonce));
        bodyOf[id] = body;
    }

    function deliver(CabalGate gate, bytes32 id, Attestation calldata a, bytes calldata signature) external {
        deliverRaw(gate, abi.encode(id, a, signature));
    }

    /// @dev The exact shape the live Intake uses: selector prepended to the writer's payload, bounded gas.
    function deliverRaw(CabalGate gate, bytes memory payload) public {
        (bool ok, bytes memory ret) =
            address(gate).call{gas: callbackGas}(abi.encodePacked(gate.onOracleResult.selector, payload));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
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
