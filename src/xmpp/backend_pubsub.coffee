notifications = require('./pubsub_notifications')
pubsubClient = require('./pubsub_client')
errors = require('../errors')

##
# Initialize with XMPP connection
class exports.PubsubBackend
    constructor: (@conn) ->
        @disco = new BuddycloudDiscovery(@conn)
        @authorizeFor = (args...) =>
            @disco.authorizeFor(args...)

    getMyJids: ->
        [@conn.jid]

    run: (router, opts, cb) ->
        user = getNodeUser opts.node
        console.log 'PubsubBackend.run': opts, user: user
        @disco.findService user, (err, service) =>
            if err
                return cb err

            if @getMyJids().indexOf(service) >= 0
                # is local, return to router
                router.runLocally opts, cb
            else
                operation = opts.operation()
                reqClass = pubsubClient.byOperation(operation)
                unless reqClass
                    cb new errors.FeatureNotImplemented("Operation #{operation} not implemented for remote pubsub")
                    return

                console.log optsBefore: opts
                opts2 = Object.create(opts)
                opts2.jid = service
                console.log optsAfter: [opts2, opts2.jid, opts2.node]
                req = new reqClass @conn, opts2, (err, result) ->
                    if err
                        cb err
                    else
                        cb null, result

    notify: (opts) ->
        notificationClass = notifications.byEvent notification.event
        return false unless notificationClass

        notification = new notificationClass(opts)
        # is local? send to all resources...
        for onlineJid in @conn.getOnlineResources notification.listener
            @conn.send notification.toStanza(@conn.jid, onlineJid)


class BuddycloudDiscovery
    constructor: (@conn) ->
        @infoCache = new RequestCache (id, cb) =>
            new pubsubClient.DiscoverInfo(@conn, { jid: id }, cb)
        @itemsCache = new RequestCache (id, cb) =>
            console.log "discover items of #{id}"
            new pubsubClient.DiscoverItems(@conn, { jid: id }, cb)

    authorizeFor: (sender, actor, cb) ->
        @itemsCache.get getUserDomain(actor), (err, items) ->
            console.log itemsCache: [err, items]
            if err
                return cb err
            valid = items?.some (item) ->
                item.jid is sender
            console.log "authorizing #{sender} for #{actor}: #{valid}"
            cb null, valid

    findService: (user, cb) ->
        domain = getUserDomain(user)
        @itemsCache.get domain, (err, items) =>
            console.log itemsCache: [err, items]
            if err
                return cb err

            # Respond on earliest, or if nothing to do
            pending = 1
            resultSent = false
            done = () ->
                pending--
                # No items left, but no result yet?
                if pending < 1 and not resultSent
                    resultSent = true
                    cb new errors.NotFound("No pubsub channels service discovered")
            items.forEach (item) =>
                @infoCache.get item.jid, (err, result) ->
                    console.log infoCacheErr: err, infoCache: result
                    for identity in result?.identities or []
                        console.log { identity, resultSent }
                        if identity.category is "pubsub" and
                           identity.type is "channels" and
                           not resultSent
                            # Found one!
                            resultSent = true
                            console.log "found service for #{user}: #{item.jid}"
                            cb null, item.jid
                    done()
                pending++
            done()

class RequestCache
    cacheTimeout: 30 * 1000

    constructor: (@getter) ->
        @entries = {}

    get: (id, cb) ->
        console.log 'RequestCache.get': [id,cb]
        unless @entries.hasOwnProperty(id)
            @entries[id] =
                queued: [cb]
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


nodeRegexp = /^\/user\/([^\/]+)\/(.+)/
getNodeUser = (node) ->
    unless node
        return null

    m = nodeRegexp.exec(node)
    unless m
        return null

    m[1]
