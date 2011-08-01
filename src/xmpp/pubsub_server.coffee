xmpp = require('node-xmpp')
NS = require('./ns')
Request = require('./request')

###
# XEP-0030: Service Discovery
###

# <iq type='get'
#     from='romeo@montague.net/orchard'
#     to='plays.shakespeare.lit'
#     id='info1'>
#   <query xmlns='http://jabber.org/protocol/disco#info'/>
# </iq>
class DiscoInfoRequest extends Request.Request
    constructor: (stanza) ->
        super

        @discoInfoEl = @iq.getChild("query", NS.DISCO_INFO)
        @node = @discoInfoEl?.attrs.node

    matches: () ->
        @iq.attrs.type is 'get' &&
        @discoInfoEl?

    reply: () ->
        result =
            features: [
                NS.DISCO_ITEMS, NS.REGISTER,
                NS.PUBSUB, NS.PUBSUB_OWNER
            ]
            identities: [{
                 category: "pubsub"
                type: "service"
                name: "Channels service"
            }, {
                category: "pubsub"
                type: "channels"
                name: "Channels service"
            }]

        queryEl = new xmpp.Element("query", xmlns: NS.DISCO_INFO)
        if result?.node?
            queryEl.attrs.node = result.node

        console.log "DiscoInfoRequest.reply result": result
        for identity in result.identities
            queryEl.c "identity",
                category: identity.category
                type: identity.type
                name: identity.name

        for feature in result.features
            queryEl.c "feature",
                var: feature

        # TODO: result.forms

        super queryEl

    operation: ->
        if @node
            'browse-node-info'
        else
            'browse-info'

# <iq type='get'
#     from='romeo@montague.net/orchard'
#     to='plays.shakespeare.lit'
#     id='info1'>
#   <query xmlns='http://jabber.org/protocol/disco#items'/>
# </iq>
class DiscoItemsRequest extends Request.Request
    constructor: (stanza) ->
        super

        @discoItemsEl = @iq.getChild("query", NS.DISCO_ITEMS)
        @node = @discoItemsEl?.attrs.node

    matches: () ->
        @iq.attrs.type is 'get' &&
        @discoItemsEl?

    reply: (results) ->
        queryEl = new xmpp.Element("query", xmlns: NS.DISCO_ITEMS)
        if results?.node
            queryEl.attrs.node = results.node

        for item in results
            attrs =
                jid: result.jid
            if item.name?
                attrs.name = item.name
            queryEl.c "item", attrs

        super queryEl

    operation: ->
        'browse-nodes-items'

##
# XEP-0077: In-Band Registration
##

class RegisterRequest extends Request.Request
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

    operation: () ->
        'register-user'

###
# XEP-0060: Publish-Subscribe
###

class PubsubRequest extends Request.Request
    constructor: (stanza) ->
        super

        @pubsubEl = @iq.getChild("pubsub", NS.PUBSUB)
        @setActor @pubsubEl

    matches: () ->
        (@iq.attrs.type is 'get' ||
         @iq.attrs.type is 'set') &&
        @pubsubEl?

    reply: (child) ->
        if child?
            pubsubEl = new xmpp.Element("pubsub", { xmlns: NS.PUBSUB })
            pubsubEl.cnode child
            super pubsubEl
        else
            super()

# <iq type='set'
#     from='hamlet@denmark.lit/elsinore'
#     to='pubsub.shakespeare.lit'
#     id='create1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <create node='princely_musings'/>
#   </pubsub>
# </iq>
#
# Not used for buddycloud (see register instead)
class PubsubCreateRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @createEl = @pubsubEl?.getChild("create")
        @node = @createEl?.attrs.node

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @node

