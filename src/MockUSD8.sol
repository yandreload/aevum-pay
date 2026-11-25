// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Test-only stand-in for the real tUSD8: an ERC-20 with 6 decimals,
/// EIP-2612 permit and EIP-3009 receiveWithAuthorization, mirroring the real
/// token's interface. Never deployed to Aevum testnet — the real tUSD8 at
/// 0x456569838f1d43009A91ebA4263147Afd7233483 is used there.
contract MockUSD8 is ERC20, ERC20Permit {
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    constructor() ERC20("MockUSD8", "MUSD8") ERC20Permit("MockUSD8") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice EIP-3009: `from` authorizes `to` to receive `value` via a
    /// signed message. Callable by anyone; the signature is what matters.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(validAfter <= block.timestamp, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationState[from][nonce], "authorization already used");
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == from, "invalid signature");
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }
}
