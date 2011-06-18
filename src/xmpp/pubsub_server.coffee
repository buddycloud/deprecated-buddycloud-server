xmpp = require('node-xmpp')
NS = require('./ns')
IqHandler = require('./iqhandler')


# <iq type='get'
#     from='romeo@montague.net/orchard'
#     to='plays.shakespeare.lit'
#     id='info1'>
#   <query xmlns='http://jabber.org/protocol/disco#info'/>
# </iq>
class DiscoInfoHandler extends IqHandler.Handler
    constructor: (stanza) ->
        super stanza

        @discoInfoEl = @iq.getChild("query", NS.DISCO_INFO)
        @node = @discoInfoEl && @discoInfoEl.attrs.node

    matches: () ->
        @iq.attrs.type is 'get' &&
        @discoInfoEl?

    run: () ->
        console.log 'run DiscoInfoHandler'
        queryEl = new xmpp.Element("query", xmlns: NS.DISCO_INFO)
        if @node
            queryEl.attrs.node = @node
        features = []
        unless @node
            features.push NS.DISCO_ITEMS, NS.REGISTER
        features.forEach (feature) ->
            queryEl.c "feature", var: feature
        for x in [1..1]
    	    # Didn't request info about specific node, hence no need
    	    # to get node config but respond immediately.
            queryEl.c "identity",
                category: "pubsub"
                type: "service"
                name: "Channels service"

            queryEl.c "identity",
                category: "pubsub"
                type: "channels"
                name: "Channels service"

            console.log 'replying'
            @reply queryEl


exports.handler =
    IqHandler.GroupHandler(
        DiscoInfoHandler,
        IqHandler.NotImplemented
    );


###


        if @node
            controller.request
                feature: "config-node"
                operation: "retrieve"
                from: "xmpp:" + jid
                node: @node
                callback: (err, config) ->
                    if err
                        replyCb err
                        return
                    queryEl.c "identity",
                        category: "pubsub"
                        type: "leaf"
                        name: config.title

                    queryEl.c("x",
                        xmlns: NS.DATA
                        type: "result"
                    ).c("field",
                        var: "FORM_TYPE"
                        type: "hidden"
                    ).c("value").t(NS.PUBSUB_META_DATA).up().up().c("field",
                        var: "pubsub#title"
                        type: "text-single"
                        label: "A friendly name for the node"
                    ).c("value").t(config.title or "").up().up().c("field",
                        var: "pubsub#description"
                        type: "text-single"
                        label: "A description text for the node"
                    ).c("value").t(config.description or "").up().up().c("field",
                        var: "pubsub#type"
                        type: "text-single"
                        label: "Payload type"
                    ).c("value").t(config.type or "").up().up().c("field",
                        var: "pubsub#access_model"
                        type: "list-single"
                        label: "Who can subscribe and browse your channel?"
                    ).c("value").t(config.accessModel or "open").up().up().c("field",
                        var: "pubsub#publish_model"
                        type: "list-single"
                        label: "May new subscribers post on your channel?"
                    ).c("value").t(config.publishModel or "subscribers").up().c("field",
                        var: "pubsub#creation_date"
                        type: "text-single"
                        label: "Creation date"
                    ).c("value").t config.creationDate or new Date().toISOString()
                    replyCb null, queryEl
        else

##################

exports.setController = (c) ->
    controller = c
    controller.hookFrontend "xmpp",
        notify: notify
        retracted: retracted
        approve: approve
        subscriptionModified: subscriptionModified
        configured: configured

