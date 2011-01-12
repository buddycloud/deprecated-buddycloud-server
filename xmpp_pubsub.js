var xmpp = require('node-xmpp');
var uuid = require('node-uuid');

var NS_PUBSUB = 'http://jabber.org/protocol/pubsub';
var NS_PUBSUB_EVENT = 'http://jabber.org/protocol/pubsub#event';

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
	}
    });
};

/**
 * Request handling
 */
function handleIq(iq) {
    var reply = new xmpp.Element('iq',
				 { from: iq.attrs.to,
				   to: iq.attrs.from,
				   id: iq.attrs.id,
				   type: 'result'
				 });
    var errorReply = function(err) {
	if (err.stack)
	    console.error(err.stack);
	else
	    console.error({err:err});

	reply.attrs.type = 'error';
	reply.c('error', { type: 'cancel' }).
	    c('text').t('' + c.message);
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

    var jid = new xmpp.JID(iq.attrs.from).bare().toString();
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
	    controller.createNode('xmpp:' + jid, createNode, replyCb);
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
	    controller.subscribeNode('xmpp:' + jid, subscribeNode, replyCb);
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
	    controller.publishItems('xmpp:' + jid, publishNode, items, replyCb);
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
	    controller.retractItems('xmpp:' + jid, retractNode, itemIds, notify, replyCb);
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
	    controller.getItems('xmpp:' + jid, itemsNode, function(err, items) {
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
console.log({itemsEl:itemsEl.toString()});
		    replyCb(null, itemsEl);
		}
	    });
	    return;
	}

	/* Not yet returned? Catch all: */
	if (iq.attrs.type === 'get' || iq.attrs.type === 'set') {
	    replyCb(new Error('unimplemented'));
	}
    }
}

/**
 * Hooks for controller
 */

function notify(jid, node, items) {
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
