// SPDX-License-Identifier: BSD-3-Clause
pragma solidity =0.7.6;
pragma abicoder v2;
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4/contracts/math/Math.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4/contracts/cryptography/ECDSA.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4/contracts/presets/ERC20PresetMinterPauser.sol";


/**
@title Chequebook contract without waivers
@author The Btfs Authors
@notice The chequebook contract allows the issuer of the chequebook to send cheques to an unlimited amount of counterparties.
Furthermore, solvency can be guaranteed via hardDeposits
@dev as an issuer, no cheques should be send if the cumulative worth of a cheques send is above the cumulative worth of all deposits
as a beneficiary, we should always take into account the possibility that a cheque bounces
*/
contract SimpleSwap {
  using SafeMath for uint;

  event ChequeCashed(
    address indexed beneficiary,
    address indexed recipient,
    address indexed caller,
    uint totalPayout,
    uint cumulativePayout,
    uint callerPayout
  );
  event ChequeBounced();
  event Withdraw(uint amount);
  event IncreaseStake(uint amount);
  event DecreaseStake(uint amount, address recipient);

  struct EIP712Domain {
    string name;
    string version;
    uint256 chainId;
  }

  /* structure to keep track of the stake records*/
  struct stake {
    uint amount; /* total stake */
    uint canBeDecreasedAt; /* point in time after which stake can be decreased*/
  }

  bytes32 public constant EIP712DOMAIN_TYPEHASH = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId)"
  );
  bytes32 public constant CHEQUE_TYPEHASH = keccak256(
    "Cheque(address chequebook,address beneficiary,uint256 cumulativePayout)"
  );
  bytes32 public constant CASHOUT_TYPEHASH = keccak256(
    "Cashout(address chequebook,address sender,uint256 requestPayout,address recipient,uint256 callerPayout)"
  );



  // the EIP712 domain this contract uses
  function domain() internal pure returns (EIP712Domain memory) {
    uint256 chainId;
    assembly {
      chainId := chainid()
    }
    return EIP712Domain({
      name: "Chequebook",
      version: "1.0",
      chainId: chainId
    });
  }

  // compute the EIP712 domain separator. this cannot be constant because it depends on chainId
  function domainSeparator(EIP712Domain memory eip712Domain) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        EIP712DOMAIN_TYPEHASH,
        keccak256(bytes(eip712Domain.name)),
        keccak256(bytes(eip712Domain.version)),
        eip712Domain.chainId
    ));
  }

  // recover a signature with the EIP712 signing scheme
  function recoverEIP712(bytes32 hash, bytes memory sig) internal pure returns (address) {
    bytes32 digest = keccak256(abi.encodePacked(
        "\x19\x01",
        domainSeparator(domain()),
        hash
    ));
    return ECDSA.recover(digest, sig);
  }

  /* The token against which this chequebook writes cheques */
  ERC20 public token;
  /* associates every beneficiary with how much has been paid out to them */
  mapping (address => uint) public paidOut;
  /* total amount paid out */
  uint public totalPaidOut;
  /* issuer of the contract, set at construction */
  address public issuer;
  /* indicates wether a cheque bounced in the past */
  bool public bounced;

  /**
  @param _issuer the issuer of cheques from this chequebook (needed as an argument for "Setting up a chequebook as a payment").
  _issuer must be an Externally Owned Account, or it must support calling the function cashCheque
  @param _token the token this chequebook uses
  */
  function init(address _issuer, address _token) public {
    require(_issuer != address(0), "invalid issuer");
    require(issuer == address(0), "already initialized");
    issuer = _issuer;
    token = ERC20(_token);
  }

  /// @return the balance of the chequebook
  /// balance is parted to two parts: stake + issue cheques
  function totalbalance() public view returns(uint) {
    return token.balanceOf(address(this));
  }

  /**
  @dev internal function responsible for checking the issuerSignature, updating hardDeposit balances and doing transfers.
  Called by cashCheque and cashChequeBeneficary
  @param beneficiary the beneficiary to which cheques were assigned. Beneficiary must be an Externally Owned Account
  @param recipient receives the differences between cumulativePayment and what was already paid-out to the beneficiary minus callerPayout
  @param cumulativePayout cumulative amount of cheques assigned to beneficiary
  @param issuerSig if issuer is not the sender, issuer must have given explicit approval on the cumulativePayout to the beneficiary
  */
  function _cashChequeInternal(
    address beneficiary,
    address recipient,
    uint cumulativePayout,
    uint callerPayout,
    bytes memory issuerSig
  ) internal {
    /* The issuer must have given explicit approval to the cumulativePayout, either by being the caller or by signature*/
    if (msg.sender != issuer) {
      require(issuer == recoverEIP712(chequeHash(address(this), beneficiary, cumulativePayout), issuerSig),
      "invalid issuer signature");
    }
    /* the requestPayout is the amount requested for payment processing */
    uint requestPayout = cumulativePayout.sub(paidOut[beneficiary]);
    /* calculates acutal payout */
    uint totalPayout = Math.min(requestPayout, totalbalance());
    require(totalPayout >= callerPayout, "SimpleSwap: cannot pay caller");
    /* increase the stored paidOut amount to avoid double payout */
    paidOut[beneficiary] = paidOut[beneficiary].add(totalPayout);
    totalPaidOut = totalPaidOut.add(totalPayout);

    /* let the world know that the issuer has over-promised on outstanding cheques */
    if (requestPayout != totalPayout) {
      bounced = true;
      emit ChequeBounced();
    }

    if (callerPayout != 0) {
    /* do a transfer to the caller if specified*/
      require(token.transfer(msg.sender, callerPayout), "transfer failed");
      /* do the actual payment */
      require(token.transfer(recipient, totalPayout.sub(callerPayout)), "transfer failed");
    } else {
      /* do the actual payment */
      require(token.transfer(recipient, totalPayout), "transfer failed");
    }

    emit ChequeCashed(beneficiary, recipient, msg.sender, totalPayout, cumulativePayout, callerPayout);
  }
  /**
  @notice cash a cheque of the beneficiary by a non-beneficiary and reward the sender for doing so with callerPayout
  @dev a beneficiary must be able to generate signatures (be an Externally Owned Account) to make use of this feature
  @param beneficiary the beneficiary to which cheques were assigned. Beneficiary must be an Externally Owned Account
  @param recipient receives the differences between cumulativePayment and what was already paid-out to the beneficiary minus callerPayout
  @param cumulativePayout cumulative amount of cheques assigned to beneficiary
  @param beneficiarySig beneficiary must have given explicit approval for cashing out the cumulativePayout by the sender and sending the callerPayout
  @param issuerSig if issuer is not the sender, issuer must have given explicit approval on the cumulativePayout to the beneficiary
  @param callerPayout when beneficiary does not have ether yet, he can incentivize other people to cash cheques with help of callerPayout
  @param issuerSig if issuer is not the sender, issuer must have given explicit approval on the cumulativePayout to the beneficiary
  */
  function cashCheque(
    address beneficiary,
    address recipient,
    uint cumulativePayout,
    bytes memory beneficiarySig,
    uint256 callerPayout,
    bytes memory issuerSig
  ) public {
    require(
      beneficiary == recoverEIP712(
        cashOutHash(
          address(this),
          msg.sender,
          cumulativePayout,
          recipient,
          callerPayout
        ), beneficiarySig
      ), "invalid beneficiary signature");
    _cashChequeInternal(beneficiary, recipient, cumulativePayout, callerPayout, issuerSig);
  }

  /**
  @notice cash a cheque as beneficiary
  @param recipient receives the differences between cumulativePayment and what was already paid-out to the beneficiary minus callerPayout
  @param cumulativePayout amount requested to pay out
  @param issuerSig issuer must have given explicit approval on the cumulativePayout to the beneficiary
  */
  function cashChequeBeneficiary(address recipient, uint cumulativePayout, bytes memory issuerSig) public {
    _cashChequeInternal(msg.sender, recipient, cumulativePayout, 0, issuerSig);
  }

  function withdraw(uint amount) public {
    /* only issuer can do this */
    require(msg.sender == issuer, "not issuer");
    /* ensure we don't take anything from the hard deposit */
    require(amount <= totalbalance(), "totalbalance not sufficient");
    require(token.transfer(issuer, amount), "transfer failed");
  }

  function chequeHash(address chequebook, address beneficiary, uint cumulativePayout)
  internal pure returns (bytes32) {
    return keccak256(abi.encode(
      CHEQUE_TYPEHASH,
      chequebook,
      beneficiary,
      cumulativePayout
    ));
  }

  function cashOutHash(address chequebook, address sender, uint requestPayout, address recipient, uint callerPayout)
  internal pure returns (bytes32) {
    return keccak256(abi.encode(
      CASHOUT_TYPEHASH,
      chequebook,
      sender,
      requestPayout,
      recipient,
      callerPayout
    ));
  }
}