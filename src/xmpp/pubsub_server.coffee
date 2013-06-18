logger = require('../logger').makeLogger 'xmpp/pubsub_server'
xmpp = require('node-xmpp')
{ EventEmitter } = require('events')
{ inspect } = require('util')
NS = require('./ns')
forms = require('./forms')
errors = require('../errors')
RSM = require('./rsm')

##
# A request:
# * Unpacks the request
# * Specifies the operation to run
# * Compiles the response
class Request
    constructor: (stanza) ->
        @iq = stanza
        @sender = new xmpp.JID(stanza.attrs.from).bare().toString()
        @fullSender = stanza.attrs.from
        # can be overwritten by <actor xmlns="#{NS.BUDDYCLOUD_V1}"/>:
        @actor = @sender
        @me = stanza.attrs.to

    ##
    # Is this handler eligible for the request, or proceed to next
    # handler?
    matches: () ->
        false

    ##
    # Empty <iq type='result'/> by default
    reply: (child) ->
        @iq.reply child

    replyError: (error) ->
        @iq.replyError error

    callback: (err, results) ->
        if err
            @replyError err
        else
            try
                @reply results
            catch e
                if e.constructor is errors.MaxStanzaSizeExceeded and
                   results.length > 0
                    # Retry with smaller result set
                    logger.warn "MaxStanzaSizeExceeded: #{results.length} items"
                    if results.length >= 20
                        newLength = Math.floor(results.length / 2)
                    else
                        newLength = results.length - 1
                    smallerResults = results?.slice(0, newLength)
                    smallerResults.rsm ?= results?.rsm
                    @callback err, smallerResults
                else
                    throw e

    operation: undefined

    setActor: (childEl) ->
        actorEl = childEl?.getChild("actor", NS.BUDDYCLOUD_V1)
        if actorEl?
            @actor = actorEl.getText()
        # Elsewhile @actor stays @sender (see @constructor)

    setRSM: (childEl) ->
        # Even if there was no <set/> element,
        # code relies on @rsm being present
        rsmEl = childEl?.getChild('set', NS.RSM)
        @rsm = RSM.fromXml rsmEl

class NotImplemented extends Request
    matches: () ->
        true

    reply: () ->
        @replyError new errors.FeatureNotImplemented("Feature not implemented")

###
# XEP-0092: Software Version
###

# <iq type='get'
#     from='romeo@montague.net/orchard'
#     to='plays.shakespeare.lit'
#     id='info1'>
#   <query xmlns='jabber:iq:version'/>
# </iq>
class VersionGetRequest extends Request
    matches: () ->
        @iq.attrs.type is 'get' &&
        @iq.getChild("query", NS.VERSION)?

    reply: (result) ->
        queryEl = new xmpp.Element("query", xmlns: NS.VERSION)
        if result.name
            queryEl.c('name').t result.name
        if result.version
            queryEl.c('version').t result.version
        if result.os
            queryEl.c('os').t result.os

        super queryEl

    operation: 'get-version'


###
# XEP-0030: Service Discovery
###

# <iq type='get'
#     from='romeo@montague.net/orchard'
#     to='plays.shakespeare.lit'
#     id='info1'>
#   <query xmlns='http://jabber.org/protocol/disco#info'/>
# </iq>
class DiscoInfoRequest extends Request
    constructor: (stanza) ->
        super

        @discoInfoEl = @iq.getChild("query", NS.DISCO_INFO)
        @node = @discoInfoEl?.attrs.node
        if @node
            @operation = 'browse-node-info'
        else
            @operation = 'browse-info'

    matches: () ->
        @iq.attrs.type is 'get' &&
        @discoInfoEl?

    reply: (result) ->
        queryEl = new xmpp.Element("query", xmlns: NS.DISCO_INFO)
        if result?.node?
            queryEl.attrs.node = result.node

        for identity in result.identities
            queryEl.c "identity",
                category: identity.category
                type: identity.type
                name: identity.name

        for feature in result.features
            queryEl.c "feature",
                var: feature

        if result.config?
            queryEl.cnode forms.configToForm(result.config, 'result', NS.PUBSUB_META_DATA).toXml()

        super queryEl

