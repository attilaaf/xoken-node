CREATE KEYSPACE xoken WITH replication = {'class': 'SimpleStrategy', 'replication_factor': '3'}  AND durable_writes = true;

CREATE TABLE xoken.misc_store (
    key text PRIMARY KEY,
    value frozen<tuple<boolean, int, bigint, text>>
) 

CREATE TABLE xoken.transactions (
    tx_id text PRIMARY KEY,
    block_info frozen<tuple<frozen<tuple<text, int>>, int>>,
    tx_serialized blob
) 

CREATE TABLE xoken.blocks_by_hash (
    block_hash text PRIMARY KEY,
    block_header text,
    block_height int
) 

CREATE TABLE xoken.ep_address_outputs (
    epoch boolean,
    address text,
    output frozen<tuple<text, int>>,
    is_output_spent boolean,
    is_type_receive boolean,
    other_address text,
    prev_outpoint frozen<tuple<text, int>>,
    value bigint,
    PRIMARY KEY (epoch, address, output)
) 

CREATE TABLE xoken.address_outputs (
    address text,
    output frozen<tuple<text, int>>,
    block_info frozen<tuple<frozen<tuple<text, int>>, int>>,
    is_block_confirmed boolean,
    is_output_spent boolean,
    is_type_receive boolean,
    other_address text,
    prev_outpoint frozen<tuple<text, int>>,
    value bigint,
    PRIMARY KEY (address, output)
) 

CREATE TABLE xoken.txidmap (
    txid text PRIMARY KEY,
    blockhash text,
    txindex int
) 

CREATE TABLE xoken.blocks_by_height (
    block_height int PRIMARY KEY,
    block_hash text,
    block_header text
) 

CREATE TABLE xoken.ep_transactions (
    epoch boolean,
    tx_id text,
    tx_serialized blob,
    PRIMARY KEY (epoch, tx_id)
) 
