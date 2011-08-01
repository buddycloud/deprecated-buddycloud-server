xmpp = require('node-xmpp')
async = require('async')
NS = require('./ns')

class Request
    constructor: (conn, opts, cb) ->
        @opts = opts
        iq = @requestIq().root()
        iq.attrs.to = opts.jid
        conn.sendIq iq, (errorStanza, replyStanza) =>
            if errorStanza
                # TODO: wrap errorStanza
                cb new Error("Error from remote server")
            else
                result = null
                err = null
                try
                    result = @decodeReply replyStanza
                catch e
                    err = e
                cb err, result

    requestIq: ->
        throw new TypeError("Unimplemented request")

    decodeReply: (stanza) ->
        throw new TypeError("Unimplemented reply")


class DiscoverRequest extends Request
    xmlns: undefined

    requestIq: ->
        queryAttrs =
            xmlns: @xmlns
        if @opts.node?
                queryAttrs.node = @opts.node
        new xmpp.Element('iq', type: 'get').
            c('query', queryAttrs)

    decodeReply: (stanza) ->
        @results = []
        queryEl = stanza?.getChild('query', @xmlns)
        if queryEl
            for child in queryEl.children
                unless typeof child is 'string'
                    @decodeReplyEl child
        @results

    # Can add to @results
    decodeReplyEl: (el) ->


class exports.DiscoverItems extends DiscoverRequest
    xmlns: NS.DISCO_ITEMS

    decodeReplyEl: (el) ->
        if el.is('item', @xmlns) and el.attrs.jid?
            result = { jid: el.attrs.jid }
            if el.attrs.node
                result.node = el.attrs.node
            @results.push result

class exports.DiscoverInfo extends DiscoverRequest
    xmlns: NS.DISCO_INFO

    decodeReplyEl: (el) ->
        @results.identities ?= []
        @results.features ?= []
        @results.forms ?= []
        switch el.getName()
            when "identity"
                @results.identities.push
                    name: el.attrs.name
                    category: el.attrs.category
                    info: el.attrs.info
            when "feature"
                @results.features.push el.attrs.variable
            when "form"
                # TODO: .getForm(formType)
                @results.forms.push