# <iq type='get'
#     from='romeo@montague.net/orchard'
#     to='plays.shakespeare.lit'
#     id='info1'>
#   <query xmlns='http://jabber.org/protocol/disco#items'/>
# </iq>
#
# TODO: RSM
class DiscoItemsRequest extends Request
    constructor: (stanza) ->
        super

        @discoItemsEl = @iq.getChild("query", NS.DISCO_ITEMS)
        @node = @discoItemsEl?.attrs.node
        unless @node?
            @operation = 'browse-nodes'
        else if @node is "/top-followed-nodes"
            @operation = 'browse-top-followed-nodes'
            # not requesting a particular node:
            delete @node
        else if @node is "/top-published-nodes"
            @operation = 'browse-top-published-nodes'
            # not requesting a particular node:
            delete @node
        else
            @operation = 'browse-node-items'
        @setRSM @discoItemsEl

    matches: () ->
        @iq.attrs.type is 'get' &&
        @discoItemsEl?

    reply: (results) ->
        logger.debug "DiscoItemsRequest.reply: #{inspect results}"
        queryEl = new xmpp.Element("query", xmlns: NS.DISCO_ITEMS)
        if results?.node
            queryEl.attrs.node = results.node

        for item in results
            attrs = {}
            attrs.jid ?= item.jid
            attrs.name ?= item.name
            attrs.node ?= item.node
            queryEl.c "item", attrs

        if results.rsm
            if @operation is 'browse-node-items'
                results.rsm.setReplyInfo results, 'name'
            else
                results.rsm.setReplyInfo results, 'node'
            results.rsm.rmRequestInfo()
            queryEl.cnode results.rsm.toXml()

        super queryEl


##
# XEP-0077: In-Band Registration
##

class RegisterRequest extends Request
    constructor: (stanza) ->
        super
        @registerEl = @iq.getChild("query", NS.REGISTER)

    matches: () ->
        @registerEl

class RegisterGetRequest extends RegisterRequest
    matches: () ->
        super &&
        @iq.attrs.type is 'get'

    reply: () ->
        super new xmpp.Element("query", xmlns: NS.REGISTER).
            c("instructions").
            t("Simply register here")

class RegisterSetRequest extends RegisterRequest
    matches: () ->
        super &&
        @iq.attrs.type is 'set'

    operation: 'register-user'

    subscriptionRequired: true

    writes: true

###
# XEP-0060: Publish-Subscribe
###

class PubsubRequest extends Request
    xmlns: NS.PUBSUB

    constructor: (stanza) ->
        super

        @pubsubEl = @iq.getChild("pubsub", @xmlns)
        if @pubsubEl
            @setActor @pubsubEl
            @setRSM @pubsubEl

    matches: () ->
        (@iq.attrs.type is 'get' ||
         @iq.attrs.type is 'set') &&
        @pubsubEl?

    reply: (child, rsm) ->
        if child? and (child.children? or child instanceof Array)
            pubsubEl = new xmpp.Element("pubsub", { xmlns: @xmlns })
            if child instanceof Array
                for el in child
                    pubsubEl.cnode el if el?
            else
                pubsubEl.cnode child
            if rsm
                rsm.rmRequestInfo()
                pubsubEl.cnode rsm.toXml()
            super pubsubEl
        else
            super()

##
# *Owner* is not related to a required affiliation. The derived
# *operations are all requested with the pubsub#owner xmlns.
class PubsubOwnerRequest extends PubsubRequest
    xmlns: NS.PUBSUB_OWNER

