// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {SafeCastLibrary} from "./SafeCastLibrary.sol";
import {Checkpoints} from "./Checkpoints.sol";
import {Time} from "./Time.sol";

/**
 * @title CheckPointSystem
 * @dev This contract is used to manage checkpoints in the system.
 */
library EscrowDelegateCheckpoints {
    using Checkpoints for Checkpoints.Trace;
    using Checkpoints for Checkpoints.TraceAddress;
    using SafeCastLibrary for int128;
    using SafeCastLibrary for uint256;

    /// @notice Maximum time for a checkpoint
    int128 public constant MAX_TIME = 2 * 365 * 86400;
    /// @notice Unit of time for the clock
    uint48 public constant CLOCK_UNIT = 7 days;

    struct EscrowDelegateStore {
        /// @notice Global checkpoints
        Checkpoints.Trace _globalCheckpoints;
        /// @notice Mapping of global slope changes
        /// @dev Intended to be exposed with a getter
        mapping(uint256 timestamp => int128 slopeChange) globalSlopeChanges;
        /// @notice escrow lock checkpoints
        mapping(uint256 escrowId => Checkpoints.Trace) _escrowCheckpoints;
        /// @notice Delegate checkpoints
        mapping(address delegatee => Checkpoints.Trace) _delegateCheckpoints;
        /// @notice escrow lock to delegatee mapping
        mapping(uint256 escrowId => Checkpoints.TraceAddress) _escrowDelegateeAddress;
        /// @notice Delegatee slope changes
        /// @dev Intended to be exposed with a getter
        mapping(address delegatee => mapping(uint256 timestamp => int128 slopeChange)) delegateeSlopeChanges;
    }

    event CheckpointGlobal(uint48 timestamp, int128 slope, int128 bias, int128 permanent);
    event CheckpointDelegate(address delegatee, uint48 timestamp, int128 slope, int128 bias, int128 permanent);
    event CheckpointEscrow(uint256 escrowId, uint48 timestamp, int128 slope, int128 bias, int128 permanent);

    /**
     * @notice Clock used for flagging checkpoints.
     * @return Current timestamp
     */
    function clock() public view returns (uint48) {
        return Time.timestamp();
    }

    /**
     * @notice Clock used for flagging global checkpoints.
     * @return Current timestamp rounded to the nearest clock unit
     */
    function globalClock() public view returns (uint48) {
        return toGlobalClock(Time.timestamp());
    }

    /**
     * @notice Converts a timestamp to a global clock value.
     * @param timestamp The timestamp to convert
     * @return The converted global clock value
     */
    function toGlobalClock(uint256 timestamp) internal pure returns (uint48) {
        return uint48((timestamp / CLOCK_UNIT) * CLOCK_UNIT);
    }

    /**
     * @dev Record global and per-escrow data to checkpoints. Used by VotingEscrow system.
     * @param store_ The EscrowDelegateStore struct containing all the storage mappings.
     * @param escrowId NFT escrow lock ID. No escrow checkpoint if 0
     * @param uOldAmount Locked amount from last checkpoint
     * @param uNewAmount Locked amount from current checkpoint
     * @param uOldEndTime Last checkpoint time
     * @param uNewEndTime Current checkpoint time
     */
    function checkpoint(
        EscrowDelegateStore storage store_,
        uint256 escrowId,
        int128 uOldAmount,
        int128 uNewAmount,
        uint256 uOldEndTime,
        uint256 uNewEndTime
    ) external {
        int128 oldDslope = 0;
        int128 newDslope = 0;
        Checkpoints.Point memory uOldPoint = Checkpoints.blankPoint();
        Checkpoints.Point memory uNewPoint = Checkpoints.blankPoint();
        /// @notice if this is not rounded to CLOCK_UNIT
        /// the system will not be able to go too long without checkpoints
        uNewEndTime = toGlobalClock(uNewEndTime);
        if (escrowId != 0) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            uNewPoint.permanent = uNewEndTime == 0 ? uNewAmount : int128(0);
            uOldPoint.permanent = uOldEndTime == 0 ? uOldAmount : int128(0);
            if (uOldEndTime > block.timestamp && uOldAmount > 0) {
                /// @dev  Calculate the slope based on the older checkpoint amount
                uOldPoint.slope = (uOldAmount) / MAX_TIME;
                uOldPoint.bias = (uOldPoint.slope * (uOldEndTime - block.timestamp).toInt128());
            }
            if (uNewEndTime > block.timestamp && uNewAmount > 0) {
                uNewPoint.slope = (uNewAmount) / MAX_TIME;
                uNewPoint.bias = (uNewPoint.slope * (uNewEndTime - block.timestamp).toInt128());
            }
            oldDslope = store_.globalSlopeChanges[uOldEndTime];
            if (uNewEndTime != 0) {
                if (uNewEndTime == uOldEndTime) {
                    newDslope = oldDslope;
                } else {
                    newDslope = store_.globalSlopeChanges[uNewEndTime];
                }
            }

            // Schedule the slope changes (slope is going down)
            // We subtract new escrow slope from [_newLocked.endTime]
            // and add old_escrow_slope to [_oldLocked.end]
            if (uOldEndTime > block.timestamp) {
                // oldDslope was <something> - uOld.slope, so we cancel that
                oldDslope += uOldPoint.slope;
                if (uOldEndTime == uNewEndTime) {
                    oldDslope -= uNewPoint.slope; // It was a new deposit, not extension
                }
                store_.globalSlopeChanges[uOldEndTime] = oldDslope;
            }

            if (uNewEndTime > block.timestamp) {
                // update slope if new lock is greater than old lock and is not permanent or if old lock is permanent
                if ((uNewEndTime > uOldEndTime)) {
                    newDslope -= uNewPoint.slope; // old slope disappeared at this point
                    store_.globalSlopeChanges[uNewEndTime] = newDslope;
                }
                // else: we recorded it already in oldDslope
            }
            /// @dev Add the new point to the escrowId Checkpoints.Trace
            _pushPointAtClock(store_._escrowCheckpoints[escrowId], uNewPoint);
            emit CheckpointEscrow(escrowId, clock(), uNewPoint.slope, uNewPoint.bias, uNewPoint.permanent);

            (, uint48 delegateTs, address delegateeAddress) = store_
                ._escrowDelegateeAddress[escrowId]
                .latestCheckpoint();

            if (delegateTs != 0) {
                /// @notice this can likely be handled more efficiently
                _checkpointDelegatee(store_, delegateeAddress, uOldPoint, uOldEndTime, false);
                _checkpointDelegatee(store_, delegateeAddress, uNewPoint, uNewEndTime, true);
            }
        }
        /// @dev If escrowId is 0,  this  will still create a global checkpoint
        globalCheckpoint(store_, escrowId, uOldPoint, uNewPoint);
    }

    /**
     * @dev Function to update global checkpoint
     */
    function globalCheckpoint(EscrowDelegateStore storage store_) external {
        globalCheckpoint(store_, 0, Checkpoints.blankPoint(), Checkpoints.blankPoint());
    }

    /**
     * @dev Function to update global checkpoint with new points
     * @param escrowId The ID of the escrow lock
     * - If
     * @param uOldPoint The old point to be updated
     * @param uNewPoint The new point to be updated
     */
    function globalCheckpoint(
        EscrowDelegateStore storage store_,
        uint256 escrowId,
        Checkpoints.Point memory uOldPoint,
        Checkpoints.Point memory uNewPoint
    ) public {
        (, uint48 lastPoint, Checkpoints.Point memory lastGlobal) = store_._globalCheckpoints.latestCheckpoint();
        uint48 lastCheckpoint = lastPoint != 0 ? lastPoint : uint48(block.timestamp);

        {
            // Go over weeks to fill history and calculate what the current point is
            uint48 testTime = toGlobalClock(lastCheckpoint); /// @dev  lastCheckpoint > tesTime
            uint256 maxTime = testTime + MAX_TIME.toUint256();

            while (testTime < block.timestamp) {
                testTime += CLOCK_UNIT;
                int128 dSlope = 0;
                if (testTime > block.timestamp) {
                    testTime = block.timestamp.toUint48();
                } else {
                    dSlope = store_.globalSlopeChanges[testTime];
                }
                if (dSlope != 0) {
                    lastGlobal.bias -= lastGlobal.slope * uint256(testTime - lastCheckpoint).toInt128();
                    lastGlobal.slope += dSlope;
                    if (lastGlobal.bias < 0) {
                        lastGlobal.bias = 0;
                    }
                    if (lastGlobal.slope < 0) {
                        lastGlobal.bias = 0;
                    }

                    lastCheckpoint = testTime;
                    store_._globalCheckpoints.push(lastCheckpoint, lastGlobal);
                }
                if (testTime > maxTime) break;
            }
        }

        if (escrowId != 0) {
            lastGlobal.bias = lastGlobal.bias - ((lastGlobal.slope * (block.timestamp - lastCheckpoint).toInt128()));

            lastGlobal.slope += uNewPoint.slope - uOldPoint.slope;
            lastGlobal.bias += uNewPoint.bias - uOldPoint.bias;
            lastGlobal.permanent += uNewPoint.permanent - uOldPoint.permanent;
        } else {
            // Initial value of testTime is always larger than the ts of the last point
            uint256 testTime = block.timestamp;
            lastGlobal.bias -= (lastGlobal.slope * (testTime - lastCheckpoint).toInt128());
        }

        _pushPointAtClock(store_._globalCheckpoints, lastGlobal);
        emit CheckpointGlobal(clock(), lastGlobal.slope, lastGlobal.bias, lastGlobal.permanent);
    }

    /**
     * @dev Function to calculate total voting power at some point in the past
     * @param _delegateeAddress The address of the delegatee
     * @param timestamp Time to calculate the total voting power at
     * @return Total voting power at that time
     */
    function getAdjustedVotes(
        EscrowDelegateStore storage store_,
        address _delegateeAddress,
        uint48 timestamp
    ) external view returns (uint256) {
        Checkpoints.Point memory lastPoint = _getAdjustedVotesCheckpoint(store_, _delegateeAddress, timestamp);
        return (lastPoint.bias + lastPoint.permanent).toUint256();
    }

    /**
     * @dev Function to get delegated votes checkpoint at some point in the past
     * @param _delegateeAddress The address of the delegatee
     * @param timestamp Time to calculate the total voting power at
     * @return Total voting power at that time
     */
    function _getAdjustedVotesCheckpoint(
        EscrowDelegateStore storage store_,
        address _delegateeAddress,
        uint48 timestamp
    ) internal view returns (Checkpoints.Point memory) {
        (bool exists, uint48 lastCheckpointTs, Checkpoints.Point memory lastPoint) = store_
            ._delegateCheckpoints[_delegateeAddress]
            .upperLookupRecent(timestamp);
        if (!exists) return lastPoint;
        uint48 testTime = toGlobalClock(lastCheckpointTs); /// @dev  lastCheckpointTs > tesTime
        uint256 maxTime = testTime + MAX_TIME.toUint256();
        while (testTime < timestamp) {
            testTime += CLOCK_UNIT;
            int128 dSlope = 0;
            if (testTime > timestamp) {
                testTime = timestamp;
            } else {
                dSlope = store_.delegateeSlopeChanges[_delegateeAddress][testTime];
            }
            if (dSlope != 0) {
                lastPoint.bias -= lastPoint.slope * uint256(testTime - lastCheckpointTs).toInt128();
                lastPoint.slope += dSlope;
                if (lastPoint.bias < 0) {
                    lastPoint.bias = 0;
                }
                if (lastPoint.slope < 0) {
                    lastPoint.slope = 0;
                }
                lastCheckpointTs = uint48(testTime);
            }
            if (testTime > maxTime) break;
        }
        int128 change = lastPoint.slope * uint256(timestamp - lastCheckpointTs).toInt128();
        lastPoint.bias = lastPoint.bias < change ? int128(0) : lastPoint.bias - change;

        return lastPoint;
    }

    /**
     * @notice Public function to get the delegatee of an escrow lock
     * @param escrowId The ID of the escrow
     * @return The address of the delegate
     */
    function getEscrowDelegatee(EscrowDelegateStore storage store_, uint256 escrowId) external view returns (address) {
        return getEscrowDelegateeAtTime(store_, escrowId, block.timestamp.toUint48());
    }

    /**
     * @notice Public function to get the delegatee of an escrow lock
     * @param escrowId The ID of the escrow lock
     * @param timestamp The timestamp to get the delegate at
     * @return The address of the delegate
     */
    function getEscrowDelegateeAtTime(
        EscrowDelegateStore storage store_,
        uint256 escrowId,
        uint48 timestamp
    ) public view returns (address) {
        return store_._escrowDelegateeAddress[escrowId].upperLookupRecent(timestamp);
    }

    /**
     * @dev Function to record escrow delegation checkpoints. Used by voting system.
     * @param escrowId The ID of the escrow lock
     * @param delegatee The address of the delegatee
     * @param endTime The end time of the delegation
     */
    function delegate(
        EscrowDelegateStore storage store_,
        uint256 escrowId,
        address delegatee,
        uint256 endTime
    ) external returns (address oldDelegatee, address newDelegatee) {
        oldDelegatee = store_._escrowDelegateeAddress[escrowId].latest();
        if (oldDelegatee == delegatee) return (oldDelegatee, delegatee);

        (, uint48 ts, Checkpoints.Point memory lastPoint) = store_._escrowCheckpoints[escrowId].latestCheckpoint();
        lastPoint.bias -= ((lastPoint.slope * (block.timestamp - ts).toInt128()));
        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }

        if (oldDelegatee != delegatee && oldDelegatee != address(0)) {
            _checkpointDelegatee(store_, oldDelegatee, lastPoint, endTime, false);
        }
        // Delegate to new delegator
        if (endTime > block.timestamp) {
            _checkpointDelegatee(store_, delegatee, lastPoint, endTime, true);
        }
        _pushAddressAtClock(store_._escrowDelegateeAddress[escrowId], delegatee);
        return (oldDelegatee, delegatee);
    }

    /**
     * @dev Function to update delegatee's `delegatedBalance` by `balance`.
     *      Only updates if delegating to a new delegatee.
     * @param delegateeAddress The address of the delegatee
     * @param escrowPoint The point of the escrow
     * @param endTime The end time of the delegation
     * @param increase Whether to increase or decrease the balance
     */
    function _checkpointDelegatee(
        EscrowDelegateStore storage store_,
        address delegateeAddress,
        Checkpoints.Point memory escrowPoint,
        uint256 endTime,
        bool increase
    ) internal {
        (Checkpoints.Point memory lastPoint, uint48 lastCheckpoint) = baseCheckpointDelegatee(store_, delegateeAddress);

        int128 baseBias = lastPoint.bias - (lastPoint.slope * (block.timestamp - lastCheckpoint).toInt128());

        if (!increase) {
            store_.delegateeSlopeChanges[delegateeAddress][endTime] += escrowPoint.slope;
            lastPoint.bias = escrowPoint.bias < baseBias ? baseBias - escrowPoint.bias : int128(0);
            lastPoint.slope = escrowPoint.slope < lastPoint.slope ? lastPoint.slope - escrowPoint.slope : int128(0);
            lastPoint.permanent = escrowPoint.permanent < lastPoint.permanent
                ? lastPoint.permanent - escrowPoint.permanent
                : int128(0);
        } else {
            store_.delegateeSlopeChanges[delegateeAddress][endTime] -= escrowPoint.slope;
            lastPoint.bias = baseBias + escrowPoint.bias;
            lastPoint.slope = lastPoint.slope + escrowPoint.slope;
            lastPoint.permanent = lastPoint.permanent + escrowPoint.permanent;
        }
        /// @dev bias can be rounded up by lack of precision. If slope is 0 we are out
        if (lastPoint.slope == 0) {
            lastPoint.bias = 0;
        }
        _pushPointAtClock(store_._delegateCheckpoints[delegateeAddress], lastPoint);
        emit CheckpointDelegate(delegateeAddress, clock(), lastPoint.slope, lastPoint.bias, lastPoint.permanent);
    }

    /**
     * @dev Function to update delegatee's checkpoint
     * @param delegateeAddress The address of the delegatee
     * @return lastPoint The last point of the delegatee
     * @return lastCheckpoint The last checkpoint time of the delegatee
     */
    function baseCheckpointDelegatee(
        EscrowDelegateStore storage store_,
        address delegateeAddress
    ) public returns (Checkpoints.Point memory lastPoint, uint48 lastCheckpoint) {
        (bool exists, uint48 ts, Checkpoints.Point memory point) = store_
            ._delegateCheckpoints[delegateeAddress]
            .latestCheckpoint();
        lastPoint = point;
        lastCheckpoint = ts;
        if (exists) {
            // Go over days to fill history and calculate what the current point is
            uint48 testTime = toGlobalClock(lastCheckpoint); /// @dev  lastCheckpoint > tesTime

            uint256 maxTime = testTime + MAX_TIME.toUint256();

            // Iterate over time until current block timestamp or maxtime
            while (testTime < block.timestamp) {
                testTime += CLOCK_UNIT;
                int128 dSlope = 0;
                if (testTime > block.timestamp) {
                    testTime = uint48(block.timestamp);
                } else {
                    dSlope = store_.delegateeSlopeChanges[delegateeAddress][testTime];
                }
                if (dSlope != 0) {
                    lastPoint.bias -= lastPoint.slope * uint256(testTime - lastCheckpoint).toInt128();
                    lastPoint.slope += dSlope;
                    if (lastPoint.bias < 0) {
                        lastPoint.bias = 0;
                    }
                    if (lastPoint.slope < 0) {
                        lastPoint.slope = 0;
                    }
                    lastCheckpoint = uint48(testTime);
                    store_._delegateCheckpoints[delegateeAddress].push(lastCheckpoint, lastPoint);
                }
                if (testTime > maxTime) break;
            }
        }
    }

    /**
     * @dev Function to calculate total voting power at some point in the past
     * @param timestamp Time to calculate the total voting power at
     * @return Total voting power at that time
     */
    function getAdjustedGlobalVotes(
        EscrowDelegateStore storage store_,
        uint48 timestamp
    ) external view returns (uint256) {
        Checkpoints.Point memory lastPoint = _getAdjustedCheckpoint(store_, timestamp);
        return (lastPoint.bias + lastPoint.permanent).toUint256();
    }

    /**
     * @dev Function to get latest checkpoint of some point in the past
     * @param timestamp Time to calculate the total voting power at
     * @return Total voting power at that time
     */
    function _getAdjustedCheckpoint(
        EscrowDelegateStore storage store_,
        uint48 timestamp
    ) internal view returns (Checkpoints.Point memory) {
        uint48 clockTime = timestamp;
        (bool exists, uint48 lastCheckpointTs, Checkpoints.Point memory lastGlobal) = store_
            ._globalCheckpoints
            .upperLookupRecent(clockTime);
        if (!exists) return lastGlobal;
        uint48 testTime = toGlobalClock(lastCheckpointTs); /// @dev  lastCheckpointTs > tesTime
        uint256 maxTime = testTime + MAX_TIME.toUint256();

        // Iterate over time until the specified timestamp or maxtime is reached
        while (testTime < timestamp) {
            testTime += CLOCK_UNIT;
            int128 dSlope = 0;
            if (testTime > timestamp) {
                testTime = timestamp;
            } else {
                dSlope = store_.globalSlopeChanges[testTime];
            }
            if (dSlope != 0) {
                lastGlobal.bias -= lastGlobal.slope * uint256(testTime - lastCheckpointTs).toInt128();
                lastGlobal.slope += dSlope;
                if (lastGlobal.bias < 0) {
                    lastGlobal.bias = 0;
                }
                if (lastGlobal.slope < 0) {
                    lastGlobal.slope = 0;
                }
                lastCheckpointTs = uint48(testTime);
            }
            if (testTime > maxTime) break;
        }

        int128 change = lastGlobal.slope * uint256(clockTime - lastCheckpointTs).toInt128();
        lastGlobal.bias = lastGlobal.bias < change ? int128(0) : lastGlobal.bias - change;

        return lastGlobal;
    }

    /**
     * @notice Get the current bias for `escrowId` at `timestamp`
     * @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
     * @dev Fetches last escrow point prior to a certain timestamp, then walks forward to timestamp.
     * @param escrowId NFT for lock
     * @param timestamp Epoch time to return bias power at
     * @return NFT bias
     */
    function getAdjustedEscrowBias(
        EscrowDelegateStore storage store_,
        uint256 escrowId,
        uint256 timestamp
    ) external view returns (uint256) {
        uint48 clockTime = timestamp.toUint48();
        (bool exists, uint48 ts, Checkpoints.Point memory lastPoint) = store_
            ._escrowCheckpoints[escrowId]
            .upperLookupRecent(clockTime);
        if (!exists) return 0;
        if (lastPoint.permanent != 0) return lastPoint.permanent.toUint256();
        int128 change = ((lastPoint.slope * uint256(clockTime - ts).toInt128()));
        lastPoint.bias = lastPoint.bias < change ? int128(0) : lastPoint.bias - change;
        return lastPoint.bias.toUint256();
    }

    /// -----------------------------------------------------------------------
    /// Private functions
    /// -----------------------------------------------------------------------

    /**
     * @dev Function to push an address to the checkpoint
     * @param store The storage to push the address to
     * @param value The address to be pushed
     * @return The old and new address
     */
    function _pushAddressAtClock(
        Checkpoints.TraceAddress storage store,
        address value
    ) private returns (address, address) {
        return store.push(clock(), value);
    }

    /**
     * @dev Function to push a struct to the checkpoint
     * @param store The storage to push the struct to
     * @param value The struct to be pushed
     * @return The old and new struct
     */
    function _pushPointAtClock(
        Checkpoints.Trace storage store,
        Checkpoints.Point memory value
    ) private returns (Checkpoints.Point memory, Checkpoints.Point memory) {
        return store.push(clock(), value);
    }
}