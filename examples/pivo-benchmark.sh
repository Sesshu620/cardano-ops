#!/usr/bin/env bash
#
# See 'pivo-version-change.sh' for more information on this script.

set -euo pipefail

[ -z ${POOL_NODES+x} ] && (echo "Environment variable POOL_NODES must be defined"; exit 1)

CLI=cardano-cli

. $(dirname $0)/pivo-version-change/lib.sh

if [ -z ${1+x} ];
then
    echo "'redeploy' command was not specified, so the test will run on an existing testnet";
else
    case $1 in
        redeploy )
            echo "Redeploying the testnet"
            nixops destroy --confirm
            ./scripts/create-shelley-genesis-and-keys.sh
            nixops deploy -k
            ;;
        * )
            echo "Unknown command $1"
            exit
    esac
fi

# Run the transaction submission loop in the pool nodes
pids=()
for p in ${POOL_NODES[@]}
do
    try_till_success \
        "nixops scp $p examples/pivo-version-change/lib.sh /root/ --to"
    nixops scp $p examples/pivo-version-change/create-and-fund-spending-keys.sh /root/ --to
    nixops scp $p examples/pivo-version-change/run-parallel-tx-sub-loop.sh /root/ --to

    nixops ssh $p "./create-and-fund-spending-keys.sh"
    nixops ssh $p "./run-parallel-tx-sub-loop.sh" > tx-submission.log &
    pids+=( $! )
done

./examples/pivo-version-change/run-voting-process.sh > voting-process.log &
pid=$!

wait $pid

for t in ${pids[@]}; do
    kill $t
done

echo "Voting process completed"

# TODO: we are trying to submit the transactions from the pool nodes
echo "Fetching transaction logs"
for f in ${POOL_NODES[@]}
do
    nixops scp $f /root/tx-submission.log $f-tx-submission.log --from
done

rm -f bft-nodes-tx-submission.log
for f in ${POOL_NODES[@]}
do
    cat $f-tx-submission.log >> bft-nodes-tx-submission.log
    rm $f-tx-submission.log
done

echo "Fetchihg a node log"
nixops ssh ${BFT_NODES[0]} "journalctl -u cardano-node -b" > bft-node.log

wait
