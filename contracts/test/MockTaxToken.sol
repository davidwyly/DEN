// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Mock ERC20 with a configurable transfer tax.
 *      On every transfer/transferFrom, `taxBps` basis points are burned (removed from circulation).
 *      This simulates fee-on-transfer tokens like SafeMoon, SHIB-derivatives, etc.
 */
contract MockTaxToken is ERC20 {
    uint256 public taxBps; // tax in basis points (e.g., 500 = 5%)
    address public taxReceiver; // where tax goes (address(0) = burn)

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _taxBps,
        uint256 _initialSupply
    ) ERC20(_name, _symbol) {
        taxBps = _taxBps;
        _mint(msg.sender, _initialSupply);
    }

    function setTaxBps(uint256 _taxBps) external {
        taxBps = _taxBps;
    }

    function setTaxReceiver(address _receiver) external {
        taxReceiver = _receiver;
    }

    function _update(address from, address to, uint256 amount) internal override {
        // No tax on mints or burns
        if (from == address(0) || to == address(0) || taxBps == 0) {
            super._update(from, to, amount);
            return;
        }

        uint256 taxAmount = (amount * taxBps) / 10000;
        uint256 sendAmount = amount - taxAmount;

        if (taxReceiver == address(0)) {
            // Burn the tax
            super._update(from, address(0), taxAmount);
        } else {
            // Send tax to receiver
            super._update(from, taxReceiver, taxAmount);
        }
        super._update(from, to, sendAmount);
    }
}
