// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {FeeMath} from "../shared/FeeMath.sol";
import {PositionConfig} from "../../../src/pool-cl/libraries/PositionConfig.sol";
import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";

contract FeeCollectionTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using FeeMath for ICLPositionManager;

    IVault vault;
    ICLPoolManager manager;

    PoolId poolId;
    PoolKey key;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    // expresses the fee as a wad (i.e. 3000 = 0.003e18)
    uint256 FEE_WAD;

    function setUp() public {
        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (vault, manager, key, poolId) = createFreshPool(IHooks(address(hook)), 3000, SQRT_RATIO_1_1, ZERO_BYTES);
        currency0 = key.currency0;
        currency1 = key.currency1;

        deployAndApproveRouter(vault, manager);

        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(vault, manager);

        // Give tokens to Alice and Bob.
        seedBalance(alice);
        seedBalance(bob);

        // Approve posm for Alice and bob.
        approvePosmFor(alice);
        approvePosmFor(bob);
    }

    // asserts that donations agree with feesOwed helper function
    function test_fuzz_getFeesOwed_donate(uint256 feeRevenue0, uint256 feeRevenue1) public {
        feeRevenue0 = bound(feeRevenue0, 0, 100_000_000 ether);
        feeRevenue1 = bound(feeRevenue1, 0, 100_000_000 ether);

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10e18, address(this), ZERO_BYTES);

        // donate to generate fee revenue
        router.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        BalanceDelta expectedFees = ICLPositionManager(address(lpm)).getFeesOwed(manager, config, tokenId);
        assertApproxEqAbs(uint128(expectedFees.amount0()), feeRevenue0, 1 wei); // imprecision 😅
        assertApproxEqAbs(uint128(expectedFees.amount1()), feeRevenue1, 1 wei);
    }

    function test_fuzz_collect_erc20(ICLPoolManager.ModifyLiquidityParams memory params) public {
        params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
        uint256 tokenId;
        (tokenId, params) = addFuzzyTwoSidedLiquidity(lpm, address(this), key, params, SQRT_RATIO_1_1, ZERO_BYTES);

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, -int256(swapAmount), ZERO_BYTES);

        BalanceDelta expectedFees = ICLPositionManager(address(lpm)).getFeesOwed(manager, config, tokenId);

        // collect fees
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        collect(tokenId, config, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        assertApproxEqAbs(uint256(int256(delta.amount1())), swapAmount.mulWadDown(FEE_WAD), 1 wei);
        assertEq(uint256(int256(delta.amount1())), uint256(int256(expectedFees.amount1())));
        assertEq(uint256(int256(delta.amount0())), uint256(int256(expectedFees.amount0())));

        assertEq(uint256(int256(delta.amount0())), currency0.balanceOfSelf() - balance0Before);
        assertEq(uint256(int256(delta.amount1())), currency1.balanceOfSelf() - balance1Before);
    }

    function test_fuzz_collect_sameRange_erc20(
        ICLPoolManager.ModifyLiquidityParams memory params,
        uint256 liquidityDeltaBob
    ) public {
        params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
        params = createFuzzyTwoSidedLiquidityParams(key, params, SQRT_RATIO_1_1);

        liquidityDeltaBob = bound(liquidityDeltaBob, 100e18, 100_000e18);

        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, uint256(params.liquidityDelta), alice, ZERO_BYTES);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 tokenIdBob = lpm.nextTokenId();
        mint(config, liquidityDeltaBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // confirm the positions are same range
        // (, int24 tickLowerAlice, int24 tickUpperAlice) = lpm.tokenRange(tokenIdAlice);
        // (, int24 tickLowerBob, int24 tickUpperBob) = lpm.tokenRange(tokenIdBob);
        // assertEq(tickLowerAlice, tickLowerBob);
        // assertEq(tickUpperAlice, tickUpperBob);

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, -int256(swapAmount), ZERO_BYTES);

        // alice collects only her fees
        uint256 balance0AliceBefore = currency0.balanceOf(alice);
        uint256 balance1AliceBefore = currency1.balanceOf(alice);
        vm.startPrank(alice);
        collect(tokenIdAlice, config, ZERO_BYTES);
        vm.stopPrank();
        BalanceDelta delta = getLastDelta();
        uint256 balance0AliceAfter = currency0.balanceOf(alice);
        uint256 balance1AliceAfter = currency1.balanceOf(alice);

        assertEq(balance0AliceBefore, balance0AliceAfter);
        assertEq(uint256(uint128(delta.amount1())), balance1AliceAfter - balance1AliceBefore);
        assertTrue(delta.amount1() != 0);

        // bob collects only his fees
        uint256 balance0BobBefore = currency0.balanceOf(bob);
        uint256 balance1BobBefore = currency1.balanceOf(bob);
        vm.startPrank(bob);
        collect(tokenIdBob, config, ZERO_BYTES);
        vm.stopPrank();
        delta = getLastDelta();
        uint256 balance0BobAfter = currency0.balanceOf(bob);
        uint256 balance1BobAfter = currency1.balanceOf(bob);

        assertEq(balance0BobBefore, balance0BobAfter);
        assertEq(uint256(uint128(delta.amount1())), balance1BobAfter - balance1BobBefore);
        assertTrue(delta.amount1() != 0);

        // position manager should never hold fees
        assertEq(vault.balanceOf(address(lpm), currency0), 0);
        assertEq(vault.balanceOf(address(lpm), currency1), 0);
    }

    function test_collect_donate() public {
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, 10e18, address(this), ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue = 1e18;
        router.donate(key, feeRevenue, feeRevenue, ZERO_BYTES);

        BalanceDelta expectedFees = ICLPositionManager(address(lpm)).getFeesOwed(manager, config, tokenId);

        // collect fees
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        collect(tokenId, config, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        assertApproxEqAbs(uint256(int256(delta.amount0())), feeRevenue, 1 wei);
        assertApproxEqAbs(uint256(int256(delta.amount1())), feeRevenue, 1 wei);
        assertEq(delta.amount0(), expectedFees.amount0());
        assertEq(delta.amount1(), expectedFees.amount1());

        assertEq(balance0Before + uint256(uint128(delta.amount0())), currency0.balanceOfSelf());
        assertEq(balance1Before + uint256(uint128(delta.amount1())), currency1.balanceOfSelf());
    }

    function test_collect_donate_sameRange() public {
        // alice and bob create liquidity on the same range [-120, 120]
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        // alice provisions 3x the amount of liquidity as bob
        uint256 liquidityAlice = 3000e18;
        uint256 liquidityBob = 1000e18;

        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 tokenIdBob = lpm.nextTokenId();
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        router.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        {
            // alice collects her share
            BalanceDelta expectedFeesAlice = ICLPositionManager(address(lpm)).getFeesOwed(manager, config, tokenIdAlice);
            assertApproxEqAbs(
                uint128(expectedFeesAlice.amount0()),
                feeRevenue0.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob),
                1 wei
            );
            assertApproxEqAbs(
                uint128(expectedFeesAlice.amount1()),
                feeRevenue1.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob),
                1 wei
            );

            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            collect(tokenIdAlice, config, ZERO_BYTES);
            BalanceDelta deltaAlice = getLastDelta();
            vm.stopPrank();

            assertEq(deltaAlice.amount0(), expectedFeesAlice.amount0());
            assertEq(deltaAlice.amount1(), expectedFeesAlice.amount1());
            assertEq(currency0.balanceOf(alice), balance0BeforeAlice + uint256(uint128(expectedFeesAlice.amount0())));
            assertEq(currency1.balanceOf(alice), balance1BeforeAlice + uint256(uint128(expectedFeesAlice.amount1())));
        }

        {
            // bob collects his share
            BalanceDelta expectedFeesBob = ICLPositionManager(address(lpm)).getFeesOwed(manager, config, tokenIdBob);
            assertApproxEqAbs(
                uint128(expectedFeesBob.amount0()),
                feeRevenue0.mulDivDown(liquidityBob, liquidityAlice + liquidityBob),
                1 wei
            );
            assertApproxEqAbs(
                uint128(expectedFeesBob.amount1()),
                feeRevenue1.mulDivDown(liquidityBob, liquidityAlice + liquidityBob),
                1 wei
            );

            uint256 balance0BeforeBob = currency0.balanceOf(bob);
            uint256 balance1BeforeBob = currency1.balanceOf(bob);
            vm.startPrank(bob);
            collect(tokenIdBob, config, ZERO_BYTES);
            BalanceDelta deltaBob = getLastDelta();
            vm.stopPrank();

            assertEq(deltaBob.amount0(), expectedFeesBob.amount0());
            assertEq(deltaBob.amount1(), expectedFeesBob.amount1());
            assertEq(currency0.balanceOf(bob), balance0BeforeBob + uint256(uint128(expectedFeesBob.amount0())));
            assertEq(currency1.balanceOf(bob), balance1BeforeBob + uint256(uint128(expectedFeesBob.amount1())));
        }
    }

    /// @dev Alice and Bob create liquidity on the same config, and decrease their liquidity
    // Even though their positions are the same config, they are unique positions in pool manager.
    function test_decreaseLiquidity_sameRange_exact() public {
        // alice and bob create liquidity on the same range [-120, 120]
        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        // alice provisions 3x the amount of liquidity as bob
        uint256 liquidityAlice = 3000e18;
        uint256 liquidityBob = 1000e18;

        uint256 tokenIdAlice = lpm.nextTokenId();
        vm.startPrank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        BalanceDelta lpDeltaAlice = getLastDelta();

        uint256 tokenIdBob = lpm.nextTokenId();
        vm.startPrank(bob);
        mint(config, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();
        BalanceDelta lpDeltaBob = getLastDelta();

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES); // zeroForOne is true, so zero is the input
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back, // zeroForOne is false, so one is the input

        uint256 tolerance = 0.000000001 ether;

        {
            uint256 aliceBalance0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(alice));
            uint256 aliceBalance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(alice));
            // alice decreases liquidity
            vm.startPrank(alice);
            decreaseLiquidity(tokenIdAlice, config, liquidityAlice, ZERO_BYTES);
            vm.stopPrank();

            // alice has accrued her principle liquidity + any fees in token0
            assertApproxEqAbs(
                IERC20(Currency.unwrap(currency0)).balanceOf(address(alice)) - aliceBalance0Before,
                uint256(int256(-lpDeltaAlice.amount0()))
                    + swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, liquidityAlice + liquidityBob),
                tolerance
            );
            // alice has accrued her principle liquidity + any fees in token1
            assertApproxEqAbs(
                IERC20(Currency.unwrap(currency1)).balanceOf(address(alice)) - aliceBalance1Before,
                uint256(int256(-lpDeltaAlice.amount1()))
                    + swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityAlice, liquidityAlice + liquidityBob),
                tolerance
            );
        }

        {
            uint256 bobBalance0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(bob));
            uint256 bobBalance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(bob));
            // bob decreases half of his liquidity
            vm.startPrank(bob);
            decreaseLiquidity(tokenIdBob, config, liquidityBob / 2, ZERO_BYTES);
            vm.stopPrank();

            // bob has accrued half his principle liquidity + any fees in token0
            assertApproxEqAbs(
                IERC20(Currency.unwrap(currency0)).balanceOf(address(bob)) - bobBalance0Before,
                uint256(int256(-lpDeltaBob.amount0()) / 2)
                    + swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, liquidityAlice + liquidityBob),
                tolerance
            );
            // bob has accrued half his principle liquidity + any fees in token0
            assertApproxEqAbs(
                IERC20(Currency.unwrap(currency1)).balanceOf(address(bob)) - bobBalance1Before,
                uint256(int256(-lpDeltaBob.amount1()) / 2)
                    + swapAmount.mulWadDown(FEE_WAD).mulDivDown(liquidityBob, liquidityAlice + liquidityBob),
                tolerance
            );
        }
    }
}