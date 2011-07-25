##
# Initialize with XMPP connection
class exports.PubsubBackend
    constructor: (@conn) ->
        # TODO: notifications?
        @disco = new BuddycloudDiscovery(@conn)

    request: (opts, cb) ->
        new Request(conn, opts, cb)

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

getUserDomain = (user) ->
    if user.indexOf('@') >= 0
        user.substr(user.indexOf('@') + 1)
    else
        user

