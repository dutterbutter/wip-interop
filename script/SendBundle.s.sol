// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "@zksync-contracts/contracts/bridgehub/IBridgehub.sol";
import "@zksync-contracts/contracts/interop/IInteropCenter.sol";
import "@zksync-contracts/contracts/bridge/ntv/INativeTokenVault.sol";
import {InteropCallStarter} from "@zksync-contracts/contracts/common/Messaging.sol";
import {IERC7786Attributes} from "@zksync-contracts/contracts/interop/IERC7786Attributes.sol";
import "../src/TestToken.sol";
import {L2_NATIVE_TOKEN_VAULT, L2_INTEROP_CENTER, L2_ASSET_ROUTER} from "@zksync-system-contracts/Constants.sol";

contract SendInteropBundle is Script {
    function run() external {
        vm.startBroadcast();

        address sender = msg.sender;
        uint256 destChain = 506;
        uint256 fee = 1 ether;

        // deploy & mint TestToken on source chain
        TestToken token = new TestToken("Token A", "AA");
        token.mint(sender, 100 ether);

        // approve + register
        token.approve(address(L2_NATIVE_TOKEN_VAULT), 100 ether);
        INativeTokenVault(address(L2_NATIVE_TOKEN_VAULT)).registerToken(address(token));
        bytes32 assetId = INativeTokenVault(address(L2_NATIVE_TOKEN_VAULT)).assetId(address(token));

        // build payload & call attributes
        bytes memory payload = abi.encodePacked(
            hex"01",
            abi.encode(assetId, abi.encode(uint256(100 ether), sender, address(0)))
        );

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            nextContract: address(L2_ASSET_ROUTER),
            data:         payload,
            callAttributes: new bytes[](1)
        });
        calls[0].callAttributes[0] = abi.encodeWithSelector(
            IERC7786Attributes.interopCallValue.selector,
            fee
        );

        // TODO: seems to fail unless we mockcall L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR burnMsgValue?
        // weird as L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR is deployed on the chain? 

        // send bundle
        bytes32 hash = IInteropCenter(address(L2_INTEROP_CENTER)).sendBundle{ value: fee }(
            destChain,
            calls,
            new bytes[](0)
        );

        console.logBytes32(hash);

        vm.stopBroadcast();
    }
}
