pragma solidity =0.6.6;

import '../../swap-contracts-core/contracts/interfaces/ICroDefiSwapCallee.sol';

import '../libraries/CroDefiSwapLibrary.sol';
import '../interfaces/V1/ICroDefiSwapV1Factory.sol';
import '../interfaces/V1/ICroDefiSwapV1Exchange.sol';
import '../interfaces/ICroDefiSwapRouter01.sol';
import '../interfaces/IERC20.sol';
import '../interfaces/IWETH.sol';

contract ExampleFlashSwap is ICroDefiSwapCallee {
    ICroDefiSwapV1Factory immutable factoryV1;
    address immutable factory;
    IWETH immutable WETH;

    constructor(address _factory, address _factoryV1, address router) public {
        factoryV1 = ICroDefiSwapV1Factory(_factoryV1);
        factory = _factory;
        WETH = IWETH(ICroDefiSwapRouter01(router).WETH());
    }

    // needs to accept ETH from any V1 exchange and WETH. ideally this could be enforced, as in the router,
    // but it's not possible because it requires a call to the v1 factory, which takes too much gas
    receive() external payable {}

    // gets tokens/WETH via a V2 flash swap, swaps for the ETH/tokens on V1, repays V2, and keeps the rest!
    function croDefiSwapCall(address sender, uint amount0, uint amount1, bytes calldata data) external override {
        address[] memory path = new address[](2);
        uint amountToken;
        uint amountETH;
        { // scope for token{0,1}, avoids stack too deep errors
        address token0 = ICroDefiSwapPair(msg.sender).token0();
        address token1 = ICroDefiSwapPair(msg.sender).token1();
        assert(msg.sender == CroDefiSwapLibrary.pairFor(factory, token0, token1)); // ensure that msg.sender is actually a V2 pair
        assert(amount0 == 0 || amount1 == 0); // this strategy is unidirectional
        path[0] = amount0 == 0 ? token0 : token1;
        path[1] = amount0 == 0 ? token1 : token0;
        amountToken = token0 == address(WETH) ? amount1 : amount0;
        amountETH = token0 == address(WETH) ? amount0 : amount1;
        }

        assert(path[0] == address(WETH) || path[1] == address(WETH)); // this strategy only works with a V2 WETH pair
        IERC20 token = IERC20(path[0] == address(WETH) ? path[1] : path[0]);
        ICroDefiSwapV1Exchange exchangeV1 = ICroDefiSwapV1Exchange(factoryV1.getExchange(address(token))); // get V1 exchange

        if (amountToken > 0) {
            (uint minETH) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            token.approve(address(exchangeV1), amountToken);
            uint amountReceived = exchangeV1.tokenToEthSwapInput(amountToken, minETH, uint(-1));
            uint amountRequired = CroDefiSwapLibrary.getAmountsIn(factory, amountToken, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough ETH back to repay our flash loan
            WETH.deposit{value: amountRequired}();
            assert(WETH.transfer(msg.sender, amountRequired)); // return WETH to V2 pair
            (bool success,) = sender.call{value: amountReceived - amountRequired}(new bytes(0)); // keep the rest! (ETH)
            assert(success);
        } else {
            (uint minTokens) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            WETH.withdraw(amountETH);
            uint amountReceived = exchangeV1.ethToTokenSwapInput{value: amountETH}(minTokens, uint(-1));
            uint amountRequired = CroDefiSwapLibrary.getAmountsIn(factory, amountETH, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough tokens back to repay our flash loan
            assert(token.transfer(msg.sender, amountRequired)); // return tokens to V2 pair
            assert(token.transfer(sender, amountReceived - amountRequired)); // keep the rest! (tokens)
        }
    }
}
