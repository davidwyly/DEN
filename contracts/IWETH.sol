// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IWETH {
    function flashMinted() external view returns(uint256);
    function decimals() external view returns(uint8);
    function deposit() external payable;
    function depositTo(address to) external payable;
    function withdraw(uint256 value) external;
    function withdrawTo(address payable to, uint256 value) external;
    function withdrawFrom(address from, address payable to, uint256 value) external;
    function depositToAndCall(address to, bytes calldata data) external payable returns (bool);
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
    function transferAndCall(address to, uint value, bytes calldata data) external returns (bool);
}