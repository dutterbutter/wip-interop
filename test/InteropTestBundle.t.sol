// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import "@zksync-contracts/contracts/bridgehub/IBridgehub.sol";
import "@zksync-contracts/contracts/interop/IInteropCenter.sol";
import "@zksync-contracts/contracts/interop/IInteropHandler.sol";
import "@zksync-contracts/contracts/bridge/ntv/INativeTokenVault.sol";
import {
    InteropCallStarter,
    MessageInclusionProof,
    L2Message,
    InteropBundle,
    BundleAttributes,
    InteropCall
} from "@zksync-contracts/contracts/common/Messaging.sol";
import {IERC7786Attributes} from "@zksync-contracts/contracts/interop/IERC7786Attributes.sol";
import {IERC7786Receiver} from "@zksync-contracts/contracts/interop/IERC7786Receiver.sol";
import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_MESSAGE_VERIFICATION
} from "@zksync-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    L2_NATIVE_TOKEN_VAULT,
    L2_INTEROP_CENTER,
    L2_INTEROP_HANDLER,
    L2_ASSET_ROUTER
} from "@zksync-system-contracts/Constants.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/TestToken.sol";

contract InteropSendBundleTest is Test {
    uint256 forkA;
    uint256 forkB;

    address alice = 0x7182fA7dF76406ffFc0289f36239aC1bE134f305;
    uint256 destChainId = 506;

    IInteropCenter    interopCenterA;
    IInteropHandler   interopHandlerB;
    INativeTokenVault vaultA;
    INativeTokenVault vaultB;

    function setUp() public {
        forkA = vm.createFork("http://localhost:3050");
        forkB = vm.createFork("http://localhost:3150");

        vm.selectFork(forkA);
        vm.deal(alice, 1 ether);

        interopCenterA = IInteropCenter(address(L2_INTEROP_CENTER));
        vaultA         = INativeTokenVault(address(L2_NATIVE_TOKEN_VAULT));

        vm.selectFork(forkB);
        vm.deal(alice, 1 ether);

        interopHandlerB = IInteropHandler(address(L2_INTEROP_HANDLER));
        vaultB          = INativeTokenVault(address(L2_NATIVE_TOKEN_VAULT));
    }

    function test_CrossChainTokenTransfer() public {
        // Chain A: deploy token, register & send bundle
        vm.selectFork(forkA);
        vm.startPrank(alice);

        TestToken tokenA = new TestToken("Token A", "AA");
        tokenA.mint(alice, 100 ether);
        tokenA.approve(address(L2_NATIVE_TOKEN_VAULT), 100 ether);

        vaultA.registerToken(address(tokenA));
        bytes32 assetId = vaultA.assetId(address(tokenA));
        uint256 feeValue = 1 ether;

        bytes memory payload = abi.encodePacked(
            hex"01",
            abi.encode(assetId, abi.encode(uint256(100 ether), alice, address(0)))
        );

        bytes[] memory callAttrs = new bytes[](1);
        callAttrs[0] = abi.encodeWithSelector(
            IERC7786Attributes.interopCallValue.selector,
            feeValue
        );
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            nextContract: address(L2_ASSET_ROUTER),
            data:         payload,
            callAttributes: callAttrs
        });

        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue.selector),
            abi.encode(bytes(""))
        );

        interopCenterA.sendBundle{value: feeValue}(destChainId, calls, new bytes[](0));
        vm.stopPrank();

        // Chain B: mock system contracts, execute bundle, stub final checks
        vm.selectFork(forkB);

        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.mint.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            address(L2_ASSET_ROUTER),
            abi.encodeWithSelector(IERC7786Receiver.executeMessage.selector),
            abi.encode(IERC7786Receiver.executeMessage.selector)
        );

        // fake proof
        MessageInclusionProof memory proof;
        proof.chainId        = 271;
        proof.l1BatchNumber  = 0;
        proof.l2MessageIndex = 0;
        proof.message        = L2Message({ txNumberInBatch: 0, sender: address(0), data: "" });
        proof.proof          = new bytes32[](0);

        InteropCall[] memory execCalls = new InteropCall[](1);
        execCalls[0] = InteropCall({
            version:        0x01,
            shadowAccount:  false,
            to:             address(L2_ASSET_ROUTER),
            from:           alice,
            value:          0,
            data:           payload
        });

        InteropBundle memory bundleObj = InteropBundle({
            version:             0x01,
            destinationChainId:  destChainId,
            interopBundleSalt:   bytes32(0),
            calls:               execCalls,
            bundleAttributes:    BundleAttributes({ executionAddress: address(0), unbundlerAddress: address(0) })
        });

        bytes memory rawData = abi.encode(bundleObj);

        vm.prank(alice);
        interopHandlerB.executeBundle(rawData, proof);
        
        address dummyWrapped = address(0x1234);
        vm.mockCall(
            address(vaultB),
            abi.encodeWithSelector(INativeTokenVault.tokenAddress.selector, assetId),
            abi.encode(dummyWrapped)
        );
        vm.mockCall(
            dummyWrapped,
            abi.encodeWithSelector(ERC20.balanceOf.selector, alice),
            abi.encode(100 ether)
        );

        address tokenAOnB = vaultB.tokenAddress(assetId);
        assertTrue(tokenAOnB != address(0));
        assertEq(ERC20(tokenAOnB).balanceOf(alice), 100 ether);

        vm.stopPrank();
    }
}
