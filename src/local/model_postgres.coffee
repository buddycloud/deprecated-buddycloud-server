##
# PostgreSQL backend
#
# For table subscriptions:
# * "user"  = "listener" means subscription to a local node
# * "user" != "listener" means subscription to a remote node

logger = require('../logger').makeLogger 'local/model_postgres'
pg = require("pg")
ltx = require("ltx")  # for item XML parsing & serialization
async = require("async")
errors = require("../errors")

# Required schema version -- don't forget to bump it as needed!
required_schema_version = 1

# ready DB connections
pool = []
# waiting transaction requests
queue = []

debugDB = (db) ->
    oldQuery = db.query
    db.query = (sql, params) ->
        logger.trace "query #{sql} #{JSON.stringify(params)}"
        oldQuery.apply(@, arguments)

# at start and when connection died
connectDB = (config) ->
    db = new pg.Client(config)
    debugDB db
    db.connect()
    # Reconnect in up to 5s
    db.on "error", (err) ->
        logger.error "Postgres: " + err.message
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

exports.checkSchemaVersion = ->
    withNextDb (db) ->
        db.query "SELECT MAX(version) FROM schema_version", (err, res) ->
            process.nextTick ->
                dbIsAvailable(db)

            version = 0
            if res?.rows?[0]?.max?
                version = res.rows[0].max

            if version < required_schema_version
                logger.error "Database schema too old: require version #{required_schema_version} but using #{version}. Please backup your DB and upgrade it using the scripts in the postgres folder."
                process.exit 1
            else if version > required_schema_version
                logger.error "Database schema too recent: require version #{required_schema_version} but using #{version}. Please update the server to a version that matches your DB."
                process.exit 1

exports.cleanupTemporaryData = (cb) ->
    withNextDb (db) ->
        db.query "DELETE FROM subscriptions WHERE temporary=TRUE", (err) ->
            process.nextTick ->
                dbIsAvailable db
            cb err

exports.transaction = (cb) ->
    withNextDb (db) ->
        new Transaction(db, cb)

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
                logger.error err
                return

            res?.rows?.forEach (row) ->
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

LOST_TRANSACTION_TIMEOUT = 60 * 1000