##
# Request handling
handleIq = (iq) ->
    jid = new xmpp.JID(iq.attrs.from).bare().toString()
    reply = new xmpp.Element("iq",
        from: iq.attrs.to
        to: iq.attrs.from
        id: iq.attrs.id or ""
        type: "result"
    )
    errorReply = (err) ->
        if err.stack
            console.error err.stack
        else
            console.error err: err
        reply.attrs.type = "error"
        if err.xmppElement
            reply.cnode err.xmppElement()
        else
            reply.c("error", type: "cancel").c("text").t "" + err.message
        reply

    replyCb = (err, child) ->
        if err
            conn.send errorReply(err)
        else if not err and child and child.root
            conn.send reply.cnode(child.root())
        else
            conn.send reply

    # <iq type='get'
    #     from='romeo@montague.net/orchard'
    #     to='shakespeare.lit'
    #     id='items1'>
    #   <query xmlns='http://jabber.org/protocol/disco#items'/>
    # </iq>
    discoItemsEl = iq.getChild("query", NS.DISCO_ITEMS)
    if iq.attrs.type == "get" and discoItemsEl
        node = discoItemsEl.attrs.node
        queryEl = new xmpp.Element("query", xmlns: NS.DISCO_ITEMS)
        unless node
            # Discovering service, not a specific node
            controller.request
                feature: "browse-nodes"
                operation: "list"
                from: "xmpp:" + jid
                callback: (err, nodes) ->
                    if err
                        errorReply err
                        return
                    # Iterate the controller browse-nodes result
                    nodes.forEach (node) ->
                        itemEl = queryEl.c("item",
                            jid: conn.jid
                            node: node.node
                        )
                        if node.title
                            itemEl.attrs.title = node.title

                    replyCb null, queryEl
        else if /^\/user\/[^\/]+$/.test(node)
            # Discovery to all user's node
            controller.request
                feature: "browse-nodes"
                operation: "by-user"
                node: node
                from: "xmpp:" + jid
                callback: (err, nodes) ->
                    if err
                        errorReply err
                        return
                    # Iterate the controller browse-nodes result
                    nodes.forEach (node) ->
                        itemEl = queryEl.c("item",
                            jid: conn.jid
                            node: node.node
                        )
                        if node.title
                            itemEl.attrs.title = node.title

                    replyCb null, queryEl
        else
            # Anything else: empty
            replyCb null, queryEl
        return
    pubsubEl = iq.getChild("pubsub", NS.PUBSUB)
    if pubsubEl
        # XEP-0059: Result Set Management
        rsmQuery = getRSMQuery(pubsubEl)

	    # <iq type='set'
	    #     from='hamlet@denmark.lit/elsinore'
	    #     to='pubsub.shakespeare.lit'
	    #     id='create1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	    #     <create node='princely_musings'/>
	    #   </pubsub>
	    # </iq>
        createEl = pubsubEl.getChild("create")
        createNode = createEl and createEl.attrs.node
        if iq.attrs.type == "set" and createEl and createNode
            controller.request
                feature: "create-nodes"
                operation: "create"
                from: "xmpp:" + jid
                node: createNode
                callback: replyCb

            subscribeIfNeeded jid
            return
	    # <iq type='set'
	    #     from='francisco@denmark.lit/barracks'
	    #     to='pubsub.shakespeare.lit'
	    #     id='sub1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	    #     <subscribe node='princely_musings'/>
	    #   </pubsub>
	    # </iq>
        subscribeEl = pubsubEl.getChild("subscribe")
        subscribeNode = subscribeEl and subscribeEl.attrs.node
        if iq.attrs.type == "set" and subscribeEl and subscribeNode
            # TODO: reply is more complex
            controller.request
                feature: "subscribe"
                operation: "subscribe"
                from: "xmpp:" + jid
                node: subscribeNode
                callback: (err, subscription) ->
                    if err
                        replyCb err
                        return
                    if subscription == "pending"
                        replyCb null, new xmpp.Element("pubsub", xmlns: NS.PUBSUB).c("subscription",
                            node: subscribeNode
                            jid: jid
                            subscription: subscription
                        )
                    else
                        replyCb null

            subscribeIfNeeded jid
            return
	    # <iq type='set'
	    #     from='francisco@denmark.lit/barracks'
	    #     to='pubsub.shakespeare.lit'
	    #     id='unsub1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	    #      <unsubscribe
	    #          node='princely_musings'/>
	    #   </pubsub>
	    # </iq>
        unsubscribeEl = pubsubEl.getChild("unsubscribe")
        unsubscribeNode = unsubscribeEl and unsubscribeEl.attrs.node
        if iq.attrs.type == "set" and unsubscribeEl and unsubscribeNode
            controller.request
                feature: "unsubscribe"
                operation: "unsubscribe"
                from: "xmpp:" + jid
                node: unsubscribeNode
                callback: replyCb

            return
	    # <iq type='set'
	    #     from='hamlet@denmark.lit/blogbot'
	    #     to='pubsub.shakespeare.lit'
	    #     id='publish1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	    #     <publish node='princely_musings'>
	    #       <item id='bnd81g37d61f49fgn581'>
	    # ...
        publishEl = pubsubEl.getChild("publish")
        publishNode = publishEl and publishEl.attrs.node
        if iq.attrs.type == "set" and publishEl and publishNode
            items = {}
            publishEl.getChildren("item").forEach (itemEl) ->
                itemNode = itemEl.attrs.node or uuid()
                items[itemNode] = itemEl.children[0]

            controller.request
                feature: "publish"
                operation: "publish"
                from: "xmpp:" + jid
                node: publishNode
                items: items
                callback: replyCb

            return
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
        retractEl = pubsubEl.getChild("retract")
        retractNode = retractEl and retractEl.attrs.node
        if iq.attrs.type == "set" and retractEl and retractNode
            itemIds = retractEl.getChildren("item").map((itemEl) ->
                itemEl.attrs.id
            )
            notify = retractEl.attrs.notify and (retractEl.attrs.notify == "1" or retractEl.attrs.notify == "true")
            controller.request
                feature: "retract-items"
                operation: "retract"
                from: "xmpp:" + jid
                node: retractNode
                itemIds: itemIds
                notify: notify
                callback: replyCb

            return
	    # <iq type='get'
	    #     from='francisco@denmark.lit/barracks'
	    #     to='pubsub.shakespeare.lit'
	    #     id='items1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	    #     <items node='princely_musings'/>
	    #   </pubsub>
	    # </iq>
        itemsEl = pubsubEl.getChild("items")
        itemsNode = itemsEl and itemsEl.attrs.node
        if iq.attrs.type == "get" and itemsEl and itemsNode
            # TODO: check stanza size & support RSM
            controller.request
                feature: "retrieve-items"
                operation: "retrieve"
                from: "xmpp:" + jid
                node: itemsNode
                rsmQuery: rsmQuery
                callback: (err, items) ->
                    if err
                        replyCb err
                    else
                        itemsEl = new xmpp.Element("pubsub", xmlns: NS.PUBSUB).c("items", node: itemsNode)
                        items.forEach (item) ->
                            itemEl = itemsEl.c("item", id: item.id)
                            if items[id]
                                itemEl.cnode item.item

                        addRSMResult items.rsmResult, itemsEl.up()
                        replyCb null, itemsEl

            return
	    # <iq type='get'
	    #     from='francisco@denmark.lit/barracks'
	    #     to='pubsub.shakespeare.lit'
	    #     id='subscriptions1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	    #     <subscriptions/>
	    #   </pubsub>
	    # </iq>
        subscriptionsEl = pubsubEl.getChild("subscriptions")
        if iq.attrs.type == "get" and subscriptionsEl
            controller.request
                feature: "retrieve-subscriptions"
                operation: "retrieve"
                from: "xmpp:" + jid
                callback: (err, nodes) ->
                    if err
                        replyCb err
                    else
                        subscriptionsEl = new xmpp.Element("pubsub", xmlns: NS.PUBSUB).c("subscriptions")
                        nodes.forEach (node) ->
                            subscriptionsEl.c "subscription",
                                node: node.node
                                jid: jid
                                subscription: node.subscription

                        replyCb null, subscriptionsEl

            return
	    # <iq type='get'
	    #     from='francisco@denmark.lit/barracks'
	    #     to='pubsub.shakespeare.lit'
	    #     id='affil1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	    #     <affiliations/>
	    #   </pubsub>
	    # </iq>
        affiliationsEl = pubsubEl.getChild("affiliations")
        if iq.attrs.type == "get" and affiliationsEl
            controller.request
                feature: "retrieve-affiliations"
                operation: "retrieve"
                from: "xmpp:" + jid
                callback: (err, affiliations) ->
                    if err
                        replyCb err
                    else
                        affiliationsEl = new xmpp.Element("pubsub", xmlns: NS.PUBSUB).c("affiliations")
                        affiliations.forEach (affiliation) ->
                            affiliationsEl.c "affiliation",
                                node: affiliation.node
                                affiliation: affiliation.affiliation

                        replyCb null, affiliationsEl

            return
    pubsubOwnerEl = iq.getChild("pubsub", NS.PUBSUB_OWNER)
    if pubsubOwnerEl
	    # <iq type='get'
	    #     from='hamlet@denmark.lit/elsinore'
	    #     to='pubsub.shakespeare.lit'
	    #     id='subman1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	    #     <subscriptions node='princely_musings'/>
	    #   </pubsub>
	    # </iq>
        subscriptionsEl = pubsubOwnerEl.getChild("subscriptions")
        subscriptionsNode = subscriptionsEl and subscriptionsEl.attrs.node
        if iq.attrs.type == "get" and subscriptionsEl and subscriptionsNode
            controller.request
                feature: "manage-subscriptions"
                operation: "retrieve"
                from: "xmpp:" + jid
                node: subscriptionsNode
                callback: (err, subscribers) ->
                    if err
                        replyCb err
                    else
                        subscriptionsEl = new xmpp.Element("pubsub", xmlns: NS.PUBSUB_OWNER).c("subscriptions", node: subscriptionsNode)
                        subscribers.forEach (subscriber) ->
                            if (m = subscriber.user.match(/^xmpp:(.+)$/))
                                subscriptionsEl.c "subscription",
                                    jid: m[1]
                                    subscription: subscriber.subscription

                        replyCb null, subscriptionsEl

            return
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
        if iq.attrs.type == "set" and subscriptionsEl and subscriptionsNode
            subscriptions = {}
            subscriptionsEl.getChildren("subscription").forEach (subscriptionEl) ->
                jid = subscriptionEl.attrs.jid
                subscription = subscriptionEl.attrs.subscription
                if jid and subscription
                    subscriptions["xmpp:" + jid] = subscription

            controller.request
                feature: "manage-subscriptions"
                operation: "modify"
                from: "xmpp:" + jid
                node: subscriptionsNode
                subscriptions: subscriptions
                callback: replyCb

            return
	    # <iq type='get'
	    #     from='hamlet@denmark.lit/elsinore'
	    #     to='pubsub.shakespeare.lit'
	    #     id='ent1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	    #     <affiliations node='princely_musings'/>
	    #   </pubsub>
	    # </iq>
        affiliationsEl = pubsubOwnerEl.getChild("affiliations")
        affiliationsNode = affiliationsEl and affiliationsEl.attrs.node
        if iq.attrs.type == "get" and affiliationsEl and affiliationsNode
            controller.request
                feature: "modify-affiliations"
                operation: "retrieve"
                from: "xmpp:" + jid
                node: affiliationsNode
                callback: (err, affiliations) ->
                    if err
                        replyCb err
                    else
                        affiliationsEl = new xmpp.Element("pubsub", xmlns: NS.PUBSUB_OWNER).c("affiliations", node: affiliationsNode)
                        affiliations.forEach (affiliation) ->
                            if (m = affiliation.user.match(/^xmpp:(.+)$/))
                                affiliationsEl.c "affiliation",
                                    jid: m[1]
                                    affiliation: affiliation.affiliation

                        replyCb null, affiliationsEl

            return
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
        if iq.attrs.type == "set" and affiliationsEl and affiliationsNode
            affiliations = {}
            affiliationsEl.getChildren("affiliation").forEach (affiliationEl) ->
                jid = affiliationEl.attrs.jid
                affiliation = affiliationEl.attrs.affiliation
                if jid and affiliation
                    affiliations["xmpp:" + jid] = affiliation

            controller.request
                feature: "modify-affiliations"
                operation: "modify"
                from: "xmpp:" + jid
                node: affiliationsNode
                affiliations: affiliations
                callback: replyCb

            return
	    # <iq type='get'
	    #     from='hamlet@denmark.lit/elsinore'
	    #     to='pubsub.shakespeare.lit'
	    #     id='config1'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	    #     <configure node='princely_musings'/>
	    #   </pubsub>
	    # </iq>
        configureEl = pubsubOwnerEl.getChild("configure")
        configureNode = configureEl and configureEl.attrs.node
        if iq.attrs.type == "get" and configureEl and configureNode
            controller.request
                feature: "config-node"
                operation: "retrieve"
                from: "xmpp:" + jid
                node: configureNode
                callback: (err, config) ->
                    if err
                        replyCb err
                        return
                    replyCb null, new xmpp.Element("pubsub", xmlns: NS.PUBSUB_OWNER).c("configure", node: configureNode).c("x",
                        xmlns: NS.DATA
                        type: "form"
                    ).c("field",
                        var: "FORM_TYPE"
                        type: "hidden"
                    ).c("value").t(NS.PUBSUB_NODE_CONFIG).up().up().c("field",
                        var: "pubsub#title"
                        type: "text-single"
                        label: "A friendly name for the node"
                    ).c("value").t(config.title or "").up().up().c("field",
                        var: "pubsub#description"
                        type: "text-single"
                        label: "A description text for the node"
                    ).c("value").t(config.description or "").up().up().c("field",
                        var: "pubsub#type"
                        type: "text-single"
                        label: "Payload type"
                    ).c("value").t(config.type or "").up().up().c("field",
                        var: "pubsub#access_model"
                        type: "list-single"
                        label: "Who can subscribe and browse your channel?"
                    ).c("option").c("value").t("open").up().up().c("option").c("value").t("authorize").up().up().c("option").c("value").t("whitelist").up().up().c("value").t(config.accessModel or "open").up().up().c("field",
                        var: "pubsub#publish_model"
                        type: "list-single"
                        label: "May new subscribers post on your channel?"
                    ).c("option").c("value").t("publishers").up().up().c("option").c("value").t("subscribers").up().up().c("value").t(config.publishModel or "subscribers").up().c("field",
                        var: "pubsub#creation_date"
                        type: "text-single"
                        label: "Creation date"
                    ).c("value").t(config.creationDate or new Date().toISOString())

            return
	    # <iq type='set'
	    #     from='hamlet@denmark.lit/elsinore'
	    #     to='pubsub.shakespeare.lit'
	    #     id='config2'>
	    #   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	    #     <configure node='princely_musings'>
	    #       <x xmlns='jabber:x:data' type='submit'>
	    #         <field var='FORM_TYPE' type='hidden'>
	    #           <value>http://jabber.org/protocol/pubsub#node_config</value>
	    #         </field>
	    # [...]
        if iq.attrs.type == "set" and configureEl and configureNode
            xEl = configureEl.getChild("x")
            if not xEl or xEl.attrs.type != "submit"
                replyCb new errors.BadRequest("No submitted form")
                return
            fields = {}
            xEl.getChildren("field").forEach (fieldEl) ->
                fields[fieldEl.attrs["var"]] = fieldEl.getChildText("value")

            if fields["FORM_TYPE"] != NS.PUBSUB_NODE_CONFIG
                replyCb new errors.BadRequest("Invalid form type")
                return
            controller.request
                feature: "config-node"
                operation: "modify"
                from: "xmpp:" + jid
                node: configureNode
                title: fields["pubsub#title"]
                description: fields["pubsub#description"]
                type: fields["pubsub#type"]
                accessModel: fields["pubsub#access_model"]
                publishModel: fields["pubsub#publish_model"]
                creationDate: fields["pubsub#creation_date"]
                callback: replyCb

            return

    # <iq type='get' id='reg1'>
    #   <query xmlns='jabber:iq:register'/>
    # </iq>
    registerEl = iq.getChild("query", NS.REGISTER)
    if iq.attrs.type == "get" and registerEl
        replyCb null, new xmpp.Element("query", xmlns: NS.REGISTER).c("instructions").t("Simply register here")
        return
    # <iq type='set' id='reg2'>
    #   <query xmlns='jabber:iq:register'/>
    # </iq>
    if iq.attrs.type == "set" and registerEl
        controller.request
            feature: "register"
            operation: "register"
            from: "xmpp:" + jid
            callback: replyCb

        return
    # <iq type='set'
    #     from='hamlet@denmark.lit/elsinore'
    #     to='pubsub.shakespeare.lit'
    #     id='pending1'>
    #   <command xmlns='http://jabber.org/protocol/commands'
    #            node='http://jabber.org/protocol/pubsub#get-pending'
    #            action='execute'/>
    commandEl = iq.getChild("command", NS.COMMANDS)
    if iq.attrs.type == "set" and commandEl and commandEl.attrs.node == NS.PUBSUB + "#get-pending" and commandEl.attrs.action == "execute"
        xEl = commandEl.getChild("x", NS.DATA)
        if xEl and xEl.attrs.type == "submit"
            xEl.getChildren("field").forEach (fieldEl) ->
                if field.attrs["var"] == "pubsub#node"
                    node = fieldEl.getChildText("value")
        unless node
    	    # Requesting pending subscriptions for all nodes, just
    	    # reply with a nodes list.
            controller.request
                feature: "get-pending"
                operation: "list-nodes"
                from: "xmpp:" + jid
                callback: (err, nodes) ->
                    if err
                        replyCb err
                        return
                    fieldEl = new xmpp.Element("command",
                        xmlns: NS.COMMANDS
                        node: NS.PUBSUB + "#get-pending"
                        status: "executing"
                        action: "execute"
                        sessionid: ""
                    ).c("x",
                        xmlns: NS.DATA
                        type: "form"
                    ).c("field",
                        var: "FORM_TYPE"
                        type: "hidden"
                    ).c("value").t(NS.PUBSUB + "#subscribe_authorization").up().up().c("field",
                        type: "list-single"
                        var: "pubsub#node"
                    )
                    nodes.forEach (node) ->
                        fieldEl.c("option").c("value").t node

                    replyCb null, fieldEl
        else
    	    # Requesting pending subscriptions for a specific
    	    # node. Reply ok and re-send form messages.
            controller.request
                feature: "get-pending"
                operation: "get-for-node"
                from: "xmpp:" + jid
                node: node
                callback: (err, users) ->
                    if err
                        replyCb err
                        return
                    replyCb null
                    # TODO: call notification hook from here
        return

    # <iq type='get' id='juliet1'>
    #   <query xmlns='urn:xmpp:archive#management'
    #          start='2002-06-07T00:00:00Z'
    #          end='2010-07-07T13:23:54Z'/>
    # </iq>
    archiveQueryEl = iq.getChild("query", NS.ARCHIVE_MANAGEMENT)
    if iq.attrs.type == "get" and archiveQueryEl
        # TODO: not only items
        controller.request
            feature: "retrieve-items"
            operation: "replay"
            from: "xmpp:" + jid
            timeStart: archiveQueryEl.attrs.start
            timeEnd: archiveQueryEl.attrs.end
            notifyCb: (item) ->
                conn.send new xmpp.Element("message",
                    to: iq.attrs.from
                    from: conn.jid.toString()
                    type: "headline"
                ).c("event", xmlns: NS.PUBSUB_EVENT).c("items", node: node).c("item", id: item.id).cnode(item.item)

            callback: replyCb

        return

    # Not yet returned? Catch all:
    if iq.attrs.type == "get" or iq.attrs.type == "set"
        replyCb new errors.FeatureNotImplemented("Feature is not implemented yet")


