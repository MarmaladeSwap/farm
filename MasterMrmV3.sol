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

import "./MarmToken.sol";
import "./MarmSplitBar.sol";

// MasterMarm is the master of MARM AND MARMSPLIT. 
// He can make Marm and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once MARM is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterMarm is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of MARMs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accMarmPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accMarmPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. MARMs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that MARMs distribution occurs.
        uint256 accMarmPerShare; // Accumulated MARMs per share, times 1e12. See below.
    }

    // The MARM TOKEN!
    MarmToken public marm;
    // The MARMSPLIT TOKEN!
    MarmSplitBar public marmsplit;
    // Dev address.
    address public devaddr;
    // MARM tokens created per block.
    uint256 public marmPerBlock;
    // Bonus muliplier for early marm makers.
    uint256 public BONUS_MULTIPLIER;


    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when MARM mining starts.
    uint256 public startBlock;
    
    
    // Referral commission rate in basis points.		
    uint16 public referralCommissionRate = 500;		
    // Max referral commission rate: 10%.		
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;
    
    mapping(address => address) public referrers; // user address => referrer address
    mapping(address => uint256) public referralsCount; // referrer address => referrals count

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);
    event UpdateEmissionRate(address indexed user, uint256 marmPerBlock);
    event SetStartBlock(address indexed user, uint256 newStartBlock);
    event ReferralRecorded(address indexed user, address indexed referrer);
    event OperatorUpdated(address indexed operator, bool indexed status);

    constructor(
        MarmToken _marm,
        MarmSplitBar _marmSplit,
        address _devaddr,
        uint256 _marmPerBlock,
        uint256 _startBlock,
        uint256 _multiplier
    ) public {
        marm = _marm;
        marmsplit = _marmSplit;
        devaddr = _devaddr;
        marmPerBlock = _marmPerBlock;
        startBlock = _startBlock;
        BONUS_MULTIPLIER = _multiplier;

        // staking pool
        poolInfo.push(PoolInfo({
            lpToken: _marm,
            allocPoint: 1000,
            lastRewardBlock: startBlock,
            accMarmPerShare: 0
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
            accMarmPerShare: 0
        }));
        updateStakingPool();
    }

    // Update the given pool's MARM allocation point. Can only be called by the owner.
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

    // View function to see pending MARMs on frontend.
    function pendingMarm(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMarmPerShare = pool.accMarmPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 marmReward = multiplier.mul(marmPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accMarmPerShare = accMarmPerShare.add(marmReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accMarmPerShare).div(1e12).sub(user.rewardDebt);
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
        uint256 marmReward = multiplier.mul(marmPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        marm.mint(devaddr, marmReward.div(10));
        marm.mint(address(marmsplit), marmReward);
        pool.accMarmPerShare = pool.accMarmPerShare.add(marmReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterMARM for MARM allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public validatePool(_pid) {
        require (_pid != 0, 'deposit MARM by staking');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
         if (_amount > 0 && _referrer != address(0) && _referrer != msg.sender) {		
            _recordReferral(msg.sender, _referrer);		
        }
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accMarmPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeMarmTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMarmPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterMarm.
    function withdraw(uint256 _pid, uint256 _amount) public validatePool(_pid) {
        require (_pid != 0, 'withdraw MARM by unstaking');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accMarmPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeMarmTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMarmPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Stake MARM tokens to MasterMarm
    function enterStaking(uint256 _amount, address _referrer) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (_amount > 0 && _referrer != address(0) && _referrer != msg.sender) {		
            _recordReferral(msg.sender, _referrer);
        }
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accMarmPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeMarmTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMarmPerShare).div(1e12);

        marmsplit.mint(msg.sender, _amount);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw MARM tokens from STAKING.
    function leaveStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accMarmPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeMarmTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMarmPerShare).div(1e12);

        marmsplit.burn(msg.sender, _amount);
        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        if(_pid == 0) {
                marmsplit.burn(address(msg.sender), user.amount);
        }
        user.amount = 0;
        user.rewardDebt = 0;
    }

    function getPoolInfo(uint256 _pid) public view
    returns(address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accMarmPerShare) {
        return (address(poolInfo[_pid].lpToken),
            poolInfo[_pid].allocPoint,
            poolInfo[_pid].lastRewardBlock,
            poolInfo[_pid].accMarmPerShare);
    }

    // Safe marm transfer function, just in case if rounding error causes pool to not have enough MARMs.
    function safeMarmTransfer(address _to, uint256 _amount) internal {
        marmsplit.safeMarmTransfer(_to, _amount);
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
    

    // Update referral commission rate by the owner		
    function setReferralCommissionRate(uint16 _referralCommissionRate) external onlyOwner {		
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");		
        referralCommissionRate = _referralCommissionRate;		
    }	
    
    // Pay referral commission to the referrer who referred this user.		
    function payReferralCommission(address _user, uint256 _pending) internal {		
        if (referralCommissionRate > 0) {		
            address referrer = getReferrer(_user);		
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);		
            if (referrer != address(0) && commissionAmount > 0) {		
                marm.mint(referrer, commissionAmount);		
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);		
            }		
        }		
    }
    
    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _marmPerBlock) public onlyOwner {
        massUpdatePools();
        marmPerBlock = _marmPerBlock;
        emit UpdateEmissionRate(msg.sender, _marmPerBlock);
    }
       
    // Only update before start of farm
    function setStartBlock(uint256 newStartBlock) external onlyOwner() {
        massUpdatePools();
        startBlock = newStartBlock;
        emit SetStartBlock(msg.sender, newStartBlock);
    }
    
    /**
     * @dev Record referral.
     */
    function _recordReferral(address _user, address _referrer) internal {
        if (_user != address(0)
            && _referrer != address(0)
            && _user != _referrer
            && referrers[_user] == address(0)
        ) {
            referrers[_user] = _referrer;
            referralsCount[_referrer] += 1;
            emit ReferralRecorded(_user, _referrer);
        }
    }

    // Get the referrer address that referred the user
    function getReferrer(address _user) public view returns (address) {
        return referrers[_user];
    }
 
}
