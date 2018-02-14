#!/bin/bash
NODE=$1
SPORE="node.sporestack.com"
BINDIR="gincoin-binaries"
MN_CONFIRMATIONS=15

timeout() {
    time=$1

    # start the command in a subshell to avoid problem with pipes
    # (spawn accepts one command)
    command="/bin/sh -c \"$2\""

    expect -c "set echo \"-noecho\"; set timeout $time; spawn -noecho $command; expect timeout { exit 1 } eof { exit 0 }"

    if [ $? = 1 ] ; then
        echo "Timeout after ${time} seconds"
    fi
}

hr() {
    printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' ${1:--}
}

if [[ ! $(command -v sporestack) ]]; then
    echo "Install sporestack first: \"pip3 install sporestack || pip install sporestack\""
    exit 1
fi

echo "1. Make sure you have about \$1 worth of BCH available to spend in a wallet of your choosing"
echo "2. Open Gincoin QT (further referred to as WALLET) and wait for it to sync"
echo -n "3. Press [ENTER] to continue..."
hr
read tmp

if [[ ! $NODE ]]; then
    echo "Building new server..."
    exec 5>&1
    OUTPUT=$(sporestack spawn --days 1 --osid 215 --dcid AUTO --flavor 201 | tee >(cat - >&5))
    NODE="${OUTPUT##*$'\n'}"
    echo "In case you need to resume setup use $NODE as a the first parameter to this command"
    hr
    sleep 5
fi

CONN="sporestack ssh $NODE --command "
CONN_DIRECT="ssh -o StrictHostKeyChecking=no root@$NODE.$SPORE -C "

echo "Testing connectivity..."

TEST=$($CONN 'pwd')

if [[ ! "$TEST" == "/root" ]]; then
    echo "Can not connect to server $NODE.$SPORE"
    exit 1
fi

if [[ "$($CONN 'dpkg-query --show "jq"' 2>&1)" = *"no packages"* ]]; then
    hr
    echo "Installing dependencies..."
    hr
    $CONN 'add-apt-repository ppa:bitcoin/bitcoin -y' || exit 1
    $CONN 'apt-get update && apt-get upgrade -y && apt-get dist-upgrade -y && apt-get autoremove -y' || exit 1
    $CONN 'apt-get install -y htop libboost-all-dev libzmq3-dev libdb4.8-dev libdb4.8++-dev libevent-dev libssl-doc zlib1g-dev fail2ban jq' || exit 1
    echo "Reboot" && $CONN 'reboot'
fi

if [[ "$($CONN "ufw status" 2>&1)" = *"inactive"* ]]; then
    hr
    echo "Setting up firewall..."
    hr

    $CONN 'ufw default allow outgoing && \
            ufw default deny incoming && \
            ufw allow ssh/tcp && \
            ufw allow 10111/tcp && \
            ufw logging on && \
            ufw --force enable' || exit 1

    $CONN 'systemctl enable fail2ban && \
            systemctl start fail2ban' || exit 1
fi

if [[ ! $($CONN "ls -la | grep $BINDIR" 2>&1) = *"$BINDIR"* ]]; then
    hr
    echo "Loading files..."
    hr
    tar -czf - $BINDIR | $CONN 'tar -xzvf - -C .' || exit 1
    $CONN "mkdir -p .gincoincore && mv $BINDIR/gincoin.conf .gincoincore/" || exit 1
fi

IP=$($CONN 'dig +short myip.opendns.com @resolver1.opendns.com') || exit 1

if [[ ! -z $($CONN "cat .gincoincore/gincoin.conf | grep {IP}") ]]; then
    hr
    echo "Configuring IP..."
    hr

    $CONN "echo \"Setting public IP: $IP\" && sed -i -e \"s/{IP}/$IP/g\" .gincoincore/gincoin.conf" || exit 1
fi

if [[ ! -z $($CONN "cat .gincoincore/gincoin.conf | grep {MPK}") ]]; then
    hr
    echo "Configuring masternode private key..."
    hr

    echo -n "[WALLET] Open gincoin-qt's debug console and type 'masternode genkey' (paste output here): "
    read PRIVKEY || exit 1
    PRIVKEY=$(echo $PRIVKEY | xargs)
    $CONN "echo \"Setting MN private key: $PRIVKEY\" && sed -i -e \"s/{MPK}/$PRIVKEY/g\" .gincoincore/gincoin.conf" || exit 1
