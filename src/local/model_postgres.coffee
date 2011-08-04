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

dbIsAvailable = (db) ->
    if (cb = queue.shift())
        # request was waiting in queue
        cb db
    else
        # no request, put into pool
        pool.push db

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

##
# Wraps the postgres-js transaction with our model operations.
class Transaction
    constructor: (db, cb) ->
        @db = db
        db.query "BEGIN", [], (err, res) =>
            cb err, @

    commit: (cb) ->
        @db.query "COMMIT", [], (err, res) =>
            process.nextTick =>
                dbIsAvailable @db

            cb err

    rollback: (cb) ->
        @db.query "ROLLBACK", [], (err, res) =>
            process.nextTick =>
                dbIsAvailable @db

            cb err

    ##
    # Actual data model

    ##
    # Can be dropped in a async.waterfall() sequence to validate presence of a node.
    nodeExists: (node) ->
        db = @db
        (cb) ->
            db.query "SELECT node FROM nodes WHERE node=$1", [ node ], (err, res) ->
                if err
                    cb err
                else if res?.rows?[0]?
                    cb null
                else
                    cb new errors.NotFound("Node does not exist")

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
    # cb(err, [{ node: String, title: String }])
    listNodes: (cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node FROM nodes WHERE node IN (SELECT node FROM node_config WHERE \"key\"='accessModel' AND \"value\"='open') " + "ORDER BY node ASC", cb2
        , (res, cb2) ->
            nodes = res.rows.map (row) ->
                node: row.node
                title: row.title
            cb2 null, nodes
        ], cb

    listNodesByUser: (user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node FROM nodes WHERE position('/user/' || $1 IN node) = 1 AND node IN (SELECT node FROM node_config WHERE \"key\"='accessModel' AND \"value\"='open') " + "ORDER BY node ASC", [ user ], cb2
        , (res, cb2) ->
            nodes = res.rows.map (row) ->
                node: row.node
                title: row.title
            cb2 null, nodes
        ], cb

    ##
    # Subscription management
    ##

    getSubscription: (node, user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT subscription FROM subscriptions WHERE node=$1 AND user=$2", [ node, user ], cb2
        , (res, cb2) ->
            cb2 null, (res.rows[0] and res.rows[0].subscription) or "none"
        ], cb

    setSubscription: (node, user, listener, subscription, cb) ->
        db = @db
        toDelete = not subscription or subscription == "none"
        async.waterfall [ @nodeExists(node)
        , (cb2) ->
            db.query "SELECT subscription FROM subscriptions WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
        , (res, cb2) ->
            isSet = res?.rows?[0]
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
                db.query "INSERT INTO subscriptions (node, \"user\", listener, subscription, updated) VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)"
                , [ node, user, listener, subscription ]
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
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\", subscription FROM subscriptions WHERE node=$1", [ node ], cb2
        , (res, cb2) ->
            subscribers = for row in res.rows
                { user: row.user, subscription: row.subscription }

            cb2 null, subscribers
        ], cb

    getSubscriptions: (user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node, subscription FROM subscriptions WHERE \"user\"=$1", [ user ], cb2
        , (res, cb2) ->
            subscriptions = for row in res.rows
                { node: row.node, subscription: row.subscription }
            cb2 null, subscriptions
        ], cb

    getPingNodes: (user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node FROM affiliations WHERE affiliation = 'owner' AND \"user\" = $1 AND EXISTS (SELECT \"user\" FROM subscriptions WHERE subscription = 'pending' AND node = affiliations.node)", [ user ], cb2
        , (res, cb2) ->
            cb2 null, res.rows.map((row) ->
                row.node
            )
        ], cb

    getPending: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT user FROM subscriptions WHERE subscription = 'pending' AND node = $1", [ node ], cb2
        , (res, cb2) ->
            cb2 null, res.rows.map((row) ->
                row.user
            )
        ], cb

    getNodeListeners: (node, cb) ->
        @db.query "SELECT DISTINCT listener FROM subscriptions WHERE node = $1"
        , [node]
        , (err, res) ->
            cb err, res?.rows?.map((row) -> row.listener)

    ##
    # Affiliation management
    ##

    getAffiliation: (node, user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT affiliation FROM affiliations WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
        , (res, cb2) ->
            cb2 null, (res.rows[0] and res.rows[0].affiliation) or "none"
        ], cb

    setAffiliation: (node, user, affiliation, cb) ->
        db = @db
        async.waterfall [ @nodeExists(node)
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
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node, affiliation FROM affiliations WHERE \"user\"=$1", [ user ], cb2
        , (res, cb2) ->
            affiliations = for row in res.rows
                { node: row.node, affiliation: row.affiliation }
            cb2 null, affiliations
        ], cb

    getAffiliated: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\", affiliation FROM affiliations WHERE node=$1", [ node ], cb2
        , (res, cb2) ->
            affiliations = for row in res.rows
                { user: row.user, affiliation: row.affiliation }

            cb2 null, affiliations
        ], cb

    getOwners: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\" FROM affiliations WHERE node=$1 AND affiliation='owner'", [ node ], cb2
        , (res, cb2) ->
            cb2 null, res.rows.map((row) ->
                row.user
            )
        ], cb

    writeItem: (node, id, author, el, cb) ->
        db = @db
        async.waterfall [ @nodeExists(node), (cb2) ->
            db.query "SELECT id FROM items WHERE node=$1 AND id=$2", [ node, id ], cb2
        , (res, cb2) ->
            isSet = res and res.rows and res.rows[0]
            xml = el.toString()
            if isSet
                db.query "UPDATE items SET xml=$1, author=$2, updated=CURRENT_TIMESTAMP WHERE node=$3 AND id=$4"
                , [ xml, author, node, id ]
                , cb2
            else unless isSet
                db.query "INSERT INTO items (node, id, author, xml, updated) VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)"
                , [ node, id, author, xml ]
                , cb2
        ], cb

    deleteItem: (node, itemId, cb) ->
        # TODO: tombstone
        db = @db
        async.waterfall [(cb2) ->
            db.query "DELETE FROM items WHERE node=$1 AND id=$2", [ node, itemId ], cb2
        , (res, cb2) ->
            if res?.rows?[0]
                cb2 null
            else
                cb2 new errors.NotFound("No such item")
        ], cb

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
        async.waterfall [ @nodeExists(node), (cb2) ->
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
        async.waterfall [ @nodeExists(node), (cb2) ->
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

parseEl = (xml) ->
    try
        return ltx.parse(xml)
    catch e
        console.error "Parsing " + xml + ": " + e.stack
        return undefined

