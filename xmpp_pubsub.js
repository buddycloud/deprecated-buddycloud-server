/* TODO: filter for xmpp:* users everywhere */
var xmpp = require('node-xmpp');
var uuid = require('node-uuid');
var errors = require('./errors');

var NS_PUBSUB = 'http://jabber.org/protocol/pubsub';
var NS_PUBSUB_EVENT = 'http://jabber.org/protocol/pubsub#event';
var NS_PUBSUB_OWNER = 'http://jabber.org/protocol/pubsub#owner';
var NS_PUBSUB_NODE_CONFIG = 'http://jabber.org/protocol/pubsub#node_config';
var NS_PUBSUB_META_DATA = 'http://jabber.org/protocol/pubsub#meta-data';
var NS_DISCO_INFO = 'http://jabber.org/protocol/disco#info';
var NS_DISCO_ITEMS = 'http://jabber.org/protocol/disco#items';
var NS_DATA = 'jabber:x:data';
var NS_REGISTER = 'jabber:iq:register';
var NS_COMMANDS = 'http://jabber.org/protocol/commands';

/* Set by main.js */
var controller;
exports.setController = function(c) {
    controller = c;
    controller.hookFrontend('xmpp', { notify: notify,
				      retracted: retracted,
				      approve: approve,
				      subscriptionModified: subscriptionModified,
				      configured: configured
				    });
};


/* XMPP Component Connection */
var conn;

exports.start = function(config) {
    conn = new xmpp.Component(config.xmpp);
    conn.on('online', startPresenceTracking);
    conn.on('stanza', function(stanza) {

	console.log(stanza.toString());

	/* Don't reply to error stanzas */
	if (stanza.attrs.type === "error")
	    return;

	if (stanza.name === 'iq') {
	    switch(stanza.attrs.type) {
	    case 'get':
	    case 'set':
		handleIq(stanza);
		break;
	    }
	} else if (stanza.name === 'presence')
	    handlePresence(stanza);
	else if (stanza.name === 'message' &&
		 stanza.attrs.type !== 'error')
	    handleMessage(stanza);
    });
};

/**
 * Presence tracking
 */
var onlineResources = {};
function handlePresence(presence) {
    var jid = new xmpp.JID(presence.attrs.from);
    var user = jid.bare().toString();
    var resource = jid.resource;

    switch(presence.attrs.type) {
    case 'subscribe':
	conn.send(new xmpp.Element('presence', {
				       from: presence.attrs.to,
				       to: presence.attrs.from,
				       id: presence.attrs.id,
				       type: 'subscribed'
				   }));
	break;
    case 'subscribed':
	break;
    case 'unsubscribe':
	conn.send(new xmpp.Element('presence', {
				       from: presence.attrs.to,
				       to: presence.attrs.from,
				       id: presence.attrs.id,
				       type: 'unsubscribed'
				   }));
	break;
    case 'unsubscribed':
	break;
    case 'probe':
	conn.send(new xmpp.Element('presence', {
				       from: presence.attrs.to,
				       to: presence.attrs.from,
				       id: presence.attrs.id
				   }).
		  c('status').
		  t('Small happy channel server!'));
	break;
    case 'error':
	if (!resource) {
	    delete onlineResources[user];
	    break;
	}
	/* error from a full JID, fall-through: */
    case 'unavailable':
	if (onlineResources[user]) {
	    onlineResources[user] = onlineResources[user].filter(function(r) {
		return r != resource;
	    });
	    /* No resources left? */
	    if (onlineResources[user].length < 1)
		delete onlineResources[user];
	}
	break;
    default:
	if (!onlineResources.hasOwnProperty(user))
	    onlineResources[user] = [];
	if (onlineResources[user].indexOf(resource) < 0)
	    onlineResources[user].push(resource);
    }
}
/**
 * Returns all full JIDs we've seen presence from for a bare JID.
 */
function getOnlineResources(bareJid) {
    return onlineResources.hasOwnProperty(bareJid) ?
	onlineResources[bareJid] : [];
}
function startPresenceTracking() {
    onlineResources = {};
    controller.getAllSubscribers(function(err, subscribers) {
	if (!err && subscribers)
	    subscribers.forEach(function(subscriber) {
		var m;
		if ((m = subscriber.match(/^xmpp:(.+)$/))) {
		    var jid = m[1];
		    conn.send(new xmpp.Element('presence', { to: jid,
							     from: conn.jid,
							     type: 'probe'
							   }));
		}
	    });
    });
}
function subscribeIfNeeded(jid) {
    if (!onlineResources.hasOwnProperty(jid)) {
	conn.send(new xmpp.Element('presence', { to: jid,
						 from: conn.jid,
						 type: 'subscribe'
					       }));
    }
}

