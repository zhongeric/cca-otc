// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OTCSaleVault} from '../src/OTCSaleVault.sol';
import {Milestone, OTCSaleParams} from '../src/interfaces/IOTCSaleVault.sol';
import {Script, console} from 'forge-std/Script.sol';

contract Deploy is Script {
    function run() external {
        address underlyingToken = vm.envAddress('UNDERLYING_TOKEN');
        address sellerAddr = vm.envAddress('SELLER');
        uint128 totalShares = uint128(vm.envUint('TOTAL_SHARES'));
        address currencyAddr = vm.envAddress('CURRENCY');
        uint128 bondAmount = uint128(vm.envUint('BOND_AMOUNT'));

        uint256[] memory deadlines = vm.envUint('MILESTONE_DEADLINES', ',');
        uint256[] memory amounts = vm.envUint('MILESTONE_AMOUNTS', ',');
        require(deadlines.length == amounts.length, 'Mismatched milestone arrays');

        Milestone[] memory milestoneArr = new Milestone[](deadlines.length);
        for (uint256 i = 0; i < deadlines.length; i++) {
            milestoneArr[i] = Milestone({deadline: uint64(deadlines[i]), cumulativeAmount: uint128(amounts[i])});
        }

        OTCSaleParams memory params = OTCSaleParams({
            underlyingToken: underlyingToken,
            seller: sellerAddr,
            totalShares: totalShares,
            currency: currencyAddr,
            bondAmount: bondAmount,
            milestones: milestoneArr
        });

        vm.startBroadcast();

        // NOTE: Bond must already be at the deployment address before this runs.
        // With CREATE2, predict the address and pre-transfer bondAmount of currency.
        OTCSaleVault vault = new OTCSaleVault(params);

        console.log('OTCSaleVault deployed at:', address(vault));
        console.log('Shares minted to deployer:', totalShares);

        vm.stopBroadcast();
    }
}
