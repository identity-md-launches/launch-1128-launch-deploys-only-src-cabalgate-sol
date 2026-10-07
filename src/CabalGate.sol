// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CabalHook} from "./CabalHook.sol";
import {QuestionBuilder} from "./QuestionBuilder.sol";
import {IIntake, Attestation} from "./interfaces/IIntake.sol";
import {OracleSignature} from "./libraries/OracleSignature.sol";
import {MainnetDefaults} from "./libraries/MainnetDefaults.sol";

contract CabalGate is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    enum Status {
        None,
        Pending,
        Approved,
        Rejected,
        Executed,
        Cleared
    }

    struct Config {
        address intake;
        address imd;
        address signer;
        address oracleVerifier;
        bytes32 action;
        uint128 maxBuyAmount;
        uint128 maxSellAmount;
        uint16 maxImpactBps;
        uint8 windowHours;
        uint8 boolAnswerType;
    }

    struct Request {
        address requester;
        Status status;
        bool buy;
        uint64 createdAt;
        uint64 deadline;
        uint64 approvedUntil;
        uint64 version;
        uint128 amount;
        uint160 sqrtPriceX96;
        uint256 minimumOutput;
        bytes32 questionHash;
    }

    struct Holding {
        uint256 units;
        uint256 costImd;
        uint64 firstBuy;
    }

    error InvalidConfig();
    error WrongChain();
    error InvalidRequest();
    error NotRequester();
    error ActiveRequest();
    error LimitExceeded();
    error UnauthorizedCallback();
    error InvalidAttestation();
    error Expired();
    error Slippage();
    error UnsupportedToken();
    error PartialFill();

    uint256 private constant Q96 = 1 << 96;
    uint256 public constant REQUEST_TIMEOUT = 1 hours;
    uint256 public constant APPROVAL_WINDOW = 5 minutes;
    address public constant IDENTITY_NFT = MainnetDefaults.IDENTITY_NFT;
    CabalHook public immutable hook;
    IPoolManager public immutable poolManager;
    IERC20 public immutable cabal;
    QuestionBuilder public immutable questionBuilder;
    PoolKey private _key;
    mapping(bytes32 => Request) private _requests;
    mapping(address => bytes32) public activeRequest;
    mapping(address => Holding) public holdings;
    mapping(uint64 => Config) private _configs;
    uint64 public configVersion;
    bool private _executing;
    bytes32 private _executingId;

    event Configured(uint64 indexed version, Config configuration);
    event RequestSubmitted(
        bytes32 indexed id, address indexed user, bool buy, uint256 amount, bytes32 questionHash, bytes body
    );
    event OracleResult(bytes32 indexed id, bool approved, uint64 approvedUntil);
    event SlippageLimitSet(bytes32 indexed id, uint256 minimumOutput);
    event RequestCleared(bytes32 indexed id);
    event RequestExecuted(bytes32 indexed id, uint256 input, uint256 output, uint256 fee);

    constructor(CabalHook launchHook, address initialOwner, Config memory initialConfig) Ownable(initialOwner) {
        if (!launchHook.initialized()) revert InvalidConfig();
        hook = launchHook;
        poolManager = launchHook.poolManager();
        cabal = IERC20(launchHook.cabal());
        _key = launchHook.poolKey();
        questionBuilder = new QuestionBuilder();
        _configure(initialConfig);
    }

    function mainnetConfig(uint128 maxBuy, uint128 maxSell, uint16 impact) external pure returns (Config memory) {
        return Config(
            MainnetDefaults.INTAKE,
            MainnetDefaults.IMD,
            MainnetDefaults.SIGNER,
            MainnetDefaults.INTAKE,
            MainnetDefaults.ACTION,
            maxBuy,
            maxSell,
            impact,
            1,
            0
        );
    }

    function configuration() external view returns (Config memory) {
        return _configs[configVersion];
    }

    function configurationAt(uint64 version) external view returns (Config memory) {
        return _configs[version];
    }

    function getRequest(bytes32 id) external view returns (Request memory) {
        return _requests[id];
    }

    /// @dev Configuration changes invalidate execution of old approvals. Oracle identities remain snapshotted.
    /// A pool's currency cannot be changed after initialization; a new IMD asset requires a new pool and gate.
    function configure(Config calldata cfg) external onlyOwner nonReentrant {
        _configure(cfg);
    }

    function _configure(Config memory cfg) private {
        if (
            cfg.intake.code.length == 0 || cfg.imd != address(hook.imd()) || cfg.imd.code.length == 0
                || cfg.signer == address(0) || cfg.oracleVerifier == address(0) || cfg.action == bytes32(0)
                || cfg.maxBuyAmount == 0 || cfg.maxSellAmount == 0 || cfg.maxBuyAmount > uint128(type(int128).max)
                || cfg.maxSellAmount > uint128(type(int128).max) || cfg.maxImpactBps == 0 || cfg.maxImpactBps > 5000
                || cfg.windowHours == 0 || cfg.windowHours > 24
        ) revert InvalidConfig();
        _configs[++configVersion] = cfg;
        emit Configured(configVersion, cfg);
    }

    function submitBuyRequest(uint256 imdAmount, string calldata reason) external nonReentrant returns (bytes32) {
        return _submit(true, imdAmount, reason);
    }

    function submitSellRequest(uint256 cabalAmount, string calldata reason) external nonReentrant returns (bytes32) {
        return _submit(false, cabalAmount, reason);
    }

    function _submit(bool buy, uint256 amount, string calldata reason) private returns (bytes32 id) {
        if (block.chainid != 1) revert WrongChain();
        if (activeRequest[msg.sender] != bytes32(0)) revert ActiveRequest();
        Config memory cfg = _configs[configVersion];
        uint256 maxAmount = buy ? cfg.maxBuyAmount : cfg.maxSellAmount;
        if (amount == 0 || amount > maxAmount) revert LimitExceeded();
        uint256 balance = cabal.balanceOf(msg.sender);
        if (!buy && amount > balance) revert LimitExceeded();
        _reconcile(msg.sender, balance);
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(_key.toId());
        uint256 estimated = estimateImpact(buy, amount);
        if (estimated > cfg.maxImpactBps) revert LimitExceeded();
        Holding memory h = holdings[msg.sender];
        QuestionBuilder.Context memory context = QuestionBuilder.Context({
            buy: buy,
            user: msg.sender,
            amount: amount,
            impactBps: estimated,
            maxAmount: maxAmount,
            maxImpactBps: cfg.maxImpactBps,
            holdings: balance,
            currentPrice: _spotCabalPrice(sqrtPrice),
            averageBuyPrice: h.units == 0 ? 0 : FullMath.mulDiv(h.costImd, 1e18, h.units),
            firstBuy: h.firstBuy,
            timeHeld: h.firstBuy == 0 ? 0 : block.timestamp - h.firstBuy,
            trackedUnits: h.units,
            windowHours: cfg.windowHours,
            nftStatus: _nftStatus(msg.sender)
        });
        (bytes memory body, bytes32 questionHash) = questionBuilder.build(context, reason);
        IERC20 payment = IERC20(cfg.imd);
        uint256 price = IIntake(cfg.intake).priceOf(cfg.action, cfg.imd);
        uint256 beforePayment = payment.balanceOf(address(this));
        _pullExact(payment, msg.sender, price);
        payment.forceApprove(cfg.intake, price);
        id = IIntake(cfg.intake)
            .request(cfg.action, body, IIntake.Callback(address(this), this.onOracleResult.selector), cfg.imd, price);
        payment.forceApprove(cfg.intake, 0);
        if (payment.balanceOf(address(this)) != beforePayment) revert UnsupportedToken();
        if (id == bytes32(0) || _requests[id].status != Status.None) revert InvalidRequest();
        _requests[id] = Request({
            requester: msg.sender,
            status: Status.Pending,
            buy: buy,
            createdAt: uint64(block.timestamp),
            deadline: uint64(block.timestamp + REQUEST_TIMEOUT),
            approvedUntil: 0,
            version: configVersion,
            amount: uint128(amount),
            sqrtPriceX96: sqrtPrice,
            minimumOutput: 0,
            questionHash: questionHash
        });
        activeRequest[msg.sender] = id;
        emit RequestSubmitted(id, msg.sender, buy, amount, questionHash, body);
    }

    /// @notice Verify and store only: no trades, token transfers, JSON construction or NFT reads here.
    function onOracleResult(bytes32 requestId, Attestation calldata a, bytes calldata signature) external nonReentrant {
        Request storage r = _requests[requestId];
        Config storage cfg = _configs[r.version];
        if (msg.sender != cfg.intake || r.status != Status.Pending) revert UnauthorizedCallback();
        if (block.chainid != 1 || block.timestamp >= r.deadline) revert Expired();
        if (
            a.requestId != requestId || a.chainId != 1 || a.questionHash != r.questionHash
                || a.answerType != cfg.boolAnswerType || a.answer.length != 32 || a.fromBlock > a.toBlock
                || a.toBlock > block.number || a.blockHash == bytes32(0) || a.panelJobId == bytes32(0)
                || a.panelSize != 30 || a.quorum != 20 || a.agreementBps < 6667 || a.agreementBps > 10000
                || a.issuedAt < r.createdAt || a.issuedAt > block.timestamp || a.expiresAt <= block.timestamp
                || a.expiresAt <= a.issuedAt || a.expiresAt - a.issuedAt > 900
        ) revert InvalidAttestation();
        if (ECDSA.recover(OracleSignature.digest(a, cfg.oracleVerifier), signature) != cfg.signer) {
            revert InvalidAttestation();
        }
        bool approved = abi.decode(a.answer, (bool));
        if (approved) {
            r.status = Status.Approved;
            // Never execute past the attestation's own expiration, even within the nominal five minutes.
            uint256 until = block.timestamp + APPROVAL_WINDOW;
            r.approvedUntil = uint64(until < a.expiresAt ? until : a.expiresAt);
        } else {
            r.status = Status.Rejected;
            delete activeRequest[r.requester];
        }
        emit OracleResult(requestId, approved, r.approvedUntil);
    }

    /// @notice Required with the one-argument execute API. Only the requester can choose or update a minimum.
    function setSlippageLimit(bytes32 id, uint256 minimumOutput) external {
        Request storage r = _requests[id];
        if (r.requester != msg.sender) revert NotRequester();
        if ((r.status != Status.Pending && r.status != Status.Approved) || minimumOutput == 0) revert InvalidRequest();
        r.minimumOutput = minimumOutput;
        emit SlippageLimitSet(id, minimumOutput);
    }

    function clearRequest(bytes32 id) external nonReentrant {
        Request storage r = _requests[id];
        if (r.requester != msg.sender) revert NotRequester();
        bool staleConfig = r.version != configVersion;
        if (r.status == Status.Pending) {
            if (!staleConfig && block.timestamp < r.deadline) revert InvalidRequest();
        } else if (r.status == Status.Approved) {
            if (!staleConfig && block.timestamp < r.approvedUntil) revert InvalidRequest();
        } else {
            revert InvalidRequest();
        }
        r.status = Status.Cleared;
        delete activeRequest[msg.sender];
        emit RequestCleared(id);
    }

    function executeBuyRequest(bytes32 id) external nonReentrant returns (uint256) {
        return _execute(id, true);
    }

    function executeSellRequest(bytes32 id) external nonReentrant returns (uint256) {
        return _execute(id, false);
    }

    function _execute(bytes32 id, bool buy) private returns (uint256 output) {
        if (block.chainid != 1) revert WrongChain();
        Request storage r = _requests[id];
        if (r.requester != msg.sender) revert NotRequester();
        if (r.status != Status.Approved || r.buy != buy || r.version != configVersion) revert InvalidRequest();
        if (block.timestamp >= r.approvedUntil) revert Expired();
        if (r.minimumOutput == 0) revert Slippage();
        Config memory cfg = _configs[r.version];
        (uint160 current,,,) = poolManager.getSlot0(_key.toId());
        if (priceMovement(r.sqrtPriceX96, current) > cfg.maxImpactBps) revert LimitExceeded();
        _reconcile(msg.sender, cabal.balanceOf(msg.sender));
        r.status = Status.Executed;
        delete activeRequest[msg.sender];
        uint256 fee = buy ? hook.feeFor(r.amount) : 0;
        IERC20 input = buy ? IERC20(cfg.imd) : cabal;
        _pullExact(input, msg.sender, uint256(r.amount) + fee);
        _executing = true;
        _executingId = id;
        (output, fee) = abi.decode(poolManager.unlock(abi.encode(id)), (uint256, uint256));
        _executing = false;
        delete _executingId;
        Holding storage h = holdings[msg.sender];
        if (buy) {
            if (h.units == 0) h.firstBuy = uint64(block.timestamp);
            h.units += output;
            h.costImd += uint256(r.amount) + fee;
        } else {
            uint256 sold = r.amount < h.units ? r.amount : h.units;
            _reduceHolding(h, sold);
        }
        (buy ? cabal : IERC20(cfg.imd)).safeTransfer(msg.sender, output);
        emit RequestExecuted(id, r.amount, output, fee);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_executing) revert UnauthorizedCallback();
        bytes32 id = abi.decode(data, (bytes32));
        if (id != _executingId) revert InvalidRequest();
        // Consume the callback capability before any token interaction.
        _executing = false;
        Request storage r = _requests[id];
        Config storage cfg = _configs[r.version];
        bool input0 = r.buy == (Currency.unwrap(_key.currency0) == cfg.imd);
        Currency input = input0 ? _key.currency0 : _key.currency1;
        Currency outputCurrency = input0 ? _key.currency1 : _key.currency0;
        // Prefund before the swap, including on a freshly seeded manager.
        poolManager.sync(input);
        IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), r.amount);
        if (poolManager.settle() != r.amount) revert UnsupportedToken();
        (uint160 beforePrice,,,) = poolManager.getSlot0(_key.toId());
        BalanceDelta delta = poolManager.swap(
            _key,
            SwapParams(
                input0, -int256(uint256(r.amount)), TickMath.getSqrtPriceAtTick(input0 ? int24(-880000) : int24(880000))
            ),
            ""
        );
        int256 inputDelta = input0 ? int256(delta.amount0()) : int256(delta.amount1());
        int256 outputDelta = input0 ? int256(delta.amount1()) : int256(delta.amount0());
        if (inputDelta != -int256(uint256(r.amount)) || outputDelta <= 0) revert PartialFill();
        (uint160 afterPrice,,,) = poolManager.getSlot0(_key.toId());
        if (
            priceMovement(beforePrice, afterPrice) > cfg.maxImpactBps
                || priceMovement(r.sqrtPriceX96, afterPrice) > cfg.maxImpactBps
        ) revert LimitExceeded();
        uint256 output = uint256(outputDelta);
        poolManager.take(outputCurrency, address(this), output);
        uint256 fee = hook.feeFor(r.buy ? r.amount : output);
        IERC20(cfg.imd).forceApprove(address(hook), fee);
        if (hook.finishSwap() != fee) revert InvalidRequest();
        IERC20(cfg.imd).forceApprove(address(hook), 0);
        if (!r.buy) output -= fee;
        if (output < r.minimumOutput) revert Slippage();
        return abi.encode(output, fee);
    }

    /// @notice An indicative current-active-range estimate; the panel must assess tick-crossing liquidity.
    function estimateImpact(bool buy, uint256 amount) public view returns (uint256) {
        (uint160 sqrtPrice, int24 tick,,) = poolManager.getSlot0(_key.toId());
        uint128 liquidity = poolManager.getLiquidity(_key.toId());
        bool input0 = buy == (Currency.unwrap(_key.currency0) == address(hook.imd()));
        // A token1-only seed at its upper boundary has zero active liquidity until a downward swap crosses it.
        if (liquidity == 0 && input0 && sqrtPrice == TickMath.getSqrtPriceAtTick(tick)) {
            (, int128 netLiquidity) = poolManager.getTickLiquidity(_key.toId(), tick);
            if (netLiquidity < 0) liquidity = uint128(uint256(-int256(netLiquidity)));
        }
        if (liquidity == 0) return 10000;
        uint256 reserve =
            input0 ? FullMath.mulDiv(liquidity, Q96, sqrtPrice) : FullMath.mulDiv(liquidity, sqrtPrice, Q96);
        uint256 net = FullMath.mulDiv(amount, 1_000_000 - _key.fee, 1_000_000);
        uint256 ratio = FullMath.mulDiv(reserve, Q96, reserve + net);
        return 10000 - FullMath.mulDiv(FullMath.mulDiv(ratio, ratio, Q96), 10000, Q96);
    }

    /// @notice Symmetric relative price movement: 1 - min(priceA,priceB)/max(priceA,priceB).
    function priceMovement(uint160 a, uint160 b) public pure returns (uint256) {
        uint256 ratio = a < b ? FullMath.mulDiv(a, Q96, b) : FullMath.mulDiv(b, Q96, a);
        return 10000 - FullMath.mulDiv(FullMath.mulDiv(ratio, ratio, Q96), 10000, Q96);
    }

    function _spotCabalPrice(uint160 sqrtPrice) private view returns (uint256) {
        if (Currency.unwrap(_key.currency0) == address(hook.imd())) {
            return FullMath.mulDiv(FullMath.mulDiv(1e18, Q96, sqrtPrice), Q96, sqrtPrice);
        }
        return FullMath.mulDiv(FullMath.mulDiv(1e18, sqrtPrice, Q96), sqrtPrice, Q96);
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnsupportedToken();
    }

    function _reconcile(address user, uint256 balance) private {
        Holding storage h = holdings[user];
        if (balance < h.units) _reduceHolding(h, h.units - balance);
    }

    function _reduceHolding(Holding storage h, uint256 amount) private {
        if (amount == 0) return;
        h.costImd -= FullMath.mulDiv(h.costImd, amount, h.units);
        h.units -= amount;
        if (h.units == 0) {
            h.costImd = 0;
            h.firstBuy = 0;
        }
    }

    function _nftStatus(address user) private view returns (string memory) {
        (bool ok, bytes memory result) =
            IDENTITY_NFT.staticcall{gas: 30000}(abi.encodeWithSignature("balanceOf(address)", user));
        if (!ok || result.length != 32) return "unknown";
        return abi.decode(result, (uint256)) > 0 ? "yes" : "no";
    }
}
