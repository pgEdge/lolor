var pg = require('pg');
const express = require('express');
const app = express();

var CONFIG = require('./config.json');
// pool takes the object above -config- as parameter
const pool = new pg.Pool(CONFIG);

var LargeObjectManager = require('pg-large-object').LargeObjectManager;
var LargeObject = require('pg-large-object').LargeObject;

const loWrite = async (bufData) => {
    const client = await pool.connect();
    // init
    await client.query("CREATE EXTENSION IF NOT EXISTS lolor;");
    await client.query('SET search_path TO lolor,"$user",public,pg_catalog');
    var man = new LargeObjectManager({ pg: client });

    // When working with Large Objects, always use a transaction
    await client.query('BEGIN');
    const oid = await man.createAsync();
    await client.query('COMMIT');

    await client.query('BEGIN');
    const obj = await man.openAsync(oid, LargeObjectManager.WRITE, function (err, obj) {
        if (err) {
            done(err);
            return console.error(
                'Unable to open the given large object',
                oid,
                err);
        }
    });
    obj.write(bufData, function (err, buf) {
        // buf is a standard node.js Buffer
        if(err) {
            console.log(err);
        }
    });

    await client.query('COMMIT');
    // Release the client
    await client.release(true)
    return oid;
};

const loRead = async (oid, size) => {
    const client = await pool.connect();
    // init
    await client.query("CREATE EXTENSION IF NOT EXISTS lolor;");
    await client.query('SET search_path TO lolor,"$user",public,pg_catalog');
    var man = new LargeObjectManager({ pg: client });

    // When working with Large Objects, always use a transaction
    await client.query('BEGIN');
    const obj = await man.openAsync(oid, LargeObjectManager.READ, function (err, obj) {
        if (err) {
            done(err);
            return console.error(
                'Unable to open the given large object',
                oid,
                err);
        }
    });
    const buf = await obj.readAsync(size, function (err, buf) {
        // buf is a standard node.js Buffer
        if (err) {
            console.log(err);
        }
    });
    await client.query('COMMIT');
    await client.release(true)
    return buf;
};

const loSeek = async (oid, bufData) => {
    const client = await pool.connect();
    // init
    await client.query("CREATE EXTENSION IF NOT EXISTS lolor;");
    await client.query('SET search_path TO lolor,"$user",public,pg_catalog');
    var man = new LargeObjectManager({ pg: client });

    // When working with Large Objects, always use a transaction
    await client.query('BEGIN');
    const obj = await man.openAsync(oid, LargeObjectManager.READWRITE, function (err, obj) {
        if (err) {
            done(err);
            return console.error(
                'Unable to open the given large object',
                oid,
                err);
        }
    });

    const pos = await obj.seekAsync(15, LargeObject.SEEK_SET);

    obj.write(bufData, function (err, buf) {
        // buf is a standard node.js Buffer
        if(err) {
            console.log(err);
        }
    });

    await client.query('COMMIT');
    // Release the client
    await client.release(true)
    return pos;
};

// Perform the tell operatoin on large object and return the current positions
const loTell = async (oid, bufData) => {
    const client = await pool.connect();
    // init
    await client.query("CREATE EXTENSION IF NOT EXISTS lolor;");
    await client.query('SET search_path TO lolor,"$user",public,pg_catalog');
    var man = new LargeObjectManager({ pg: client });

    // When working with Large Objects, always use a transaction
    await client.query('BEGIN');
    const obj = await man.openAsync(oid, LargeObjectManager.READWRITE, function (err, obj) {
        if (err) {
            done(err);
            return console.error(
                'Unable to open the given large object',
                oid,
                err);
        }
    });

    const pos1 = await obj.tellAsync();
    obj.write(bufData, function (err, buf) {
        // buf is a standard node.js Buffer
        if(err) {
            console.log(err);
        }
    });

    const pos2 = await obj.tellAsync();
    await client.query('COMMIT');
    expect(client).toBeTruthy();

    // Release the client
    await client.release(true)
    return [pos1, pos2];
};

// Perform truncate operation on large object
const loTruncate = async (oid, size) => {
    const client = await pool.connect();
    // init
    await client.query("CREATE EXTENSION IF NOT EXISTS lolor;");
    await client.query('SET search_path TO lolor,"$user",public,pg_catalog');
    var man = new LargeObjectManager({ pg: client });

    // When working with Large Objects, always use a transaction
    await client.query('BEGIN');
    const obj = await man.openAsync(oid, LargeObjectManager.READWRITE, function (err, obj) {
        if (err) {
            done(err);
            return console.error(
                'Unable to open the given large object',
                oid,
                err);
        }
    });

    await obj.truncateAsync(size);
    await client.query('COMMIT');
    // Release the client
    await client.release(true)
};

// Drop the large object
const loUnlink = async (oid) => {
    const client = await pool.connect();
    // init
    await client.query("CREATE EXTENSION IF NOT EXISTS lolor;");
    await client.query('SET search_path TO lolor,"$user",public,pg_catalog');
    var man = new LargeObjectManager({ pg: client });

    // When working with Large Objects, always use a transaction
    await client.query('BEGIN');
    await man.unlinkAsync(oid);
    await client.query('COMMIT');
    // Release the client
    await client.release(true)
};

module.exports = {
    loWrite,
    loRead,
    loSeek,
    loTell,
    loTruncate,
    loUnlink
};

