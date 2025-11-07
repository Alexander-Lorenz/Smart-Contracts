// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Wind Oracle (push model from Python)
/// @notice Store latest wind readings per location key (e.g., keccak("Miami,US")).
/// Units:
/// - speedX100, gustX100: meters/second * 100 (e.g., 12.34 m/s -> 1234)
/// - directionDeg: degrees [0..359], use -1 if unknown.
/// Timestamps are block.timestamp of the write.


// Minimal interface so the oracle can call the bond
interface IOraclePushReceiver {
    function oraclePushWind(
        bytes32 locationId,
        uint64 speedX100,
        uint64 gustX100,
        int16  directionDeg,
        uint64 updatedAt,
        address updater
    ) external;
}


contract WindOracle {
    struct WindReading {
        uint64 speedX100;      // m/s * 100
        uint64 gustX100;       // m/s * 100
        int16  directionDeg;   // 0..359, -1 if unknown
        uint64 updatedAt;      // unix epoch seconds
        address updater;       // who wrote the reading
    }

    address public owner;
    mapping(address => bool) public isUpdater;
    mapping(bytes32 => WindReading) private _readings;

    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event UpdaterSet(address indexed updater, bool allowed);
    event WindSet(
        bytes32 indexed locationId,
        uint64 speedX100,
        uint64 gustX100,
        int16 directionDeg,
        uint64 updatedAt,
        address indexed updater
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyUpdater() {
        require(isUpdater[msg.sender], "not updater");
        _;
    }

    constructor() {
        owner = msg.sender;
        isUpdater[msg.sender] = true; // deployer is updater by default
        emit UpdaterSet(msg.sender, true);
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero addr");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Grant/revoke write access for a wallet your Python code uses.
    function setUpdater(address updater, bool allowed) external onlyOwner {
        isUpdater[updater] = allowed;
        emit UpdaterSet(updater, allowed);
    }

    /// @notice Set the latest wind reading for a location.
    /// @param locationId bytes32 key, e.g., keccak256("Miami,US")
    /// @param speedX100 m/s * 100
    /// @param gustX100  m/s * 100
    /// @param directionDeg degrees [0..359], or -1 if unknown
// Add this inside WindOracle

function _setWind(
    bytes32 locationId,
    uint64 speedX100,
    uint64 gustX100,
    int16  directionDeg
) internal {
    WindReading memory wr = WindReading({
        speedX100: speedX100,
        gustX100:  gustX100,
        directionDeg: directionDeg,
        updatedAt: uint64(block.timestamp),
        updater: msg.sender
    });
    _readings[locationId] = wr;
    emit WindSet(locationId, speedX100, gustX100, directionDeg, wr.updatedAt, msg.sender);
}

function setWind(
    bytes32 locationId,
    uint64 speedX100,
    uint64 gustX100,
    int16  directionDeg
) external onlyUpdater {
    _setWind(locationId, speedX100, gustX100, directionDeg);
}

// keep your interface IOraclePushReceiver as shown earlier
function setWindAndPush(
    bytes32 locationId,
    uint64 speedX100,
    uint64 gustX100,
    int16  directionDeg,
    address bond
) external onlyUpdater {
    _setWind(locationId, speedX100, gustX100, directionDeg);
    WindReading memory wr = _readings[locationId];
    IOraclePushReceiver(bond).oraclePushWind(
        locationId, wr.speedX100, wr.gustX100, wr.directionDeg, wr.updatedAt, wr.updater
    );
}



    /// @notice Get the latest reading for a location.
    function getWind(bytes32 locationId)
        external
        view
        returns (uint64 speedX100, uint64 gustX100, int16 directionDeg, uint64 updatedAt, address updater)
    {
        WindReading memory wr = _readings[locationId];
        return (wr.speedX100, wr.gustX100, wr.directionDeg, wr.updatedAt, wr.updater);
    }

    event WindPushed(address indexed bond, bytes32 indexed locationId, uint64 updatedAt);

/// @notice Read the stored wind reading and push it to a CatBond.
/// @dev Uses the current on-chain snapshot; does NOT fetch from the web.
///      Gated by onlyUpdater to avoid spam; the bond also checks msg.sender==oracle.
function getWindAndPush(address bond, bytes32 locationId) external onlyUpdater {
    WindReading memory wr = _readings[locationId];
    require(wr.updatedAt != 0, "no data");
    IOraclePushReceiver(bond).oraclePushWind(
        locationId,
        wr.speedX100,
        wr.gustX100,
        wr.directionDeg,
        wr.updatedAt,
        wr.updater
    );
    emit WindPushed(bond, locationId, wr.updatedAt);
}

}
