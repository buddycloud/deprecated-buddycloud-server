logger = require('../logger').makeLogger 'xmpp/pubsub_client'
xmpp = require('node-xmpp')
async = require('async')
NS = require('./ns')
errors = require('../errors')
forms = require('./forms')
RSM = require('./rsm')

class Request
    constructor: (conn, @disco, @opts, cb) ->
        @myJid = conn.jid
        @checkFeatures (err) =>
            if err
                logger.warn err
                return cb err

            iq = @requestIq().root()
            iq.attrs.to = @opts.jid
            conn.sendIq iq, (err, replyStanza) =>
                if err
                    # wrap <error/> child
                    return cb err

                result = null
                err = null
                try
                    result = @decodeReply replyStanza
                catch e
                    logger.error e.stack
                    err = e
                process.nextTick ->
                    cb err, result

    checkFeatures: (cb) ->
        cb null

    requestIq: ->
        throw new TypeError("Unimplemented request")

    decodeReply: (stanza) ->
        throw new TypeError("Unimplemented reply")

###
# XEP-0030: Service Discovery
###

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
        @results.config ?= null
        if el.is('identity', @xmlns)
            @results.identities.push
                name: el.attrs.name
                category: el.attrs.category
                type: el.attrs.type
        else if el.is('feature', @xmlns)
            @results.features.push el.attrs.var
        else if el.is('x', NS.DATA)
            form = forms.fromXml(el)
            if form.getFormType() is NS.PUBSUB_META_DATA
                @results.config = forms.formToConfig(form)

##
# XEP-0060
##

class PubsubRequest extends Request
    xmlns: NS.PUBSUB
    requestIq: ->
        pubsubEl = new xmpp.Element('iq', type: @iqType()).
            c('pubsub', xmlns: @xmlns)
        child = @pubsubChild()
        if child instanceof Array
            for el in child
                pubsubEl.cnode el.root()
        else
            pubsubEl.cnode child.root()
        if @opts.actor
            pubsubEl.c('actor', xmlns: NS.BUDDYCLOUD_V1)
                .t(@opts.actor)
        if @opts.rsm
            pubsubEl.cnode @opts.rsm.toXml()
        pubsubEl.up()

    iqType: ->
        throw new TypeError("Unimplemented request")

    pubsubChild: ->
        throw new TypeError("Unimplemented reply")

    decodeReply: (stanza) ->
        @results = []
        pubsubEl = stanza?.getChild('pubsub', @xmlns)
        if pubsubEl?
            if @decodeReplyEl?
                for child in pubsubEl.children
                    unless typeof child is 'string'
                        @decodeReplyEl child
            # With fromRemote=true so that remote RSM information
            # won't be overwritten by RSM.setReplyInfo():
            @results.rsm = RSM.fromXml(pubsubEl.getChild('set', NS.RSM), true)
        @results

class CreateNode extends PubsubRequest
    iqType: ->
        'set'

    pubsubChild: ->
        new xmpp.Element('create', node: @opts.node)

class Publish extends PubsubRequest
    iqType: ->
        'set'

    pubsubChild: ->
        publishEl = new xmpp.Element('publish', node: @opts.node)
        for item in @opts.items
            itemAttrs = {}
            itemAttrs.id ?= item.id
            publishEl.c('item', itemAttrs).
                cnode(item.el)
        publishEl

class RetractItems extends PubsubRequest
    iqType: ->
        'set'

    pubsubChild: ->
        publishEl = new xmpp.Element('retract', node: @opts.node)
        for item in @opts.items
            publishEl.c('item', id: item)
        publishEl

class Subscribe extends PubsubRequest
    iqType: ->
        'set'

    checkFeatures: (cb) ->
        if @opts.temporary? and @opts.temporary
            @disco.findFeatures @opts.jid, (err, features) =>
                if err
                    return cb err
                if NS.PUBSUB_SUBSCRIPTION_OPTIONS in features
                    return cb null
                else
                    return cb new errors.FeatureNotImplemented("Subscription options not implemented on #{@opts.jid}")
        else
            return cb null

    pubsubChild: ->
        els = [new xmpp.Element('subscribe', node: @opts.node, jid: @opts.actor)]
        if @opts.temporary? and @opts.temporary
            els.push new xmpp.Element('options', node: @opts.node, jid: @opts.actor)
                .c('x', xmlns: NS.DATA)
                .c('field', var: 'FORM_TYPE', type: 'hidden')
                .c('value').t('http://jabber.org/protocol/pubsub#subscribe_options').up().up()
                .c('field', var: 'pubsub#expire')
                .c('value').t('presence')
                .root()
        return els

    decodeReplyEl: (el) ->
        if el.is('subscription', @xmlns) and
           el.attrs.node is @opts.node
            @results.user ?= el.attrs.jid or @opts.actor
            @results.subscription ?= el.attrs.subscription or 'subscribed'
            @results.temporary ?= el.attrs.temporary? and el.attrs.temporary is '1'

    localPushData: ->
        if @results.subscription is 'subscribed'
            [{
                type: 'subscription'
                node: @opts.node
                user: @results.user
                listener: @opts.sender
                subscription: @results.subscription
                temporary: @results.temporary
            }]
        else
            []

class Unsubscribe extends PubsubRequest
    iqType: ->
        'set'

    pubsubChild: ->
        new xmpp.Element('unsubscribe', node: @opts.node)

    localPushData: ->
        [{
            type: 'subscription'
            node: @opts.node
            user: @opts.actor
            subscription: 'none'
        }]

