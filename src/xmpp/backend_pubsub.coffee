notifications = require('./pubsub_notifications')

##
# Initialize with XMPP connection
class exports.PubsubBackend
    constructor: (@conn) ->
        # TODO: notifications?
        @disco = new BuddycloudDiscovery(@conn)

    getMyJids: ->
        [@conn.jid]

    run: (opts, cb) ->
        # TODO: what class to spawn? → operations.run
        new Request(conn, opts, cb)

    notify: (notification) ->
        nKlass = notifications.byOperation notification.operation
        return false unless nKlass

        n = new nKlass(notification)
        # TODO: is local? send to all resources...
        console.log n.toStanza(@conn.jid, notification.listener).toString()
        @conn.send n.toStanza(@conn.jid, notification.listener)


class BuddycloudDiscovery
    constructor: (@conn) ->
        @infoCache = new RequestCache
        @itemsCache = new RequestCache

    authorizeFor: (sender, actor, cb) ->
        @itemsCache.get getUserDomain(actor), (err, items) ->
            if err
                return cb err
            valid = items?.some (item) ->
                item.jid is sender
            cb null, valid

    findService: (user, cb) ->
        domain = user
        @itemsCache.get domain, (err, items) =>
            if err
                return cb err

            # Respond on earliest, or if nothing to do
            pending = 1
            done = () ->
                pending--
                # No items left, but no result yet?
                if pending < 1 and not resultSent
                    cb new errors.NotFound("No pubsub channels service discovered")
            resultSent = false
            for item in items
                @infoCache.get item, (err, result) ->
                    for identity in identities
                        if identity.category is "pubsub" and
                           identity.type is "channels" and
                           not resultSent
                            # Found one!
                            resultSent = true
                            cb null, item.jid
                    done()
            done()

class RequestCache
    cacheTimeout: 30 * 1000

    constructor: (@getter) ->
        @entries = {}

    get: (id, cb) ->
        unless @entries.hasOwnProperty(id)
            @entries[id] =
                queued: cb
            # Go fetch
            @getter id, (err, results) =>
                queued = @entries[id].queued
                @entries[id] = if err then { err } else { results }
                # flush after timeout
                setTimeout =>
                    delete @entries[id]
                , @cacheTimeout
                # respond to requests
                for cb in queued
                    cb err, results
        else if @entries[id].queued?
            # Already fetching
            @entries[id].queued.push cb
        else
            # Result already present
            process.nextTick =>
                cb @entries[id].err, @entries[id].results


getUserDomain = (user) ->
    if user.indexOf('@') >= 0
        user.substr(user.indexOf('@') + 1)
    else
        user