# <iq type='set'
#     from='hamlet@denmark.lit/elsinore'
#     to='pubsub.shakespeare.lit'
#     id='create1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <create node='princely_musings'/>
#   </pubsub>
# </iq>
class PubsubCreateRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @createEl = @pubsubEl?.getChild("create")
        @node = @createEl?.attrs.node

        configureEl = @pubsubEl?.getChild("configure")
        if configureEl
            @config = {}
            configureEl?.getChildren("x", NS.DATA).forEach (formEl) =>
                form = forms.fromXml formEl
                @config = forms.formToConfig(form) or @config

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @node

    operation: 'create-node'

    writes: true

# <iq type='set'
#     from='francisco@denmark.lit/barracks'
#     to='pubsub.shakespeare.lit'
#     id='sub1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <subscribe node='princely_musings'/>
#     <options node='princely_musings' jid='francisco@denmark.lit'>
#       <x xmlns='jabber:x:data' type='submit'>
#         <field var='FORM_TYPE' type='hidden'>
#           <value>http://jabber.org/protocol/pubsub#subscribe_options</value>
#         </field>
#         <field var='pubsub#expire'><value>presence</value></field>
#       </x>
#     </options>
#   </pubsub>
# </iq>
class PubsubSubscribeRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @subscribeEl = @pubsubEl?.getChild("subscribe")
        @node = @subscribeEl?.attrs.node
        @temporary = false

        optionsEl = @pubsubEl?.getChild("options")
        formEl = optionsEl?.getChild("x")
        if formEl
            for field in formEl.getChildren("field")
                if field.attrs.var == 'pubsub#expire'
                    @temporary = field.getChild("value")?.getText() is 'presence'

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @node

    reply: (result) ->
        attrs =
            node: @node
            jid: result?.user
            subscription: result?.subscription
            temporary: if result?.temporary then '1' else '0'
        super new xmpp.Element("subscription", attrs)

    operation: 'subscribe-node'

    writes: true

# <iq type='set'
#     from='francisco@denmark.lit/barracks'
#     to='pubsub.shakespeare.lit'
#     id='unsub1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#      <unsubscribe
#          node='princely_musings'/>
#   </pubsub>
# </iq>
class PubsubUnsubscribeRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @unsubscribeEl = @pubsubEl?.getChild("unsubscribe")
        @node = @unsubscribeEl?.attrs.node

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @node

    operation: 'unsubscribe-node'

    writes: true

# <iq type='set'
#     from='hamlet@denmark.lit/blogbot'
#     to='pubsub.shakespeare.lit'
#     id='publish1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <publish node='princely_musings'>
#       <item id='bnd81g37d61f49fgn581'>
# ...
class PubsubPublishRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @publishEl = @pubsubEl?.getChild("publish")
        @items = []
        if @publishEl
            @node = @publishEl.attrs.node
            for itemEl in @publishEl.getChildren("item")
                # el is 1st XML child
                item =
                    el: itemEl.children.filter((itemEl) ->
                        itemEl.hasOwnProperty('children')
                    )[0]
                if itemEl.attrs.id
                    item.id = itemEl.attrs.id
                @items.push item

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @node

    operation: 'publish-node-items'

    reply: (ids) ->
        if ids?
            publishEl = new xmpp.Element('publish', node: @node)
            for id in ids
                publishEl.c('item', id: id)
            super publishEl
        else
            super()

    writes: true

# <iq type='set'
#     from='hamlet@denmark.lit/elsinore'
#     to='pubsub.shakespeare.lit'
#     id='retract1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <retract node='princely_musings'>
#       <item id='ae890ac52d0df67ed7cfdf51b644e901'/>
#     </retract>
#   </pubsub>
# </iq>
class PubsubRetractRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @retractEl = @pubsubEl?.getChild("retract")
        @items = []
        if @retractEl
            @node = @retractEl.attrs.node
            for itemEl in @retractEl.getChildren("item")
                if itemEl.attrs.id
                    @items.push itemEl.attrs.id

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @node &&
        @items.length > 0

    operation: 'retract-node-items'

    writes: true