class RetrieveItems extends PubsubRequest
    iqType: ->
        'get'

    pubsubChild: ->
        new xmpp.Element('items', node: @opts.node)

    decodeReplyEl: (el) ->
        if el.is('items', @xmlns)
            for itemEl in el.getChildren('item')
                @results.push
                    id: itemEl.attrs.id
                    el: itemEl.children.filter((child) ->
                        child isnt 'string'
                    )[0]

class RetrieveUserSubscriptions extends PubsubRequest
    iqType: ->
        'get'

    pubsubChild: ->
        new xmpp.Element('subscriptions')

    decodeReplyEl: (el) ->
        if el.is('subscriptions', @xmlns)
            for subscriptionEl in el.getChildren('subscription')
                subscription = {}
                subscription.user ?= subscriptionEl.attrs.jid
                subscription.subscription ?= subscriptionEl.attrs.subscription
                subscription.node ?= subscriptionEl.attrs.node
                @results.push subscription

class PubsubOwnerRequest extends PubsubRequest
    xmlns: NS.PUBSUB_OWNER

class RetrieveNodeSubscriptions extends PubsubOwnerRequest
    iqType: ->
        'get'

    pubsubChild: ->
        new xmpp.Element('subscriptions', node: @opts.node)

    decodeReplyEl: (el) ->
        if el.is('subscriptions', @xmlns)
            for subscriptionEl in el.getChildren('subscription')
                @results.push
                    user: subscriptionEl.attrs.jid
                    subscription: subscriptionEl.attrs.subscription

class RetrieveNodeAffiliations extends PubsubOwnerRequest
    iqType: ->
        'get'

    pubsubChild: ->
        new xmpp.Element('affiliations', node: @opts.node)

    decodeReplyEl: (el) ->
        if el.is('affiliations', @xmlns)
            for affiliationEl in el.getChildren('affiliation')
                @results.push
                    user: affiliationEl.attrs.jid
                    affiliation: affiliationEl.attrs.affiliation

class ManageNodeSubscriptions extends PubsubOwnerRequest
    iqType: ->
        'set'

    pubsubChild: ->
        subscriptionsEl = new xmpp.Element('subscriptions', node: @opts.node)
        for subscription in @opts.subscriptions
            subscriptionsEl.c 'subscription',
                jid: subscription.user
                subscription: subscription.subscription
        subscriptionsEl

class ManageNodeAffiliations extends PubsubOwnerRequest
    iqType: ->
        'set'

    pubsubChild: ->
        affiliationsEl = new xmpp.Element('affiliations', node: @opts.node)
        for affiliation in @opts.affiliations
            affiliationsEl.c 'affiliation',
                jid: affiliation.user
                affiliation: affiliation.affiliation
        affiliationsEl

class RetrieveNodeConfiguration extends PubsubOwnerRequest
    iqType: ->
        'get'

    pubsubChild: ->
        new xmpp.Element('configure', node: @opts.node)

    decodeReplyEl: (el) ->
        if el.is('configure', @xmlns)
            xEl = el.getChild('x', NS.DATA)
            form = xEl and forms.fromXml(xEl)
            @results.config ?= form and forms.formToConfig(form)

class ManageNodeConfiguration extends PubsubOwnerRequest
    iqType: ->
        'set'

    pubsubChild: ->
        new xmpp.Element('configure', node: @opts.node).
            cnode(forms.configToForm(@opts.config, 'submit', NS.PUBSUB_NODE_CONFIG).toXml())


# No <iq/> but a <message/> without expected reply
class AuthorizeSubscriber
    constructor: (conn, disco, @opts, cb) ->
        conn.send @makeStanza()
        cb()

    makeStanza: ->
        form = new forms.Form('submit', NS.PUBSUB_SUBSCRIBE_AUTHORIZATION)
        form.addField 'pubsub#node', 'text-single',
            'Node', @opts.node
        form.addField 'pubsub#subscriber_jid', 'jid-single',
            'Subscriber Address', @opts.user
        form.addField 'pubsub#allow', 'boolean',
            'Allow?', (if @opts.allow then 'true' else 'false')
        form.addField 'buddycloud#actor', 'jid-single',
            'Authorizing actor', @opts.actor

        new xmpp.Element('message',
                type: 'headline'
                to: @opts.jid
            ).cnode form.toXml()


REQUESTS =
    'browse-node-info': exports.DiscoverInfo
    'browse-info': exports.DiscoverInfo
    'create-node': CreateNode
    'publish-node-items': Publish
    'subscribe-node': Subscribe
    'unsubscribe-node': Unsubscribe
    'retrieve-node-items': RetrieveItems
    'retract-node-items': RetractItems
    'retrieve-user-subscriptions': RetrieveUserSubscriptions
    'retrieve-node-subscriptions': RetrieveNodeSubscriptions
    'retrieve-node-affiliations': RetrieveNodeAffiliations
    'manage-node-subscriptions': ManageNodeSubscriptions
    'manage-node-affiliations': ManageNodeAffiliations
    'retrieve-node-configuration': RetrieveNodeConfiguration
    'manage-node-configuration': ManageNodeConfiguration
    'confirm-subscriber-authorization': AuthorizeSubscriber

exports.byOperation = (opName) ->
    REQUESTS[opName]
