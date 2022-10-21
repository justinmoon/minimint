#!/usr/bin/env bash

# start setup
# set -euxo pipefail
export RUST_LOG=info

FM_FED_SIZE=${1:-4}

source ./scripts/build.sh $FM_FED_SIZE

# Starts Bitcoin and 2 LN nodes, opening a channel between the LN nodes
POLL_INTERVAL=1

# Start bitcoind and wait for it to become ready
bitcoind -regtest -fallbackfee=0.0004 -txindex -server -rpcuser=bitcoin -rpcpassword=bitcoin -datadir=$FM_BTC_DIR -zmqpubrawblock=tcp://127.0.0.1:28332 -zmqpubrawtx=tcp://127.0.0.1:28333 &
echo $! >> $FM_PID_FILE

until [ "$($FM_BTC_CLIENT getblockchaininfo | jq -r '.chain')" == "regtest" ]; do
  sleep $POLL_INTERVAL
done
$FM_BTC_CLIENT createwallet ""


# end setup

# TODO: put these data dirs in /tmp
# setup lnd1 datadir
rm -rf $PWD/lnd1
mkdir $PWD/lnd1
cp $PWD/scripts/lnd1.conf $PWD/lnd1/lnd.conf

# setup lnd2 datadir
rm -rf $PWD/lnd2
mkdir $PWD/lnd2
cp $PWD/scripts/lnd2.conf $PWD/lnd2/lnd.conf

# bitcoind -regtest -daemon -fallbackfee=0.0004 -txindex -server -rpcuser=bitcoin -rpcpassword=bitcoin -zmqpubrawblock=tcp://127.0.0.1:28332 -zmqpubrawtx=tcp://127.0.0.1:28333

# start lightning nodes
lnd --noseedbackup --lnddir=$PWD/lnd1 &
lnd --noseedbackup --lnddir=$PWD/lnd2 &
mine_blocks 102  # lnd seems to want blocks mined in order to sync chain and startup rpc servers


LNCLI1="lncli -n regtest --lnddir=$PWD/lnd1 --rpcserver=localhost:11010"
LNCLI2="lncli -n regtest --lnddir=$PWD/lnd2 --rpcserver=localhost:11009"

function await_lnd_block_processing() {

  # ln1
  until [ "true" == "$($LNCLI1 getinfo | jq -r '.synced_to_chain')" ]
  do
    sleep $POLL_INTERVAL
  done

  # ln2
  until [ "true" == "$($LNCLI2 getinfo | jq -r '.synced_to_chain')" ]
  do
    sleep $POLL_INTERVAL
  done
}

echo "WAITING FOR LND STARTUP"
await_lnd_block_processing

# give ln1's on-chain wallet 1 bitcoin
ADDRESS=$($LNCLI1 newaddress p2wkh | jq -r ".address")
send_bitcoin $ADDRESS 100000000
mine_blocks 10
await_lnd_block_processing

# ln1 connects to ln2
LN2_PUBKEY=$($LNCLI2 getinfo | jq -r ".identity_pubkey")
LN2_CONNECTION_STRING=$LN2_PUBKEY@localhost:9734 # hostname is in lnd2.conf
$LNCLI1 connect $LN2_CONNECTION_STRING

# ln1 opens channel to ln2 for 1m sats
echo "OPEN CHANNEL\n\n\n"
$LNCLI1 openchannel $LN2_PUBKEY 1000000
mine_blocks 10

# send funds from ln1 to ln2 via rust
INVOICE=$($LNCLI2 addinvoice -amt 100 | jq -r ".payment_request")
echo "invoice $INVOICE"
cargo run --bin lnd http://localhost:11010 $PWD/lnd1/tls.cert $PWD/lnd1/data/chain/bitcoin/regtest/admin.macaroon $INVOICE

pkill "lnd" 2>&1 /dev/null
pkill "bitcoind" 2>&1 /dev/null
