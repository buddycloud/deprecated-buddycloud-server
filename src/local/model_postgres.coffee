##
# PostgreSQL backend
#
# For table subscriptions:
# * "user"  = "listener" means subscription to a local node
# * "user" != "listener" means subscription to a remote node

pg = require("pg")
ltx = require("ltx")  # for item XML parsing & serialization
async = require("async")
errors = require("../errors")

# ready DB connections
pool = []
# waiting transaction requests
queue = []

debugDB = (db) ->
    oldQuery = db.query
    db.query = (sql, params) ->
        console.log "query #{sql} #{JSON.stringify(params)}"
        oldQuery.apply(@, arguments)

# at start and when connection died
connectDB = (config) ->
    db = new pg.Client(config)
    debugDB db
    db.connect()
    # Reconnect in up to 5s
    db.on "error", (err) ->
        console.error "Postgres: " + err.message
        setTimeout ->
            connectDB config
        , Math.ceil(Math.random() * 5000)
        try
            db.end()
        catch e

    # wait until connected & authed
    db.connection.once "readyForQuery", ->
        dbIsAvailable db

##
# Put into connection pool
dbIsAvailable = (db) ->
    if (cb = queue.shift())
        # request was waiting in queue
        cb db
    else
        # no request, put into pool
        pool.push db

##
# Get from connection pool
withNextDb = (cb) ->
    if (db = pool.shift())
        # Got one from pool
        cb(db)
    else
        # Pool was empty, waiting... TODO: limit length, shift first
        queue.push (db) ->
           cb(db)

# config: { user, database, host, port, poolSize: 4 }
exports.start = (config) ->
    for i in [0..(config.poolSize or 4)]
        connectDB config

exports.transaction = (cb) ->
    withNextDb (db) ->
        new Transaction(db, cb)

# TODO: currently unused, should re-check to delete local node after an unsubscribe
exports.isListeningToNode = (node, listenerJids, cb) ->
    i = 1
    conditions = listenerJids.map((listenerJid) ->
        i++
        "listener = $#{i}"
    ).join(" OR ")
    unless conditions
        # Short-cut
        return cb null, false

    withNextDb (db) ->
        db.query "SELECT listener FROM subscriptions WHERE node = $1 AND (#{conditions}) LIMIT 1"
        , [node, listenerJids...]
        , (err, res) ->
            process.nextTick ->
                dbIsAvailable(db)
            cb err, (res?.rows?[0]?)

exports.nodeExists = (node, cb) ->
    withNextDb (db) ->
        db.query "SELECT node FROM nodes WHERE node=$1", [ node ], (err, res) ->
            process.nextTick ->
                dbIsAvailable(db)
            if err
                cb err
            else
                cb null, res?.rows?[0]?


# TODO: batchify
exports.forListeners = (iter) ->
    withNextDb (db) ->
        db.query "SELECT DISTINCT listener FROM subscriptions WHERE listener IS NOT NULL", (err, res) ->
            process.nextTick ->
                dbIsAvailable(db)
            if err
                console.error err
                return

            res?.rows?.forEach (row) ->
                console.log listener: row.listener
                iter row.listener

# TODO: batchify
exports.getAllNodes = (cb) ->
    withNextDb (db) ->
        db.query "SELECT node FROM nodes", (err, res) ->
            process.nextTick ->
                dbIsAvailable(db)
            if err
                return cb err

            nodes = res?.rows?.map (row) ->
                row.node
            cb null, nodes

exports.getListenerNodes = (listener, cb) ->
    db.query "SELECT DISTINCT node FROM subscriptions WHERE listener=$1", [listener], (err, res) ->
        cb err, res?.rows?.map (row) -> row.node


LOST_TRANSACTION_TIMEOUT = 60 * 1000