# <iq type='get'
#     from='francisco@denmark.lit/barracks'
#     to='pubsub.shakespeare.lit'
#     id='items1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <items node='princely_musings'/>
#   </pubsub>
# </iq>
class PubsubItemsRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @itemsEl = @pubsubEl?.getChild("items")
        if (itemEls = @itemsEl?.getChildren("item"))?.length > 0
            @itemIds = itemEls.map (itemEl) ->
                itemEl.attrs.id
        @node = @itemsEl?.attrs.node

    matches: () ->
        super &&
        @iq.attrs.type is 'get' &&
        @node

    reply: (items) ->
        items.rsm.setReplyInfo(items, 'id')

        itemsEl = new xmpp.Element("items", node: items.node)
        for item in items
            itemEl = itemsEl.c("item", id: item.id)
            itemEl.cnode(item.el)

        super itemsEl, items.rsm

    operation: 'retrieve-node-items'

# <iq type='get'
#     from='francisco@denmark.lit/barracks'
#     to='pubsub.shakespeare.lit'
#     id='recentitems1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <recent-items xmlns='http://buddycloud.org/v1'
#                   since='2012-12-04T23:36:51.123Z'
#                   max='50'/>
#   </pubsub>
# </iq>
class PubsubRecentItemsRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @recentItemsEl = @pubsubEl?.getChild('recent-items', NS.BUDDYCLOUD_V1)
        @since = @recentItemsEl?.attrs.since
        @maxItems = @recentItemsEl?.attrs.max

    matches: ->
        super &&
        @iq.attrs.type is 'get' &&
        @recentItemsEl && @since && @maxItems

    reply: (items) ->
        items.rsm.setReplyInfo(items, 'globalId')

        results = []
        lastItemsEl = null
        for item in items
            unless lastItemsEl?.attrs.node is item.node
                lastItemsEl = new xmpp.Element("items", node: item.node)
                results.push lastItemsEl
            lastItemsEl.c("item", id: item.id).cnode(item.el)

        super results, items.rsm

    operation: 'retrieve-recent-items'

# <iq type='get'
#     from='francisco@denmark.lit/barracks'
#     to='pubsub.shakespeare.lit'
#     id='recentitems1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <replies xmlns='http://buddycloud.org/v1'
#              node='princely_musings'
#              item_id='ae890ac52d0df67ed7cfdf51b644e901'/>
#   </pubsub>
# </iq>
class PubsubRepliesRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @repliesEl = @pubsubEl?.getChild('replies', NS.BUDDYCLOUD_V1)
        @node = @repliesEl?.attrs.node
        @itemId = @repliesEl?.attrs.item_id

    matches: ->
        super &&
        @iq.attrs.type is 'get' &&
        @repliesEl && @node && @itemId

    reply: (items) ->
        items.rsm.setReplyInfo(items, 'id')

        results = []
        itemsEl = new xmpp.Element("items")
        results.push itemsEl
        for item in items
            itemsEl.c("item", id: item.id).cnode(item.el)

        super results, items.rsm

    operation: 'retrieve-replies'

# <iq type='get'
#     from='francisco@denmark.lit/barracks'
#     to='pubsub.shakespeare.lit'
#     id='subscriptions1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <subscriptions/>
#   </pubsub>
# </iq>
class PubsubSubscriptionsRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @subscriptionsEl = @pubsubEl?.getChild("subscriptions")

    matches: () ->
        super &&
        @iq.attrs.type is 'get' &&
        @subscriptionsEl

    reply: (nodes) ->
        nodes.rsm.setReplyInfo(nodes, 'node')

        subscriptionsEl = new xmpp.Element("subscriptions")
        for node in nodes
            attrs =
                node: node.node
                subscription: node.subscription
            if node.jid
                attrs.jid = node.jid
            subscriptionsEl.c "subscription", attrs

        super subscriptionsEl, nodes.rsm

    operation: 'retrieve-user-subscriptions'