else
    PRIVKEY=$($CONN "cat .gincoincore/gincoin.conf | grep masternodeprivkey | sed -e "s/masternodeprivkey=//"")
fi

if [[ $($CONN "$BINDIR/gincoin-cli getinfo" 2>&1) = *"error:"* ]]; then
    hr
    echo "Starting Gincoin Core..."
    hr

    timeout 10 "$CONN_DIRECT \\"./$BINDIR/gincoind -daemon\\""
    echo "Waiting for client to sync (30 sec)..." && sleep 30
fi

STATUS=$($CONN "$BINDIR/gincoin-cli mnsync status | jq \".AssetID\"")

while [ ! "$STATUS" == "999" ]; do
    echo -ne "Waiting for client to sync (status $STATUS)...\r"
    sleep 10
    STATUS=$($CONN "$BINDIR/gincoin-cli mnsync status | jq \".AssetID\"")
done
echo -ne '\n'

echo "[WALLET] Open Gincoin QT's debug console and type 'getnewaddress $NODE'"
echo -n "Press [ENTER] to continue..."
read tmp

echo "[WALLET] Send exactly 1000 GIN (no more, no less) to the address obtained in the previous step"
echo -n "Press [ENTER] to continue..."
read tmp

echo "[WALLET] Wait for at least 1 confirmation of the transaction titled 'Payment to yourself' (on the Transactions tab, 1-2 min)"
echo -n "Press [ENTER] to continue..."
read tmp

echo "[WALLET] In the debug console type 'masternode outputs'; You should see something like this: "
echo "{"
echo "  \"04cddada78z063332b4b4a3a2f088dd9e3425aab79ea86fdaa86a18dbbd87825\": \"0\""
echo "   ^ Transaction ID                                                    ^ Transaction Index"
echo "}"
echo -n "Enter Transaction ID (ex: 04cddada78z063332b4b4a3a2f088dd9e3425aab79ea86fdaa86a18dbbd87825): "
read TX_ID
echo -n "Enter Transaction Index (usually 0 or 1): "
read TX_INDEX

echo "Waiting for transaction to get $MN_CONFIRMATIONS confirmations. This takes about 30 min."
CONFIRMATIONS=$($CONN "$BINDIR/gincoin-cli getrawtransaction $TX_ID 1 | jq \".confirmations\"")

while [ "$CONFIRMATIONS" -lt "$MN_CONFIRMATIONS" ]; do
    echo -ne "  ($CONFIRMATIONS/$MN_CONFIRMATIONS)...\r"
    sleep 30
    CONFIRMATIONS=$($CONN "$BINDIR/gincoin-cli getrawtransaction $TX_ID 1 | jq \".confirmations\"")
done
echo -ne '\n'

echo "Enter the following line in your masternode.conf file (Debug console -> Information tab -> Datadir):"
hr
echo "$NODE $IP:10111 $PRIVKEY $TX_ID $TX_INDEX"
hr
echo -n "Press [ENTER] to continue..."
read tmp
echo "[WALLET] Close the Gincoin QT wallet and open it again. Wait for it to sync."
echo -n "Press [ENTER] to continue..."
read tmp
echo "[WALLET] In the Gincoint QT debug console enter the following command:"
hr
echo "masternode start-alias $NODE"
hr
echo -n "Press [ENTER] to continue..."
read tmp

hr
echo "Checking masternode is listed..."
hr

STATUS=$($CONN "$BINDIR/gincoin-cli masternodelist | jq \".[\\\"$TX_ID-$TX_INDEX\\\"]\"")
while [[ ! $STATUS = *"ENABLED"* ]]; do
    echo -ne "Waiting for masternode to be accepted (currently $STATUS)...\r"
    sleep 5
    STATUS=$($CONN "$BINDIR/gincoin-cli masternodelist | jq \".[\\\"$TX_ID-$TX_INDEX\\\"]\"")
done

hr
echo "Great success! Your masternode is active and will start receiving rewards soon"
hr

echo "Restoring SSH limit..."

#$CONN 'ufw limit ssh/tcp' || exit 1
