var xmpp = require('node-xmpp');

var NS_PUBSUB = 'http://jabber.org/protocol/pubsub';

/* Set by main.js */
var controller;
exports.setController = function(c) {
    controller = c;
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
	if (createEl && createEl.attrs.node) {
	    var owner = new xmpp.JID(iq.attrs.from).bare().toString();
	    controller.createNode(createEl.attrs.node, owner, replyCb);
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
	if (subscribeEl && subscribeEl.attrs.node) {
	    var subscriber = new xmpp.JID(iq.attrs.from).bare().toString();
	    /* TODO: reply is more complex */
	    controller.subscribeNode(subscribeNode.attrs.node, owner, replyCb);
	    return;
	}
    }
}

