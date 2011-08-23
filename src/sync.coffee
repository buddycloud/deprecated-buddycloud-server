async = require('async')
RSM = require('./xmpp/rsm')

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
        console.log 'router.run': @request, cb: cb
        @router.runRemotely @request, cb


class ConfigSynchronization extends Synchronization
    operation: 'retrieve-node-configuration'

    reset: (t, cb) ->
        cb()

    writeResults: (t, results, cb) ->
        t.setConfig @node, results, cb

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
            @request.rsm.after ?= offset
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

                        offset = results.rsm?.last
                        if offset
                            # Remote supports RSM, walk:
                            if seenOffsets.hasOwnProperty(offset)
                                cb new Error("RSM offset loop detected for #{@request.node}: #{offset} already seen")
                            else
                                seenOffsets[offset] = true
                                walk offset
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
        # TODO: clear table
        cb()

    operation: 'retrieve-node-items'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            # TODO: author?
            t.writeItem @node, item.id, null, item.el, cb2
        , cb



exports.syncNode = (router, model, node, cb) ->
    console.log "syncNode #{node}"
    async.forEachSeries [ConfigSynchronization, ItemsSynchronization]
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