/**
 * Request handling
 */
function handleIq(iq) {
    var jid = new xmpp.JID(iq.attrs.from).bare().toString();
    var reply = new xmpp.Element('iq',
				 { from: iq.attrs.to,
				   to: iq.attrs.from,
				   id: iq.attrs.id || '',
				   type: 'result'
				 });
    var errorReply = function(err) {
	if (err.stack)
	    console.error(err.stack);
	else
	    console.error({err:err});

	reply.attrs.type = 'error';
	if (err.xmppElement)
	    reply.cnode(err.xmppElement());
	else
	    reply.c('error', { type: 'cancel' }).
		    c('text').t('' + err.message);
	return reply;
    };
    var replyCb = function(err, child) {
	if (err)
	    /* Error case */
	    conn.send(errorReply(err));
	else if (!err && child && child.root)
	    /* Result with info element */
	    conn.send(reply.cnode(child.root()));
	else
	    /* Result, empty */
	    conn.send(reply);
    };

    /*
     * <iq type='get'
     *     from='romeo@montague.net/orchard'
     *     to='plays.shakespeare.lit'
     *     id='info1'>
     *   <query xmlns='http://jabber.org/protocol/disco#info'/>
     * </iq>
     */
    var discoInfoEl = iq.getChild('query', NS_DISCO_INFO);
    if (iq.attrs.type === 'get' && discoInfoEl) {
	var node = discoInfoEl.attrs.node;
	var queryEl = new xmpp.Element('query', { xmlns: NS_DISCO_INFO });
	if (node)
	    queryEl.attrs.node = node;
	var features = controller.pubsubFeatures().
	    map(function(feature) {
		    return NS_PUBSUB + '#' + feature;
		}).
	    concat(NS_DISCO_INFO);
	if (!node)
	    features.push(NS_DISCO_ITEMS, NS_REGISTER);
	features.forEach(function(feature) {
	    queryEl.c('feature', { var: feature });
	});

	if (node) {
	    controller.request({ feature: 'config-node',
				 operation: 'retrieve',
				 from: 'xmpp:' + jid,
				 node: node,
				 callback: function(err, config) {
	        if (err) {
		    replyCb(err);
		    return;
		}

		queryEl.c('identity', { category: 'pubsub',
					type: 'leaf',
					name: config.title });
		queryEl.c('x', { xmlns: NS_DATA,
				 type: 'result' }).
			c('field', { var: 'FORM_TYPE',
				     type: 'hidden' }).
			c('value').t(NS_PUBSUB_META_DATA).up().
			up().
			c('field', { var: 'pubsub#title',
				     type: 'text-single',
				     label: 'A friendly name for the node' }).
			c('value').t(config.title || '').up().
			up().
			c('field', { var: 'pubsub#description',
				     type: 'text-single',
				     label: 'A description text for the node' }).
			c('value').t(config.description || '').up().
			up().
			c('field', { var: 'pubsub#type',
				     type: 'text-single',
				     label: 'Payload type' }).
			c('value').t(config.type || '').up().
			up().
			c('field', { var: 'pubsub#access_model',
				     type: 'list-single',
				     label: 'Who can subscribe and browse your channel?' }).
			c('value').t(config.accessModel || 'open').up().
			up().
			c('field', { var: 'pubsub#publish_model',
				     type: 'list-single',
				     label: 'May new subscribers post on your channel?' }).
			c('value').t(config.publishModel || 'subscribers').
			up().
			c('field', { var: 'pubsub#creation_date',
				     type: 'text-single',
				     label: 'Creation date' }).
			c('value').t(config.creationDate || new Date().toISOString());
		replyCb(null, queryEl);
	    } });
	} else {
	    /* Didn't request info about specific node, hence no need
	     * to get node config but respond immediately.
	     */
	    queryEl.c('identity', { category: 'pubsub',
				    type: 'service',
				    name: 'Channels service' });
	    queryEl.c('identity', { category: 'pubsub',
				    type: 'channels',  /* not in registry yet */
				    name: 'Channels service' });
	    replyCb(null, queryEl);
	}

	return;
    }
    /*
     * <iq type='get'
     *     from='romeo@montague.net/orchard'
     *     to='shakespeare.lit'
     *     id='items1'>
     *   <query xmlns='http://jabber.org/protocol/disco#items'/>
     * </iq>
     */
    var discoItemsEl = iq.getChild('query', NS_DISCO_ITEMS);
    if (iq.attrs.type === 'get' && discoItemsEl) {
	var node = discoItemsEl.attrs.node;
	var queryEl = new xmpp.Element('query', { xmlns: NS_DISCO_ITEMS });

	if (!node) {
	    /* Discovering service, not a specific node */
	    controller.request({ feature: 'browse-nodes',
				 operation: 'list',
				 from: 'xmpp:' + jid,
				 callback: function(err, nodes) {
	        if (err) {
		    errorReply(err);
		    return;
		}

		/* Iterate the controller browse-nodes result */
		nodes.forEach(function(node) {
		    var itemEl = queryEl.c('item', { jid: conn.jid,
						     node: node.node
						   });
		    if (node.title)
			itemEl.attrs.title = node.title;
		});
		replyCb(null, queryEl);
	    } });
	} else
	    replyCb(null, queryEl);
	return;
    }

    var pubsubEl = iq.getChild('pubsub', NS_PUBSUB);
    if (pubsubEl) {
	/*
	 * <iq type='set'
	 *     from='hamlet@denmark.lit/elsinore'
	 *     to='pubsub.shakespeare.lit'
	 *     id='create1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	 *     <create node='princely_musings'/>
	 *   </pubsub>
	 * </iq>
	 */
	var createEl = pubsubEl.getChild('create');
	var createNode = createEl && createEl.attrs.node;
	if (iq.attrs.type === 'set' && createEl && createNode) {
	    controller.request({ feature: 'create-nodes',
				 operation: 'create',
				 from: 'xmpp:' + jid,
				 node: createNode,
				 callback: replyCb
			       });
	    subscribeIfNeeded(jid);
	    return;
	}
	/*
	 * <iq type='set'
	 *     from='francisco@denmark.lit/barracks'
	 *     to='pubsub.shakespeare.lit'
	 *     id='sub1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	 *     <subscribe node='princely_musings'/>
	 *   </pubsub>
	 * </iq>
	 */
	var subscribeEl = pubsubEl.getChild('subscribe');
	var subscribeNode = subscribeEl && subscribeEl.attrs.node;
	if (iq.attrs.type === 'set' && subscribeEl && subscribeNode) {
	    /* TODO: reply is more complex */
	    controller.request({ feature: 'subscribe',
				 operation: 'subscribe',
				 from: 'xmpp:' + jid,
				 node: subscribeNode,
				 callback: function(err, subscription) {
				     if (err) {
					 replyCb(err);
					 return;
				     }

				     if (subscription === 'pending') {
					 replyCb(null, new xmpp.Element('pusub', { xmlns: NS_PUBSUB }).
						       c('subscription', { node: subscribeNode,
									   jid: jid,
									   subscription: subscription }));
				     } else {
					 replyCb(null);
				     }
				 } });
	    subscribeIfNeeded(jid);
	    return;
	}
	/*
	 * <iq type='set'
	 *     from='francisco@denmark.lit/barracks'
	 *     to='pubsub.shakespeare.lit'
	 *     id='unsub1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	 *      <unsubscribe
	 *          node='princely_musings'/>
	 *   </pubsub>
	 * </iq>
	 */
	var unsubscribeEl = pubsubEl.getChild('unsubscribe');
	var unsubscribeNode = unsubscribeEl && unsubscribeEl.attrs.node;
	if (iq.attrs.type === 'set' && unsubscribeEl && unsubscribeNode) {
	    controller.request({ feature: 'unsubscribe',
				 operation: 'unsubscribe',
				 from: 'xmpp:' + jid,
				 node: unsubscribeNode,
				 callback: replyCb
			       });
	    return;
	}
	/*
	 * <iq type='set'
	 *     from='hamlet@denmark.lit/blogbot'
	 *     to='pubsub.shakespeare.lit'
	 *     id='publish1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	 *     <publish node='princely_musings'>
	 *       <item id='bnd81g37d61f49fgn581'>
	 * ...
	 */
	var publishEl = pubsubEl.getChild('publish');
	var publishNode = publishEl && publishEl.attrs.node;
	if (iq.attrs.type === 'set' && publishEl && publishNode) {
	    var items = {};
	    publishEl.getChildren('item').forEach(function(itemEl) {
		var itemNode = itemEl.attrs.node || uuid();
		items[itemNode] = itemEl.children;
	    });
	    controller.request({ feature: 'publish',
				 operation: 'publish',
				 from: 'xmpp:' + jid,
				 node: publishNode,
				 items: items,
				 callback: replyCb
			       });
	    return;
	}
	/*
	 * <iq type='set'
	 *     from='hamlet@denmark.lit/elsinore'
	 *     to='pubsub.shakespeare.lit'
	 *     id='retract1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	 *     <retract node='princely_musings'>
	 *       <item id='ae890ac52d0df67ed7cfdf51b644e901'/>
	 *     </retract>
	 *   </pubsub>
	 * </iq>
	 */
	var retractEl = pubsubEl.getChild('retract');
	var retractNode = retractEl && retractEl.attrs.node;
	if (iq.attrs.type === 'set' && retractEl && retractNode) {
	    var itemIds = retractEl.getChildren('item').map(function(itemEl) {
		return itemEl.attrs.id;
	    });
	    var notify = retractEl.attrs.notify &&
		    (retractEl.attrs.notify === '1' ||
		     retractEl.attrs.notify === 'true');
	    controller.request({ feature: 'retract-items',
				 operation: 'retract',
				 from: 'xmpp:' + jid,
				 node: retractNode,
				 itemIds: itemIds,
				 notify: notify,
				 callback: replyCb
			       });
	    return;
	}
	/*
	 * <iq type='get'
	 *     from='francisco@denmark.lit/barracks'
	 *     to='pubsub.shakespeare.lit'
	 *     id='items1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	 *     <items node='princely_musings'/>
	 *   </pubsub>
	 * </iq>
	 */
	var itemsEl = pubsubEl.getChild('items');
	var itemsNode = itemsEl && itemsEl.attrs.node;
	if (iq.attrs.type === 'get' && itemsEl && itemsNode) {
	    /* TODO: check stanza size & support RSM */
	    controller.request({ feature: 'retrieve-items',
				 operation: 'retrieve',
				 from: 'xmpp:' + jid,
				 node: itemsNode,
				 callback: function(err, items) {
		if (err)
		    replyCb(err);
		else {
		    var itemsEl = new xmpp.Element('pubsub', { xmlns: NS_PUBSUB }).
				      c('items', { node: itemsNode });
		    for(var id in items) {
			var itemEl = itemsEl.c('item', { id: id  });
			items[id].forEach(function(el) {
			    if (el.name)
				itemEl.cnode(el);
			});
		    }
		    replyCb(null, itemsEl);
		}
	    } });
	    return;
	}
	/*
	 * <iq type='get'
	 *     from='francisco@denmark.lit/barracks'
	 *     to='pubsub.shakespeare.lit'
	 *     id='subscriptions1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	 *     <subscriptions/>
	 *   </pubsub>
	 * </iq>
	 */
	var subscriptionsEl = pubsubEl.getChild('subscriptions');
	if (iq.attrs.type === 'get' && subscriptionsEl) {
	    controller.request({ feature: 'retrieve-subscriptions',
				 operation: 'retrieve',
				 from: 'xmpp:' + jid,
				 callback: function(err, nodes) {
		if (err)
		    replyCb(err);
		else {
		    var subscriptionsEl = new xmpp.Element('pubsub', { xmlns: NS_PUBSUB }).
					      c('subscriptions');
		    nodes.forEach(function(node) {
			subscriptionsEl.c('subscription', { node: node.node,
							    jid: jid,
							    subscription: node.subscription
							  });
		    });
		    replyCb(null, subscriptionsEl);
		}
	    } });
	    return;
	}
	/*
	 * <iq type='get'
	 *     from='francisco@denmark.lit/barracks'
	 *     to='pubsub.shakespeare.lit'
	 *     id='affil1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub'>
	 *     <affiliations/>
	 *   </pubsub>
	 * </iq>
	 */
	var affiliationsEl = pubsubEl.getChild('affiliations');
	if (iq.attrs.type === 'get' && affiliationsEl) {
	    controller.request({ feature: 'retrieve-affiliations',
				 operation: 'retrieve',
				 from: 'xmpp:' + jid,
				 callback: function(err, affiliations) {
		if (err)
		    replyCb(err);
		else {
		    var affiliationsEl = new xmpp.Element('pubsub', { xmlns: NS_PUBSUB }).
					     c('affiliations');
		    affiliations.forEach(function(affiliation) {
			affiliationsEl.c('affiliation', { node: affiliation.node,
							  affiliation: affiliation.affiliation
							});
		    });
		    replyCb(null, affiliationsEl);
		}
	    } });
	    return;
	}
    }

    var pubsubOwnerEl = iq.getChild('pubsub', NS_PUBSUB_OWNER);
    if (pubsubOwnerEl) {
	/*
	 * <iq type='get'
	 *     from='hamlet@denmark.lit/elsinore'
	 *     to='pubsub.shakespeare.lit'
	 *     id='subman1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	 *     <subscriptions node='princely_musings'/>
	 *   </pubsub>
	 * </iq>
	 */
	var subscriptionsEl = pubsubOwnerEl.getChild('subscriptions');
	var subscriptionsNode = subscriptionsEl && subscriptionsEl.attrs.node;
	if (iq.attrs.type === 'get' && subscriptionsEl && subscriptionsNode) {
	    controller.request({ feature: 'manage-subscriptions',
				 operation: 'retrieve',
				 from: 'xmpp:' + jid,
				 node: subscriptionsNode,
				 callback: function(err, subscribers) {
		if (err)
		    replyCb(err);
		else {
		    var subscriptionsEl = new xmpp.Element('pubsub', { xmlns: NS_PUBSUB_OWNER }).
					      c('subscriptions', { node: subscriptionsNode });
		    subscribers.forEach(function(subscriber) {
			var m;
			if ((m = subscriber.user.match(/^xmpp:(.+)$/)))
			    subscriptionsEl.c('subscription', { jid: m[1],
								subscription: subscriber.subscription
							      });
		    });
		    replyCb(null, subscriptionsEl);
		}
	    } });
	    return;
	}
	/*
	 * <iq type='set'
	 *     from='hamlet@denmark.lit/elsinore'
	 *     to='pubsub.shakespeare.lit'
	 *     id='subman2'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	 *     <subscriptions node='princely_musings'>
	 *       <subscription jid='bard@shakespeare.lit' subscription='subscribed'/>
	 *     </subscriptions>
	 *   </pubsub>
	 * </iq>
	 */
	 if (iq.attrs.type === 'set' && subscriptionsEl && subscriptionsNode) {
	     var subscriptions = {};
	     subscriptionsEl.getChildren('subscription').forEach(function(subscriptionEl) {
		 var jid = subscriptionEl.attrs.jid;
		 var subscription = subscriptionEl.attrs.subscription;
		 if (jid && subscription)
		     subscriptions['xmpp:' + jid] = subscription;
	     });
	     controller.request({ feature: 'manage-subscriptions',
				  operation: 'modify',
				  from: 'xmpp:' + jid,
				  node: subscriptionsNode,
				  subscriptions: subscriptions,
				  callback: replyCb
				});
	     return;
	 }
	/*
	 * <iq type='get'
	 *     from='hamlet@denmark.lit/elsinore'
	 *     to='pubsub.shakespeare.lit'
	 *     id='ent1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	 *     <affiliations node='princely_musings'/>
	 *   </pubsub>
	 * </iq>
	 */
	var affiliationsEl = pubsubOwnerEl.getChild('affiliations');
	var affiliationsNode = affiliationsEl && affiliationsEl.attrs.node;
	if (iq.attrs.type === 'get' && affiliationsEl && affiliationsNode) {
	    controller.request({ feature: 'modify-affiliations',
				 operation: 'retrieve',
				 from: 'xmpp:' + jid,
				 node: affiliationsNode,
				 callback: function(err, affiliations) {
	        if (err)
		    replyCb(err);
		else {
		    var affiliationsEl = new xmpp.Element('pubsub', { xmlns: NS_PUBSUB_OWNER }).
					     c('affiliations', { node: affiliationsNode });
		    affiliations.forEach(function(affiliation) {
			var m;
			if ((m = affiliation.user.match(/^xmpp:(.+)$/)))
			    affiliationsEl.c('affiliation', { jid: m[1],
							      affiliation: affiliation.affiliation
							    });
		    });
		    replyCb(null, affiliationsEl);
		}
	    } });
	    return;
	}
	/*
	 * <iq type='set'
	 *     from='hamlet@denmark.lit/elsinore'
	 *     to='pubsub.shakespeare.lit'
	 *     id='ent2'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	 *     <affiliations node='princely_musings'>
	 *       <affiliation jid='bard@shakespeare.lit' affiliation='publisher'/>
	 *     </affiliations>
	 *   </pubsub>
	 * </iq>
	 */
	if (iq.attrs.type === 'set' && affiliationsEl && affiliationsNode) {
	    var affiliations = {};
	    affiliationsEl.getChildren('affiliation').forEach(function(affiliationEl) {
		 var jid = affiliationEl.attrs.jid;
		 var affiliation = affiliationEl.attrs.affiliation;
		 if (jid && affiliation)
		     affiliations['xmpp:' + jid] = affiliation;
	    });
	    controller.request({ feature: 'modify-affiliations',
				 operation: 'modify',
				 from: 'xmpp:' + jid,
				 node: affiliationsNode,
				 affiliations: affiliations,
				 callback: replyCb
			       });
	    return;
	}
	/*
	 * <iq type='get'
	 *     from='hamlet@denmark.lit/elsinore'
	 *     to='pubsub.shakespeare.lit'
	 *     id='config1'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	 *     <configure node='princely_musings'/>
	 *   </pubsub>
	 * </iq>
	 */
	var configureEl = pubsubOwnerEl.getChild('configure');
	var configureNode = configureEl && configureEl.attrs.node;
	if (iq.attrs.type === 'get' && configureEl && configureNode) {
	    controller.request({ feature: 'config-node',
				 operation: 'retrieve',
				 from: 'xmpp:' + jid,
				 node: configureNode,
				 callback: function(err, config) {
	        if (err) {
		    replyCb(err);
		    return;
		}

		replyCb(null, new xmpp.Element('pubsub', { xmlns: NS_PUBSUB_OWNER }).
			c('configure', { node: configureNode }).
			c('x', { xmlns: NS_DATA,
				 type: 'form' }).
			c('field', { var: 'FORM_TYPE',
				     type: 'hidden' }).
			c('value').
			t(NS_PUBSUB_NODE_CONFIG).up().up().
			c('field', { var: 'pubsub#title',
				     type: 'text-single',
				     label: 'A friendly name for the node' }).
			c('value').t(config.title || '').up().
			up().
			c('field', { var: 'pubsub#description',
				     type: 'text-single',
				     label: 'A description text for the node' }).
			c('value').t(config.description || '').up().
			up().
			c('field', { var: 'pubsub#type',
				     type: 'text-single',
				     label: 'Payload type' }).
			c('value').t(config.type || '').up().
			up().
			c('field', { var: 'pubsub#access_model',
				     type: 'list-single',
				     label: 'Who can subscribe and browse your channel?' }).
			c('option').c('value').t('open').up().up().
			c('option').c('value').t('authorize').up().up().
			c('option').c('value').t('whitelist').up().up().
			c('value').t(config.accessModel || 'open').up().
			up().
			c('field', { var: 'pubsub#publish_model',
				     type: 'list-single',
				     label: 'May new subscribers post on your channel?' }).
			c('option').c('value').t('publishers').up().up().
			c('option').c('value').t('subscribers').up().up().
			c('value').t(config.publishModel || 'subscribers').
			up().
			c('field', { var: 'pubsub#creation_date',
				     type: 'text-single',
				     label: 'Creation date' }).
			c('value').t(config.creationDate || new Date().toISOString())
		       );
	    } });
	    return;
	}
	/*
	 * <iq type='set'
	 *     from='hamlet@denmark.lit/elsinore'
	 *     to='pubsub.shakespeare.lit'
	 *     id='config2'>
	 *   <pubsub xmlns='http://jabber.org/protocol/pubsub#owner'>
	 *     <configure node='princely_musings'>
	 *       <x xmlns='jabber:x:data' type='submit'>
	 *         <field var='FORM_TYPE' type='hidden'>
	 *           <value>http://jabber.org/protocol/pubsub#node_config</value>
	 *         </field>
	 * [...]
	 */
	if (iq.attrs.type === 'set' && configureEl && configureNode) {
	    var xEl = configureEl.getChild('x');
	    if (!xEl || xEl.attrs.type !== 'submit') {
		replyCb(new errors.BadRequest('No submitted form'));
		return;
	    }

	    var fields = {};
	    xEl.getChildren('field').forEach(function(fieldEl) {
		fields[fieldEl.attrs['var']] = fieldEl.getChildText('value');
	    });

	    if (fields['FORM_TYPE'] !== NS_PUBSUB_NODE_CONFIG) {
		replyCb(new errors.BadRequest('Invalid form type'));
		return;
	    }

	    controller.request({ feature: 'config-node',
				 operation: 'modify',
				 from: 'xmpp:' + jid,
				 node: configureNode,
				 title: fields['pubsub#title'],
				 description: fields['pubsub#description'],
				 type: fields['pubsub#type'],
				 accessModel: fields['pubsub#access_model'],
				 publishModel: fields['pubsub#publish_model'],
				 creationDate: fields['pubsub#creation_date'],
				 callback: replyCb });
	    return;
	}
    }
    /*
     * <iq type='get' id='reg1'>
     *   <query xmlns='jabber:iq:register'/>
     * </iq>
     */
    var registerEl = iq.getChild('query', NS_REGISTER);
    if (iq.attrs.type === 'get' && registerEl) {
	/* TODO: may include <registered/> */
	replyCb(null, new xmpp.Element('query', { xmlns: NS_REGISTER }).
		c('instructions').
		t('Simply register here'));
	return;
    }
    /*
     * <iq type='set' id='reg2'>
     *   <query xmlns='jabber:iq:register'>
     *   </query>
     * </iq>
     */
    if (iq.attrs.type === 'set' && registerEl) {
	controller.request({ feature: 'register',
			     operation: 'register',
			     from: 'xmpp:' + jid,
			     callback: replyCb });
	return;
    }
    /*
     * <iq type='set'
     *     from='hamlet@denmark.lit/elsinore'
     *     to='pubsub.shakespeare.lit'
     *     id='pending1'>
     *   <command xmlns='http://jabber.org/protocol/commands'
     *            node='http://jabber.org/protocol/pubsub#get-pending'
     *            action='execute'/>
     * </iq>
     */
    var commandEl = iq.getChild('command', NS_COMMANDS);
    if (iq.attrs.type === 'set' &&
	commandEl &&
	commandEl.attrs.node === NS_PUBSUB + '#get-pending' &&
	commandEl.attrs.action === 'execute') {

	var node;
	var xEl = commandEl.getChild('x', NS_DATA);
	if (xEl && xEl.attrs.type === 'submit') {
	    xEl.getChildren('field').forEach(function(fieldEl) {
		if (field.attrs['var'] === 'pubsub#node') {
		    node = fieldEl.getChildText('value');
		}
	    });
	}

	if (!node) {
	    /* Requesting pending subscriptions for all nodes, just
	     * reply with a nodes list.
	     */
	    controller.request({ feature: 'get-pending',
				 operation: 'list-nodes',
				 from: 'xmpp:' + jid,
				 callback: function(err, nodes) {
	        if (err) {
		    replyCb(err);
		    return;
		}

		var fieldEl = new xmpp.Element('command', { xmlns: NS_COMMANDS,
							    node: NS_PUBSUB + '#get-pending',
							    status: 'executing',
							    action: 'execute',
							    sessionid: '' }).
					 c('x', { xmlns: NS_DATA,
						  type: 'form' }).
					 c('field', { var: 'FORM_TYPE',
						      type: 'hidden' }).
					 c('value').t(NS_PUBSUB + '#subscribe_authorization').
					 up().up().
					 c('field', { type: 'list-single',
						      var: 'pubsub#node' });
		nodes.forEach(function(node) {
		    fieldEl.c('option').
			    c('value').
			    t(node);
		});
		replyCb(null, fieldEl);
	    } });
	} else {
	    /* Requesting pending subscriptions for a specific
	     * node. Reply ok and re-send form messages.
	     */
	    controller.request({ feature: 'get-pending',
				 operation: 'get-for-node',
				 from: 'xmpp:' + jid,
				 node: node,
				 callback: function(err, users) {
	        if (err) {
		    replyCb(err);
		    return;
		}

		replyCb(null);
		/* TODO: call notification hook from here */
	    } });
	}

	return;
    }

    /* Not yet returned? Catch all: */
    if (iq.attrs.type === 'get' || iq.attrs.type === 'set') {
	replyCb(new errors.FeatureNotImplemented('Feature is not implemented yet'));
    }
}