##
# Wraps the postgres-js transaction with our model operations.
class Transaction
    constructor: (db, cb) ->
        @db = db
        db.query "BEGIN", [], (err, res) =>
            cb err, @

        timeout = setTimeout =>
            logger.error "Danger: lost transaction, rolling back!"
            timeout = undefined
            @rollback()
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

            cb? err

    rollback: (cb) ->
        @db.query "ROLLBACK", [], (err, res) =>
            @rmTimeout()
            process.nextTick =>
                dbIsAvailable @db

            cb? err

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
                    logger.warn "#{node} does not exist!"
                    cb new errors.NotFound("Node does not exist")

    nodeExists: (node, cb) ->
        @db.query "SELECT node FROM nodes WHERE node=$1", [ node ], (err, res) ->
            if err
                cb err
            else
                exists = res?.rows?[0]?
                unless exists
                    logger.warn "#{node} does not exist"
                cb null, exists

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

    purgeRemoteNode: (node, cb) ->
        db = @db
        q = (sql) ->
            (cb2) ->
                db.query sql, [ node ], cb2
        async.series [
            # Don't remove subscriptions: remote users are still subscribed to
            # the remote node
            q "DELETE FROM items WHERE node=$1"
            q "DELETE FROM affiliations WHERE node=$1"
            q "DELETE FROM node_config WHERE node=$1"
            q "DELETE FROM nodes WHERE node=$1 AND node NOT IN (SELECT node FROM subscriptions)"
        ], (err) ->
            unless err
                logger.info "Purged all data of node #{node}"
            cb err

    ##
    # only open ones
    #
    # cb(err, [{ node: String, title: String }])
    listNodes: (cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query """SELECT node FROM nodes
                        WHERE node IN (SELECT node FROM open_nodes)
                        ORDER BY node ASC""", cb2
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

    getSubscriptionListener: (node, user, cb) ->
        @db.query "SELECT listener FROM subscriptions WHERE node=$1 AND \"user\"=$2"
        , [ node, user ]
        , (err, res) ->
            cb err, res?.rows?[0]?.listener or "none"

    setSubscription: (node, user, listener, subscription, temporary, cb) ->
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
            logger.debug "setSubscription #{node} #{user} temporary=#{temporary} isSet=#{isSet} toDelete=#{toDelete}"
            if isSet and not toDelete
                if listener
                    db.query "UPDATE subscriptions SET listener=$1, subscription=$2, temporary=$3, updated=CURRENT_TIMESTAMP WHERE node=$4 AND \"user\"=$5"
                    , [ listener, subscription, temporary, node, user ]
                    , cb2
                else
                    db.query "UPDATE subscriptions SET subscription=$1, temporary=$2, updated=CURRENT_TIMESTAMP WHERE node=$3 AND \"user\"=$4"
                    , [ subscription, temporary, node, user ]
                    , cb2
            else if not isSet and not toDelete
                # listener=null is allowed for 3rd-party inboxes
                if listener
                    db.query "INSERT INTO subscriptions (node, \"user\", listener, subscription, temporary, updated) VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP)"
                    , [ node, user, listener, subscription, temporary ]
                    , cb2
                else
                    db.query "INSERT INTO subscriptions (node, \"user\", subscription, temporary, updated) VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)"
                    , [ node, user, subscription, temporary ]
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
            db.query "SELECT \"user\", subscription FROM subscriptions WHERE node=$1 AND temporary=FALSE ORDER BY updated ASC", [ node ], cb2
        , (res, cb2) ->
            subscribers = for row in res.rows
                { user: row.user, subscription: row.subscription }

            cb2 null, subscribers
        ], cb

    getTemporarySubscription: (node, user, cb) ->
        unless node
            return cb(new Error("No node"))
        unless user
            return cb(new Error("No user"))

        @db.query "SELECT subscription, temporary FROM subscriptions WHERE node=$1 AND \"user\"=$2"
        , [ node, user ]
        , (err, res) ->
            cb err, res?.rows?[0]?.subscription or "none", res?.rows?[0]?.temporary or false

    getUserTemporarySubscriptions: (user, cb) ->
        unless user
            return cb(new Error("No user"))

        @db.query "SELECT node, listener, subscription FROM subscriptions WHERE \"user\"=$1 AND temporary=TRUE ORDER BY updated ASC", [ user ], (err, res) ->
            cb err, res?.rows

    ##
    # Not only by users but also by listeners.
    # @param cb {Function} cb(Error, { user, node, subscription })
    getSubscriptions: (actor, cb) ->
        @db.query "SELECT \"user\", node, subscription FROM subscriptions WHERE (\"user\"=$1 OR listener=$1) AND temporary=FALSE ORDER BY updated ASC", [ actor ], (err, res) ->
            cb err, res?.rows

    getPending: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\" FROM subscriptions WHERE subscription = 'pending' AND node = $1 ORDER BY updated ASC", [ node ], cb2
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

    getNodeLocalListeners: (node, cb) ->
        @db.query """SELECT DISTINCT listener
                     FROM subscriptions
                     WHERE node=$1
                     AND listener=\"user\"
                     AND subscription='subscribed'"""
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

    walkModeratorAuthorizationRequests: (user, forPusher, iter, cb) ->
        if forPusher
            listenerCond = ''
            params = []
        else
            listenerCond = 'AND "user"=$1'
            params = [user]
        # TODO: make batched
        @db.query """SELECT "user", node
                     FROM subscriptions
                     WHERE subscription='pending'
                     AND node IN (SELECT node
                                  FROM affiliations
                                  WHERE (affiliation='owner' OR affiliation='moderator')
                                  #{listenerCond})"""
        , params
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
                db.query "UPDATE affiliations SET affiliation=$1, updated=CURRENT_TIMESTAMP WHERE node=$2 AND \"user\"=$3", [ affiliation, node, user ], cb2
            else if not isSet and not toDelete
                db.query "INSERT INTO affiliations (node, \"user\", affiliation, updated) VALUES ($1, $2, $3, CURRENT_TIMESTAMP)", [ node, user, affiliation ], cb2
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
            db.query "SELECT node, affiliation FROM affiliations WHERE \"user\"=$1 ORDER BY updated ASC", [ user ], cb2
        , (res, cb2) ->
            affiliations = for row in res.rows
                { node: row.node, affiliation: row.affiliation }
            cb2 null, affiliations
        ], cb

    getAffiliated: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\", affiliation FROM affiliations JOIN subscriptions USING (\"user\", node) WHERE affiliations.node=$1 AND subscriptions.temporary=FALSE ORDER BY affiliations.updated ASC", [ node ], cb2
        , (res, cb2) ->
            affiliations = for row in res.rows
                { user: row.user, affiliation: row.affiliation }

            cb2 null, affiliations
        ], cb

    getOutcast: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\" FROM affiliations WHERE affiliation = 'outcast' AND node = $1 ORDER BY updated ASC", [ node ], cb2
        , (res, cb2) ->
            cb2 null, res.rows.map((row) ->
                row.user
            )
        ], cb

    getOwnersByNodePrefix: (nodePrefix, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT DISTINCT \"user\" FROM affiliations WHERE node LIKE ($1 || '%') AND affiliation='owner'"
            , [ nodePrefix ]
            , cb2
        , (res, cb2) ->
            cb2 null, res.rows.map (row) -> row.user
        ], cb

    writeItem: (node, id, el, cb) ->
        db = @db
        async.waterfall [ @validateNode(node), (cb2) ->
            db.query "SELECT id FROM items WHERE node=$1 AND id=$2", [ node, id ], cb2
        , (res, cb2) ->
            isSet = res and res.rows and res.rows[0]
            xml = el.toString()
            params = [ node, id, xml ]
            pos = 4
            updated = el.getChildText('updated') or
                el.getChildText('published')
            if updated
                params.push updated
                updated_query = "$" + (pos++)
            else
                updated_query = "CURRENT_TIMESTAMP"
            irtEl = el.getChild('in-reply-to', 'http://purl.org/syndication/thread/1.0')
            if irtEl?.attrs.ref?
                params.push irtEl.attrs.ref
                irt_query = "$" + (pos++)
            else
                irt_query = "NULL"
            if isSet
                db.query "UPDATE items SET xml=$3, updated=#{updated_query}, in_reply_to=#{irt_query} WHERE node=$1 AND id=$2"
                , params
                , cb2
            else
                db.query "INSERT INTO items (node, id, xml, updated, in_reply_to) VALUES ($1, $2, $3, #{updated_query}, #{irt_query})"
                , params
                , cb2
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

    getRecentPosts: (subscriber, timeStart, maxItems, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query """SELECT node FROM subscriptions
                        WHERE  \"user\"=$1
                        AND    node LIKE '%/posts'
                        AND    subscription='subscribed'""", [ subscriber ], cb2
        , (res, cb2) ->
            async.map res?.rows, (row, cb3) ->
                node = row.node
                q = """SELECT id, node, xml, updated FROM items
                       WHERE node=$1
                       AND   updated >= $2::timestamp
                       ORDER BY updated DESC
                       LIMIT $3"""
                db.query q, [ node, timeStart, maxItems ], cb3
            , cb2
        , (res, cb2) ->
            items = []
            for r in res
                items = items.concat r?.rows.map (row) ->
                    node: row.node
                    id: row.id
                    globalId: "#{row.node};#{row.id}"
                    updated: row.updated
                    el: parseEl(row.xml)
            cb2 null, items
        ], cb

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
        logger.debug "setConfig " + node + ": " + require("util").inspect(config)
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
        @db.query "SELECT \"user\", listener FROM subscriptions WHERE node=$1 AND listener IS NOT NULL AND temporary=FALSE", [node], (err, res) =>
            if err
                return cb err

            userListeners = {}
            for row in res.rows
                userListeners[row.user] = row.listener

            @db.query "DELETE FROM subscriptions WHERE node=$1 AND temporary=FALSE", [node], (err) ->
                cb err, userListeners

    resetAffiliations: (node, cb) ->
        @db.query "DELETE FROM affiliations WHERE node=$1", [node], cb

    ##
    # MAM
    #
    # @param cb: Function(err, results)
    walkListenerArchive: (listener, start, end, max, forPusher, iter, cb) ->
        db = @db
        if forPusher
            params = []
            listenerCond = ""
        else
            params = [listener]
            listenerCond = "AND listener=$1"
        conds = ""
        i = params.length
        if start
            conds += "AND updated <= $#{i += 1}::timestamp"
            params.push start
        if end
            conds += " AND updated >= $#{i += 1}::timestamp"
            params.push end
        limit = if max
            params.push max
            "LIMIT $#{i += 1}"
        else
            ""

        q = (fields, table, cb2, mapper) ->
            db.query "SELECT #{fields}, updated FROM #{table} WHERE node in (SELECT node FROM subscriptions WHERE NOT temporary #{listenerCond}) #{conds} ORDER BY updated ASC #{limit}", params
            , (err, res) ->
                if err
                    return cb2 err

                if mapper
                    iter res.rows.map(mapper)
                else
                    iter res.rows
                cb2()

        async.parallel [ (cb2) ->
            db.query "SELECT node, MAX(updated) AS updated FROM node_config WHERE node in (SELECT node FROM subscriptions WHERE NOT temporary #{listenerCond}) #{conds} GROUP BY node ORDER BY updated ASC #{limit}", params
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
            logger.debug 'walkListenerArchive done'
            cb err

    ##
    # Stats
    ##

    getTopFollowedNodes: (count, timespan="7 days", nodePattern="/user/%@%/posts", cb) ->
        @db.query """SELECT node,
                            COUNT(user) AS count
                     FROM subscriptions
                     WHERE node LIKE $1
                       AND node IN (SELECT node FROM open_nodes)
                       AND updated >= CURRENT_TIMESTAMP - $2 :: INTERVAL
                     GROUP BY node
                     ORDER BY count DESC
                     LIMIT $3"""
        , [nodePattern, timespan, count]
        , (err, res) ->
            cb err, res?.rows

    getTopPublishedNodes: (count, timespan="7 days", nodePattern="/user/%@%/posts", cb) ->
        @db.query """SELECT node,
                            COUNT(xml) AS count
                     FROM items
                     WHERE node LIKE $1
                       AND node IN (SELECT node FROM open_nodes)
                       AND updated >= CURRENT_TIMESTAMP - $2 :: INTERVAL
                     GROUP BY node
                     ORDER BY count DESC
                     LIMIT $3"""
        , [nodePattern, timespan, count]
        , (err, res) ->
            cb err, res?.rows

parseEl = (xml) ->
    try
        return ltx.parse(xml)
    catch e
        logger.error "Parsing " + xml + ": " + e.stack
        return undefined
