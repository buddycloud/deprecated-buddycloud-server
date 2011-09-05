{EventEmitter} = require('events')
async = require('async')
{Notification} = require('./pubsub_notifications')
pubsubClient = require('./pubsub_client')
errors = require('../errors')
NS = require('./ns')
forms = require('./forms')

##
# Initialize with XMPP connection
class exports.PubsubBackend extends EventEmitter
    constructor: (@conn) ->

        @conn.on 'message', (args...) =>
            @onMessage_(args...)

        @disco = new BuddycloudDiscovery(@conn)
        @authorizeFor = (args...) =>
            @disco.authorizeFor(args...)

    getMyJids: ->
        [@conn.jid]

    run: (router, opts, cb) ->
        if opts.jid?
            # Target server already known
            reqClass = pubsubClient.byOperation(opts.operation)
            unless reqClass
                return cb(new errors.FeatureNotImplemented("Operation #{opts.operation} not implemented for remote pubsub"))

            req = new reqClass @conn, opts, (err, result) ->
                if err
                    cb err
                else
                    # Successfully done at remote
                    if (localPushData = req.localPushData?())
                        router.pushData localPushData, (err) ->
                            cb err, result
                    else
                        cb null, result
        else
            # Discover first
            user = getNodeUser opts.node
            unless user
                return cb new errors.NotFound("Unrecognized node form")

            console.log 'PubsubBackend.run': opts, user: user
            @disco.findService user, (err, service) =>
                if err
                    return cb err

                if @getMyJids().indexOf(service) >= 0
                    # is local, return to router
                    return cb new errors.SeeLocal()
                else
                    opts2 = Object.create(opts)
                    opts2.jid = service
                    # Target server now known, recurse:
                    @run router, opts2, cb

    notify: (opts) ->
        notification = Notifications.make(opts)
        listener = opts.listener
        if listener.indexOf("@") >= 0
            # is user? send to all resources...
            for onlineJid in @conn.getOnlineResources listener
                console.log "notifying client #{onlineJid} for #{opts.node}"
                @conn.send notification.toStanza(@conn.jid, onlineJid)
        else
            # other component (inbox)? just send out
            console.log "notifying service #{listener} for #{opts.node}"
            @conn.send notification.toStanza(@conn.jid, listener)

    # <message from='pubsub.shakespeare.lit' to='francisco@denmark.lit' id='foo'>
    #
    # TODO: encapsulate XMPP protocol cruft
    onMessage_: (message) ->
        sender = message.attrs.from
        updates = []

        for child in message.children
            unless child.is
                # Ignore any text child
                continue

            # <event xmlns='http://jabber.org/protocol/pubsub#event'>
            if child.is("event", NS.PUBSUB_EVENT)
                child.children.forEach (child) ->
                unless child.is
                    # No element, but text
                    return
                node = child.attrs.node
                unless node
                    return

                if child.is('items')
                    items = []
                    for itemEl in child.getChildren('item')
                        item =
                            el: itemEl.children.filter((itemEl) ->
                                itemEl.hasOwnProperty('children')
                            )[0]
                        if itemEl.attrs.id
                            item.id = itemEl.attrs.id
                        if item.el
                            items.push item
                    updates.push
                        type: 'items'
                        node: node
                        items: items

                if child.is('subscription')
                    updates.push
                        type: 'subscription'
                        node: node
                        user: child.attrs.jid
                        subscription: child.attrs.subscription

                if child.is('affiliation')
                    updates.push
                        type: 'affiliation'
                        node: node
                        user: child.attrs.jid
                        affiliation: child.attrs.affiliation

                if child.is('configuration')
                    xEl = child.getChild('x', NS.DATA)
                    form = xEl and forms.fromXml(xEl)
                    config = form and forms.formToConfig(form)
                    if config
                        updates.push
                            type: 'config'
                            node: node
                            config: config

            # <you-missed-something/>
            if child.is("you-missed-something", NS.BUDDYCLOUD_V1)
                @emit 'syncNeeded', sender

            # data form
            if child.is("x", NS.DATA)
                form = forms.fromXml(child)
                if form.type is 'form' and
                   form.getFormType() is NS.PUBSUB_SUBSCRIBE_AUTHORIZATION
                    # authorization prompt
                    node = form.get('pubsub#node')
                    user = form.get('pubsub#subscriber_jid')
                    @emit 'authorizationPrompt', { node, user }
                else if form.type is 'submit' and
                        form.getFormType() is NS.PUBSUB_SUBSCRIBE_AUTHORIZATION
                        # authorization confirm
                    node = form.get('pubsub#node')
                    user = form.get('pubsub#subscriber_jid')
                    allow = form.get('pubsub#allow')
                    @emit 'authorizationConfirm', { node, user, allow }

        # Which nodes' updates pertain our local cache?
        async.filter(updates, (update, cb) =>
            user = getNodeUser(update.node)
            unless user
                return cb(false)
            # Security: authorize
            @authorizeFor sender, user, (err, valid) ->
                cb(!err && valid)
        , (updates) =>
            if updates? and updates.length > 0
                # Apply pushed updates
                @emit 'notificationPush', updates
        )


class BuddycloudDiscovery
    constructor: (@conn) ->
        @infoCache = new RequestCache (id, cb) =>
            new pubsubClient.DiscoverInfo(@conn, { jid: id }, cb)
        @itemsCache = new RequestCache (id, cb) =>
            console.log "discover items of #{id}"
            new pubsubClient.DiscoverItems(@conn, { jid: id }, cb)

    authorizeFor: (sender, actor, cb) ->
        @itemsCache.get getUserDomain(actor), (err, items) ->
            if err
                return cb err
            valid = items?.some (item) ->
                item.jid is sender
            console.log "authorizing #{sender} for #{actor}: #{valid}"
            cb null, valid

    findService: (user, cb) ->
        domain = getUserDomain(user)
        @itemsCache.get domain, (err, items) =>
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
                    for identity in result?.identities or []
                        if identity.category is "pubsub" and
                           identity.type is "channels" and
                           not resultSent
                            # Found one!
                            resultSent = true
                            console.log "found service for #{user}: #{item.jid}"
                            cb null, item.jid
                    done()
                pending++
            # `pending' initialized with 1, to not miss the items=[] case
            done()

class RequestCache
    cacheTimeout: 30 * 1000

    constructor: (@getter) ->
        @entries = {}

    get: (id, cb) ->
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


nodeRegexp = /^\/user\/([^\/]+)\/?(.*)/
getNodeUser = (node) ->
    unless node
        return null

    m = nodeRegexp.exec(node)
    unless m
        return null

    m[1]
