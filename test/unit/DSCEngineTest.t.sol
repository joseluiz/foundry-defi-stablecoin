//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console2} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeedAddress;
    address btcUsdPriceFeedAddress;
    address weth;
    address wbtc;

    address public USER = makeAddr("USER");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeedAddress, btcUsdPriceFeedAddress, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function test_RevertIfTokenLengthDoesNotMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeedAddress);
        priceFeedAddresses.push(btcUsdPriceFeedAddress);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsce));
    }

    function test_GetTokenAmountFromDsc() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    function test_getUsdValue() public view {
        uint256 ethAmount = 15 ether;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function test_revertIfCollateralIsZero() public {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_revertIfNotApprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector));
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function test_depositCollateralAndGetAccountInformation() public depositCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    function test_CanDepositCollateralAndMintDsc() public depositCollateral {
        vm.startPrank(USER);
        uint256 amountToMint = 100 ether;
        dsce.mintDsc(amountToMint);

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);
        vm.stopPrank();
    }

    function test_RevertMintDscIfBreaksHealthFactor() public depositCollateral {
        // Trying to mint more than the collateral value
        vm.startPrank(USER);
        uint256 amountToMint = 30000 ether; // Way too much DSC
        uint256 expectedHealthFactor = 333333333333333333;
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function test_CanBurnDsc() public {
        // First mint some DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 100 ether);
        dsc.approve(address(dsce), 50 ether);
        dsce.burnDsc(50 ether);

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 50 ether);
        vm.stopPrank();
    }

    function test_CanRedeemCollateral() public depositCollateral {
        vm.startPrank(USER);

        // Get balance before redemption
        uint256 balanceBefore = ERC20Mock(weth).balanceOf(USER);

        // Redeem collateral
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);

        // Get balance after redemption
        uint256 balanceAfter = ERC20Mock(weth).balanceOf(USER);

        // Assert that the difference is exactly AMOUNT_COLLATERAL
        assertEq(balanceAfter - balanceBefore, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function test_RevertRedeemCollateralIfBreaksHealthFactor() public {
        // Setup: deposit collateral and mint DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 100 ether);

        // Try to redeem all collateral while having DSC minted
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function test_CanRedeemCollateralForDsc() public {
        // Setup: deposit collateral and mint DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 100 ether);

        // Approve DSC for burning
        dsc.approve(address(dsce), 100 ether);

        // Redeem collateral and burn DSC
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, 100 ether);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
        vm.stopPrank();
    }

    function test_LiquidationFailsIfHealthFactorOk() public depositCollateral {
        // Setup a user with good health factor
        vm.startPrank(USER);
        dsce.mintDsc(100 ether); // Small amount compared to collateral

        // Try to liquidate
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dsce.liquidate(weth, USER, 100 ether);
        vm.stopPrank();
    }

    function testFuzz_DepositCollateralAndMintDsc(uint256 amountCollateral, uint256 amountToMint) public {
        // Assume reasonable amounts
        vm.assume(amountCollateral > 0 && amountCollateral < 1000e18);
        vm.assume(amountToMint > 0 && amountToMint < 1000e18);

        // Calculate collateral value in USD
        uint256 collateralValueInUsd = dsce.getUsdValue(weth, amountCollateral);

        // Ensure amountToMint is less than 50% of collateral value (200% overcollateralization)
        vm.assume(amountToMint <= (collateralValueInUsd * 50) / 100);

        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, amountCollateral);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);

        dsce.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);

        // Verify the health factor is maintained
        uint256 healthFactor = dsce.getHelthFactor(USER);
        assertGe(healthFactor, 1e18); // Health factor should be >= 1
        vm.stopPrank();
    }
}
