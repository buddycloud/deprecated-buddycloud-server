errors = require('./errors')

transaction = null
exports.setBackend = (backend) ->
    transaction = backend.transaction

##
# Is created with options from the request
#
# Implementations set result
class Operation
    constructor: (handler) ->
        @handler = handler

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
        # Check privileges


class BrowseInfo extends Operation

    run: (cb) ->
        cb()


OPERATIONS =
    'browse-node-info': undefined
    'browse-info': BrowseInfo

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

