// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@zksync-contracts/contracts/interop/IInteropCenter.sol";
import "@zksync-contracts/contracts/interop/IInteropHandler.sol";
import "@zksync-contracts/contracts/bridge/ntv/INativeTokenVault.sol";
import {InteropCallStarter} from "@zksync-contracts/contracts/common/Messaging.sol";

import {L2_NATIVE_TOKEN_VAULT, L2_INTEROP_CENTER, L2_INTEROP_HANDLER, L2_ASSET_ROUTER} from "@zksync-system-contracts/Constants.sol";

import "../src/TestToken.sol";

contract InteropSendBundleTest is Test {
    uint256 forkL1;
    uint256 forkA;
    uint256 forkB;

    address alice;
    uint256 destChainId;

    IInteropCenter   interopCenterA;
    IInteropHandler  interopHandlerB;
    INativeTokenVault vaultA;
    INativeTokenVault vaultB;

    TestToken tokenA;
    bytes32   assetId;

    function setUp() public {
        // ——— create forks ———
        string memory rpcL1 = "http://localhost:8545";
        string memory rpcA  = "http://localhost:3050";
        string memory rpcB  = "http://localhost:3150";
        forkL1 = vm.createFork(rpcL1);
        forkA  = vm.createFork(rpcA);
        forkB  = vm.createFork(rpcB);

        alice = address(0x7182fA7dF76406ffFc0289f36239aC1bE134f305);
        vm.selectFork(forkA);  vm.deal(alice, 1 ether);
        vm.selectFork(forkB);  vm.deal(alice, 1 ether);

        vm.selectFork(forkA);
        interopCenterA = IInteropCenter(address(L2_INTEROP_CENTER));
        vaultA         = INativeTokenVault(address(L2_NATIVE_TOKEN_VAULT));

        vm.selectFork(forkB);
        interopHandlerB = IInteropHandler(address(L2_INTEROP_HANDLER));
        vaultB          = INativeTokenVault(address(L2_NATIVE_TOKEN_VAULT));

        destChainId = vm.envUint("DEST_CHAIN_ID");
    }

    function test_CrossChainTokenTransfer() public {
        /////////////////////
        // Chain A (source)
        /////////////////////
        vm.selectFork(forkA);
        vm.startPrank(alice);

        // 1) Deploy & mint
        tokenA = new TestToken("Token A", "AA");
        tokenA.mint(alice, 100 ether);

        // 2) Approve & register in vault
        tokenA.approve(address(vaultA), 100 ether);
        vaultA.registerToken(address(tokenA));
        assetId = vaultA.assetId(address(tokenA));

        // 3) Build the InteropCallStarter for the AssetRouter on Chain B
        //    calldata = 0x01 ++ abi.encode(assetId, abi.encode(amount, recipient, refund))
        bytes memory payload =
            abi.encodePacked(
                hex"01",
                abi.encode(
                    assetId,
                    abi.encode(uint256(100 ether), alice, address(0))
                )
            );

        InteropCallStarter[]
            memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            nextContract: address(L2_ASSET_ROUTER),
            data: payload,
            callAttributes: new bytes[](0)
        });

        // 4) Send the bundle
        bytes32 bundleMsgHash =
            interopCenterA.sendBundle{value: 0}(destChainId, calls, new bytes[](0));
        vm.stopPrank();
        console.log("Bundle sent with hash:");
        console.logBytes32(bundleMsgHash);

        // bytes memory bundle = hex"__REPLACE_WITH_RAW_BUNDLE_BYTES__";
        // Messaging.MessageInclusionProof memory proof = Messaging.MessageInclusionProof({
        //     _l1BatchNumber: 0,
        //     _l2MessageIndex: 0,
        //     _proof: new bytes32
        // });

        // /////////////////////
        // // Chain B (dest)
        // /////////////////////
        // vm.selectFork(forkB);
        // vm.startPrank(alice);

        // // 5) Execute and verify
        // interopHandlerB.executeBundle(bundle, proof);

        // // 6) Check bridged‑token balance
        // address bridged = vaultB.tokenAddress(assetId);
        // uint256 bal = TestToken(bridged).balanceOf(alice);
        // assertEq(bal, 100 ether);

        // vm.stopPrank();
    }
}
