async = require('async')

class Synchronization
    constructor: (@router, node) ->
        @request = {
            operation: => @operation,
            node,
            rsm: {}
        }

    run: (t, cb) ->
        @router.run @request, cb


class ConfigSynchronization extends Synchronization
    operation: 'retrieve-node-configuration'

##
# Walks items with RSM
class PaginatedSynchronization extends Synchronization
    run: (t, cb) ->
        # for detecting RSM loops
        seenOffsets = {}
        walk = (offset) =>
            @request.rsm.after ?= offset
            super t, (err, results) =>
                if err
                    return cb err

                # reset() only after 1st successful result
                unless @resetted  # (excuse my grammar)
                    # TODO: is async!
                    @reset(t)
                    @resetted = true
                async.forEach results, (item, cb2) =>
                    @writeItem t, item, (err) ->
                        cb2()
                , (err) ->
                    if err
                        return cb results

                    offset = results.rsm?.last
                    if offset
                        # Remote supports RSM, walk:
                        if seenOffsets.hasOwnProperty(offset)
                            cb new Error("RSM offset loop detected for #{@request.node}")
                        else
                            seenOffsets[offset] = true
                            walk offset
                    else
                        # No RSM support, done:
                        cb()
        # Go
        walk()

class ItemsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        # clear table

    operation: 'retrieve-node-items'

    writeItem: (t, item, cb) ->



syncNode = (router, model, node, cb) ->
    async.forEachSeries [ConfigSynchronization, ItemsSynchronization]
    , (syncClass, cb2) ->
        synchronization = new syncClass(router, node)
        model.transaction (err, t) ->
            if err
                console.error err.stack or err
                return cb2 err

            synchronization.run (err) ->
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