function handleMessage(msg) {
    var xEl = msg.getChild('x', NS_DATA);
    if (xEl.attrs.type === 'submit') {
	var fields = {};
	xEl.getChildren('field').forEach(function(fieldEl) {
	    fields[fieldEl.attrs['var']] = fieldEl.getChildText('value');
	});

	if (field.FORM_TYPE === NS_PUBSUB + '#subscribe_authorization') {
	    var subscriptions = {};
	    subscriptions[fields['pubsub#subscriber_jid']] = (fields['pubsub#allow'] === 'true') ?
		'subscribed' : 'none';
	    controller.request({ feature: 'manage-subscriptions',
				 operation: 'modify',
				 from: 'xmpp:' + jid,
				 node: fields['pubsub#node'],
				 subscriptions: subscriptions
			       });
	}
    }
}

/**
 * Hooks for controller
 */

function notify(jid, node, items) {
    getOnlineResources(jid).forEach(function(fullJid) {
	var itemsEl = new xmpp.Element('message', { to: jid,
						    from: conn.jid.toString(),
						    type: 'headline'
						  }).
	    c('event', { xmlns: NS_PUBSUB_EVENT }).
	    c('items', { node: node });
	for(var id in items)
	    if (items.hasOwnProperty(id)) {
		var itemEl = itemsEl.c('item', { id: id });
		items[id].forEach(function(child) {
		    itemEl.cnode(child);
		});
	    }
	conn.send(itemsEl.root());
    });
}

