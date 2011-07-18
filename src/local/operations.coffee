async = require('async')
errors = require('./errors')

transaction = null
exports.setBackend = (backend) ->
    transaction = backend.transaction

##
# Is created with options from the request
#
# Implementations set result
class Operation
    constructor: (request) ->
        @req = request

    run: (cb) ->
        cb new errors.NotImplemented("Operation defined but not yet implemented")

class ModelOperation extends Operation
    run: (cb) ->
        model.transaction (err, t) ->
            if err
                return req.callback err

            @transaction t, (err) ->
                if err
                    t.rollback ->
                        cb err
                else
                    t.commit ->
                        cb


    # Must be implemented by subclass
    transaction: (t, cb) ->
        cb null


class PrivilegedOperation extends Operation

    transaction: (t, cb) ->
        # TODO: Check privileges

        @privilegedTransaction t, cb


class BrowseInfo extends Operation

    run: (cb) ->
        cb()

class Register extends ModelOperation
    # TODO: overwrite @run() and check if this component is
    # authoritative for the requesting user's domain
    transaction: (t, cb) ->

class Publish extends PrivilegedOperation
    requiredAffiliation: 'publisher'

    privilegedTransaction: (t, cb) ->
        steps = @req.items.map (item) =>
            (cb2) =>
                t.writeItem @req.actor, @req.node, item.id, item.els[0].toString(), cb2
        steps.push cb
        async.series steps



OPERATIONS =
    'browse-node-info': undefined
    'browse-info': BrowseInfo
    'register-user': Register
    'publish-node-items': Publish

exports.run = (request) ->
    opName = request.operation()
    opClass = OPERATIONS[opName]

    unless opClass
        console.error "Unimplemented operation #{opName}"
        request.replyError(new errors.NotImplemented("Unimplemented operation #{opName}"))
        return

    op = new opClass(request)
    op.run (error, result) ->
        if error
            request.replyError error
        else
            request.reply result

