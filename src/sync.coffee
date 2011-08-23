async = require('async')
RSM = require('./xmpp/rsm')
NS = require('./xmpp/ns')

class Synchronization
    constructor: (@router, @node) ->
        @request = {
            operation: => @operation
            node: @node
            dontCache: true
        }

    run: (t, cb) ->
        @runRequest (err, results) =>
            if err
                return cb err

            @reset t, (err) =>
                if err
                    return cb err

                @writeResults t, results, cb

    runRequest: (cb) ->
        @router.runRemotely @request, cb


class ConfigSynchronization extends Synchronization
    operation: 'browse-node-info'

    reset: (t, cb) ->
        t.resetConfig(@node, cb)

    writeResults: (t, results, cb) ->
        console.log 'configResults': results
        if results.config
            t.setConfig(@node, results.config, cb)
        else
            cb(new Error("No pubsub meta data form found"))

##
# Walks items with RSM
class PaginatedSynchronization extends Synchronization
    constructor: ->
        super
        @request.rsm = new RSM.RSM()
        @request.rsm.max = 3

    run: (t, cb) ->
        # for detecting RSM loops
        seenOffsets = {}
        walk = (offset) =>
            console.log "walk", offset
            @request.rsm.after = offset
            @runRequest (err, results) =>
                console.log "ranRequest", err, results
                if err
                    return cb err

                go = (err) =>
                    if err
                        return cb err

                    @writeResults t, results, (err) =>
                        if err
                            return cb results

                        nextOffset = results.rsm?.last
                        if nextOffset
                            # Remote supports RSM, walk:
                            if seenOffsets.hasOwnProperty(nextOffset)
                                cb new Error("RSM offset loop detected for #{@request.node}: #{offset} already seen")
                            else
                                seenOffsets[nextOffset] = true
                                walk nextOffset
                        else
                            # No RSM support, done:
                            console.log("No RSM last")
                            cb()

                # reset() only after 1st successful result
                unless @resetted  # (excuse my grammar)
                    @resetted = true
                    @reset t, go
                else
                    go()
        # Go
        walk()

class ItemsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        t.resetItems(@node, cb)

    operation: 'retrieve-node-items'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            # TODO: author?
            t.writeItem @node, item.id, null, item.el, cb2
        , cb

class SubscriptionsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        t.resetSubscriptions @node, (err, @userListeners) =>
            cb err

    operation: 'retrieve-node-subscriptions'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            listener = @userListeners[item.user]
            t.setSubscription @node, item.user, listener, item.subscription, cb2
        , cb

class AffiliationsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        t.resetAffiliations(@node, cb)

    operation: 'retrieve-node-affiliations'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            t.setAffiliation @node, item.user, item.affiliations, cb2
        , cb


exports.syncNode = (router, model, node, cb) ->
    console.log "syncNode #{node}"
    async.forEachSeries [
        ConfigSynchronization, ItemsSynchronization,
        SubscriptionsSynchronization, AffiliationsSynchronization
    ]
    , (syncClass, cb2) ->
        synchronization = new syncClass(router, node)
        model.transaction (err, t) ->
            if err
                console.error err.stack or err
                return cb2 err

            synchronization.run t, (err) ->
                if err
                    console.error err.stack or err
                    t.rollback ->
                        cb2 err
                    return

                t.commit (err) ->
                    if err
                        return cb2 err

                    cb2()
    , cb
