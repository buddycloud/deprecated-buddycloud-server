var xmpp = require('node-xmpp');

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
	    case 'set':
		handleIqSet(stanza);
		break;
	    }
	}
    });
};

function handleIqSet(iq) {
    var reply = new xmpp.Element('iq',
				 { from: iq.attrs.to,
				   to: iq.attrs.from,
				   id: iq.attrs.id,
				   type: 'result'
				 });
    var errorReply = function(err) {
	reply.attrs.type = 'error';
	reply.c('error', { type: 'cancel' });
	return reply;
    };
    var replyCb = function(err) {
	if (!err)
	    conn.send(reply);
	else
	    conn.send(errorReply(err));
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
	if (createEl && createNode) {
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
	if (subscribeEl && subscribeNode) {
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
	if (publishEl && publishNode) {
	    var items = {};
	    publishEl.getChildren('item').forEach(function(itemEl) {
		var itemNode = itemEl.attrs.node || 'current';
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
	if (retractEl && retractNode) {
	    var itemIds = retractEl.getChildren('item').map(function(itemEl) {
		return itemEl.attrs.id;
	    });
	    var notify = retractEl.attrs.notify &&
		    (retractEl.attrs.notify === '1' ||
		     retractEl.attrs.notify === 'true');
	    controller.retractItems('xmpp:' + jid, retractNode, itemIds, notify, replyCb);
	}
    }
}

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
