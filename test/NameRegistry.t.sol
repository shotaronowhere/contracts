// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import {NameRegistry} from "../src/NameRegistry.sol";
import {ERC1967Proxy} from "openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* solhint-disable state-visibility */
/* solhint-disable max-states-count */
/* solhint-disable avoid-low-level-calls */

contract NameRegistryTest is Test {
    NameRegistry nameRegistryImpl;
    NameRegistry nameRegistry;
    ERC1967Proxy nameRegistryProxy;

    address proxyAddr;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 indexed id);

    event Renew(uint256 indexed tokenId, uint256 expiry);

    event ChangeRecoveryAddress(address indexed recovery, uint256 indexed tokenId);

    event RequestRecovery(uint256 indexed id, address indexed from, address indexed to);

    event CancelRecovery(uint256 indexed id);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address owner = address(this);
    address vault = address(this);
    address trustedForwarder = address(0xC8223c8AD514A19Cc10B0C94c39b52D4B43ee61A);
    address trustedSender = address(0x572e3354fBA09e865a373aF395933d8862CFAE54);
    address zeroAddress = address(0);

    address constant PRECOMPILE_CONTRACTS = address(9); // some addresses up to 0x9 are precompiled contracts

    // Known contracts that must not be made to call other contracts in tests
    address[] knownContracts = [
        address(0xCe71065D4017F316EC606Fe4422e11eB2c47c246), // FuzzerDict
        address(0x4e59b44847b379578588920cA78FbF26c0B4956C), // CREATE2 Factory
        address(0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84), // address(this)
        address(0xC8223c8AD514A19Cc10B0C94c39b52D4B43ee61A), // trustedForwarder
        address(0x185a4dc360CE69bDCceE33b3784B0282f7961aea), // ???
        address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D) // ???
    ];

    uint256 constant ESCROW_PERIOD = 3 days;
    uint256 constant COMMIT_REGISTER_DELAY = 60;

    uint256 constant TS_2022 = 1640995200; // Jan 1, 2022 0:00:00 GMT
    uint256 constant TS_2023 = 1672531200; // Jan 1, 2023 0:00:00 GMT
    uint256 constant TS_2024 = 1704067200; // Jan 1, 2024 0:00:00 GMT

    uint256 aliceTokenId = uint256(bytes32("alice"));
    uint256 bobTokenId = uint256(bytes32("bob"));
    uint256 aliceRegisterTs = 1669881600; // Dec 1, 2022 00:00:00 GMT
    uint256 aliceRenewableTs = TS_2023; // Jan 1, 2023 0:00:00 GMT
    uint256 aliceBiddableTs = 1675123200; // Jan 31, 2023 0:00:00 GMT

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        nameRegistryImpl = new NameRegistry(trustedForwarder);

        nameRegistryProxy = new ERC1967Proxy(address(nameRegistryImpl), "");
        proxyAddr = address(nameRegistryProxy);

        (bool s, ) = address(nameRegistryProxy).call(
            abi.encodeWithSelector(nameRegistry.initialize.selector, "Farcaster NameRegistry", "FCN", vault)
        );

        assertEq(s, true);

        // Instantiate the ERC1967 Proxy as a NameRegistry so that we can call the NameRegistry methods easily
        nameRegistry = NameRegistry(address(nameRegistryProxy));
    }

    /*//////////////////////////////////////////////////////////////
                              COMMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function testGenerateCommit(address) public {
        address alice = address(0x123);

        // alphabetic name
        bytes32 commit1 = nameRegistry.generateCommit("alice", alice, "secret");
        assertEq(commit1, 0xe89b588f69839d6c3411027709e47c05713159feefc87e3173f64c01f4b41c72);

        // 1-char name
        bytes32 commit2 = nameRegistry.generateCommit("1", alice, "secret");
        assertEq(commit2, 0xf52e7be4097c2afdc86002c691c7e5fab52be36748174fe15303bb32cb106da6);

        // 16-char alphabetic
        bytes32 commit3 = nameRegistry.generateCommit("alicenwonderland", alice, "secret");
        assertEq(commit3, 0x94f5dd34daadfe7565398163e7cb955832b2a2e963a6365346ab8ba92b5f5126);

        // 16-char alphanumeric name
        bytes32 commit4 = nameRegistry.generateCommit("alice0wonderland", alice, "secret");
        assertEq(commit4, 0xdf1dc48666da9fcc229a254aa77ffab008da2d29b617fada59b645b7cc0928b9);

        // 16-char alphanumeric hyphenated name
        bytes32 commit5 = nameRegistry.generateCommit("-al1c3w0nderl4nd", alice, "secret");
        assertEq(commit5, 0x48ba82e0c3aa3f6a18bff166ca475b8cb257b83768160ee7e2702e9834d7380d);
    }

    function testCannotGenerateCommitWithInvalidName(address alice) public {
        vm.expectRevert(NameRegistry.InvalidName.selector);
        nameRegistry.generateCommit("Alice", alice, "secret");

        vm.expectRevert(NameRegistry.InvalidName.selector);
        nameRegistry.generateCommit("a/lice", alice, "secret");

        vm.expectRevert(NameRegistry.InvalidName.selector);
        nameRegistry.generateCommit("a:lice", alice, "secret");

        vm.expectRevert(NameRegistry.InvalidName.selector);
        nameRegistry.generateCommit("a`ice", alice, "secret");

        vm.expectRevert(NameRegistry.InvalidName.selector);
        nameRegistry.generateCommit("a{ice", alice, "secret");

        vm.expectRevert(NameRegistry.InvalidName.selector);
        nameRegistry.generateCommit("", alice, "secret");

        // We cannot specify valid UTF-8 chars like £ in a test using string literals, so we encode
        // a bytes16 string that has the second character set to a byte-value of 129, which is a
        // valid UTF-8 character that cannot be typed
        bytes16 nameWithInvalidUtfChar = 0x61816963650000000000000000000000;
        vm.expectRevert(NameRegistry.InvalidName.selector);
        nameRegistry.generateCommit(nameWithInvalidUtfChar, alice, "secret");
    }

    function testMakeCommit(address alice) public {
        vm.prank(owner);
        nameRegistry.disableTrustedRegister();
        bytes32 commitHash = nameRegistry.generateCommit("alice", alice, "secret");

        vm.prank(alice);
        nameRegistry.makeCommit(commitHash);
        assertEq(nameRegistry.timestampOf(commitHash), block.timestamp);
    }

    function testCannotMakeCommitDuringTrustedRegister(address alice) public {
        bytes32 commitHash = nameRegistry.generateCommit("alice", alice, "secret");
        vm.prank(alice);
        vm.expectRevert(NameRegistry.NotRegistrable.selector);
        nameRegistry.makeCommit(commitHash);
    }

    /*//////////////////////////////////////////////////////////////
                           REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRegister(
        address alice,
        address charlie,
        bytes32 secret
    ) public {
        _assumeClean(alice);
        _disableTrusted();
        // TODO: Implement fuzzing for name using valid name generator

        // 1. Give alice money and fast forward to 2022 to begin registration.
        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        // 2. Make the commitment to register the name alice
        vm.startPrank(alice);
        bytes32 commitHash = nameRegistry.generateCommit("alice", alice, secret);
        nameRegistry.makeCommit(commitHash);

        // 3. Register the name alice
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, uint256(bytes32("alice")));
        uint256 balance = alice.balance;
        nameRegistry.register{value: 0.01 ether}("alice", alice, secret, charlie);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        assertEq(alice.balance, balance - nameRegistry.currYearFee());
        assertEq(nameRegistry.recoveryOf(aliceTokenId), charlie);
        vm.stopPrank();
    }

    function testRegisterToAnotherAddress(
        address alice,
        address bob,
        bytes32 secret
    ) public {
        vm.assume(bob != zeroAddress);
        _assumeClean(alice);
        _disableTrusted();

        // 1. Give alice money and fast forward to 2022 to begin registration.
        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        // 2. Make the commitment to register the name @bob to the user bob
        vm.prank(alice);
        bytes32 commitHash = nameRegistry.generateCommit("bob", bob, secret);
        nameRegistry.makeCommit(commitHash);

        // 3. Register the name @bob to bob
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), bob, uint256(bytes32("bob")));
        vm.prank(alice);
        nameRegistry.register{value: 0.01 ether}("bob", bob, secret, zeroAddress);

        assertEq(nameRegistry.ownerOf(bobTokenId), bob);
        assertEq(nameRegistry.expiryOf(bobTokenId), TS_2023);
    }

    function testRegisterWorksWhenAlreadyOwningAName(address alice, bytes32 secret) public {
        _assumeClean(alice);
        _disableTrusted();

        // 1. Give alice money and fast forward to 2022 to begin registration.
        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);
        vm.startPrank(alice);

        // 2. Register @alice to alice
        bytes32 commitHash = nameRegistry.generateCommit("alice", alice, secret);
        nameRegistry.makeCommit(commitHash);
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);
        nameRegistry.register{value: nameRegistry.fee()}("alice", alice, secret, zeroAddress);

        // 3. Register @bob to alice
        bytes32 commitHashBob = nameRegistry.generateCommit("bob", alice, secret);
        nameRegistry.makeCommit(commitHashBob);
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);
        nameRegistry.register{value: 0.01 ether}("bob", alice, secret, zeroAddress);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        assertEq(nameRegistry.ownerOf(bobTokenId), alice);
        assertEq(nameRegistry.expiryOf(bobTokenId), TS_2023);
        assertEq(nameRegistry.balanceOf(alice), 2);
        vm.stopPrank();
    }

    function testRegisterAfterUnpausing(
        address alice,
        address bob,
        bytes32 secret
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        _disableTrusted();

        // 1. Make commitment to register the name @alice
        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);
        vm.prank(alice);
        bytes32 commitHash = nameRegistry.generateCommit("alice", alice, secret);
        nameRegistry.makeCommit(commitHash);

        // 2. Fast forward past the register delay and pause and unpause the contract
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);
        vm.prank(owner);
        nameRegistry.pause();
        vm.prank(owner);
        nameRegistry.unpause();

        // 3. Register the name alice
        vm.prank(alice);
        nameRegistry.register{value: 0.01 ether}("alice", alice, secret, bob);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);
    }

    function testCannotRegisterTheSameNameTwice(
        address alice,
        address bob,
        bytes32 secret
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        _disableTrusted();

        vm.prank(owner);
        nameRegistry.disableTrustedRegister();

        // 1. Give alice and bob money and have alice register @alice
        vm.startPrank(alice);
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.warp(aliceRegisterTs);

        bytes32 aliceCommitHash = nameRegistry.generateCommit("alice", alice, secret);
        nameRegistry.makeCommit(aliceCommitHash);
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);
        nameRegistry.register{value: 0.01 ether}("alice", alice, secret, zeroAddress);

        // 2. alice tries to register @alice again and fails
        nameRegistry.makeCommit(aliceCommitHash);
        vm.expectRevert(NameRegistry.NotRegistrable.selector);
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);
        nameRegistry.register{value: 0.01 ether}("alice", alice, secret, zeroAddress);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        vm.stopPrank();

        // 3. bob tries to register @alice and fails
        vm.startPrank(bob);
        bytes32 bobCommitHash = nameRegistry.generateCommit("alice", bob, secret);
        nameRegistry.makeCommit(bobCommitHash);
        vm.expectRevert(NameRegistry.NotRegistrable.selector);
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);
        nameRegistry.register{value: 0.01 ether}("alice", bob, secret, zeroAddress);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        vm.stopPrank();
    }

    function testCannotRegisterWithoutPayment(address alice, bytes32 secret) public {
        _assumeClean(alice);
        _disableTrusted();

        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        bytes32 commitHash = nameRegistry.generateCommit("alice", alice, secret);
        vm.prank(alice);
        nameRegistry.makeCommit(commitHash);

        vm.prank(alice);
        vm.expectRevert(NameRegistry.InsufficientFunds.selector);
        nameRegistry.register{value: 1 wei}("alice", alice, secret, zeroAddress);
    }

    function testCannotRegisterWithoutCommit(
        address alice,
        address bob,
        bytes32 secret
    ) public {
        _assumeClean(alice);
        _disableTrusted();

        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        bytes16 username = "bob";
        vm.prank(alice);
        vm.expectRevert(NameRegistry.InvalidCommit.selector);
        nameRegistry.register{value: 0.01 ether}(username, bob, secret, zeroAddress);
    }

    function testCannotRegisterWithInvalidCommitSecret(
        address alice,
        address bob,
        bytes32 secret
    ) public {
        _assumeClean(alice);
        _disableTrusted();

        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        bytes16 username = "bob";
        bytes32 commitHash = nameRegistry.generateCommit(username, bob, secret);
        vm.prank(alice);
        nameRegistry.makeCommit(commitHash);

        bytes32 incorrectSecret = "foobar";
        vm.assume(secret != incorrectSecret);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.InvalidCommit.selector);
        nameRegistry.register{value: 0.01 ether}(username, bob, incorrectSecret, zeroAddress);
    }

    function testCannotRegisterWithInvalidCommitAddress(
        address alice,
        address bob,
        bytes32 secret
    ) public {
        _assumeClean(alice);
        _disableTrusted();

        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        bytes16 username = "bob";
        bytes32 commitHash = nameRegistry.generateCommit(username, bob, secret);
        vm.prank(alice);
        nameRegistry.makeCommit(commitHash);

        address incorrectOwner = address(0x1234A);
        vm.assume(bob != incorrectOwner);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.InvalidCommit.selector);
        nameRegistry.register{value: 0.01 ether}(username, incorrectOwner, secret, zeroAddress);
    }

    function testCannotRegisterWithInvalidCommitName(
        address alice,
        address bob,
        bytes32 secret
    ) public {
        _assumeClean(alice);
        _disableTrusted();

        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        bytes16 username = "bob";
        bytes32 commitHash = nameRegistry.generateCommit(username, bob, secret);
        vm.prank(alice);
        nameRegistry.makeCommit(commitHash);

        bytes16 incorrectUsername = "alice";
        vm.expectRevert(NameRegistry.InvalidCommit.selector);
        vm.prank(alice);
        nameRegistry.register{value: 0.01 ether}(incorrectUsername, bob, secret, zeroAddress);
    }

    function testCannotRegisterBeforeDelay(address alice, bytes32 secret) public {
        _assumeClean(alice);
        _disableTrusted();

        // 1. Give alice money and fast forward to 2022 to begin registration.
        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        // 2. Make the commitment to register the name alice
        bytes32 commitHash = nameRegistry.generateCommit("alice", alice, secret);
        vm.prank(alice);
        nameRegistry.makeCommit(commitHash);

        // 3. Try to register the name and fail
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY - 1);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.InvalidCommit.selector);
        nameRegistry.register{value: 0.01 ether}("alice", alice, secret, zeroAddress);
    }

    function testCannotRegisterWithInvalidNames(address alice, bytes32 secret) public {
        _assumeClean(alice);
        _disableTrusted();

        bytes16 incorrectUsername = "al{ce";
        bytes32 invalidCommit = keccak256(abi.encode(incorrectUsername, alice, secret));
        nameRegistry.makeCommit(invalidCommit);

        vm.expectRevert(NameRegistry.InvalidName.selector);
        nameRegistry.register{value: 0.01 ether}(incorrectUsername, alice, secret, zeroAddress);
    }

    function testCannotRegisterWhilePaused(address alice, address bob) public {
        _assumeClean(alice);
        _disableTrusted();

        // 1. Make the commitment to register @alice
        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);
        vm.prank(alice);
        bytes32 commitHash = nameRegistry.generateCommit("alice", alice, "secret");
        nameRegistry.makeCommit(commitHash);

        // 2. Pause the contract and try to register the name alice
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);
        vm.prank(owner);
        nameRegistry.pause();

        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        nameRegistry.register{value: 0.01 ether}("alice", alice, "secret", bob);

        vm.expectRevert(NameRegistry.Registrable.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.expiryOf(aliceTokenId), 0);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                         REGISTER TRUSTED TESTS
    //////////////////////////////////////////////////////////////*/

    function testTrustedRegister(address _trustedSender, address alice) public {
        vm.assume(alice != zeroAddress);

        vm.warp(TS_2022);
        vm.prank(owner);
        nameRegistry.setTrustedSender(_trustedSender);
        assertEq(nameRegistry.trustedRegisterEnabled(), true);

        vm.prank(_trustedSender);
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), alice, aliceTokenId);
        nameRegistry.trustedRegister(alice, "alice", zeroAddress);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
    }

    function testTrustedRegisterSetsRecoveryAddress(
        address _trustedSender,
        address alice,
        address bob
    ) public {
        vm.assume(alice != zeroAddress);

        vm.prank(owner);
        nameRegistry.setTrustedSender(_trustedSender);
        assertEq(nameRegistry.trustedRegisterEnabled(), true);

        vm.prank(_trustedSender);
        nameRegistry.trustedRegister(alice, "alice", bob);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);
    }

    function testCannotTrustedRegisterWhenDisabled(address _trustedSender, address alice) public {
        vm.assume(alice != zeroAddress);
        vm.prank(owner);
        nameRegistry.setTrustedSender(_trustedSender);

        vm.prank(owner);
        nameRegistry.disableTrustedRegister();

        vm.prank(_trustedSender);
        vm.expectRevert(NameRegistry.Registrable.selector);
        nameRegistry.trustedRegister(alice, "alice", zeroAddress);

        vm.expectRevert(NameRegistry.Registrable.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.expiryOf(aliceTokenId), 0);
    }

    function testCannotTrustedRegisterTwice(address _trustedSender, address alice) public {
        vm.assume(alice != zeroAddress);
        vm.prank(owner);
        nameRegistry.setTrustedSender(_trustedSender);
        assertEq(nameRegistry.trustedRegisterEnabled(), true);

        vm.prank(_trustedSender);
        nameRegistry.trustedRegister(alice, "alice", zeroAddress);

        vm.prank(_trustedSender);
        vm.expectRevert("ERC721: token already minted");
        nameRegistry.trustedRegister(alice, "alice", zeroAddress);
    }

    function testCannotTrustedRegisterFromArbitrarySender(
        address _trustedSender,
        address arbitrarySender,
        address alice
    ) public {
        vm.assume(arbitrarySender != _trustedSender);
        vm.assume(alice != zeroAddress);
        assertEq(nameRegistry.trustedRegisterEnabled(), true);

        vm.prank(owner);
        nameRegistry.setTrustedSender(_trustedSender);

        vm.prank(arbitrarySender);
        vm.expectRevert(NameRegistry.Unauthorized.selector);
        nameRegistry.trustedRegister(alice, "alice", zeroAddress);
    }

    function testCannotTrustedRegisterWhilePaused(address _trustedSender, address alice) public {
        vm.assume(alice != zeroAddress);
        assertEq(nameRegistry.trustedRegisterEnabled(), true);
        vm.prank(owner);
        nameRegistry.setTrustedSender(_trustedSender);

        vm.prank(owner);
        nameRegistry.pause();

        vm.prank(_trustedSender);
        vm.expectRevert("Pausable: paused");
        nameRegistry.trustedRegister(alice, "alice", zeroAddress);

        vm.expectRevert(NameRegistry.Registrable.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(alice), 0);
        assertEq(nameRegistry.expiryOf(aliceTokenId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               RENEW TESTS
    //////////////////////////////////////////////////////////////*/

    function testRenewSelf(address alice) public {
        // 1. Register alice and fast forward to renewal
        _assumeClean(alice);
        _register(alice);

        vm.warp(aliceRenewableTs);

        // 2. Alice renews her own username
        vm.expectEmit(true, true, true, true);
        emit Renew(aliceTokenId, TS_2024);
        vm.prank(alice);
        nameRegistry.renew{value: 0.01 ether}(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
    }

    function testRenewOther(address alice, address bob) public {
        // 1. Register alice and fast forward to renewal
        _assumeClean(bob);
        vm.assume(alice != bob);
        _assumeClean(alice);
        _register(alice);
        vm.warp(aliceRenewableTs);

        // 2. Bob renews alice's username for her
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Renew(aliceTokenId, TS_2024);
        nameRegistry.renew{value: 0.01 ether}(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
    }

    function testRenewWithOverpayment(address alice) public {
        _assumeClean(alice);
        _register(alice);
        vm.warp(aliceRenewableTs);

        // Renew alice's registration, but overpay the amount
        vm.startPrank(alice);
        uint256 balance = alice.balance;
        nameRegistry.renew{value: 0.02 ether}(aliceTokenId);
        vm.stopPrank();

        assertEq(alice.balance, balance - 0.01 ether);
        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
    }

    function testCannotRenewWithoutPayment(address alice) public {
        _assumeClean(alice);
        _register(alice);
        vm.warp(aliceRenewableTs);

        // 2. Renewing fails if insufficient funds are provided
        vm.prank(alice);
        vm.expectRevert(NameRegistry.InsufficientFunds.selector);
        nameRegistry.renew(aliceTokenId);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
    }

    function testCannotRenewIfRegistrable(address alice) public {
        _assumeClean(alice);
        // 1. Fund alice and fast-forward to 2022, when registrations can occur
        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        vm.prank(alice);
        vm.expectRevert(NameRegistry.Registrable.selector);
        nameRegistry.renew{value: 0.01 ether}(aliceTokenId);

        vm.expectRevert(NameRegistry.Registrable.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.expiryOf(aliceTokenId), 0);
    }

    function testCannotRenewIfBiddable(address alice) public {
        // 1. Register alice and fast-forward to 2023 when the registration expires
        _assumeClean(alice);
        _register(alice);
        vm.warp(aliceBiddableTs);

        vm.prank(alice);
        vm.expectRevert(NameRegistry.Biddable.selector);
        nameRegistry.renew{value: 0.01 ether}(aliceTokenId);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
    }

    function testCannotRenewIfRegistered(address alice) public {
        // Fast forward to the last second of this year (2022) when the registration is still valid
        _assumeClean(alice);

        _register(alice);
        vm.warp(aliceRenewableTs - 1);

        vm.prank(alice);
        vm.expectRevert(NameRegistry.Registered.selector);
        nameRegistry.renew{value: 0.01 ether}(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
    }

    function testCannotRenewIfPaused(address alice) public {
        _assumeClean(alice);
        _register(alice);

        vm.warp(aliceRenewableTs);
        vm.prank(owner);
        nameRegistry.pause();

        vm.expectRevert("Pausable: paused");
        vm.prank(alice);
        nameRegistry.renew{value: 0.01 ether}(aliceTokenId);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
    }

    /*//////////////////////////////////////////////////////////////
                                BID TESTS
    //////////////////////////////////////////////////////////////*/

    function testBid(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.deal(bob, 1001 ether);
        vm.warp(aliceBiddableTs);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, aliceTokenId);
        nameRegistry.bid{value: 1_000.01 ether}(aliceTokenId, charlie);

        assertEq(nameRegistry.ownerOf(aliceTokenId), bob);
        assertEq(nameRegistry.balanceOf(alice), 0);
        assertEq(nameRegistry.balanceOf(bob), 1);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), charlie);
    }

    function testBidResetsERC721Approvals(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);

        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        // 1. Set bob as the approver of alice's token
        vm.prank(alice);
        nameRegistry.approve(bob, aliceTokenId);
        vm.warp(aliceBiddableTs);

        // 2. Bob bids and succeeds because bid >= premium + fee
        vm.deal(bob, 1001 ether);
        vm.prank(bob);
        nameRegistry.bid{value: 1_000.01 ether}(aliceTokenId, charlie);

        assertEq(nameRegistry.getApproved(aliceTokenId), address(0));
    }

    function testBidOverpaymentIsRefunded(address alice, address bob) public {
        _assumeClean(alice);

        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        // 1. Bob bids and overpays the amount.
        vm.warp(aliceBiddableTs);
        vm.deal(bob, 1001 ether);
        vm.prank(bob);
        nameRegistry.bid{value: 1001 ether}(aliceTokenId, zeroAddress);

        // 2. Check that bob 's change is returned
        assertEq(bob.balance, 0.990821917808219179 ether);
    }

    function testBidAfterOneStep(address alice, address bob) public {
        // 1. Register alice and fast-forward to 8 hours into the auction
        _assumeClean(alice);

        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);
        vm.warp(aliceBiddableTs + 8 hours);

        // 2. Bob bids and fails because bid < price (premium + fee)
        // price = (0.9^1 * 1_000) + 0.00916894977 = 900.009169
        vm.deal(bob, 1000 ether);
        vm.startPrank(bob);
        vm.expectRevert(NameRegistry.InsufficientFunds.selector);
        nameRegistry.bid{value: 900.0091 ether}(aliceTokenId, zeroAddress);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(bob), 0);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);

        // 3. Bob bids and succeeds because bid > price
        nameRegistry.bid{value: 900.0092 ether}(aliceTokenId, zeroAddress);
        assertEq(nameRegistry.ownerOf(aliceTokenId), bob);
        vm.stopPrank();

        assertEq(nameRegistry.ownerOf(aliceTokenId), bob);
        assertEq(nameRegistry.balanceOf(alice), 0);
        assertEq(nameRegistry.balanceOf(bob), 1);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
    }

    function testBidOnHundredthStep(address alice, address bob) public {
        // 1. Register alice and fast-forward to 800 hours into the auction
        _assumeClean(alice);

        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);
        vm.warp(aliceBiddableTs + (8 hours * 100));

        // 2. Bob bids and fails because bid < price (premium + fee)
        // price = (0.9^100 * 1_000) + 0.00826484018 = 0.0348262391
        vm.deal(bob, 1000 ether);
        vm.startPrank(bob);
        vm.expectRevert(NameRegistry.InsufficientFunds.selector);
        nameRegistry.bid{value: 0.0348 ether}(aliceTokenId, zeroAddress);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(bob), 0);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);

        // 3. Bob bids and succeeds because bid > price
        nameRegistry.bid{value: 0.0349 ether}(aliceTokenId, zeroAddress);
        vm.stopPrank();

        assertEq(nameRegistry.ownerOf(aliceTokenId), bob);
        assertEq(nameRegistry.balanceOf(alice), 0);
        assertEq(nameRegistry.balanceOf(bob), 1);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
    }

    function testBidOnPenultimateStep(address alice, address bob) public {
        // 1. Register alice and fast-forward to 3056 hours into the auction
        _assumeClean(alice);

        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);
        vm.warp(aliceBiddableTs + (8 hours * 382));

        // 2. Bob bids and fails because bid < price (premium + fee)
        // price = (0.9^382 * 1_000) + 0.00568949772 = 0.00568949772 (+ ~ - 3.31e-15)
        vm.deal(bob, 1000 ether);
        vm.startPrank(bob);
        vm.expectRevert(NameRegistry.InsufficientFunds.selector);
        nameRegistry.bid{value: 0.00568949771 ether}(aliceTokenId, zeroAddress);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(bob), 0);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);

        // 3. Bob bids and succeeds because bid > price
        nameRegistry.bid{value: 0.005689498772 ether}(aliceTokenId, zeroAddress);
        vm.stopPrank();

        assertEq(nameRegistry.ownerOf(aliceTokenId), bob);
        assertEq(nameRegistry.balanceOf(alice), 0);
        assertEq(nameRegistry.balanceOf(bob), 1);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
    }

    function testBidFlatRate(address alice, address bob) public {
        _assumeClean(bob);
        _assumeClean(alice);

        vm.assume(alice != bob);
        _register(alice);

        vm.warp(aliceBiddableTs + (8 hours * 383));
        vm.deal(bob, 1000 ether);
        vm.startPrank(bob);

        // 2. Bob bids and fails because bid < price (0 + fee) == 0.0056803653
        vm.expectRevert(NameRegistry.InsufficientFunds.selector);
        nameRegistry.bid{value: 0.0056803652 ether}(aliceTokenId, zeroAddress);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(bob), 0);
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);

        // 3. Bob bids and succeeds because bid > price (0 + fee)
        nameRegistry.bid{value: 0.0056803653 ether}(aliceTokenId, zeroAddress);
        vm.stopPrank();

        assertEq(nameRegistry.ownerOf(aliceTokenId), bob);
        assertEq(nameRegistry.balanceOf(alice), 0);
        assertEq(nameRegistry.balanceOf(bob), 1);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
    }

    function testCannotBidAfterSuccessfulBid(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        // 1. Bob bids and succeeds because bid >= premium + fee
        vm.warp(aliceBiddableTs);
        vm.deal(bob, 1001 ether);
        vm.prank(bob);
        nameRegistry.bid{value: 1_000.01 ether}(aliceTokenId, zeroAddress);

        // 2. Alice bids again and fails because the name is no longer for auction
        vm.prank(alice);
        vm.expectRevert(NameRegistry.NotBiddable.selector);
        nameRegistry.bid(aliceTokenId, charlie);

        assertEq(nameRegistry.ownerOf(aliceTokenId), bob);
        assertEq(nameRegistry.balanceOf(alice), 0);
        assertEq(nameRegistry.balanceOf(bob), 1);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), zeroAddress);
    }

    function testCannotBidWithUnderpayment(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        // 1. Bob bids and fails because bid < premium + fee
        vm.warp(aliceBiddableTs);
        vm.deal(bob, 1001 ether);
        vm.startPrank(bob);
        vm.expectRevert(NameRegistry.InsufficientFunds.selector);
        nameRegistry.bid{value: 1000 ether}(aliceTokenId, zeroAddress);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(bob), 0);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), zeroAddress);
    }

    function testCannotBidUnlessBiddable(address alice, address bob) public {
        // 1. Register alice and fast-forward to one second before the auction starts
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        // 2. Bid during registered state should fail
        vm.startPrank(bob);
        vm.warp(aliceRenewableTs - 1);
        vm.expectRevert(NameRegistry.NotBiddable.selector);
        nameRegistry.bid(aliceTokenId, zeroAddress);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(bob), 0);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);

        // 2. Bid during renewable state should fail
        vm.warp(aliceBiddableTs - 1);
        vm.expectRevert(NameRegistry.NotBiddable.selector);
        nameRegistry.bid(aliceTokenId, zeroAddress);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(bob), 0);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        vm.stopPrank();
    }

    function testBidShouldClearRecovery(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. Register alice and set up a recovery address.
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. Bob requests a recovery of @alice to Charlie
        vm.startPrank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), block.timestamp);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);

        // 3. Bob completes a bid on alice
        vm.warp(aliceBiddableTs);
        vm.deal(bob, 1001 ether);
        nameRegistry.bid{value: 1001 ether}(aliceTokenId, zeroAddress);
        vm.stopPrank();

        // 4. Assert that the recovery state has been unset
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
    }

    function testCannotBidIfInvitable(address bob) public {
        _assumeClean(bob);

        // 1. Bid on @alice when it is not minted and still in trusted registration
        vm.prank(bob);
        vm.expectRevert(NameRegistry.Registrable.selector);
        nameRegistry.bid(aliceTokenId, zeroAddress);

        vm.expectRevert(NameRegistry.Registrable.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(bob), 0);
        assertEq(nameRegistry.expiryOf(aliceTokenId), 0);
    }

    function testCannotBidIfPaused(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.deal(bob, 1001 ether);
        vm.prank(owner);
        nameRegistry.pause();
        vm.warp(aliceBiddableTs);

        vm.prank(bob);
        vm.expectRevert("Pausable: paused");
        nameRegistry.bid{value: 1_000.01 ether}(aliceTokenId, charlie);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(alice), 1); // balanceOf counts expired ids by design
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        assertEq(nameRegistry.balanceOf(bob), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              ERC-721 TESTS
    //////////////////////////////////////////////////////////////*/

    function testOwnerOfRevertsIfExpired(address alice) public {
        _assumeClean(alice);
        _register(alice);

        vm.warp(aliceBiddableTs);
        vm.expectRevert(NameRegistry.Expired.selector);
        nameRegistry.ownerOf(aliceTokenId);
    }

    function testOwnerOfRevertsIfRegistrable() public {
        vm.expectRevert(NameRegistry.Registrable.selector);
        nameRegistry.ownerOf(aliceTokenId);
    }

    function testTransferFrom(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, aliceTokenId);
        nameRegistry.transferFrom(alice, bob, aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), bob);
        assertEq(nameRegistry.balanceOf(alice), 0);
        assertEq(nameRegistry.balanceOf(bob), 1);
    }

    function testTransferFromResetsRecovery(
        address alice,
        address bob,
        address charlie,
        address david
    ) public {
        // 1. Register alice and set up a recovery address.
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != david);
        vm.assume(alice != bob);
        vm.assume(david != zeroAddress);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. Bob requests a recovery of @alice to Charlie
        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), block.timestamp);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);

        // 3. Alice transfers then name to david
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, david, aliceTokenId);
        nameRegistry.transferFrom(alice, david, aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), david);
        assertEq(nameRegistry.balanceOf(david), 1);
        assertEq(nameRegistry.balanceOf(alice), 0);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
    }

    function testTransferFromCannotTransferExpiredName(address alice, address bob) public {
        // 1. Register alice and set up a recovery address.
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        // 2. Fast forward to name in renewable state
        vm.startPrank(alice);
        vm.warp(aliceRenewableTs);
        vm.expectRevert(NameRegistry.Expired.selector);
        nameRegistry.transferFrom(alice, bob, aliceTokenId);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(bob), 0);

        // 3. Fast forward to name in expired state
        vm.warp(aliceBiddableTs);
        vm.expectRevert(NameRegistry.Expired.selector);
        nameRegistry.transferFrom(alice, bob, aliceTokenId);
        vm.stopPrank();

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(bob), 0);
    }

    function testCannotTransferFromIfPaused(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.prank(owner);
        nameRegistry.pause();

        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        nameRegistry.transferFrom(alice, bob, aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(bob), 0);
    }

    function testTokenUri() public {
        uint256 tokenId = uint256(bytes32("alice"));
        assertEq(nameRegistry.tokenURI(tokenId), "http://www.farcaster.xyz/u/alice.json");

        // Test with min length name
        uint256 tokenIdMin = uint256(bytes32("a"));
        assertEq(nameRegistry.tokenURI(tokenIdMin), "http://www.farcaster.xyz/u/a.json");

        // Test with max length name
        uint256 tokenIdMax = uint256(bytes32("alicenwonderland"));
        assertEq(nameRegistry.tokenURI(tokenIdMax), "http://www.farcaster.xyz/u/alicenwonderland.json");
    }

    function testCannotGetTokenUriForInvalidName() public {
        vm.expectRevert(NameRegistry.InvalidName.selector);
        nameRegistry.tokenURI(uint256(bytes32("alicenWonderland")));
    }

    /*//////////////////////////////////////////////////////////////
                          CHANGE RECOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function testChangeRecoveryAddress(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        // 1. alice sets bob as her recovery address
        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true);
        emit ChangeRecoveryAddress(alice, aliceTokenId);

        nameRegistry.changeRecoveryAddress(aliceTokenId, alice);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), alice);

        // 2. alice sets charlie as her recovery address
        vm.expectEmit(true, true, false, true);
        emit ChangeRecoveryAddress(charlie, aliceTokenId);
        nameRegistry.changeRecoveryAddress(aliceTokenId, charlie);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), charlie);

        vm.stopPrank();
    }

    function testCannotChangeRecoveryAddressUnlessOwner(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.prank(bob);
        vm.expectRevert(NameRegistry.Unauthorized.selector);
        nameRegistry.changeRecoveryAddress(aliceTokenId, charlie);

        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
    }

    function testCannotChangeRecoveryAddressIfRenewable(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.warp(aliceRenewableTs);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.Expired.selector);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
    }

    function testCannotChangeRecoveryAddressIfBiddable(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.warp(aliceBiddableTs);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.Expired.selector);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
    }

    function testCannotChangeRecoveryAddressIfRegistrable(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);

        vm.expectRevert(NameRegistry.Registrable.selector);
        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(bobTokenId, bob);

        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
    }

    function testCannotChangeRecoveryAddressIfPaused(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.prank(owner);
        nameRegistry.pause();

        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), zeroAddress);
    }

    function testChangeRecoveryAddressResetsRecovery(
        address alice,
        address bob,
        address charlie,
        address david
    ) public {
        // 1. alice registers @alice and sets bob as her recovery
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != david);
        vm.assume(alice != bob);
        vm.assume(david != zeroAddress);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. bob requests a recovery of @alice to charlie and then alice changes the recovery address
        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit CancelRecovery(aliceTokenId);
        nameRegistry.changeRecoveryAddress(aliceTokenId, david);

        assertEq(nameRegistry.recoveryOf(aliceTokenId), david);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         REQUEST RECOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function testRequestRecovery(
        address alice,
        address bob,
        address charlie,
        address david
    ) public {
        // 1. alice registers id 1 and sets bob as her recovery address
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != david);
        vm.assume(alice != bob);
        vm.assume(david != zeroAddress);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. bob requests a recovery of alice's id to charlie
        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit RequestRecovery(aliceTokenId, alice, charlie);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), block.timestamp);
        assertEq(nameRegistry.recoveryDestinationOf(aliceTokenId), charlie);

        // 3. bob then requests another recovery to david
        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, david);

        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), block.timestamp);
        assertEq(nameRegistry.recoveryDestinationOf(aliceTokenId), david);
    }

    function testCannotRequestRecoveryToZeroAddr(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 1. bob requests a recovery of alice's id to 0x0
        vm.prank(bob);
        vm.expectRevert(NameRegistry.InvalidRecovery.selector);
        nameRegistry.requestRecovery(aliceTokenId, alice, address(0));

        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
        assertEq(nameRegistry.recoveryDestinationOf(aliceTokenId), address(0));
    }

    function testCannotRequestRecoveryUnlessAuthorized(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        // 1. bob requests a recovery from alice to charlie, which fails
        vm.prank(bob);
        vm.expectRevert(NameRegistry.Unauthorized.selector);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
        assertEq(nameRegistry.recoveryDestinationOf(aliceTokenId), address(0));
    }

    function testCannotRequestRecoveryIfRegistrable(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);

        // 1. bob requests a recovery from alice to charlie, which fails
        vm.prank(bob);
        vm.expectRevert(NameRegistry.Unauthorized.selector);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
        assertEq(nameRegistry.recoveryDestinationOf(aliceTokenId), address(0));
    }

    function testCannotRequestRecoveryIfPaused(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice, sets bob as her recovery address and the contract is paused
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);
        vm.prank(owner);
        nameRegistry.pause();

        // 2. bob requests a recovery which fails
        vm.prank(bob);
        vm.expectRevert("Pausable: paused");
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
        assertEq(nameRegistry.recoveryDestinationOf(aliceTokenId), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                         COMPLETE RECOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function testCompleteRecovery(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice and sets bob as her recovery address
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. bob requests a recovery of alice's id to charlie
        vm.startPrank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        // 3. after escrow period, bob completes the recovery to charlie
        vm.warp(block.timestamp + ESCROW_PERIOD);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, charlie, aliceTokenId);
        nameRegistry.completeRecovery(aliceTokenId);
        vm.stopPrank();

        assertEq(nameRegistry.ownerOf(aliceTokenId), charlie);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
    }

    function testRecoveryCompletionResetsERC721Approvals(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice and sets bob as her recovery address and approver
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.startPrank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);
        nameRegistry.approve(bob, aliceTokenId);
        vm.stopPrank();

        // 2. bob requests and completes a recovery to charlie
        vm.startPrank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);
        vm.warp(block.timestamp + ESCROW_PERIOD);
        nameRegistry.completeRecovery(aliceTokenId);
        vm.stopPrank();

        assertEq(nameRegistry.getApproved(aliceTokenId), address(0));
    }

    function testCannotCompleteRecoveryIfUnauthorized(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(bob != charlie);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        // warp to ensure that block.timestamp is not zero so we can assert the reset of the recovery clock
        vm.warp(100);
        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        vm.prank(charlie);
        vm.expectRevert(NameRegistry.Unauthorized.selector);
        nameRegistry.completeRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), block.timestamp);
    }

    function testCannotCompleteRecoveryIfStartedByPrevious(
        address alice,
        address bob,
        address charlie,
        address david
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(alice != charlie);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 1. bob requests a recovery of @alice to charlie and then alice changes the recovery to david
        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);
        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, david);

        // 2. after escrow period, david attempts to complete recovery which fails
        vm.warp(block.timestamp + ESCROW_PERIOD);
        vm.prank(david);
        vm.expectRevert(NameRegistry.NoRecovery.selector);
        nameRegistry.completeRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.balanceOf(alice), 1);
        assertEq(nameRegistry.balanceOf(charlie), 0);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), david);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
    }

    function testCannotCompleteRecoveryIfNotStarted(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 1. bob calls recovery complete on alice's id, which fails
        vm.prank(bob);
        vm.warp(block.number + ESCROW_PERIOD);
        vm.expectRevert(NameRegistry.NoRecovery.selector);
        nameRegistry.completeRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
    }

    function testCannotCompleteRecoveryWhenInEscrow(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice and sets bob as her recovery address
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. bob requests a recovery of @alice to charlie
        vm.startPrank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        // 3. before escrow period, bob completes the recovery to charlie
        vm.expectRevert(NameRegistry.Escrow.selector);
        nameRegistry.completeRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), block.timestamp);
        vm.stopPrank();
    }

    function testCannotCompleteRecoveryIfExpired(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice and sets bob as her recovery address
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. bob requests a recovery of @alice to charlie
        uint256 requestTs = block.timestamp;
        vm.startPrank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        // 3. during the renewal period, bob attempts to recover to charlie
        vm.warp(aliceRenewableTs);
        vm.expectRevert(NameRegistry.Unauthorized.selector);
        nameRegistry.completeRecovery(aliceTokenId);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), requestTs);

        // 3. during expiry, bob attempts to recover to charlie
        vm.warp(aliceBiddableTs);
        vm.expectRevert(NameRegistry.Unauthorized.selector);
        nameRegistry.completeRecovery(aliceTokenId);

        vm.expectRevert(NameRegistry.Expired.selector);
        assertEq(nameRegistry.ownerOf(aliceTokenId), address(0));
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), requestTs);
        vm.stopPrank();
    }

    function testCannotCompleteRecoveryIfPaused(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice and sets bob as her recovery address, and @bob requests a recovery to recovery.
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);
        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);
        uint256 recoveryTs = block.timestamp;

        // 2. the contract is then paused by the owner and we warp past the escrow period
        vm.prank(owner);
        nameRegistry.pause();
        vm.warp(recoveryTs + ESCROW_PERIOD);

        // 3. bob attempts to complete the recovery, which fails
        vm.prank(bob);
        vm.expectRevert("Pausable: paused");
        nameRegistry.completeRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), bob);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), recoveryTs);
    }

    /*//////////////////////////////////////////////////////////////
                          CANCEL RECOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function testCancelRecoveryFromCustodyAddress(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice and sets bob as her recovery address
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. bob requests a recovery of @alice to charlie
        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        // 3. alice cancels the recovery
        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit CancelRecovery(aliceTokenId);
        nameRegistry.cancelRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);

        // 4. after escrow period, bob tries to recover to charlie and fails
        vm.warp(block.timestamp + ESCROW_PERIOD);
        vm.expectRevert(NameRegistry.NoRecovery.selector);
        vm.prank(bob);
        nameRegistry.completeRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
    }

    function testCancelRecoveryFromRecoveryAddress(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice and sets bob as her recovery address
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. bob requests a recovery of @alice to charlie
        vm.startPrank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        // 3. bob cancels the recovery
        vm.expectEmit(true, false, false, false);
        emit CancelRecovery(aliceTokenId);
        nameRegistry.cancelRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);

        // 4. after escrow period, bob tries to recover to charlie and fails
        vm.warp(block.timestamp + ESCROW_PERIOD);
        vm.expectRevert(NameRegistry.NoRecovery.selector);
        nameRegistry.completeRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        vm.stopPrank();
    }

    function testCancelRecoveryIfPaused(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice and sets bob as her recovery address and @bob requests a recovery, after which
        // the owner pauses the contract
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);
        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);
        vm.prank(owner);
        nameRegistry.pause();

        // 2. alice cancels the recovery, which succeeds
        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit CancelRecovery(aliceTokenId);
        nameRegistry.cancelRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
    }

    function testCannotCancelRecoveryIfNotStarted(address alice, address bob) public {
        // 1. alice registers @alice and sets bob as her recovery address
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.startPrank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. alice cancels the recovery which fails
        vm.expectRevert(NameRegistry.NoRecovery.selector);
        nameRegistry.cancelRecovery(aliceTokenId);
        vm.stopPrank();

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
    }

    function testCannotCancelRecoveryIfUnauthorized(
        address alice,
        address bob,
        address charlie
    ) public {
        // 1. alice registers @alice and sets bob as her recovery address
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        vm.assume(charlie != bob);
        vm.assume(charlie != alice);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        // 2. bob requests a recovery of @alice to charlie
        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        // 3. charlie cancels the recovery which fails
        vm.prank(charlie);
        vm.expectRevert(NameRegistry.Unauthorized.selector);
        nameRegistry.cancelRecovery(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                           OWNER ACTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testReclaimRegisteredNames(address alice) public {
        _assumeClean(alice);
        _register(alice);

        vm.expectEmit(true, true, true, false);
        emit Transfer(alice, vault, aliceTokenId);
        vm.prank(owner);
        nameRegistry.reclaim(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), vault);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
    }

    function testReclaimRenewableNames(address alice) public {
        _assumeClean(alice);
        _register(alice);

        vm.warp(aliceRenewableTs);
        vm.expectEmit(true, true, true, false);
        emit Transfer(alice, vault, aliceTokenId);
        vm.prank(owner);
        nameRegistry.reclaim(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), vault);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
    }

    function testReclaimBiddableNames(address alice) public {
        _assumeClean(alice);
        _register(alice);

        vm.warp(aliceBiddableTs);
        vm.expectEmit(true, true, true, false);
        emit Transfer(alice, vault, aliceTokenId);
        vm.prank(owner);
        nameRegistry.reclaim(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), vault);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2024);
    }

    function testReclaimResetsERC721Approvals(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        _register(alice);

        vm.prank(alice);
        nameRegistry.approve(bob, aliceTokenId);

        vm.prank(owner);
        nameRegistry.reclaim(aliceTokenId);

        assertEq(nameRegistry.getApproved(aliceTokenId), address(0));
    }

    function testCannotReclaimUnlessMinted() public {
        vm.expectRevert(NameRegistry.Registrable.selector);
        vm.prank(owner);
        nameRegistry.reclaim(aliceTokenId);
    }

    function testReclaimResetsRecoveryState(
        address alice,
        address bob,
        address charlie
    ) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != bob);
        vm.assume(charlie != zeroAddress);
        _register(alice);

        vm.prank(alice);
        nameRegistry.changeRecoveryAddress(aliceTokenId, bob);

        vm.prank(bob);
        nameRegistry.requestRecovery(aliceTokenId, alice, charlie);

        vm.prank(owner);
        nameRegistry.reclaim(aliceTokenId);

        assertEq(nameRegistry.ownerOf(aliceTokenId), vault);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
        assertEq(nameRegistry.recoveryOf(aliceTokenId), address(0));
        assertEq(nameRegistry.recoveryClockOf(aliceTokenId), 0);
    }

    function testReclaimWhenPaused(address alice) public {
        _assumeClean(alice);
        _register(alice);

        vm.startPrank(owner);
        nameRegistry.pause();

        vm.expectRevert("Pausable: paused");
        nameRegistry.reclaim(aliceTokenId);
        vm.stopPrank();

        assertEq(nameRegistry.ownerOf(aliceTokenId), alice);
        assertEq(nameRegistry.expiryOf(aliceTokenId), TS_2023);
    }

    function testSetTrustedSender(address alice) public {
        vm.assume(alice != nameRegistry.trustedSender());

        vm.prank(owner);
        nameRegistry.setTrustedSender(alice);
        assertEq(nameRegistry.trustedSender(), alice);
    }

    function testCannotSetTrustedSenderUnlessOwner(address alice, address bob) public {
        _assumeClean(alice);
        vm.assume(alice != owner);
        assertEq(nameRegistry.trustedSender(), zeroAddress);

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        nameRegistry.setTrustedSender(bob);
        assertEq(nameRegistry.trustedSender(), zeroAddress);
    }

    function testDisableTrustedSender() public {
        assertEq(nameRegistry.trustedRegisterEnabled(), true);

        vm.prank(owner);
        nameRegistry.disableTrustedRegister();
        assertEq(nameRegistry.trustedRegisterEnabled(), false);
    }

    function testCannotDisableTrustedSenderUnlessOwner(address alice) public {
        _assumeClean(alice);
        vm.assume(alice != owner);
        assertEq(nameRegistry.trustedRegisterEnabled(), true);

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        nameRegistry.disableTrustedRegister();
        assertEq(nameRegistry.trustedRegisterEnabled(), true);
    }

    function testTransferOwnership(address alice) public {
        _assumeClean(alice);
        vm.assume(alice != zeroAddress);
        assertEq(nameRegistry.owner(), owner);

        vm.prank(owner);
        nameRegistry.transferOwnership(alice);
        assertEq(nameRegistry.owner(), alice);
    }

    function testCannotTransferOwnershipUnlessOwner(address alice, address bob) public {
        _assumeClean(alice);
        _assumeClean(bob);
        vm.assume(alice != owner);
        assertEq(nameRegistry.owner(), owner);

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        nameRegistry.transferOwnership(bob);
        assertEq(nameRegistry.owner(), owner);
    }

    /*//////////////////////////////////////////////////////////////
                          YEARLY PAYMENTS TESTS
    //////////////////////////////////////////////////////////////*/

    function testCurrYear() public {
        // Incorrectly returns 2021 for any date before 2021
        vm.warp(1607558400); // GMT Thursday, December 10, 2020 0:00:00
        assertEq(nameRegistry.currYear(), 2021);

        // Works correctly for known year range [2021 - 2072]
        vm.warp(1640095200); // GMT Tuesday, December 21, 2021 14:00:00
        assertEq(nameRegistry.currYear(), 2021);

        vm.warp(1670889599); // GMT Monday, December 12, 2022 23:59:59
        assertEq(nameRegistry.currYear(), 2022);

        // Does not work after 2072
        vm.warp(3250454400); // GMT Friday, January 1, 2073 0:00:00
        vm.expectRevert(NameRegistry.InvalidTime.selector);
        assertEq(nameRegistry.currYear(), 0);
    }

    function testCurrYearFee() public {
        // fee = 0.1 ether
        vm.warp(1672531200); // GMT Friday, January 1, 2023 0:00:00
        assertEq(nameRegistry.currYearFee(), 0.01 ether);

        vm.warp(1688256000); // GMT Sunday, July 2, 2023 0:00:00
        assertEq(nameRegistry.currYearFee(), 0.005013698630136986 ether);

        vm.warp(1704023999); // GMT Friday, Dec 31, 2023 11:59:59
        assertEq(nameRegistry.currYearFee(), 0.000013698947234906 ether);

        // fee = 0.2 ether
        vm.prank(owner);
        nameRegistry.setFee(0.02 ether);

        vm.warp(1672531200); // GMT Friday, January 1, 2023 0:00:00
        assertEq(nameRegistry.currYearFee(), 0.02 ether);

        vm.warp(1688256000); // GMT Sunday, July 2, 2023 0:00:00
        assertEq(nameRegistry.currYearFee(), 0.010027397260273972 ether);

        vm.warp(1704023999); // GMT Friday, Dec 31, 2023 11:59:59
        assertEq(nameRegistry.currYearFee(), 0.000027397894469812 ether);

        // fee = 0 ether
        vm.prank(owner);
        nameRegistry.setFee(0 ether);

        vm.warp(1672531200); // GMT Friday, January 1, 2023 0:00:00
        assertEq(nameRegistry.currYearFee(), 0);

        vm.warp(1688256000); // GMT Sunday, July 2, 2023 0:00:00
        assertEq(nameRegistry.currYearFee(), 0);

        vm.warp(1704023999); // GMT Friday, Dec 31, 2023 11:59:59
        assertEq(nameRegistry.currYearFee(), 0);
    }

    function testSetFee() public {
        assertEq(nameRegistry.fee(), 0.01 ether);

        vm.prank(owner);
        nameRegistry.setFee(0.02 ether);

        assertEq(nameRegistry.fee(), 0.02 ether);
    }

    function testCannotSetFeeUnlessOwner(address alice2) public {
        vm.assume(alice2 != trustedForwarder);
        vm.assume(alice2 != owner);

        vm.prank(alice2);
        vm.expectRevert("Ownable: caller is not the owner");
        nameRegistry.setFee(0.02 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    // Given an address, funds it with ETH, warps to a registration period and registers the username @alice
    function _register(address alice) internal {
        _disableTrusted();

        vm.deal(alice, 10_000 ether);
        vm.warp(aliceRegisterTs);

        vm.startPrank(alice);
        bytes32 commitHash = nameRegistry.generateCommit("alice", alice, "secret");
        nameRegistry.makeCommit(commitHash);
        vm.warp(block.timestamp + COMMIT_REGISTER_DELAY);

        nameRegistry.register{value: nameRegistry.fee()}("alice", alice, "secret", zeroAddress);
        vm.stopPrank();
    }

    // Ensures that a given fuzzed address does not match known contracts
    function _assumeClean(address a) internal {
        for (uint256 i = 0; i < knownContracts.length; i++) {
            vm.assume(a != knownContracts[i]);
        }

        vm.assume(a > PRECOMPILE_CONTRACTS);
    }

    function _disableTrusted() internal {
        vm.prank(owner);
        nameRegistry.disableTrustedRegister();
    }
}