handleMessage = (msg) ->
    xEl = msg.getChild("x", NS.DATA)
    if xEl.attrs.type == "submit"
        fields = {}
        xEl.getChildren("field").forEach (fieldEl) ->
            fields[fieldEl.attrs["var"]] = fieldEl.getChildText("value")

        if field.FORM_TYPE == NS.PUBSUB + "#subscribe_authorization"
            subscriptions = {}
            subscriptions[fields["pubsub#subscriber_jid"]] = (if (fields["pubsub#allow"] == "true") then "subscribed" else "none")
            controller.request
                feature: "manage-subscriptions"
                operation: "modify"
                from: "xmpp:" + jid
                node: fields["pubsub#node"]
                subscriptions: subscriptions

##
# XEP-0059: Result Set Management
getRSMQuery = (el) ->
    setEl = el.getChild("set", NS.RSM)
    unless setEl
        return undefined
    q = {}

    if (el = setEl.getChild("max"))
        q.max = parseInt(el.getText(), 10)
    if (el = setEl.getChild("after"))
        q.after = el.getText()
    if (el = setEl.getChild("before"))
        q.before = el.getText()
    q

addRSMResult = (r, el) ->
    unless r
        return
    setEl = el.c("set", NS.RSM)
    if r.hasOwnProperty("count")
        setEl.c("count").t r.count + ""
    if r.hasOwnProperty("first")
        setEl.c("first").t r.first
    if r.hasOwnProperty("last")
        setEl.c("last").t r.last


