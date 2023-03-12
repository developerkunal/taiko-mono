// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.18;

import {AddressResolver} from "../../common/AddressResolver.sol";
import {ChainData} from "../../common/IXchainSync.sol";
import {LibTokenomics} from "./LibTokenomics.sol";
import {LibUtils} from "./LibUtils.sol";
import {
    SafeCastUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {TaikoData} from "../../L1/TaikoData.sol";

library LibVerifying {
    using SafeCastUpgradeable for uint256;
    using LibUtils for TaikoData.State;

    error L1_INVALID_CONFIG();

    event BlockVerified(uint256 indexed id, ChainData chainData);
    event XchainSynced(uint256 indexed srcHeight, ChainData chainData);

    function init(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        bytes32 genesisBlockHash,
        uint64 feeBaseTwei
    ) internal {
        if (
            config.chainId <= 1 ||
            config.maxNumBlocks <= 1 ||
            config.blockHashHistory == 0 ||
            config.blockMaxGasLimit == 0 ||
            config.maxTransactionsPerBlock == 0 ||
            config.maxBytesPerTxList == 0 ||
            config.minTxGasLimit == 0 ||
            config.slotSmoothingFactor == 0 ||
            config.rewardBurnBips >= 10000 ||
            config.feeBaseMAF == 0 ||
            config.blockTimeMAF == 0 ||
            config.proofTimeMAF == 0 ||
            config.blockTimeCap == 0 ||
            config.proofTimeCap == 0 ||
            config.feeGracePeriodPctg > config.feeMaxPeriodPctg ||
            config.feeMultiplierPctg < 100
        ) revert L1_INVALID_CONFIG();

        state.genesisHeight = uint64(block.number);
        state.genesisTimestamp = uint64(block.timestamp);
        state.feeBaseTwei = feeBaseTwei;
        state.nextBlockId = 1;

        ChainData memory chainData = ChainData(genesisBlockHash, 0);
        state.l2ChainDatas[0] = chainData;

        emit BlockVerified(0, chainData);
        emit XchainSynced(0, chainData);
    }

    function verifyBlocks(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        uint256 maxBlocks
    ) internal {
        ChainData memory chainData = state.l2ChainDatas[
            state.lastBlockId % config.blockHashHistory
        ];

        uint64 processed;
        uint256 i;
        unchecked {
            i = state.lastBlockId + 1;
        }

        while (i < state.nextBlockId && processed < maxBlocks) {
            TaikoData.ProposedBlock storage proposal = state.proposedBlocks[
                i % config.maxNumBlocks
            ];

            uint256 fcId = state.forkChoiceIds[i][chainData.blockHash];

            if (proposal.nextForkChoiceId <= fcId) {
                break;
            }

            TaikoData.ForkChoice storage fc = state.forkChoices[
                i % config.maxNumBlocks
            ][fcId];

            if (fc.prover == address(0)) {
                break;
            }

            chainData = _markBlockVerified({
                state: state,
                config: config,
                fc: fc,
                proposal: proposal
            });

            emit BlockVerified(i, chainData);

            unchecked {
                ++i;
                ++processed;
            }
        }

        if (processed > 0) {
            unchecked {
                state.lastBlockId += processed;
            }

            // Note: Not all L2 hashes are stored on L1, only the last
            // verified one in a batch. This is sufficient because the last
            // verified hash is the only one needed checking the existence
            // of a cross-chain message with a merkle proof.
            state.l2ChainDatas[
                state.lastBlockId % config.blockHashHistory
            ] = chainData;

            emit XchainSynced(state.lastBlockId, chainData);
        }
    }

    function _markBlockVerified(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        TaikoData.ForkChoice storage fc,
        TaikoData.ProposedBlock storage proposal
    ) private returns (ChainData memory chainData) {
        if (config.enableTokenomics) {
            (uint256 newFeeBase, uint256 reward, uint256 tRelBp) = LibTokenomics
                .getProofReward({
                    state: state,
                    config: config,
                    provenAt: fc.provenAt,
                    proposedAt: proposal.proposedAt
                });

            // reward the prover
            if (reward > 0) {
                if (state.balances[fc.prover] == 0) {
                    // Reduce reward to 1 wei as a penalty if the prover
                    // has 0 TKO outstanding balance.
                    state.balances[fc.prover] = 1;
                } else {
                    state.balances[fc.prover] += reward;
                }
            }

            // refund proposer deposit for valid blocks
            uint256 refund;
            unchecked {
                // tRelBp in [0-10000]
                refund = (proposal.deposit * (10000 - tRelBp)) / 10000;
            }
            if (refund > 0) {
                if (state.balances[proposal.proposer] == 0) {
                    // Reduce refund to 1 wei as a penalty if the proposer
                    // has 0 TKO outstanding balance.
                    state.balances[proposal.proposer] = 1;
                } else {
                    state.balances[proposal.proposer] += refund;
                }
            }

            // Update feeBase and avgProofTime
            state.feeBaseTwei = LibUtils
                .movingAverage({
                    maValue: state.feeBaseTwei,
                    newValue: LibTokenomics.toTwei(newFeeBase),
                    maf: config.feeBaseMAF
                })
                .toUint64();
        }

        uint proofTime;
        unchecked {
            proofTime = (fc.provenAt - proposal.proposedAt) * 1000;
        }
        state.avgProofTime = LibUtils
            .movingAverage({
                maValue: state.avgProofTime,
                newValue: proofTime,
                maf: config.proofTimeMAF
            })
            .toUint64();

        chainData = fc.chainData;
        proposal.nextForkChoiceId = 1;

        // Clean up the fork choice but keep non-zeros if possible to be
        // reused.
        fc.chainData.blockHash = bytes32(uint256(1)); // none-zero placeholder
        fc.chainData.signalRoot = bytes32(uint256(1)); // none-zero placeholder
        fc.provenAt = 1; // none-zero placeholder
        fc.prover = address(0);
    }
}
