#!/bin/bash

# We need access to a bitcoin-cli instance to get some basic block information and a
# Bitcoin Core REST instance to get batches of filter headers and headers in hex.
# Requires https://github.com/bitcoin/bitcoin/pull/17631 for REST filter headers.
# After creating the zones, we scp them to SCP_TARGET, which is expected to add a
# relevant SOA record, NS record(s) and possibly DNSSec-sign the zones before loading
# them into a nameserver (knot is generally recommended as it uses much less memory to
# store such large zones, though you may need to set `zonefile-load: whole`,
# `journal-content: none` and `semantic-checks: off` to get reasonable performance out
# of it.

# The SOA record used on bitcoinheaders.net zones is:
# @	TTL_REPLACE	IN	SOA	ns.as397444.net. dnsadmin.as397444.net. (
#					SERIAL_REPLACE 	; Serial
#					TTL_REPLACE   	; Refresh
#					600            	; Retry
#					2419200        	; Expire
#					60 )         	; Negative Cache TTL
# with TTL_REPLACE replaced with max(min(head -n2 headers-$I.zone | tail -n1 | awk '{ print $2 }', 2592000), 86400) / 24.

# It is important that your secondary nameserver(s) support NOTIFYs to ensure you can
# update them as new blocks come in.

SCP_TARGET="user@hostname"
BITCOIN_CLI="~/bitcoin-cli"
BITCOIND_REST="http://127.0.0.1/rest"

mkdir -p header_zones
cc -Wall -O2 ./split.c -o split

while [ true ]; do
	if [ "$LATEST_HASH" != "$($BITCOIN_CLI getbestblockhash)" ]; then
		LATEST_HASH=$($BITCOIN_CLI getbestblockhash)
		echo "Updating for new hash $LATEST_HASH..."

		COUNT=$($BITCOIN_CLI getblockcount)

		# Break header chunks into zones of 10k headers each
		for I in `seq 0 10000 $COUNT`; do
			TARGET=$(($COUNT > $(($I + 9999)) ? $(($I + 9999)) : $COUNT))
			HEADERS=""
			FILTERS=""
			# ...but bitcoind only provides 2000 at a time, so load them in batches
			for J in `seq $I 2000 $TARGET`; do
				HASH=$($BITCOIN_CLI getblockhash $J)
				HEADERS="$HEADERS$(wget -q -O - $BITCOIND_REST/headers/2000/$HASH.hex)"
				FILTERS="$FILTERS$(wget -q -O - $BITCOIND_REST/blockfilterheaders/basic/2000/$HASH.hex)"
			done

			# split returns non-0 on error or if the zone on disk ends with the same header
			# as what we just provided, so only scp it to our nameserver if we get 0
			if echo "$HEADERS" | ./split $I $COUNT 80 headers-$(($I / 10000)).zone; then
				echo -e "put headers-$(($I / 10000)).zone dest/\nquit\n" | sftp $SCP_TARGET
			fi
			if echo "$FILTERS" | ./split $I $COUNT 32 filterheaders-$(($I / 10000)).zone; then
				echo -e "put filterheaders-$(($I / 10000)).zone dest/\nquit\n" | sftp $SCP_TARGET
			fi
		done
	fi
	sleep 10
done
