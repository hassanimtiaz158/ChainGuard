// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/common/MockERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MockERC20Test is Test {
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new MockERC20("Lab Token", "LAB", 18);
    }

    /*//////////////////////////////////////////////////////////////
                            METADATA
    //////////////////////////////////////////////////////////////*/

    function test_Metadata() public view {
        assertEq(token.name(), "Lab Token");
        assertEq(token.symbol(), "LAB");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0, "supply starts empty");
    }

    function test_DecimalsAreConfigurable() public {
        MockERC20 six = new MockERC20("Six", "SIX", 6);
        assertEq(six.decimals(), 6);
    }

    /*//////////////////////////////////////////////////////////////
                              MINT / BURN
    //////////////////////////////////////////////////////////////*/

    function test_Mint() public {
        token.mint(ALICE, 100e18);

        assertEq(token.balanceOf(ALICE), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_MintToZeroAddressReverts() public {
        vm.expectRevert(); // ERC20InvalidReceiver
        token.mint(address(0), 1e18);
    }

    function test_Burn() public {
        token.mint(ALICE, 100e18);
        token.burn(ALICE, 40e18);

        assertEq(token.balanceOf(ALICE), 60e18);
        assertEq(token.totalSupply(), 60e18);
    }

    function testFuzz_Mint(address to, uint256 amount) public {
        vm.assume(to != address(0));

        token.mint(to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), amount);
    }

    /*//////////////////////////////////////////////////////////////
                             TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        token.mint(ALICE, 100e18);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 40e18));

        assertEq(token.balanceOf(ALICE), 60e18);
        assertEq(token.balanceOf(BOB), 40e18);
        assertEq(token.totalSupply(), 100e18, "transfers must not change supply");
    }

    function test_RevertWhen_TransferExceedsBalance() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, uint256(0), 1e18
            )
        );
        token.transfer(BOB, 1e18);
    }

    function test_TransferFromWithAllowance() public {
        token.mint(ALICE, 100e18);

        vm.prank(ALICE);
        assertTrue(token.approve(BOB, 25e18));

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 25e18));

        assertEq(token.balanceOf(ALICE), 75e18);
        assertEq(token.balanceOf(BOB), 25e18);
        assertEq(token.allowance(ALICE, BOB), 0, "allowance is spent");
    }

    function test_RevertWhen_TransferFromExceedsAllowance() public {
        token.mint(ALICE, 100e18);

        vm.startPrank(ALICE);
        token.approve(BOB, 10e18);
        vm.stopPrank();

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 10e18, 25e18
            )
        );
        token.transferFrom(ALICE, BOB, 25e18);
    }

    function testFuzz_TransferRoundTrip(address from, address to, uint256 amount) public {
        vm.assume(from != address(0) && from != address(this));
        vm.assume(to != address(0) && to != from);
        amount = bound(amount, 1, 1e24);

        token.mint(from, amount);

        vm.prank(from);
        token.transfer(to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(from), 0);
        assertEq(token.totalSupply(), amount);
    }
}