##
# Hooks for controller
##

notify = (jid, node, items) ->
    getOnlineResources(jid).forEach (fullJid) ->
        itemsEl = new xmpp.Element("message",
            to: jid
            from: conn.jid.toString()
            type: "headline"
        ).c("event", xmlns: NS.PUBSUB_EVENT).c("items", node: node)
        for id of items
            if items.hasOwnProperty(id)
                itemEl = itemsEl.c("item", id: id)
                items[id].forEach (child) ->
                    itemEl.cnode child
        conn.send itemsEl.root()

retracted = (jid, node, itemIds) ->
    getOnlineResources(jid).forEach (fullJid) ->
        itemsEl = new xmpp.Element("message",
            to: jid
            from: conn.jid.toString()
            type: "headline"
        ).c("event", xmlns: NS.PUBSUB_EVENT).c("items", node: node)
        itemIds.forEach (itemId) ->
            itemsEl.c "retract", id: itemId

        conn.send itemsEl.root()

approve = (jid, node, subscriber) ->
    if (m = subscriber.match(/^xmpp:(.+)$/))
        subscriber = m[1]
    conn.send new xmpp.Element("message",
        to: jid
        from: conn.jid.toString()
    ).c("x",
        xmlns: NS.DATA
        type: "submit"
    ).c("title").t("PubSub subscriber request").up().c("field",
        var: "FORM_TYPE"
        type: "hidden"
    ).c("value").t(NS.PUBSUB + "#subscribe_authorization").up().up().c("field",
        var: "pubsub#node"
        type: "text-single"
        label: "Node ID"
    ).c("value").t(node).up().up().c("field",
        var: "pubsub#subscriber_jid"
        type: "jid-single"
        label: "Subscriber address"
    ).c("value").t(subscriber).up().up().c("field",
        var: "pubsub#allow"
        type: "boolean"
        label: "Allow this JID to subscribe to this pubsub node?"
    ).c("value").t("false")