function retracted(jid, node, itemIds) {
    getOnlineResources(jid).forEach(function(fullJid) {
	var itemsEl = new xmpp.Element('message', { to: jid,
						    from: conn.jid.toString(),
						    type: 'headline'
						  }).
	    c('event', { xmlns: NS_PUBSUB_EVENT }).
	    c('items', { node: node });
	itemIds.forEach(function(itemId) {
	    itemsEl.c('retract', { id: itemId });
	});
	conn.send(itemsEl.root());
    });
}

function approve(jid, node, subscriber) {
    var m;
    if ((m = subscriber.match(/^xmpp:(.+)$/)))
	subscriber = m[1];

    conn.send(new xmpp.Element('message', { to: jid,
					    from: conn.jid.toString()
					  }).
	      c('x', { xmlns: NS_DATA,
		       type: 'submit' }).
	      c('title').
	      t('PubSub subscriber request').
	      up().
	      c('field', { var: 'FORM_TYPE',
			   type: 'hidden' }).
	      c('value').t(NS_PUBSUB + '#subscribe_authorization').
	      up().up().
	      c('field', { var: 'pubsub#node',
			   type: 'text-single',
			   label: 'Node ID' }).
	      c('value').t(node).
	      up().up().
	      c('field', { var: 'pubsub#subscriber_jid',
			   type: 'jid-single',
			   label: 'Subscriber address' }).
	      c('value').t(/* TODO: strip /^xmpp:/ */ subscriber).
	      up().up().
	      c('field', { var: 'pubsub#allow',
			   type: 'boolean',
			   label: 'Allow this JID to subscribe to this pubsub node?' }).
	      c('value').t('false'));
}

