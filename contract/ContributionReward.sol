pragma solidity ^0.7.6;
pragma abicoder v2;
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4/contracts/math/SafeMath.sol";

//token interface
interface Token {
    //ERC20 transfer()
    function transfer(address _to, uint256 _value) external returns (bool);
    function balanceOf(address account) public view virtual override returns (uint256);
}

contract ContributionReward {
    using SafeMath for uint256;
    
    struct reward {
        uint totalRewards; /* total rewards*/
        uint totalWithdrawn; /* amount already withdrawn */
        uint lastRewards;     /* reward of last time*/
        uint legacyFromPreRound;  /* unwithdrawn reards from the previous round */
        uint canWithdrawAt; /* point in time after which rewards can be withdrawn*/
    }
    //token address, the token Rewarded
    ERC20 public token;
    address public owner;
    uint public startTime;
    uint public dayUnit;
    uint public dayTotal;
    //whitelist
    mapping (address => reward) public whiteList;
    
    //unlock rate = dayUnit/dayTotal
    constructor(address _tokenAddress, uint _dayUnit, uint _dayTotal) {
        require(_tokenAddress != address(0), "invalid token address");
        owner = msg.sender;
        token = Token(_tokenAddress);
        startTime = 0;
        dayUnit = _dayUnit;
        dayTotal = _dayTotal;
    }
    
    modifier onlyOwner() {
        require(owner == msg.sender, "only owner");
        _;
    }
    
    function changeOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }
    
    function setStartTime() public onlyOwner {
        startTime = block.timestamp;
    }
    
    function setWhiteList(address[] memory addresses, uint[] memory rewards) external onlyOwner {
        require(addresses.length == rewards.length && addresses.length > 0, "invalid paras");
        setStartTime();
        for(uint32 i = 0; i< addresses.length; i++){
            //move totalamount - totalWithdrawn to canBeWithdraw
            //when set whitelist, if address1 has rewards not withdrawn of last round, then move the rest to legacyFromPreRound
            if (whiteList[addresses[i]].totalRewards > whiteList[addresses[i]].totalWithdrawn) {
                uint amount = whiteList[addresses[i]].totalRewards.sub(whiteList[addresses[i]].totalWithdrawn);
                whiteList[addresses[i]].legacyFromPreRound = amount;
            }

            // inc totalamount
            whiteList[addresses[i]].totalRewards = whiteList[addresses[i]].totalRewards.add(rewards[i]);
            // fresh canWithdrawAt
            whiteList[addresses[i]].canWithdrawAt = startTime;
            // set lastRewards 
            whiteList[addresses[i]].lastRewards = rewards[i];
        }
    }
    
    function withdraw(address receipt) external {
        require(whiteList[msg.sender].totalRewards > whiteList[msg.sender].totalWithdrawn);

        uint rate = dayTotal.div(dayUnit);
        uint transferAmount = 0;
        uint incAmount = whiteList[msg.sender].lastRewards.div(rate);
        // if now doesn't arrive 7 days, can withdraw canBeWithdraw only
        if (whiteList[msg.sender].canWithdrawAt + dayUnit days > block.timestamp) {
            // [0, 7 days), 1 * incAmount
            transferAmount = whiteList[msg.sender].legacyFromPreRound.add(incAmount);
            // add 7 days to canWithdrawAt
            whiteList[msg.sender].canWithdrawAt = whiteList[msg.sender].canWithdrawAt + 7 days;
        } else if (whiteList[msg.sender].canWithdrawAt + 14 days > block.timestamp) {
            // [7 days, 14 days), 2 * incAmount
            transferAmount = whiteList[msg.sender].legacyFromPreRound.add(incAmount.mul(2));
            // add 14 days to canWithdrawAt
            whiteList[msg.sender].canWithdrawAt = whiteList[msg.sender].canWithdrawAt + 14 days;
        } else if (whiteList[msg.sender].canWithdrawAt + 21 days > block.timestamp) {
            // [14 days, 21 days), 3 * incAmount
            transferAmount = whiteList[msg.sender].legacyFromPreRound.add(incAmount.mul(3));
            // add 21 days to canWithdrawAt
            whiteList[msg.sender].canWithdrawAt = whiteList[msg.sender].canWithdrawAt + 21 days;
        } else {
            //[21 days..], can withdraw all rewards
            transferAmount = whiteList[msg.sender].legacyFromPreRound.add(whiteList[msg.sender].totalRewards.sub(whiteList[msg.sender].totalWithdrawn));
        }
        
        // inc totalWithdrawn
        whiteList[msg.sender].totalWithdrawn = whiteList[msg.sender].totalWithdrawn.add(transferAmount);
        // set canBeWithdraw = 0, every time call withdraw, legacyFromPreRound will be 0
        whiteList[msg.sender].legacyFromPreRound = 0;
        
        
        require(whiteList[msg.sender].totalWithdrawn <= whiteList[msg.sender].totalRewards);
        
        if (receipt == address(0)) {
            receipt = msg.sender;
        }

        require(token.transfer(receipt, transferAmount));
    }
    
    // get self status
    function getOwnStatus() external view returns(reward memory) {
        return whiteList[msg.sender];
    }
    
    // called by owner only
    function getStatus(address a) external view onlyOwner returns(reward memory) {
        return whiteList[a];
    }
    // called by owner only
    function getBalance() external view onlyOwner returns(uint256) {
        return token.balanceOf(address(this));
    }
}