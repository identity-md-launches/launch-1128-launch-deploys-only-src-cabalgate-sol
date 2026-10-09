// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
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
import {ImpactEstimator} from "./ImpactEstimator.sol";
import {IIntake, Attestation} from "./interfaces/IIntake.sol";
import {OracleSignature} from "./libraries/OracleSignature.sol";
import {MainnetDefaults} from "./libraries/MainnetDefaults.sol";
import {DataStore} from "./libraries/DataStore.sol";
import {PriceMath} from "./libraries/PriceMath.sol";

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
        /// @dev EIP-712 verifyingContract declared to the oracle as the request's consumer; zero means this gate.
        address oracleVerifier;
        bytes32 action;
        uint128 maxBuyAmount;
        uint128 maxSellAmount;
        /// @dev Cap on one trade's own price movement, estimated at submission and measured at execution.
        uint16 maxImpactBps;
        /// @dev Cap on the movement between submission and execution caused by anything else.
        uint16 maxDriftBps;
        uint16 panelSize;
        uint16 quorum;
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
        /// @dev DataStore pointer holding the JSON-escaped question, read back to verify the signed questionHash.
        address question;
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
    /// @dev The oracle stamps issuedAt from its own clock; allow it to run slightly ahead of block time.
    uint256 public constant CLOCK_TOLERANCE = 5 minutes;
    /// @dev Sanity bound on expiresAt - issuedAt.
    uint256 public constant MAX_VALIDITY = 1 days;
    address public constant IDENTITY_NFT = MainnetDefaults.IDENTITY_NFT;
    /// @dev The pool the hook binds (CabalHook.beforeInitialize accepts only fee 12500 and tick spacing 60); the
    ///      launch manifest allows at most sixteen constructor words, so they are constants rather than arguments.
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant POOL_TICK_SPACING = 60;
    CabalHook public immutable hook;
    IPoolManager public immutable poolManager;
    IERC20 public immutable cabal;
    QuestionBuilder public immutable questionBuilder;
    ImpactEstimator public immutable estimator;
    PoolKey private _key;
    /// @dev keccak256(abi.encode(_key)): what hook.poolKey() must return, checked at every submission.
    bytes32 private immutable _keyHash;
    mapping(bytes32 => Request) private _requests;
    mapping(address => bytes32) public activeRequest;
    mapping(address => Holding) public holdings;
    /// @notice Oracle attestation id => the gate request it decided; each signed attestation is consumed once.
    mapping(bytes32 => bytes32) public attestationUsedBy;
    mapping(uint64 => Config) private _configs;
    uint64 public configVersion;
    bool private _executing;
    bytes32 private _executingId;

    event Configured(uint64 indexed version, Config configuration);
    event RequestSubmitted(
        bytes32 indexed id, address indexed user, bool buy, uint256 amount, address question, bytes body
    );
    event OracleResult(bytes32 indexed id, bytes32 indexed attestationId, bool approved, uint64 approvedUntil);
    event SlippageLimitSet(bytes32 indexed id, uint256 minimumOutput);
    event RequestCleared(bytes32 indexed id);
    event RequestExecuted(bytes32 indexed id, uint256 input, uint256 output, uint256 fee);

    /// @dev Launch constructor: flat static words only, no external calls and no code-length checks, because the
    ///      launch factory rehearses deployment in an EVM where the hook, PoolManager, Intake and IMD have no code.
    ///      The hook's own view of the pool (gate, CABAL, IMD, poolKey) is checked at every submission instead.
    ///      The pool key is derived here: currency0 is the lower of CABAL and IMD, currency1 the higher, with the
    ///      constant fee and tick spacing and `hooks = hook`, so the manifest carries fifteen words.
    constructor(
        CabalHook launchHook,
        IPoolManager manager,
        address cabalToken,
        address initialOwner,
        address intake,
        address imd,
        address signer,
        bytes32 action,
        uint128 maxBuyAmount,
        uint128 maxSellAmount,
        uint16 maxImpactBps,
        uint16 maxDriftBps,
        uint16 panelSize,
        uint16 quorum,
        uint8 windowHours
    ) Ownable(initialOwner) {
        if (
            address(launchHook) == address(0) || address(manager) == address(0) || cabalToken == address(0)
                || imd == address(0) || cabalToken == imd
        ) revert InvalidConfig();
        hook = launchHook;
        poolManager = manager;
        cabal = IERC20(cabalToken);
        (address currency0, address currency1) = cabalToken < imd ? (cabalToken, imd) : (imd, cabalToken);
        _key = PoolKey(
            Currency.wrap(currency0), Currency.wrap(currency1), POOL_FEE, POOL_TICK_SPACING, IHooks(address(launchHook))
        );
        _keyHash = keccak256(abi.encode(_key));
        questionBuilder = new QuestionBuilder();
        estimator = new ImpactEstimator(manager, _key);
        _configure(
            Config({
                intake: intake,
                imd: imd,
                signer: signer,
                oracleVerifier: address(this),
                action: action,
                maxBuyAmount: maxBuyAmount,
                maxSellAmount: maxSellAmount,
                maxImpactBps: maxImpactBps,
                maxDriftBps: maxDriftBps,
                panelSize: panelSize,
                quorum: quorum,
                windowHours: windowHours,
                boolAnswerType: 0
            })
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

    /// @notice The stored JSON-escaped question of a request, as it appears inside the body's `question` string.
    function questionOf(bytes32 id) external view returns (bytes memory) {
        return DataStore.read(_requests[id].question);
    }

    /// @dev Configuration changes invalidate execution of old approvals. Oracle identities remain snapshotted.
    /// A pool's currency cannot be changed after initialization; a new IMD asset requires a new pool and gate.
    /// Runs on the live chain, so it keeps the checks that read other contracts; the constructor cannot make them.
    function configure(Config calldata cfg) external onlyOwner nonReentrant {
        if (cfg.intake.code.length == 0 || cfg.imd != address(hook.imd()) || cfg.imd.code.length == 0) {
            revert InvalidConfig();
        }
        _configure(cfg);
    }

    /// @dev Validation that needs no chain state. The oracle accepts panelSize and quorum only in 2..300.
    function _configure(Config memory cfg) private {
        if (cfg.oracleVerifier == address(0)) cfg.oracleVerifier = address(this);
        if (
            cfg.intake == address(0) || cfg.imd == address(0) || cfg.signer == address(0) || cfg.action == bytes32(0)
                || cfg.maxBuyAmount == 0 || cfg.maxSellAmount == 0 || cfg.maxBuyAmount > uint128(type(int128).max)
                || cfg.maxSellAmount > uint128(type(int128).max) || cfg.maxImpactBps == 0 || cfg.maxImpactBps > 5000
                || cfg.maxDriftBps < cfg.maxImpactBps || cfg.maxDriftBps > 5000 || cfg.quorum < 2
                || cfg.quorum > cfg.panelSize || cfg.panelSize > 300 || cfg.windowHours == 0 || cfg.windowHours > 24
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
        Config memory cfg = _configs[configVersion];
        // The constructor could not read the hook; the hook must now report this gate, this pool and these tokens.
        // poolKey() returns abi.encode(PoolKey), compared raw against the hash of the key built from the words.
        (bool ok, bytes memory reported) = address(hook).staticcall(abi.encodeCall(hook.poolKey, ()));
        if (
            !ok || keccak256(reported) != _keyHash || hook.gate() != address(this) || hook.cabal() != address(cabal)
                || address(hook.imd()) != cfg.imd
        ) revert InvalidConfig();
        if (activeRequest[msg.sender] != bytes32(0)) revert ActiveRequest();
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
            panelSize: cfg.panelSize,
            quorum: cfg.quorum,
            verifier: cfg.oracleVerifier,
            nftStatus: _nftStatus(msg.sender)
        });
        (bytes memory body, bytes memory escapedQuestion) = questionBuilder.build(context, reason);
        address question = DataStore.write(escapedQuestion);
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
            question: question
        });
        activeRequest[msg.sender] = id;
        emit RequestSubmitted(id, msg.sender, buy, amount, question, body);
    }

    /// @notice Verify and store only: no trades, token transfers or NFT reads here. The Intake calls this with
    ///         `callbackGas` (200,000 live) and `abi.encode(requestId, attestation, signature)` as the oracle
    ///         writer delivered it. `requestId` is the Intake's id; `a.requestId` is the oracle's own id, so the
    ///         attestation is bound to this request through the signed questionHash of the stored question.
    function onOracleResult(bytes32 requestId, Attestation calldata a, bytes calldata signature) external nonReentrant {
        Request storage r = _requests[requestId];
        Config storage cfg = _configs[r.version];
        if (msg.sender != cfg.intake || r.status != Status.Pending) revert UnauthorizedCallback();
        if (block.chainid != 1 || block.timestamp >= r.deadline) revert Expired();
        if (
            a.requestId == bytes32(0) || attestationUsedBy[a.requestId] != bytes32(0) || a.chainId != 1
                || a.answerType != cfg.boolAnswerType || a.answer.length != 32 || a.fromBlock > a.toBlock
                || a.toBlock > block.number || a.blockHash == bytes32(0) || a.panelJobId == bytes32(0)
                || a.panelSize != cfg.panelSize || a.quorum != cfg.quorum || a.agreed < a.quorum
                || a.agreed > a.panelSize || a.issuedAt < r.createdAt || a.issuedAt > block.timestamp + CLOCK_TOLERANCE
                || a.expiresAt <= block.timestamp || a.expiresAt <= a.issuedAt
                || a.expiresAt - a.issuedAt > MAX_VALIDITY
        ) revert InvalidAttestation();
        if (a.questionHash != questionBuilder.questionHash(DataStore.read(r.question), a.fromBlock, a.toBlock)) {
            revert InvalidAttestation();
        }
        if (ECDSA.recover(OracleSignature.digest(a, 1, cfg.oracleVerifier), signature) != cfg.signer) {
            revert InvalidAttestation();
        }
        attestationUsedBy[a.requestId] = requestId;
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
        emit OracleResult(requestId, a.requestId, approved, r.approvedUntil);
    }

    /// @notice Stores the minimum output for the one-argument execute functions. Only the requester may set it.
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

    /// @notice Executes with the minimum output previously stored through setSlippageLimit.
    function executeBuyRequest(bytes32 id) external nonReentrant returns (uint256) {
        return _execute(id, true, 0);
    }

    function executeSellRequest(bytes32 id) external nonReentrant returns (uint256) {
        return _execute(id, false, 0);
    }

    /// @notice Executes with an inline minimum output (net of the sell fee), so no separate call is needed.
    function executeBuyRequest(bytes32 id, uint256 minimumOutput) external nonReentrant returns (uint256) {
        return _execute(id, true, minimumOutput);
    }

    function executeSellRequest(bytes32 id, uint256 minimumOutput) external nonReentrant returns (uint256) {
        return _execute(id, false, minimumOutput);
    }

    function _execute(bytes32 id, bool buy, uint256 minimumOutput) private returns (uint256 output) {
        if (block.chainid != 1) revert WrongChain();
        Request storage r = _requests[id];
        if (r.requester != msg.sender) revert NotRequester();
        if (r.status != Status.Approved || r.buy != buy || r.version != configVersion) revert InvalidRequest();
        if (block.timestamp >= r.approvedUntil) revert Expired();
        if (minimumOutput != 0) {
            r.minimumOutput = minimumOutput;
            emit SlippageLimitSet(id, minimumOutput);
        }
        if (r.minimumOutput == 0) revert Slippage();
        Config memory cfg = _configs[r.version];
        (uint160 current,,,) = poolManager.getSlot0(_key.toId());
        if (priceMovement(r.sqrtPriceX96, current) > cfg.maxDriftBps) revert LimitExceeded();
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
        // The trade's own movement is bounded by maxImpactBps; drift since submission was bounded before it.
        if (priceMovement(beforePrice, afterPrice) > cfg.maxImpactBps) revert LimitExceeded();
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

    /// @notice Indicative price movement in bps of an exact-input trade, from the current price: active liquidity,
    ///         or the nearest initialised liquidity in the swap direction when none is active (see ImpactEstimator).
    function estimateImpact(bool buy, uint256 amount) public view returns (uint256) {
        return estimator.estimate(buy == (Currency.unwrap(_key.currency0) == address(hook.imd())), amount);
    }

    /// @notice Symmetric relative price movement: 1 - min(priceA,priceB)/max(priceA,priceB).
    function priceMovement(uint160 a, uint160 b) public pure returns (uint256) {
        return PriceMath.movement(a, b);
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