subscriptionModified = (jid, node, subscription) ->
    conn.send new xmpp.Element("message",
        to: jid
        from: conn.jid.toString()
    ).c("pubsub", xmlns: NS.PUBSUB_EVENT).c("subscription",
        node: node
        jid: jid
        subscription: subscription
    )

configured = (jid, node, config) ->
    conn.send new xmpp.Element("message",
        to: jid
        from: conn.jid.toString()
    ).c("pubsub", xmlns: NS.PUBSUB_EVENT).c("configuration", node: node).c("x",
        xmlns: NS.DATA
        type: "result"
    ).c("field",
        var: "FORM_TYPE"
        type: "hidden"
    ).c("value").t(NS.PUBSUB_META_DATA).up().up().c("field",
        var: "pubsub#title"
        type: "text-single"
        label: "A friendly name for the node"
    ).c("value").t(config.title or "").up().up().c("field",
        var: "pubsub#description"
        type: "text-single"
        label: "A description text for the node"
    ).c("value").t(config.description or "").up().up().c("field",
        var: "pubsub#type"
        type: "text-single"
        label: "Payload type"
    ).c("value").t(config.type or "").up().up().c("field",
        var: "pubsub#access_model"
        type: "list-single"
        label: "Who can subscribe and browse your channel?"
    ).c("value").t(config.accessModel or "open").up().up().c("field",
        var: "pubsub#publish_model"
        type: "list-single"
        label: "May new subscribers post on your channel?"
    ).c("value").t(config.publishModel or "subscribers").up().c("field",
        var: "pubsub#creation_date"
        type: "text-single"
        label: "Creation date"
    ).c("value").t(config.creationDate or new Date().toISOString())
