logger = require('../logger').makeLogger 'xmpp/backend_pubsub'
{inspect} = require('util')
{EventEmitter} = require('events')
async = require('async')
xmpp = require('node-xmpp')
Notifications = require('./pubsub_notifications')
pubsubClient = require('./pubsub_client')
errors = require('../errors')
NS = require('./ns')
forms = require('./forms')
{getNodeUser, getUserDomain} = require('../util')

##
# Initialize with XMPP connection
class exports.PubsubBackend extends EventEmitter
    constructor: (@conn) ->

        @conn.on 'message', (args...) =>
            @onMessage_(args...)

        @disco = new BuddycloudDiscovery(@conn)
        @authorizeFor = @disco.authorizeFor
        @detectAnonymousUser = @disco.detectAnonymousUser

    getMyJids: ->
        [@conn.jid]

    isUserOnline: (user) ->
        @conn.getOnlineResources(user).length > 0

    run: (router, opts, cb) ->
        if opts.jid?
            # Target server already known
            reqClass = pubsubClient.byOperation(opts.operation)
            unless reqClass
                return cb(new errors.FeatureNotImplemented("Operation #{opts.operation} not implemented for remote pubsub"))

            req = new reqClass @conn, @disco, opts, (err, result) ->
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

            logger.debug "PubsubBackend.run user: #{user}, opts: #{inspect opts}"
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
        if opts.length < 1
            # Avoid empty notifications
            return

        notification = Notifications.make(opts)
        listener = opts.listener
        try
            if not opts.replay and listener and listener.indexOf("@") >= 0
                # is user? send to all resources...
                #
                # except for replays, which are requested by a certain
                # fullJID
                for onlineJid in @conn.getOnlineResources listener
                    logger.info "notifying client #{onlineJid} for #{opts.node}"
                    @conn.send notification.toStanza(@conn.jid, onlineJid)
            else if listener
                # other component (inbox)? just send out
                logger.info "notifying #{listener} for #{opts.node}"
                @conn.send notification.toStanza(@conn.jid, listener)
        catch e
            if e.constructor is errors.MaxStanzaSizeExceeded and opts.length > 1
                # FIXME: a notification may have been sent already to a previous shorter listener jid
                copyProps = (opts_) ->
                    ['type', 'node', 'user', 'listener', 'replay', 'queryId'].forEach (prop) ->
                        opts_[prop] = opts[prop]
                pivot = Math.floor(opts.length / 2)
                opts1 = opts.slice(0, pivot)
                copyProps opts1
                opts2 = opts.slice(pivot, opts.length)
                copyProps opts2
                logger.warn "MaxStanzaSizeExceeded: split notification from #{opts.length} into #{opts1.length}+#{opts2.length}"
                @notify opts1
                @notify opts2
            else
                throw e

    # <message from='pubsub.shakespeare.lit' to='francisco@denmark.lit' id='foo'>
    #
    # TODO: encapsulate XMPP protocol cruft
    onMessage_: (message) ->
        sender = new xmpp.JID(message.attrs.from).bare().toString()
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

                    if child.is('affiliations')
                        for affEl in child.getChildren('affiliation')
                            updates.push
                                type: 'affiliation'
                                node: node
                                user: affEl.attrs.jid
                                affiliation: affEl.attrs.affiliation

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
                    nodeOwner = getNodeUser node
                    if nodeOwner
                        @emit 'authorizationPrompt', { node, user, sender, nodeOwner }
                else if form.type is 'submit' and
                        form.getFormType() is NS.PUBSUB_SUBSCRIBE_AUTHORIZATION
                    # authorization confirm
                    node = form.get('pubsub#node')
                    user = form.get('pubsub#subscriber_jid')
                    allow = (form.get('pubsub#allow') is 'true')
                    actor = form.get('buddycloud#actor') or sender
                    @emit 'authorizationConfirm', { node, user, allow, actor, sender }

        # Which nodes' updates pertain our local cache?
        async.filter updates, (update, cb) =>
            user = getNodeUser(update.node)
            unless user
                return cb false
            # Security: authorize
            @authorizeFor sender, user, (err, valid) ->
                cb not err and valid
        , (updates) =>
            # Add a listener to each subscription update
            async.map updates, (update, cb2) =>
                if update.type is 'subscription'
                    @disco.findService update.user, (err, service) =>
                        if service?
                            # If remote user, listener = sender. If local user, listener = user.
                            update.listener = if @getMyJids().indexOf(service) >= 0 then update.user else sender
                        cb2 err, update
                else
                    cb2 null, update
            , (err, updates) =>
                if err
                    logger.error "incoming message: #{err.stack or err.message or err}"
                    return
                if updates? and updates.length > 0
                    updates.sender = sender
                    updates.actor = sender
                    # Apply pushed updates
                    @emit 'notificationPush', updates


class BuddycloudDiscovery
    constructor: (@conn) ->
        @infoCache = new RequestCache (id, cb) =>
            new pubsubClient.DiscoverInfo(@conn, @, { jid: id }, cb)
        @itemsCache = new RequestCache (id, cb) =>
            logger.debug "discover items of #{id}"
            new pubsubClient.DiscoverItems(@conn, @, { jid: id }, cb)

    authorizeFor: (sender, actor, cb) =>
        @itemsCache.get getUserDomain(actor), (err, items) ->
            if err
                return cb err
            valid = items?.some (item) ->
                item.jid is sender
            logger.debug "authorizing #{sender} for #{actor}: #{valid}"
            cb null, valid

    findService: (user, cb) =>
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
                    cb new errors.NotFound("No pubsub channel service discovered for #{user}")
            items.forEach (item) =>
                @infoCache.get item.jid, (err, result) ->
                    for identity in result?.identities or []
                        if identity.category is "pubsub" and
                           identity.type is "channels" and
                           not resultSent
                            # Found one!
                            resultSent = true
                            logger.debug "found service for #{user}: #{item.jid}"
                            cb null, item.jid
                    done()
                pending++
            # `pending' initialized with 1, to not miss the items=[] case
            done()

    findFeatures: (jid, cb) =>
        @infoCache.get jid, (err, results) ->
            cb err, results?.features

    ##
    # @param user {String} Bare JID
    # @param cb {Function} callback(error, isAnonymous)
    detectAnonymousUser: (user, cb) =>
        @infoCache.get user, (err, result) ->
            isAnonymous = false
            results?.identities?.forEach (identity) ->
                isAnonymous ||=
                    identity.category is "account" and
                    identity.type is "anonymous"
            cb err, isAnonymous

class RequestCache
    cacheTimeout: 30 * 1000

    constructor: (@getter) ->
        @entries = {}

    get: (id, cb) ->
        unless @entries.hasOwnProperty(id)
            logger.trace "Cache miss for #{id}"
            @entries[id] =
                queued: [cb]
            # Go fetch
            @getter id, (err, results) =>
                queued = @entries[id].queued
                @entries[id] = { err, results }
                # flush after timeout
                setTimeout =>
                    delete @entries[id]
                , @cacheTimeout
                # respond to requests
                for cb1 in queued
                    cb1 err, results
        else if @entries[id].queued?
            # Already fetching
            logger.trace "Queued for #{id}"
            @entries[id].queued.push cb
        else
            # Result already present
            logger.trace "Cache hit for #{id}"
            entry = @entries[id]
            process.nextTick ->
                cb entry.err, entry.results