# <iq type='get'
#     from='francisco@denmark.lit/barracks'
#     to='pubsub.shakespeare.lit'
#     id='affil1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <affiliations/>
#   </pubsub>
# </iq>
class PubsubAffiliationsRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @affiliationsEl = @pubsubEl?.getChild("affiliations")

    matches: () ->
        super &&
        @iq.attrs.type is 'get' &&
        @affiliationsEl

    reply: (nodes) ->
        nodes.rsm.setReplyInfo(nodes, 'node')

        affiliationsEl = new xmpp.Element("affiliations")
        for node in nodes
            attrs =
                node: node.node
                affiliation: node.affiliation
            if node.jid
                attrs.jid = node.jid
            affiliationsEl.c "affiliation", attrs

        super affiliationsEl, nodes.rsm

    operation: 'retrieve-user-affiliations'


# <iq type='get'
#     from='hamlet@denmark.lit/elsinore'
#     to='pubsub.shakespeare.lit'
#     id='subman1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
#     <subscriptions node='princely_musings'/>
#   </pubsub>
# </iq>
class PubsubOwnerGetSubscriptionsRequest extends PubsubOwnerRequest
    constructor: (stanza) ->
        super

        @subscriptionsEl = @pubsubEl?.getChild("subscriptions")
        @node = @subscriptionsEl?.attrs.node

    matches: () ->
        super &&
        @iq.attrs.type is 'get' &&
        @node

    reply: (subscriptions) ->
        subscriptions.rsm.setReplyInfo(subscriptions, 'user')

        subscriptionsEl = new xmpp.Element("subscriptions")
        for subscription in subscriptions
            subscriptionsEl.c 'subscription',
                jid: subscription.user
                subscription: subscription.subscription

        super subscriptionsEl, subscriptions.rsm

    operation: 'retrieve-node-subscriptions'

# <iq type='set'
#     from='hamlet@denmark.lit/elsinore'
#     to='pubsub.shakespeare.lit'
#     id='subman2'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
#     <subscriptions node='princely_musings'>
#       <subscription jid='bard@shakespeare.lit' subscription='subscribed'/>
#     </subscriptions>
#   </pubsub>
# </iq>
class PubsubOwnerSetSubscriptionsRequest extends PubsubOwnerRequest
    constructor: (stanza) ->
        super

        @subscriptionsEl = @pubsubEl?.getChild("subscriptions")
        @subscriptions = []
        if @subscriptionsEl
            @node = @subscriptionsEl.attrs.node
            @subscriptions = @subscriptionsEl.getChildren("subscription").map(
                (subscriptionEl) ->
                    user: subscriptionEl.attrs.jid
                    subscription: subscriptionEl.attrs.subscription
            )

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @subscriptionsEl

    operation: 'manage-node-subscriptions'

    writes: true

# <iq type='get'
#     from='hamlet@denmark.lit/elsinore'
#     to='pubsub.shakespeare.lit'
#     id='ent1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
#     <affiliations node='princely_musings'/>
#   </pubsub>
# </iq>
class PubsubOwnerGetAffiliationsRequest extends PubsubOwnerRequest
    constructor: (stanza) ->
        super

        @affiliationsEl = @pubsubEl?.getChild("affiliations")
        @node = @affiliationsEl?.attrs.node

    matches: () ->
        super &&
        @iq.attrs.type is 'get' &&
        @affiliationsEl

    reply: (affiliations) ->
        affiliations.rsm.setReplyInfo(affiliations, 'user')

        affiliationsEl = new xmpp.Element("affiliations")
        for affiliation in affiliations
            affiliationsEl.c 'affiliation',
                jid: affiliation.user
                affiliation: affiliation.affiliation

        super affiliationsEl, affiliations.rsm

    operation: 'retrieve-node-affiliations'