##
# Wraps the postgres-js transaction with our model operations.
class Transaction
    constructor: (db, cb) ->
        @db = db
        db.query "BEGIN", [], (err, res) =>
            cb err, @

        timeout = setTimeout =>
            console.error "Danger: lost transaction, rolling back!"
            timeout = undefined
            @rollback
        , LOST_TRANSACTION_TIMEOUT
        @rmTimeout = ->
            if timeout
                clearTimeout timeout
                timeout = undefined

    commit: (cb) ->
        @db.query "COMMIT", [], (err, res) =>
            @rmTimeout()
            process.nextTick =>
                dbIsAvailable @db

            cb err

    rollback: (cb) ->
        @db.query "ROLLBACK", [], (err, res) =>
            @rmTimeout()
            process.nextTick =>
                dbIsAvailable @db

            cb err

    ##
    # Actual data model

    ##
    # Can be dropped in a async.waterfall() sequence to validate presence of a node.
    validateNode: (node) ->
        db = @db
        (cb) ->
            db.query "SELECT node FROM nodes WHERE node=$1", [ node ], (err, res) ->
                if err
                    cb err
                else if res?.rows?[0]?
                    cb null
                else
                    console.log "#{node} does not exist!"
                    cb new errors.NotFound("Node does not exist")

    nodeExists: (node, cb) ->
        @db.query "SELECT node FROM nodes WHERE node=$1", [ node ], (err, res) ->
            if err
                cb err
            else
                console.log "#{node} does not exist"
                cb null, res?.rows?[0]?

    createNode: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node FROM nodes WHERE node=$1", [ node ], cb2
        , (res, cb2) ->
            if res?.rows?[0]
                # Node already exists: ignore
                cb2(null, false)
            else
                db.query "INSERT INTO nodes (node) VALUES ($1)", [ node ], (err) ->
                    cb2 err, true
        ], cb

    ##
    # only open ones
    #
    # cb(err, [{ node: String, title: String }])
    listNodes: (cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node FROM nodes WHERE node IN (SELECT node FROM node_config WHERE \"key\"='accessModel' AND \"value\"='open') " + "ORDER BY node ASC", cb2
        , (res, cb2) ->
            nodes = res.rows.map (row) ->
                node: row.node
                title: undefined  # TODO
            cb2 null, nodes
        ], cb

    ##
    # Subscription management
    ##

    getSubscription: (node, user, cb) ->
        unless node
            return cb(new Error("No node"))
        unless user
            return cb(new Error("No user"))

        @db.query "SELECT subscription FROM subscriptions WHERE node=$1 AND \"user\"=$2"
        , [ node, user ]
        , (err, res) ->
            cb err, res?.rows?[0]?.subscription or "none"

    setSubscription: (node, user, listener, subscription, cb) ->
        unless node
            return cb(new Error("No node"))
        unless user
            return cb(new Error("No user"))

        db = @db
        toDelete = not subscription or subscription == "none"
        async.waterfall [ @validateNode(node)
        , (cb2) ->
            db.query "SELECT subscription FROM subscriptions WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
        , (res, cb2) ->
            isSet = res?.rows?[0]?
            console.log "setSubscription #{node} #{user} isSet=#{isSet} toDelete=#{toDelete}"
            if isSet and not toDelete
                if listener
                    db.query "UPDATE subscriptions SET listener=$1, subscription=$2, updated=CURRENT_TIMESTAMP WHERE node=$3 AND \"user\"=$4"
                    , [ listener, subscription, node, user ]
                    , cb2
                else
                    db.query "UPDATE subscriptions SET subscription=$1, updated=CURRENT_TIMESTAMP WHERE node=$2 AND \"user\"=$3"
                    , [ subscription, node, user ]
                    , cb2
            else if not isSet and not toDelete
                # listener=null is allowed for 3rd-party inboxes
                if listener
                    db.query "INSERT INTO subscriptions (node, \"user\", listener, subscription, updated) VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)"
                    , [ node, user, listener, subscription ]
                    , cb2
                else
                    db.query "INSERT INTO subscriptions (node, \"user\", subscription, updated) VALUES ($1, $2, $3, CURRENT_TIMESTAMP)"
                    , [ node, user, subscription ]
                    , cb2
            else if isSet and toDelete
                db.query "DELETE FROM subscriptions WHERE node=$1 AND \"user\"=$2"
                , [ node, user ]
                , cb2
            else if not isSet and toDelete
                cb2 null
            else
                cb2 new Error('Invalid subscription transition')
        ], (err) ->
            cb err

    getSubscribers: (node, cb) ->
        unless node
            return cb(new Error("No node"))

        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\", subscription FROM subscriptions WHERE node=$1 ORDER BY updated DESC", [ node ], cb2
        , (res, cb2) ->
            subscribers = for row in res.rows
                { user: row.user, subscription: row.subscription }

            cb2 null, subscribers
        ], cb

    ##
    # Not only by users but also by listeners.
    # @param cb {Function} cb(Error, { user, node, subscription })
    getSubscriptions: (actor, cb) ->
        @db.query "SELECT \"user\", node, subscription FROM subscriptions WHERE \"user\"=$1 OR listener=$1 ORDER BY updated DESC", [ actor ], (err, res) ->
            cb err, res?.rows

    getPending: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT user FROM subscriptions WHERE subscription = 'pending' AND node = $1 ORDER BY updated DESC", [ node ], cb2
        , (res, cb2) ->
            cb2 null, res.rows.map((row) ->
                row.user
            )
        ], cb

    getNodeListeners: (node, cb) ->
        @db.query """SELECT DISTINCT listener
                     FROM subscriptions
                     WHERE node=$1
                     AND subscription='subscribed'
                     AND listener IS NOT NULL"""
        , [node]
        , (err, res) ->
            cb err, res?.rows?.map((row) -> row.listener)

    getNodeModeratorListeners: (node, cb) ->
        # TODO: on subscriptions.listener=affiliations.listener
        @db.query """SELECT DISTINCT listener
                     FROM subscriptions
                     WHERE node=$1
                     AND listener IS NOT NULL
                     AND EXISTS (SELECT affiliation
                                 FROM affiliations
                                 WHERE node=$1
                                 AND (affiliation='owner' OR affiliation='moderator'))"""
        , [node]
        , (err, res) ->
            cb err, res?.rows?.map((row) -> row.listener)

    walkModeratorAuthorizationRequests: (user, iter, cb) ->
        # TODO: make batched
        @db.query """SELECT "user", node
                     FROM subscriptions
                     WHERE subscription='pending'
                     AND node IN (SELECT node
                                  FROM affiliations
                                  WHERE "user"=$1
                                  AND (affiliation='owner' OR affiliation='moderator'))"""
        , [user]
        , (err, res) ->
            res?.rows?.forEach (row) -> iter(row)
            cb err

    getUserRemoteSubscriptions: (user, cb) ->
        @db.query "SELECT node, listener, subscription FROM subscriptions WHERE \"user\"=$1 AND listener!=$1", [user], (err, res) ->
            cb err, res?.rows

    clearUserSubscriptions: (user, cb) ->
        @db.query "DELETE FROM subscriptions WHERE \"user\"=$1", [user], (err) ->
            cb err

    ##
    # Affiliation management
    ##

    getAffiliation: (node, user, cb) ->
        unless node
            return cb(new Error("No node"))
        unless user
            return cb(new Error("No user"))

        @db.query "SELECT affiliation FROM affiliations WHERE node=$1 AND \"user\"=$2"
        , [ node, user ]
        , (err, res) ->
            cb err, (res?.rows?[0]?.affiliation or "none")

    getListenerAffiliations: (node, listener, cb) ->
        unless node
            return cb(new Error("No node"))
        unless listener
            return cb(new Error("No user"))

        @db.query "SELECT DISTINCT affiliation FROM affiliations WHERE node=$1 AND \"user\" IN (SELECT \"user\" FROM subscriptions WHERE listener=$2)"
        , [ node, listener ]
        , (err, res) ->
            cb err, res?.rows?.map((row) -> row.affiliation or "none")

    setAffiliation: (node, user, affiliation, cb) ->
        unless node
            return cb(new Error("No node"))
        unless user
            return cb(new Error("No user"))

        db = @db
        async.waterfall [ @validateNode(node)
        , (cb2) ->
            db.query "SELECT affiliation FROM affiliations WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
        , (res, cb2) ->
            isSet = res and res.rows and res.rows[0]
            toDelete = not affiliation or affiliation == "none"
            if isSet and not toDelete
                db.query "UPDATE affiliations SET affiliation=$1 WHERE node=$2 AND \"user\"=$3", [ affiliation, node, user ], cb2
            else if not isSet and not toDelete
                db.query "INSERT INTO affiliations (node, \"user\", affiliation) VALUES ($1, $2, $3)", [ node, user, affiliation ], cb2
            else if isSet and toDelete
                db.query "DELETE FROM affiliations WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
            else if not isSet and toDelete
                cb2 null
        ], (err) ->
            cb err

    getAffiliations: (user, cb) ->
        unless user
            return cb(new Error("No user"))

        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node, affiliation FROM affiliations WHERE \"user\"=$1 ORDER BY updated DESC", [ user ], cb2
        , (res, cb2) ->
            affiliations = for row in res.rows
                { node: row.node, affiliation: row.affiliation }
            cb2 null, affiliations
        ], cb

    getAffiliated: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\", affiliation FROM affiliations WHERE node=$1 ORDER BY updated DESC", [ node ], cb2
        , (res, cb2) ->
            affiliations = for row in res.rows
                { user: row.user, affiliation: row.affiliation }

            cb2 null, affiliations
        ], cb

    getOwners: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\" FROM affiliations WHERE node=$1 AND affiliation='owner' ORDER BY updated DESC", [ node ], cb2
        , (res, cb2) ->
            cb2 null, res.rows.map((row) ->
                row.user
            )
        ], cb

    writeItem: (node, id, el, cb) ->
        db = @db
        async.waterfall [ @validateNode(node), (cb2) ->
            db.query "SELECT id FROM items WHERE node=$1 AND id=$2", [ node, id ], cb2
        , (res, cb2) ->
            isSet = res and res.rows and res.rows[0]
            xml = el.toString()
            if isSet
                db.query "UPDATE items SET xml=$1, updated=CURRENT_TIMESTAMP WHERE node=$2 AND id=$3"
                , [ xml, node, id ]
                , cb2
            else unless isSet
                db.query "INSERT INTO items (node, id, xml, updated) VALUES ($1, $2, $3, CURRENT_TIMESTAMP)"
                , [ node, id, xml ]
                , cb2
        ], cb

    deleteItem: (node, itemId, cb) ->
        # TODO: tombstone
        db = @db
        @db.query "DELETE FROM items WHERE node=$1 AND id=$2", [ node, itemId ], (err) ->
            # Don't eval result, ignore deleting non-existant items
            cb err

    ##
    # sorted by time
    getItemIds: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT id FROM items WHERE node=$1 ORDER BY updated DESC", [ node ], cb2
        , (res, cb2) ->
            ids = res.rows.map((row) ->
                row.id
            )
            cb2 null, ids
        ], cb

    getItem: (node, id, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT xml FROM items WHERE node=$1 AND id=$2", [ node, id ], cb2
        , (res, cb2) ->
            if res?.rows?[0]?.xml
                el = parseEl(res.rows[0].xml)
                if el?
                    cb2 null, el
                else
                    cb2 new errors.InternalServerError("Item XML parse error")
            else
                cb2 new errors.NotFound("No such item")
        ], cb

    ##
    # @param itemCb {Function} itemCb({ node: String, id: String, item: Element })
    getUpdatesByTime: (subscriber, timeStart, timeEnd, itemCb, cb) ->
        conditions = [ "node IN (SELECT node FROM subscriptions WHERE \"user\"=$1 AND subscription='subscribed')" ]
        params = [ subscriber ]
        i = 1
        if timeStart
            conditions.push "updated >= $" + (++i) + "::timestamp"
            params.push timeStart
        if timeEnd
            conditions.push "updated <= $" + (++i) + "::timestamp"
            params.push timeEnd
        q = @db.query("SELECT id, node, xml FROM items WHERE " + conditions.join(" AND ") + " ORDER BY updated ASC", params)
        q.on "row", (row) ->
            if item
                itemCb
                    node: row.node
                    id: row.id
                    item: row.xml


        q.on "error", (err_) ->
            err = err_

        q.on "end", ->
            cb err

    ##
    # Config management
    ##

    getConfig: (node, cb) ->
        db = @db
        async.waterfall [ @validateNode(node), (cb2) ->
            db.query "SELECT \"key\", \"value\" FROM node_config WHERE node=$1", [ node ], cb2
        , (res, cb2) ->
            if res.rows
                config = {}
                res.rows.forEach (row) ->
                    config[row.key] = row.value

                cb2 null, config
            else
                cb2 new errors.NotFound("No such node")
        ], cb

    setConfig: (node, config, cb) ->
        db = @db
        console.log "setConfig " + node + ": " + require("util").inspect(config)
        async.waterfall [ @validateNode(node), (cb2) ->
            async.parallel(for own key, value of config
                do (key, value) ->
                    (cb3) ->
                        if value?
                            db.query "DELETE FROM node_config WHERE node=$1 AND key=$2"
                            , [ node, key ]
                            , (err) ->
                                if err
                                    return cb err

                                db.query "INSERT INTO node_config (key, value, node, updated) VALUES ($1, $2, $3, CURRENT_TIMESTAMP)"
                                , [ key, value, node ]
                                , cb3
                        else
                            cb3 null
            , (err) ->
                cb2 err
            )
        ], cb

    ##
    # Synchronization preparation
    ##

    resetConfig: (node, cb) ->
        @db.query "DELETE FROM node_config WHERE node=$1", [node], cb

    resetItems: (node, cb) ->
        @db.query "DELETE FROM items WHERE node=$1", [node], cb

    ##
    # Calls back with { User: Listener }
    resetSubscriptions: (node, cb) ->
        @db.query "SELECT \"user\", listener FROM subscriptions WHERE node=$1 AND listener IS NOT NULL", [node], (err, res) =>
            if err
                return cb err

            userListeners = {}
            for row in res.rows
                userListeners[row.user] = row.listener

            @db.query "DELETE FROM subscriptions WHERE node=$1", [node], (err) ->
                cb err, userListeners

    resetAffiliations: (node, cb) ->
        @db.query "DELETE FROM affiliations WHERE node=$1", [node], cb

    ##
    # MAM
    #
    # @param cb: Function(err, results)
    walkListenerArchive: (listener, start, end, iter, cb) ->
        db = @db
        params = [listener]
        cond = ""
        i = params.length
        if start
            cond = "AND updated >= $#{i += 1}::timestamp"
            params.push start
        if end
            cond = " AND updated <= $#{i += 1}::timestamp"
            params.push end
        q = (fields, table, cb2, mapper) ->
            # TODO: ORDER BY updated
            db.query "SELECT #{fields} FROM #{table} WHERE node in (SELECT node FROM subscriptions WHERE listener=$1) #{cond}", params
            , (err, res) ->
                if err
                    return cb2 err

                if mapper
                    iter res.rows.map(mapper)
                else
                    iter res.rows
                cb2()

        async.parallel [ (cb2) ->
            db.query "SELECT DISTINCT node FROM node_config WHERE node in (SELECT node FROM subscriptions WHERE listener=$1) #{cond}", params
            , (err, res) =>
                if err
                    return cb2 err

                async.forEach res.rows, (row, cb3) ->
                    node = row.node
                    db.query "SELECT key, value FROM node_config WHERE node=$1", [node]
                    , (err, res) ->
                        if err
                            return cb3 err

                        config = {}
                        for row in res.rows
                            config[row.key] = row.value
                        iter [{ type: 'config', node, config }]

                        cb3()
                , cb2
        , (cb2) ->
            q "node, id, xml", "items"
            , cb2, (row) ->
                { type: 'items', node: row.node, items: [{ id: row.id, el: parseEl(row.xml) }] }
        , (cb2) ->
            q "node, \"user\", subscription, 'subscription' as type", "subscriptions"
            , cb2
        , (cb2) ->
            q "node, \"user\", affiliation, 'affiliation' as type", "affiliations"
            , cb2
        ], (err) ->
            console.log 'walkListenerArchive done'
            cb err


parseEl = (xml) ->
    try
        return ltx.parse(xml)
    catch e
        console.error "Parsing " + xml + ": " + e.stack
        return undefined

