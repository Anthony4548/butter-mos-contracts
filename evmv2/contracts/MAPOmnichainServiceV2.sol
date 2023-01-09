// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interface/IWToken.sol";
import "./utils/ButterLib.sol";
import "./interface/IMAPToken.sol";
import "./utils/TransferHelper.sol";
import "./interface/IMOSV2.sol";
import "./interface/ILightNode.sol";
import "./utils/RLPReader.sol";
import "./utils/Utils.sol";
import "./utils/EvmDecoder.sol";


contract MAPOmnichainServiceV2 is ReentrancyGuard, Initializable, Pausable, IMOSV2, UUPSUpgradeable {
    using SafeMath for uint;
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;

    uint public immutable selfChainId = block.chainid;
    uint public nonce;
    address public wToken;          // native wrapped token
    address public relayContract;
    uint256 public relayChainId;
    ILightNode public lightNode;

    mapping(bytes32 => bool) public orderList;
    mapping(address => bool) public mintableTokens;
    mapping(uint256 => mapping(address => bool)) public tokenMappingList;

    address public butterCore;

    event mapTransferExecute(uint256 indexed fromChain, uint256 indexed toChain, address indexed from);
    event mapSwapExecute(uint256 indexed fromChain, uint256 indexed toChain, address indexed from);

    function initialize(address _wToken, address _lightNode)
    public initializer checkAddress(_wToken) checkAddress(_lightNode) {
        wToken = _wToken;
        lightNode = ILightNode(_lightNode);
        _changeAdmin(msg.sender);
    }


    receive() external payable {}


    modifier checkOrder(bytes32 _orderId) {
        require(!orderList[_orderId], "order exist");
        orderList[_orderId] = true;
        _;
    }

    modifier checkBridgeable(address _token, uint _chainId) {
        require(tokenMappingList[_chainId][_token], "token not registered");
        _;
    }

    modifier checkAddress(address _address) {
        require(_address != address(0), "address is zero");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == _getAdmin(), "mos :: only admin");
        _;
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnpause() external onlyOwner {
        _unpause();
    }

    function setLightClient(address _lightNode) external onlyOwner checkAddress(_lightNode) {
        lightNode = ILightNode(_lightNode);
    }

    function addMintableToken(address[] memory _token) external onlyOwner {
        for (uint i = 0; i < _token.length; i++) {
            mintableTokens[_token[i]] = true;
        }
    }

    function removeMintableToken(address[] memory _token) external onlyOwner {
        for (uint i = 0; i < _token.length; i++) {
            mintableTokens[_token[i]] = false;
        }
    }

    function setRelayContract(uint256 _chainId, address _relay) external onlyOwner checkAddress(_relay) {
        relayContract = _relay;
        relayChainId = _chainId;
    }

    function setButterCoreAddress(address _butterCoreAddress) external onlyOwner checkAddress(_butterCoreAddress) {
        butterCore = _butterCoreAddress;
    }

    function registerToken(address _token, uint _toChain, bool _enable) external onlyOwner {
        tokenMappingList[_toChain][_token] = _enable;
    }

    function emergencyWithdraw(address _token, address payable _receiver, uint256 _amount) external onlyOwner checkAddress(_receiver) {
        if (_token == wToken) {
            TransferHelper.safeWithdraw(wToken, _amount);
            TransferHelper.safeTransferETH(_receiver, _amount);
        } else if (_token == address(0)) {
            TransferHelper.safeTransferETH(_receiver, _amount);
        } else {
            TransferHelper.safeTransfer(_token, _receiver, _amount);
        }
    }

    function transferOutToken(address _token, bytes memory _to, uint256 _amount, uint256 _toChain) external override nonReentrant whenNotPaused
    checkBridgeable(_token, _toChain) {
        require(_toChain != selfChainId, "only other chain");
        require(IERC20(_token).balanceOf(msg.sender) >= _amount, "balance too low");

        if (isMintable(_token)) {
            IMAPToken(_token).burnFrom(msg.sender, _amount);
        } else {
            TransferHelper.safeTransferFrom(_token, msg.sender, address(this), _amount);
        }
        bytes32 orderId = _getOrderID(msg.sender, _to, _toChain);
        emit mapTransferOut(selfChainId, _toChain, orderId, Utils.toBytes(_token), Utils.toBytes(msg.sender), _to, _amount, Utils.toBytes(address(0)));
    }

    function transferOutNative(bytes memory _to, uint _toChain) external override payable nonReentrant whenNotPaused
    checkBridgeable(wToken, _toChain) {
        require(_toChain != selfChainId, "only other chain");
        uint amount = msg.value;
        require(amount > 0, "balance is zero");
        IWToken(wToken).deposit{value : amount}();
        bytes32 orderId = _getOrderID(msg.sender, _to, _toChain);
        emit mapTransferOut(selfChainId, _toChain, orderId, Utils.toBytes(wToken), Utils.toBytes(msg.sender), _to, amount, Utils.toBytes(address(0)));
    }

    function swapOutToken(
        address _initiatorAddress, // swap initiator address
        address _token, // src token
        bytes memory _to,
        uint256 _amount,
        uint256 _toChain, // target chain id
        bytes calldata swapData
    )
    external
    override
    nonReentrant
    whenNotPaused
    checkBridgeable(_token, _toChain)
    {
        require(_toChain != selfChainId, "Cannot swap to self chain");
        require(IERC20(_token).balanceOf(msg.sender) >= _amount, "Insufficient token balance");

        if (isMintable(_token)) {
            IMAPToken(_token).burnFrom(msg.sender, _amount);
        } else {
            TransferHelper.safeTransferFrom(_token, msg.sender, address(this), _amount);
        }

        bytes32 orderId = _getOrderID(msg.sender, _to, _toChain);

        emit mapSwapOut(
            selfChainId,
            _toChain,
            orderId,
            Utils.toBytes(_token),
            Utils.toBytes(_initiatorAddress),
            _to,
            _amount,
            swapData
        );
    }

    function swapOutNative(
        address _initiatorAddress, // swap initiator address
        bytes memory _to,
        uint256 _toChain, // target chain id
        bytes calldata swapData
    )
    external
    override
    payable
    nonReentrant
    whenNotPaused
    checkBridgeable(wToken, _toChain)
    {
        require(_toChain != selfChainId, "Cannot swap to self chain");
        uint amount = msg.value;
        require(amount > 0, "Sending value is zero");
        IWToken(wToken).deposit{value : amount}();
        bytes32 orderId = _getOrderID(msg.sender, _to, _toChain);
        emit mapSwapOut(
            selfChainId,
            _toChain,
            orderId,
            Utils.toBytes(wToken),
            Utils.toBytes(_initiatorAddress),
            _to,
            amount,
            swapData
        );

    }

    function depositToken(address _token, address _to, uint _amount) external override nonReentrant whenNotPaused
    checkBridgeable(_token, relayChainId) {
        address from = msg.sender;
        //require(IERC20(token).balanceOf(_from) >= _amount, "balance too low");

        if (isMintable(_token)) {
            IMAPToken(_token).burnFrom(from, _amount);
        } else {
            TransferHelper.safeTransferFrom(_token, from, address(this), _amount);
        }

        bytes32 orderId = _getOrderID(from, Utils.toBytes(_to), relayChainId);
        emit mapDepositOut(selfChainId, relayChainId, orderId, _token, Utils.toBytes(from), _to, _amount);
    }

    function depositNative(address _to) external override payable nonReentrant whenNotPaused
    checkBridgeable(wToken, relayChainId) {
        address from = msg.sender;
        uint amount = msg.value;
        bytes32 orderId = _getOrderID(from, Utils.toBytes(_to), relayChainId);

        IWToken(wToken).deposit{value : amount}();
        emit mapDepositOut(selfChainId, relayChainId, orderId, wToken, Utils.toBytes(from), _to, amount);
    }

    function transferIn(uint256 _chainId, bytes memory _receiptProof) external nonReentrant whenNotPaused {
        require(_chainId == relayChainId, "invalid chain id");
        (bool sucess, string memory message, bytes memory logArray) = lightNode.verifyProofData(_receiptProof);
        require(sucess, message);
        IEvent.txLog[] memory logs = EvmDecoder.decodeTxLogs(logArray);

        for (uint i = 0; i < logs.length; i++) {
            IEvent.txLog memory log = logs[i];
            bytes32 topic = abi.decode(log.topics[0], (bytes32));

            if (topic == EvmDecoder.MAP_TRANSFEROUT_TOPIC && relayContract == log.addr) {
                (, IEvent.transferOutEvent memory outEvent) = EvmDecoder.decodeTransferOutLog(log);
                // there might be more than on events to multi-chains
                // only process the event for this chain
                if (selfChainId == outEvent.toChain) {
                    _transferIn(outEvent);
                }
            }
        }
        emit mapTransferExecute(_chainId, selfChainId, msg.sender);
    }

    function swapIn(uint256 _chainId, bytes memory _receiptProof) external nonReentrant whenNotPaused {
        require(_chainId == relayChainId, "invalid chain id");
        (bool success, string memory message, bytes memory logArray) = lightNode.verifyProofData(_receiptProof);
        require(success, message);
        IEvent.txLog[] memory logs = EvmDecoder.decodeTxLogs(logArray);
        for (uint i = 0; i < logs.length; i++) {
            IEvent.txLog memory log = logs[i];
            bytes32 topic = abi.decode(log.topics[0], (bytes32));
            if (topic == EvmDecoder.MAP_SWAPOUT_TOPIC && relayContract == log.addr) {
                (, IEvent.swapOutEvent memory outEvent) = EvmDecoder.decodeSwapOutLog(log);
                // there might be more than one events to multi-chains
                // only process the event for this chain
                if (selfChainId == outEvent.toChain) {
                    _swapIn(outEvent);
                }
            }
        }

        emit mapSwapExecute(_chainId, selfChainId, msg.sender);
    }

    function isMintable(address _token) public view returns (bool) {
        return mintableTokens[_token];
    }

    function isBridgeable(address _token, uint256 _toChain) public view returns (bool) {
        return tokenMappingList[_toChain][_token];
    }

    function _getOrderID(address _from, bytes memory _to, uint _toChain) internal returns (bytes32){
        return keccak256(abi.encodePacked(address(this), nonce++, selfChainId, _toChain, _from, _to));
    }

    function _transferIn(IEvent.transferOutEvent memory _outEvent)
    internal checkOrder(_outEvent.orderId) {
        //require(_chainId == _outEvent.toChain, "invalid chain id");
        address token = Utils.fromBytes(_outEvent.toChainToken);
        address payable toAddress = payable(Utils.fromBytes(_outEvent.to));
        uint256 amount = _outEvent.amount;
        if (token == wToken) {
            TransferHelper.safeWithdraw(wToken, amount);
            TransferHelper.safeTransferETH(toAddress, amount);
        } else if (isMintable(token)) {
            IMAPToken(token).mint(toAddress, amount);
        } else {
            TransferHelper.safeTransfer(token, toAddress, amount);
        }

        emit mapTransferIn(_outEvent.fromChain, _outEvent.toChain, _outEvent.orderId, token, _outEvent.from, toAddress, amount);
    }

    function _swapIn(IEvent.swapOutEvent memory _outEvent) internal checkOrder(_outEvent.orderId) {
        address tokenIn = Utils.fromBytes(_outEvent.token);

        // decode params
        ButterLib.SwapData memory swapData;
        (swapData.swapParams, swapData.targetToken, swapData.mapTargetToken) = abi.decode(_outEvent.swapData,
            ((ButterLib.SwapParam)[], bytes, address));

        address tokenOut = Utils.fromBytes(swapData.targetToken);

        // receiving address
        address payable toAddress = payable(Utils.fromBytes(_outEvent.to));
        // amount of token need to be sent
        uint actualAmountIn = _outEvent.amount;

        ButterLib.SwapParam[] memory swapParams = swapData.swapParams;
        // if swap params is not empty, then we need to do swap on current chain
        if (swapParams.length > 0) {
            if (isMintable(tokenIn)) {
                IMAPToken(tokenIn).mint(address(this), actualAmountIn);
            }
            uint predicatedAmountIn = Utils.getAmountInSumFromSwapParams(swapParams);
            // assemble request to call butter core
            ButterLib.ButterCoreSwapParam memory butterCoreSwapParam =
            Utils.assembleButterCoreParam(tokenIn, actualAmountIn, predicatedAmountIn, _outEvent.to, swapData);
            // low-level call butter core to finish swap
            TransferHelper.safeApprove(tokenIn, butterCore, actualAmountIn);
            (bool success,) = address(butterCore).call(
                abi.encodeWithSignature("multiSwap((uint256[],bytes[],uint32[],address[2]))", butterCoreSwapParam)
            );

            // if swap succeed, just return
            if (success) {
                emit mapSwapIn(_outEvent.fromChain, selfChainId, _outEvent.orderId, tokenOut, _outEvent.from, toAddress, actualAmountIn);
                return;
            }

            // if swap not succeed or swap not happened, give user the source token
            tokenOut = tokenIn;
        }

        // transfer token if swap did not happen
        if (tokenOut == wToken) {
            TransferHelper.safeWithdraw(wToken, actualAmountIn);
            TransferHelper.safeTransferETH(toAddress, actualAmountIn);
        } else if (isMintable(tokenOut) && swapParams.length == 0) {
            IMAPToken(tokenOut).mint(toAddress, actualAmountIn);
        } else {
            TransferHelper.safeTransfer(tokenOut, toAddress, actualAmountIn);
        }
        emit mapSwapIn(_outEvent.fromChain, selfChainId, _outEvent.orderId, tokenOut, _outEvent.from, toAddress, actualAmountIn);
    }

    /** UUPS *********************************************************/
    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == _getAdmin(), "MAPOmnichainService: only Admin can upgrade");
    }

    function changeAdmin(address _admin) external onlyOwner checkAddress(_admin) {
        _changeAdmin(_admin);
    }

    function getAdmin() external view returns (address) {
        return _getAdmin();
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}