// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployLab} from "../../script/DeployLab.s.sol";

/**
 * @notice Exercises {DeployLab} end to end in-process.
 * @dev Cheatcodes are shared between tests and scripts, so running the script
 *      here deploys the whole lab into the test EVM and writes the same
 *      `deployments/lab.json` the container produces.
 */
contract DeployLabTest is Test {
    DeployLab internal lab;

    function setUp() public {
        lab = new DeployLab();
        // In a real run the broadcasts spend the sender's balance; in-process
        // the script contract itself is the sender.
        vm.deal(address(lab), 100 ether);
    }

    function test_script_writesLabJsonWithEveryScenario() public {
        assertEq(block.chainid, 31337, "lab chain guard");

        lab.run();

        string memory json = vm.readFile("./deployments/lab.json");

        assertEq(vm.parseJsonUint(json, ".chainId"), 31337, "chainId");
        assertEq(
            vm.parseJsonString(json, ".s1_reentrancy.attackerArtifact"),
            "Attacker",
            "attacker artifact name"
        );

        // Every scenario entry carries two distinct, non-zero targets.
        string[8] memory ids = [
            "s1_reentrancy",
            "s2_access_control",
            "s3_integer_logic",
            "s4_oracle",
            "s5_flashloan",
            "s6_frontrun",
            "s7_sig_replay",
            "s8_unchecked_call"
        ];
        for (uint256 i = 0; i < ids.length; i++) {
            string memory prefix = string.concat(".", ids[i], ".");
            address vulnerable = vm.parseJsonAddress(json, string.concat(prefix, "vulnerable"));
            address secure = vm.parseJsonAddress(json, string.concat(prefix, "secure"));

            assertTrue(vulnerable != address(0), "vulnerable deployed");
            assertTrue(secure != address(0), "secure deployed");
            assertTrue(vulnerable != secure, "variants are distinct");
        }
    }

    function test_script_fundsVictims() public {
        lab.run();

        string memory json = vm.readFile("./deployments/lab.json");

        address vault = vm.parseJsonAddress(json, ".s1_reentrancy.vulnerable");
        address wallet = vm.parseJsonAddress(json, ".s2_access_control.secure");
        address payout = vm.parseJsonAddress(json, ".s8_unchecked_call.vulnerable");

        assertEq(vault.balance, 10 ether, "S1 vault funded");
        assertEq(wallet.balance, 10 ether, "S2 wallet funded");
        assertEq(payout.balance, 10 ether, "S8 desk funded");

        assertEq(
            vm.parseJsonString(json, ".s6_frontrun.fundedWei"),
            vm.toString(uint256(5 ether)),
            "S6 prize recorded"
        );
    }

    function test_script_isChainGuarded() public {
        vm.chainId(1);

        vm.expectRevert("DeployLab: not the local lab chain");
        lab.run();
    }
}
