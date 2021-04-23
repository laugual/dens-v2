pragma ton-solidity >=0.38.2;
pragma AbiHeader time;
pragma AbiHeader pubkey;
pragma AbiHeader expire;

//================================================================================
//
import "./DnsRecordBase.sol";

//================================================================================
//
contract DnsRecord is DnsRecordBase
{
    //========================================
    //
    function calculateDomainAddress(string domainName) public view override returns (address, TvmCell)
    {
        TvmCell stateInit = tvm.buildStateInit({
            contr: DnsRecord,
            varInit: {
                _domainName: domainName,
                _domainCode: _domainCode
            },
            code: _domainCode
        });

        return (address(tvm.hash(stateInit)), stateInit);
    }
    
    //========================================
    //
    /// @dev we still need address and pubkey here in constructor, because root level domains are registerd right away;
    //
    constructor(address ownerAddress) public
    {
        require(ownerAddress != addressZero, ERROR_ADDRESS_CAN_NOT_BE_EMPTY);

        // _validateDomainName() is very expensive, can't do anything without tvm.accept() first;
        // if the deployment is done by internal message, tvm.accept() is not needed, but if
        // deployment is via external message, can't help it;
        //
        // Be sure that you use a valid "_domainName", otherwise you will loose your Crystals;        
        tvm.accept();

        _nameIsValid = _validateDomainName(_domainName);
        require(_nameIsValid, ERROR_DOMAIN_NAME_NOT_VALID);
        _minimumBalance = MIN_BALANCE;

       (string[] segments, string parentName) = _parseDomainName(_domainName);
        _whoisInfo.segmentsCount              = uint8(segments.length);
        _whoisInfo.domainName                 = _domainName;
        _whoisInfo.parentDomainName           = parentName;
       (_whoisInfo.parentDomainAddress, )     = calculateDomainAddress(parentName);
        _whoisInfo.registrationType           = REG_TYPE.DENY; //sanity
        _whoisInfo.dtCreated                  = now;
        _whoisInfo.dtExpires                  = 0; // sanity
        
        // Registering a new domain is the same as claiming the expired from this point:
        _claimExpired(ownerAddress);

        // TODO: do we need to call regular "claimExpired" if it's an internal message with value?

        // Return the change adter contructor is done;
        _reserve();
        address returnAddress = (msg.sender == addressZero ? ownerAddress : msg.sender);
        returnAddress.transfer(0, false, 128);
    }

    //========================================
    //
    function _claimExpired(address newOwnerAddress) internal
    {
        // if it is a ROOT domain name
        if(_whoisInfo.segmentsCount == 1) 
        {
            // Root domains won't need approval, internal callback right away
            _callbackOnRegistrationRequest(REG_RESULT.APPROVED, newOwnerAddress);
        }
    }
    
    function claimExpired(address newOwnerAddress) public override Expired NameIsValid
    {
        require(msg.pubkey() == 0 && msg.sender != addressZero && msg.value > 0, ERROR_REQUIRE_INTERNAL_MESSAGE_WITH_VALUE);

        _reserve();

        // reset ownership first
        _changeOwner(addressZero);
        _claimExpired(newOwnerAddress);

        if(_whoisInfo.segmentsCount > 1)
        {
            _sendRegistrationRequest(newOwnerAddress);
        }
    }

    //========================================
    //
    function _sendRegistrationRequest(address newOwnerAddress) internal view
    {
        IDnsRecord(_whoisInfo.parentDomainAddress).receiveRegistrationRequest{value: 0, callback: IDnsRecord.callbackOnRegistrationRequest, flag: 128}(_domainName, newOwnerAddress, msg.sender);
    }
    
    //========================================
    //
    function receiveRegistrationRequest(string domainName, address ownerAddress, address payerAddress) external responsible override returns (REG_RESULT, address, address)
    {
        //========================================
        // 0. Sanity; We don't want to go out of gas because someone sent jibberish;
        require(domainName.byteLength() >= MIN_SEGMENTS_LENGTH && domainName.byteLength() <= MAX_DOMAIN_LENGTH, ERROR_DOMAIN_NAME_NOT_VALID);

        //========================================
        // 1. Check if the request came from domain itself; cheaper than parsing, so, it goes first;
        (address addr, ) = calculateDomainAddress(domainName);
        require(addr == msg.sender, ERROR_MESSAGE_SENDER_IS_NOT_VALID);

        // 2. Check if it is really my subdomain;
        (, string parentName) = _parseDomainName(domainName);
        require(parentName == _whoisInfo.domainName, ERROR_MESSAGE_SENDER_IS_NOT_MY_SUBDOMAIN);


        //========================================
        // 3. Reserve minimum balance;
        _reserve();

        //========================================
        // General flow;
        REG_RESULT result;
             if(_whoisInfo.registrationType == REG_TYPE.FFA)    {    result = REG_RESULT.APPROVED;    }
        else if(_whoisInfo.registrationType == REG_TYPE.DENY)   {    result = REG_RESULT.DENIED;      }
        else if(_whoisInfo.registrationType == REG_TYPE.MONEY)
        {
            if(msg.value > _whoisInfo.registrationPrice)
            {
                address(_whoisInfo.ownerAddress).transfer(_whoisInfo.registrationPrice, false, 1);
                _whoisInfo.totalFeesCollected += _whoisInfo.registrationPrice;
                result = REG_RESULT.APPROVED;
            }
            else
            {
                result = REG_RESULT.NOT_ENOUGH_MONEY;
            }
        }
        else if(_whoisInfo.registrationType == REG_TYPE.OWNER)
        {
            bool ownerCalled = (ownerAddress == _whoisInfo.ownerAddress);
            result = (ownerCalled ? REG_RESULT.APPROVED : REG_RESULT.DENIED);
        }

        // Common statistics
        if(result == REG_RESULT.APPROVED)
        {
            // 1.
            _whoisInfo.subdomainRegAccepted += 1;
            emit newSubdomainRegistered(now, domainName, 0);
        }
        else if(result == REG_RESULT.DENIED)
        {
            _whoisInfo.subdomainRegDenied += 1;
        }

        return{value: 0, flag: 128}(result, ownerAddress, payerAddress);
    }
    
    //========================================
    //
    function _callbackOnRegistrationRequest(REG_RESULT result, address ownerAddress) internal
    {
        emit registrationResult(now, result, ownerAddress);
        _whoisInfo.lastRegResult = result;
        
        if(result == REG_RESULT.APPROVED)
        {
            _whoisInfo.ownerAddress    = ownerAddress;
            _whoisInfo.dtExpires       = (now + ninetyDays);
            _whoisInfo.totalOwnersNum += 1;
        }
        else if(result == REG_RESULT.DENIED || result == REG_RESULT.NOT_ENOUGH_MONEY)
        {
            // Domain ownership is reset
            _whoisInfo.ownerAddress = addressZero;
            _whoisInfo.dtExpires    = 0;
        }
    }

    //========================================
    //
    function callbackOnRegistrationRequest(REG_RESULT result, address ownerAddress, address payerAddress) external override onlyRoot
    {
        _reserve();

        // We can't move this to a modifier because if it's there parent domain will get a Bounce message back with all the
        // TONs that need to be returned to original caller;
        // 
        // NOTE: but "onlyRoot" is still a modifier, because if anyone else is sending us a message, we should Bounce it;
        if(isExpired())
        {
            _callbackOnRegistrationRequest(result, ownerAddress);
        }

        // Return all remaining change to payer;
        payerAddress.transfer(0, false, 128);
    }
}

//================================================================================
//
