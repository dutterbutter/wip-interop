// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import { IInteropCenter }      from "@zksync-contracts/contracts/interop/IInteropCenter.sol";
import { INativeTokenVault }   from "@zksync-contracts/contracts/bridge/ntv/INativeTokenVault.sol";
import { IERC7786Attributes }  from "@zksync-contracts/contracts/interop/IERC7786Attributes.sol";
import { InteropCallStarter }  from "@zksync-contracts/contracts/common/Messaging.sol";
import { L2_NATIVE_TOKEN_VAULT,
         L2_INTEROP_CENTER,
         L2_ASSET_ROUTER }     from "@zksync-system-contracts/Constants.sol";

import "../src/TestToken.sol";

contract InteropSendBundleLiveScript is Script {
    IInteropCenter   constant interop = IInteropCenter(address(L2_INTEROP_CENTER));
    INativeTokenVault constant vault  = INativeTokenVault(address(L2_NATIVE_TOKEN_VAULT));

    function run() public {
        address sender     = msg.sender;
        uint256 destChain  = vm.envUint("DEST_CHAIN_ID");   // e.g. 506
        uint256 feeValue = 1 ether;

        console.log("Sender          :", sender);
        console.log("Destination CID :", destChain);

        vm.startBroadcast();

        /* ------------------------------------------------------------------ */
        /*  Deploy token and register it in the NativeTokenVault        */
        /* ------------------------------------------------------------------ */
        TestToken token = new TestToken("Token A","AA");
        token.mint(sender, 100 ether);
        token.approve(address(vault), 100 ether);
        vault.registerToken(address(token));
        bytes32 assetId = vault.assetId(address(token));

        /* ------------------------------------------------------------------ */
        /*  Build payload     */
        /* ------------------------------------------------------------------ */
        bytes memory assetRouterCalldata = abi.encodePacked(
            bytes1(0x01),
            abi.encode(assetId,
                       abi.encode(uint256(100 ether),
                                  sender,
                                  address(0)))
        );

        /* ------------------------------------------------------------------ */
        /*  Build call‑starters                                               */
        /* ------------------------------------------------------------------ */
        bytes[] memory feeAttrs = new bytes[](1);
        feeAttrs[0] = abi.encodeWithSelector(
            IERC7786Attributes.interopCallValue.selector, feeValue
        );

        bytes[] memory execAttrs = new bytes[](1);
        execAttrs[0] = abi.encodeWithSelector(
            IERC7786Attributes.indirectCall.selector, uint256(0)
        );

        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = InteropCallStarter({ nextContract: address(0),
                                        data:         hex"",
                                        callAttributes: feeAttrs });

        calls[1] = InteropCallStarter({ nextContract: address(L2_ASSET_ROUTER),
                                        data:         assetRouterCalldata,
                                        callAttributes: execAttrs });

        /* ------------------------------------------------------------------ */
        /*  Send bundle                           */
        /* ------------------------------------------------------------------ */
        bytes32 bundleHash = interop.sendBundle{ value: feeValue }(
            destChain,
            calls,
            new bytes[](0)
        );

        console.log("Bundle sent with hash:");
        console.logBytes32(bundleHash);
        
        vm.stopBroadcast();
    }
}
