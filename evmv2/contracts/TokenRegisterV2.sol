// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@mapprotocol/protocol/contracts/utils/Utils.sol";
import "./interface/ITokenRegisterV2.sol";
import "./interface/IVaultTokenV2.sol";


contract TokenRegisterV2 is ITokenRegisterV2,Initializable,UUPSUpgradeable {
    using SafeMath for uint;

    uint256 constant MAX_RATE_UNI = 1000000;

    struct FeeRate {
        uint256     lowest;
        uint256     highest;
        uint256     rate;      // unit is parts per million
    }

    struct Token {
        bool        mintable;
        uint8       decimals;
        address     vaultToken;

        mapping(uint256 => FeeRate) fees;
        // chain_id => decimals
        mapping(uint256 => uint8) tokenDecimals;
        // chain_id => token
        mapping(uint256 => bytes) mappingTokens;
    }

    uint public immutable selfChainId = block.chainid;

    //Source chain to Relay chain address
    // [chain_id => [source_token => map_token]]
    mapping(uint256 => mapping(bytes => address)) public tokenMappingList;

    mapping(address => Token) public tokenList;

    modifier checkAddress(address _address){
        require(_address != address(0), "address is zero");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == _getAdmin(), "register only owner");
        _;
    }

    event RegisterToken(address _token, address _vaultToken, bool _mintable);
    event SetTokenFee(address _token, uint256 _toChain, uint _lowest, uint _highest, uint _rate);

    function initialize() public initializer
    {
        _changeAdmin(msg.sender);
    }


    function registerToken(address _token, address _vaultToken, bool _mintable)
    external
    onlyOwner checkAddress(_token) checkAddress(_vaultToken) {
        Token storage token = tokenList[_token];
        address tokenAddress = IVaultTokenV2(_vaultToken).getTokenAddress();
        require(_token == tokenAddress, "invalid vault token");

        token.vaultToken = _vaultToken;
        token.decimals = IERC20Metadata(_token).decimals();
        token.mintable = _mintable;
        emit RegisterToken(_token, _vaultToken, _mintable);
    }

    function mapToken(address _token, uint256 _fromChain, bytes memory _fromToken, uint8 _decimals)
    external
    onlyOwner
    checkAddress(_token)
    {
        require(!Utils.checkBytes(_fromToken, bytes("")), "invalid from token");
        Token storage token = tokenList[_token];
        require(token.vaultToken != address(0), "invalid map token");
        token.tokenDecimals[_fromChain] = _decimals;
        token.mappingTokens[_fromChain] = _fromToken;
        tokenMappingList[_fromChain][_fromToken] = _token;
    }

    function setTokenFee( address _token, uint256 _toChain, uint _lowest, uint _highest,uint _rate) 
    external 
    onlyOwner
    checkAddress(_token)
    {
        Token storage token = tokenList[_token];
        require(token.vaultToken != address(0), "invalid map token");
        require(_highest >= _lowest, 'invalid highest and lowest');
        require(_rate <= MAX_RATE_UNI, 'invalid proportion value');

        token.fees[_toChain] = FeeRate(_lowest, _highest, _rate);

        emit SetTokenFee(_token, _toChain, _lowest, _highest, _rate);
    }

    // --------------------------------------------------------

    function getToChainToken(address _token, uint256 _toChain)
    external 
    override
    view
    returns (bytes memory _toChainToken){
        if (_toChain == selfChainId) {
            _toChainToken = Utils.toBytes(_token);
        } else {
            _toChainToken = tokenList[_token].mappingTokens[_toChain];
        }
    }

    function getToChainAmount(address _token, uint256 _amount, uint256 _toChain)
    external 
    override
    view
    returns (uint256){
        if (_toChain == selfChainId) {
            return _amount;
        }
        uint256 decimalsFrom = tokenList[_token].decimals;

        require(decimalsFrom > 0, "from token decimals not register");

        uint256 decimalsTo = tokenList[_token].tokenDecimals[_toChain];

        require(decimalsTo > 0, "from token decimals not register");

        if (decimalsFrom == decimalsTo) {
            return _amount;
        }
        return _amount.mul(10 ** decimalsTo).div(10 ** decimalsFrom);
    }

    function getRelayChainToken(uint256 _fromChain, bytes memory _fromToken)
    external 
    override
    view
    returns (address token){
        if (_fromChain == selfChainId) {
            token = Utils.fromBytes(_fromToken);
        } else {
            token = tokenMappingList[_fromChain][_fromToken];
        }
    }

    function getRelayChainAmount(address _token, uint256 _fromChain, uint256 _amount)
    external 
    override 
    view 
    returns (uint256){
        if (_fromChain == selfChainId) {
            return _amount;
        }
        uint256 decimalsFrom = tokenList[_token].tokenDecimals[_fromChain];
        uint256 decimalsTo = tokenList[_token].decimals;
        if (decimalsFrom == decimalsTo) {
            return _amount;
        }
        return _amount.mul(10 ** decimalsTo).div(10 ** decimalsFrom);
    }

    function checkMintable(address _token)
    external 
    override 
    view 
    returns (bool) {
        return tokenList[_token].mintable;
    }

    function getVaultToken(address _token)
    external 
    override 
    view 
    returns (address) {
        return tokenList[_token].vaultToken;
    }

    function getTokenFee(address _token, uint256 _amount, uint256 _toChain)
    external 
    view 
    override 
    returns (uint256) {
        FeeRate memory feeRate = tokenList[_token].fees[_toChain];

        uint256 fee = _amount.mul(feeRate.rate).div(MAX_RATE_UNI);
        if (fee > feeRate.highest){
            return feeRate.highest;
        }else if (fee < feeRate.lowest){
            return feeRate.lowest;
        }
        return fee;
    }

    function getToChainTokenInfo(address _token, uint256 _toChain)
    external
    view
    returns (bytes memory toChainToken, uint8 decimals, FeeRate memory feeRate){
        if (_toChain == selfChainId) {
            toChainToken = Utils.toBytes(_token);
            decimals = tokenList[_token].decimals;
        } else {
            toChainToken = tokenList[_token].mappingTokens[_toChain];
            decimals = tokenList[_token].tokenDecimals[_toChain];
        }

        feeRate = tokenList[_token].fees[_toChain];
    }

    function getFeeAmountAndInfo(uint256 _fromChain, bytes memory _fromToken, uint256 _fromAmount, uint256 _toChain)
    external
    view
    returns (uint256 _feeAmount, FeeRate memory _feeRate, address _relayToken, uint8 _relayTokenDecimals, bytes memory _toToken, uint8 _toTokenDecimals) {

        (_relayToken, , _feeAmount) =  this.getRelayFee(_fromChain, _fromToken, _fromAmount, _toChain);
        (_toToken, _toTokenDecimals, _feeRate) = this.getToChainTokenInfo(_relayToken, _toChain);

        _relayTokenDecimals = tokenList[_relayToken].decimals;
    }

    function getFeeAmountAndVaultBalance(uint256 _srcChain,bytes memory _srcToken,uint256 _srcAmount,uint256 _targetChain) 
    external
    view
    returns(uint256 _srcFeeAmount,uint256 _relayChainAmount,int256 _vaultBalance,bytes memory _toChainToken){
        address relayToken;
        uint256 feeAmount;

        (relayToken, _relayChainAmount, feeAmount) = this.getRelayFee(_srcChain, _srcToken, _srcAmount, _targetChain);
         _srcFeeAmount = this.getToChainAmount(relayToken, feeAmount, _srcChain);

         address vault = this.getVaultToken(relayToken);
         (bool result,bytes memory data) =  vault.staticcall(abi.encodeWithSignature("vaultBalance(uint256)",_targetChain));
         if(result && data.length > 0) {
            _vaultBalance = abi.decode(data,(int256));
            if(_vaultBalance > 0) {
                uint256 tem = this.getToChainAmount(relayToken,uint256(_vaultBalance),_targetChain);
                require(tem <= uint256(type(int256).max), "value doesn't fit in an int256");
                _vaultBalance = int256(tem);
            } else {
                  _vaultBalance = 0;
            }
         } else {
             _vaultBalance = 0;
         }

        _toChainToken = this.getToChainToken(relayToken, _targetChain);
    }

    // -----------------------------------------------------

    function getRelayFee(uint256 _fromChain,bytes memory _fromToken,uint256 _fromAmount,uint256 _toChain)
    external
    view
    returns(address _relayToken, uint256 _relayChainAmount, uint256 _feeAmount) {

        _relayToken = this.getRelayChainToken(_fromChain, _fromToken);

        _relayChainAmount = this.getRelayChainAmount(_relayToken, _fromChain, _fromAmount);

        _feeAmount = this.getTokenFee(_relayToken, _relayChainAmount, _toChain);
    }

    /** UUPS *********************************************************/
    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == _getAdmin(), "TokenRegister: only Admin can upgrade");
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