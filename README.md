# Uniswap V4 sample implementation repo

This project demonstrate some of the features enabled by Uniswap V4 Hook.

- Private Pool liquidity (all fee generated to single position|single person)
- Edit swap input, output internally. It is possible to take fee on output token instead of input
- Support ExactOutput with fee on output token.

Eg: Pool USDC/DOGE only take $DOGE token as fee whether it is input|output token. This is a new feature not possible with V3.

One of major problem, Hook is not standalone implementation.
Edit swap balance require Hook contract to manually resolve its own balance. Which require user to manually call Hook contract directly.

In this project, `Hook.sol` contract require router call an extra step `donate()` zero donation during multicall to force Hook resolve its problem.

Depends on Uniswap Periphery future implementation, it is unclear how normal user can interact with custom Uniswap V4 pool through Uniswap main website.