function subscriptionModified(jid, node, subscription) {
    conn.send(new xmpp.Element('message', { to: jid,
					    from: conn.jid.toString()
					  }).
	      c('pubsub', { xmlns: NS_PUBSUB_EVENT }).
	      c('subscription', { node: node,
				  jid: jid,
				  subscription: subscription }));
}

function configured(jid, node, config) {
    conn.send(new xmpp.Element('message', { to: jid,
					    from: conn.jid.toString()
					  }).
	      c('pubsub', { xmlns: NS_PUBSUB_EVENT }).
	      c('configuration', { node: node }).
	      c('x', { xmlns: NS_DATA,
		       type: 'result' }).
	      c('field', { var: 'FORM_TYPE',
			   type: 'hidden' }).
	      c('value').t(NS_PUBSUB_META_DATA).up().
	      up().
	      c('field', { var: 'pubsub#title',
			   type: 'text-single',
			   label: 'A friendly name for the node' }).
	      c('value').t(config.title || '').up().
	      up().
	      c('field', { var: 'pubsub#description',
			   type: 'text-single',
			   label: 'A description text for the node' }).
	      c('value').t(config.description || '').up().
	      up().
	      c('field', { var: 'pubsub#type',
			   type: 'text-single',
			   label: 'Payload type' }).
	      c('value').t(config.type || '').up().
	      up().
	      c('field', { var: 'pubsub#access_model',
			   type: 'list-single',
			   label: 'Who can subscribe and browse your channel?' }).
	      c('value').t(config.accessModel || 'open').up().
	      up().
	      c('field', { var: 'pubsub#publish_model',
			   type: 'list-single',
			   label: 'May new subscribers post on your channel?' }).
	      c('value').t(config.publishModel || 'subscribers').
	      up().
	      c('field', { var: 'pubsub#creation_date',
			   type: 'text-single',
			   label: 'Creation date' }).
	      c('value').t(config.creationDate || new Date().toISOString())
	     );
}
