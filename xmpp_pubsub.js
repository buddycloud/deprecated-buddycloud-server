/* TODO: filter for xmpp:* users everywhere */
var xmpp = require('node-xmpp');
var uuid = require('node-uuid');

var NS_PUBSUB = 'http://jabber.org/protocol/pubsub';
var NS_PUBSUB_EVENT = 'http://jabber.org/protocol/pubsub#event';
var NS_PUBSUB_OWNER = 'http://jabber.org/protocol/pubsub#owner';
var NS_PUBSUB_NODE_CONFIG = 'http://jabber.org/protocol/pubsub#node_config';
var NS_DISCO_INFO = 'http://jabber.org/protocol/disco#info';
var NS_DISCO_ITEMS = 'http://jabber.org/protocol/disco#items';
var NS_DATA = 'jabber:x:data';

/* Set by main.js */
var controller;
exports.setController = function(c) {
    controller = c;
    controller.hookFrontend('xmpp', { notify: notify,
				      retracted: retracted
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
    case 'unavailable':
	if (onlineResources[user])
	    onlineResources[user] = onlineResources[user].filter(function(r) {
		return r != resource;
	    });
	break;
    default:
	if (!onlineResources.hasOwnProperty(user))
	    onlineResources[user] = [];
	if (onlineResources[user].indexOf(resource) < 0)
	    onlineResources[user].push(resource);
    }
}
function isOnline(jid) {
    if (!jid.hasOwnProperty('resource'))
	jid = new xmpp.JID(jid);
    var user = jid.bare().toString();
    var resource = jid.resource;

    return onlineResources.hasOwnProperty(user) &&
	onlineResources[user].indexOf(resource) >= 0;
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

    var discoInfoEl = iq.getChild('query', NS_DISCO_INFO);
    if (iq.attrs.type === 'get' && discoInfoEl) {
	var queryEl = new xmpp.Element('query', { xmlns: NS_DISCO_INFO });
	queryEl.c('identity', { category: 'pubsub',
				type: 'service',
				name: 'Channels service' });
	queryEl.c('identity', { category: 'pubsub',
				type: 'channels',  /* not in registry yet */
				name: 'Channels service' });
	var features = controller.pubsubFeatures().
	    map(function(feature) {
		    return NS_PUBSUB + '#' + feature;
		}).
	    concat(NS_DISCO_INFO, NS_DISCO_ITEMS);
	features.forEach(function(feature) {
	    queryEl.c('feature', { var: feature });
	});

	replyCb(null, queryEl);
	return;
    }
    var discoItemsEl = iq.getChild('query', NS_DISCO_ITEMS);
    if (iq.attrs.type === 'get' && discoItemsEl) {
	var queryEl = new xmpp.Element('query', { xmlns: NS_DISCO_ITEMS });
	/* TODO: browse users with open nodes */

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
			subscriptionsEl.c('subscription', { node: node,
							    jid: jid,
							    subscription: 'subscribed'
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
		    for(var node in affiliations) {
			affiliationsEl.c('affiliation', { node: node,
							  affiliation: affiliations[node]
							});
		    }
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
			if ((m = subscriber.match(/^xmpp:(.+)$/)))
			    subscriptionsEl.c('subscription', { jid: m[1],
								subscription: 'subscribed'
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
console.log({'get conf':[err,config]})
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
			up()
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
		replyCb(new Error('invalid-request'));
		return;
	    }

	    var fields = {};
	    xEl.getChildren('field').forEach(function(fieldEl) {
		var k = fieldEl.attrs['var'];
		var v = fieldEl.getChildText('value');
		if (k && v)
		    fields[k] = v;
	    });

	    if (fields['FORM_TYPE'] !== NS_PUBSUB_NODE_CONFIG) {
		replyCb(new Error('invalid-request'));
		return;
	    }

	    controller.request({ feature: 'config-node',
				 operation: 'modify',
				 from: 'xmpp:' + jid,
				 node: configureNode,
				 title: fields['pubsub#title'],
				 accessModel: fields['pubsub#access_model'],
				 publishModel: fields['pubsub#publish_model'],
				 callback: replyCb });
	    return;
	}
    }

    /* Not yet returned? Catch all: */
    if (iq.attrs.type === 'get' || iq.attrs.type === 'set') {
	replyCb(new Error('unimplemented'));
    }
}

/**
 * Hooks for controller
 */

function notify(jid, node, items) {
    if (!isOnline(jid))
	return;

    var itemsEl = new xmpp.Element('message', { to: jid,
						from: conn.jid.toString()
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
}

function retracted(jid, node, itemIds) {
    if (!isOnline(jid))
	return;

    var itemsEl = new xmpp.Element('message', { to: jid,
						from: conn.jid.toString()
					      }).
	          c('event', { xmlns: NS_PUBSUB_EVENT }).
		  c('items', { node: node });
    itemIds.forEach(function(itemId) {
	itemsEl.c('retract', { id: itemId });
    });
    conn.send(itemsEl.root());
}
