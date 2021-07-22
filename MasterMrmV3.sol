// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

/*
 * MarmaladeSwapFinance 
 * App:             https://marmaladeswap.finance/ 
 * Twitter:         https://twitter.com/MarmaladeSwap
 * Facebook:    	https://www.facebook.com/groups/MarmaladeSwap
 * Telegram:        https://t.me/MarmaladeSwap
 * Telegram chat:   https://t.me/MarmaladeSwapFinance
 * GitHub:          https://github.com/MarmaladeSwap
 */

import './pancake-swap-lib/contracts/math/SafeMath.sol';
import './pancake-swap-lib/contracts/token/BEP20/IBEP20.sol';
import './pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol';
import './pancake-swap-lib/contracts/access/Ownable.sol';

import "./MrmToken.sol";
import "./MrmSplitBar.sol";
import "./libs/IReferral.sol";

// MasterMrm is the master of MRM AND MRMSPLIT. 
// He can make Mrm and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once MRM is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterMrm is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of MRMs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accMrmPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accMrmPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. MRMs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that MRMs distribution occurs.
        uint256 accMrmPerShare; // Accumulated MRMs per share, times 1e12. See below.
    }

    // The MRM TOKEN!
    MrmToken public mrm;
    // The MRMSPLIT TOKEN!
    MrmSplitBar public mrmsplit;
    // Dev address.
    address public devaddr;
    // MRM tokens created per block.
    uint256 public mrmPerBlock;
    // Bonus muliplier for early mrm makers.
    uint256 public BONUS_MULTIPLIER;


    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when MRM mining starts.
    uint256 public startBlock;
    
    
    // MarmaladeSwap referral contract address.		
    IReferral public referral;		
    // Referral commission rate in basis points.		
    uint16 public referralCommissionRate = 200;		
    // Max referral commission rate: 5%.		
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 500;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetReferralAddress(address indexed user, IReferral indexed newAddress);		
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor(
        MrmToken _mrm,
        MrmSplitBar _mrmSplit,
        address _devaddr,
        uint256 _mrmPerBlock,
        uint256 _startBlock,
        uint256 _multiplier
    ) public {
        mrm = _mrm;
        mrmsplit = _mrmSplit;
        devaddr = _devaddr;
        mrmPerBlock = _mrmPerBlock;
        startBlock = _startBlock;
        BONUS_MULTIPLIER = _multiplier;

        // staking pool
        poolInfo.push(PoolInfo({
            lpToken: _mrm,
            allocPoint: 1000,
            lastRewardBlock: startBlock,
            accMrmPerShare: 0
        }));

        totalAllocPoint = 1000;

    }

    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "validatePool: pool exists?");
        _;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Detects whether the given pool already exists
    function checkPoolDuplicate(IBEP20 _lpToken) public view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "add: existing pool");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        checkPoolDuplicate(_lpToken);
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accMrmPerShare: 0
        }));
        updateStakingPool();
    }

    // Update the given pool's MRM allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending MRMs on frontend.
    function pendingMrm(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMrmPerShare = pool.accMrmPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 mrmReward = multiplier.mul(mrmPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accMrmPerShare = accMrmPerShare.add(mrmReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accMrmPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }


    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 mrmReward = multiplier.mul(mrmPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        mrm.mint(devaddr, mrmReward.div(10));
        mrm.mint(address(mrmsplit), mrmReward);
        pool.accMrmPerShare = pool.accMrmPerShare.add(mrmReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterMrm for MRM allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public validatePool(_pid) {
        require (_pid != 0, 'deposit MRM by staking');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
         if (_amount > 0 && address(referral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {		
            referral.recordReferral(msg.sender, _referrer);		
        }
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accMrmPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeMrmTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMrmPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterMrm.
    function withdraw(uint256 _pid, uint256 _amount) public validatePool(_pid) {
        require (_pid != 0, 'withdraw MRM by unstaking');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accMrmPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeMrmTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMrmPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Stake MRM tokens to MasterMrm
    function enterStaking(uint256 _amount, address _referrer) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (_amount > 0 && address(referral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {		
            referral.recordReferral(msg.sender, _referrer);
        }
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accMrmPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeMrmTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMrmPerShare).div(1e12);

        mrmsplit.mint(msg.sender, _amount);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw MRM tokens from STAKING.
    function leaveStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accMrmPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeMrmTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMrmPerShare).div(1e12);

        mrmsplit.burn(msg.sender, _amount);
        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        if(_pid == 0) {
                mrmsplit.burn(address(msg.sender), user.amount);
        }
        user.amount = 0;
        user.rewardDebt = 0;
    }

    function getPoolInfo(uint256 _pid) public view
    returns(address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accMrmPerShare) {
        return (address(poolInfo[_pid].lpToken),
            poolInfo[_pid].allocPoint,
            poolInfo[_pid].lastRewardBlock,
            poolInfo[_pid].accMrmPerShare);
    }

    // Safe mrm transfer function, just in case if rounding error causes pool to not have enough MRMs.
    function safeMrmTransfer(address _to, uint256 _amount) internal {
        mrmsplit.safeMrmTransfer(_to, _amount);
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
    
		    // Update the referral contract address by the owner		
    function setReferralAddress(IReferral _referral) external onlyOwner {		
        referral = _referral;		
        emit SetReferralAddress(msg.sender, _referral);		
 		
    }		
    // Update referral commission rate by the owner		
    function setReferralCommissionRate(uint16 _referralCommissionRate) external onlyOwner {		
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");		
        referralCommissionRate = _referralCommissionRate;		
 		
    }		
    // Pay referral commission to the referrer who referred this user.		
    function payReferralCommission(address _user, uint256 _pending) internal {		
        if (address(referral) != address(0) && referralCommissionRate > 0) {		
            address referrer = referral.getReferrer(_user);		
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);		
            if (referrer != address(0) && commissionAmount > 0) {		
                mrm.mint(referrer, commissionAmount);		
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);		
            }		
        }		
    }
}