# <iq type='set'
#     from='hamlet@denmark.lit/elsinore'
#     to='pubsub.shakespeare.lit'
#     id='ent2'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
#     <affiliations node='princely_musings'>
#       <affiliation jid='bard@shakespeare.lit' affiliation='publisher'/>
#     </affiliations>
#   </pubsub>
# </iq>
class PubsubOwnerSetAffiliationsRequest extends PubsubOwnerRequest
    constructor: (stanza) ->
        super

        @affiliationsEl = @pubsubEl?.getChild("affiliations")
        @affiliations = []
        if @affiliationsEl
            @node = @affiliationsEl.attrs.node
            @affiliations = @affiliationsEl?.getChildren("affiliation").map(
                (affiliationEl) ->
                    user: affiliationEl.attrs.jid
                    affiliation: affiliationEl.attrs.affiliation
            )

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @affiliationsEl

    operation: 'manage-node-affiliations'

    writes: true

class PubsubOwnerGetConfigurationRequest extends PubsubOwnerRequest
    constructor: (stanza) ->
        super

        @configureEl = @pubsubEl?.getChild("configure")
        @node = @configureEl?.attrs?.node

    matches: () ->
        super &&
        @iq.attrs.type is 'get' &&
        @node

    operation: 'retrieve-node-configuration'

    reply: (result) ->
        configureEl = new xmpp.Element("configure", node: @node)

        if result.config?
            configureEl.cnode forms.configToForm(result.config, 'result', NS.PUBSUB_NODE_CONFIG).toXml()

        super configureEl

class PubsubOwnerSetConfigurationRequest extends PubsubOwnerRequest
    constructor: (stanza) ->
        super

        @configureEl = @pubsubEl?.getChild("configure")
        @node = @configureEl?.attrs?.node
        @config = {}
        @configureEl?.getChildren("x", NS.DATA).forEach (formEl) =>
            form = forms.fromXml formEl
            @config = forms.formToConfig(form) or @config

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @node

    operation: 'manage-node-configuration'

    writes: true


class MessageArchiveRequest extends Request
    constructor: (stanza) ->
        super

        @mamEl = @iq.getChild("query", NS.MAM)
        @queryId = @mamEl?.attrs?.queryid
        @start = @mamEl?.getChildText("start")
        @end = @mamEl?.getChildText("end")
        @setRSM @mamEl

    matches: () ->
        @iq.attrs.type is 'get' &&
        @mamEl?

    operation: 'replay-archive'


REQUESTS = [
    VersionGetRequest,
    DiscoInfoRequest,
    DiscoItemsRequest,
    RegisterGetRequest,
    RegisterSetRequest,
    PubsubCreateRequest,
    PubsubSubscribeRequest,
    PubsubUnsubscribeRequest,
    PubsubPublishRequest,
    PubsubRetractRequest,
    PubsubItemsRequest,
    PubsubRecentItemsRequest,
    PubsubRepliesRequest,
    PubsubSubscriptionsRequest,
    PubsubAffiliationsRequest,
    PubsubOwnerGetSubscriptionsRequest,
    PubsubOwnerSetSubscriptionsRequest,
    PubsubOwnerGetAffiliationsRequest,
    PubsubOwnerSetAffiliationsRequest,
    PubsubOwnerGetConfigurationRequest,
    PubsubOwnerSetConfigurationRequest,
    MessageArchiveRequest,
    NotImplemented
]


##
# Reacts on all <iq/> *requests
#
# Emits recognized requests with @onRequest(request)
class exports.PubsubServer extends EventEmitter
    constructor: (@conn) ->
        @conn.on 'iqRequest', (stanza) =>
            request = @makeRequest stanza
            @emit 'request', request

            if request.subscriptionRequired
                bareJid = new xmpp.JID(stanza.attrs.from).bare().toString()
                @conn.subscribePresence bareJid

    ##
    # Generates stanza-receiving function, invokes cb
    #
    # Matches the above REQUESTS for the received stanza
    makeRequest: (stanza) ->
        result = null
        for r in REQUESTS
            result = new r(stanza)
            if result.matches()
                logger.trace "found subrequest #{r.name}"
                break
            else
                result = null
        # Synchronous result:
        result
