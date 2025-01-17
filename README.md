## Decentralized Exchange Network (Smart Contracts)

This repository contains the smart contracts for the Decentralized Exchange Network project for the Eclipse DAO (the system), to be used by the All For One mobile application (the partner).

## Features

Facilitates trading of ERC20 tokens on EVM-compatible blockchains, with the following features:
- Taxation on trades, collected in the native token of the blockchain
    - Fees for the system (Eclipse DAO), typically a static 0.15% fee
    - Fees for the partner (All For One), a dynamic fee based on application logic
- Fees are collected on every trade, both buys and sells
- Support for v2 and v3 of the Uniswap protocol
- Support for some v3 forks of Uniswap, including:
    - PancakeSwap
    - SushiSwap
    - QuickSwap/Algebra
    - FusionX
    - Beamswap
    - Kyberswap

## Limitations

- Must have an awareness of the liquidity pool address for a given token pair
- Must explicitly add Uniswap v3 forks to the list of supported protocols in the DexCallbackHandler contract (only if they changed the name of the swap callback function)
- Only supports ERC20 tokens
- Only supports EVM-compatible blockchains
- Only supports Uniswap v2/v3 and some Uniswap v2 and v3 forks

## Credit

David Wyly (main author)
DeFi Mark (contributor)
