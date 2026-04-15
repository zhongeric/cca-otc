// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console} from 'forge-std/Script.sol';
import {OTCSaleVault} from '../src/OTCSaleVault.sol';
import {Milestone, OTCSaleParams} from '../src/interfaces/IOTCSaleVault.sol';

/// @notice Deploys an OTCSaleVault with parameters from environment variables.
///         Minted shares are sent to the deployer (msg.sender), who should then
///         approve and transfer them to a CCA auction contract.
///
/// Required env vars:
///   UNDERLYING_TOKEN, SELLER, TOTAL_SHARES, BOND_TOKEN, BOND_AMOUNT, BOND_DEADLINE
///
/// Milestones are encoded as two comma-separated lists:
///   MILESTONE_DEADLINES=1000000,2000000,3000000
///   MILESTONE_AMOUNTS=250000000000000000000000,500000000000000000000000,1000000000000000000000000
contract Deploy is Script {
    function run() public returns (OTCSaleVault vault) {
        address underlyingToken = vm.envAddress('UNDERLYING_TOKEN');
        address sellerAddr = vm.envAddress('SELLER');
        uint128 totalShares = uint128(vm.envUint('TOTAL_SHARES'));
        address bondToken = vm.envAddress('BOND_TOKEN');
        uint128 bondAmount = uint128(vm.envUint('BOND_AMOUNT'));
        uint64 bondDeadline = uint64(vm.envUint('BOND_DEADLINE'));

        uint256[] memory deadlines = vm.envUint('MILESTONE_DEADLINES', ',');
        uint256[] memory amounts = vm.envUint('MILESTONE_AMOUNTS', ',');
        require(deadlines.length == amounts.length, 'milestone length mismatch');

        Milestone[] memory milestones = new Milestone[](deadlines.length);
        for (uint256 i = 0; i < deadlines.length; i++) {
            milestones[i] = Milestone({deadline: uint64(deadlines[i]), cumulativeAmount: uint128(amounts[i])});
        }

        OTCSaleParams memory params = OTCSaleParams({
            underlyingToken: underlyingToken,
            seller: sellerAddr,
            totalShares: totalShares,
            bondToken: bondToken,
            bondAmount: bondAmount,
            bondDeadline: bondDeadline,
            milestones: milestones
        });

        vm.startBroadcast();
        vault = new OTCSaleVault(params);
        vm.stopBroadcast();

        console.log('OTCSaleVault deployed at:', address(vault));
        console.log('Shares minted to deployer:', totalShares);
    }
}