# <iq type='set'
#     from='francisco@denmark.lit/barracks'
#     to='pubsub.shakespeare.lit'
#     id='sub1'>
#   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
#     <subscribe node='princely_musings'/>
#   </pubsub>
# </iq>
class PubsubSubscribeRequest extends PubsubRequest
    constructor: (stanza) ->
        super

        @subscribeEl = @pubsubEl?.getChild("subscribe")
        @node = @subscribeEl?.attrs.node

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @node

    reply: (result) ->
        attrs = {}
        attrs.jid = result.jid if result && result.jid
        attrs.subscription = result.subscription if result && result.subscription
        if attrs.jid || attrs.subscription
            super new xmpp.Element("subscription", attrs)
        else
            super

    operation: ->
        'subscribe-node'

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

    operation: ->
        'unsubscribe-node'

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

    operation: ->
        'publish-node-items'

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
        @node

    operation: ->
        'retract-node-items'

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
        @node = @itemsEl?.attrs.node

    matches: () ->
        super &&
        @iq.attrs.type is 'get' &&
        @node

    reply: (items) ->
        console.log "PubsubItemsRequest.reply": items
        itemsEl = new xmpp.Element("items", node: items.node)
        for item in items
            itemEl = itemsEl.c("item", id: item.id)
            itemEl.cnode(item.el)

        super itemsEl

    operation: ->
        'retrieve-node-items'


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
        subscriptionsEl = new xmpp.Element("subscriptions")
        for node in nodes
            attrs =
                node: node.node
                subscription: node.subscription
            if node.jid
                attrs.jid = node.jid
            subscriptionsEl.c "subscription", attrs

        super subscriptionsEl

    operation: ->
        'retrieve-user-subscriptions'

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
        affiliationsEl = new xmpp.Element("affiliations")
        for node in nodes
            attrs =
                node: node.node
                affiliation: node.affiliation
            if node.jid
                attrs.jid = node.jid
            affiliationsEl.c "affiliation", attrs

        super affiliationsEl

    operation: ->
        'retrieve-user-affiliations'


##
# *Owner* is not related to a required affiliation. The derived
# *operations are all requested with the pubsub#owner xmlns.
class PubsubOwnerRequest extends Request.Request
    constructor: (stanza) ->
        super

        @pubsubEl = @iq.getChild("pubsub", NS.PUBSUB_OWNER)
        @setActor @pubsubEl

    matches: () ->
        (@iq.attrs.type is 'get' ||
         @iq.attrs.type is 'set') &&
        @pubsubEl?

    reply: (child) ->
        if child?
            pubsubEl = new xmpp.Element("pubsub", xmlns: NS.PUBSUB_OWNER)
            pubsubEl.cnode child
            super pubsubEl
        else
            super()

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
        console.log "PubsubOwnerGetSubscriptionsRequest.matches":
            node: @node
            subscriptionsEl: @subscriptionsEl
            type: @iq.attrs.type
            pubsubEl: @pubsubEl
        super &&
        @iq.attrs.type is 'get' &&
        @node

    reply: (subscriptions) ->
        subscriptionsEl = new xmpp.Element("subscriptions")
        for subscription in subscriptions
            subscriptionsEl.c 'subscription',
                jid: subscription.user
                subscription: subscription.subscription

        super subscriptionsEl

    operation: ->
        'retrieve-node-subscriptions'

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
                    { user: subscriptionEl.attrs.jid
                      subscription: subscriptionEl.attrs.subscription }
            )

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @subscriptionsEl

    operation: ->
        'manage-node-subscriptions'

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
        affiliationsEl = new xmpp.Element("affiliations")
        for affiliation in affiliations
            affiliationsEl.c 'affiliation',
                user: affiliation.user
                affiliation: affiliation.affiliation

        super affiliationsEl

    operation: ->
        'retrieve-node-affiliations'

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
                    { user: affiliationEl.attrs.jid
                      affiliation: affiliationEl.attrs.affiliation }
            )

    matches: () ->
        super &&
        @iq.attrs.type is 'set' &&
        @affiliationsEl

    operation: ->
        'manage-node-affiliations'

# TODO: PubsubOwner{Get,Set}Configuration w/ forms

REQUESTS = [
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
    PubsubSubscriptionsRequest,
    PubsubAffiliationsRequest,
    PubsubOwnerGetSubscriptionsRequest,
    PubsubOwnerSetSubscriptionsRequest,
    PubsubOwnerGetAffiliationsRequest,
    PubsubOwnerSetAffiliationsRequest,
    Request.NotImplemented
]


##
# Reacts on all <iq/> *requests
#
# Emits recognized requests with @onRequest(request)
class exports.PubsubServer
    constructor: (@conn) ->
        @conn.iqHandler = (stanza) =>
            request = @makeRequest stanza
            @onRequest request

    onRequest: (request) ->
        # hooked by main/router

    ##
    # Generates stanza-receiving function, invokes cb
    #
    # Matches the above REQUESTS for the received stanza
    makeRequest: (stanza) ->
        result = null
        console.log "searching request for #{stanza.toString()}"
        for r in REQUESTS
            result = new r(stanza)
            if result.matches()
                console.log 'found subrequest', r.name
                break
            else
                result = null
        # Synchronous result:
        result
