var vows = require('vows'),
assert = require('assert'),
ltx = require('ltx'),
controller = require('./../controller');

var modelLog = [];
function assertModelLog(condition) {
    var any = modelLog.some(function(line) {
	    var i;
	    for(i = 0; i < line.length && i < condition.length; i++) {
		if (typeof condition[i] !== 'undefined' &&
		    line[i] !== condition[i])
		    return false;
	    }
	    return true;
	});
    assert.ok(any, "Expected: " + condition.join(' '));
}
var mockModel = {
    transaction: function(cb) {
	cb(null, { commit: function(cb) {
	    cb(null);
	}, rollback: function(cb) {
	    cb(null);
	}, createNode: function(node, cb) {
	    modelLog.push(['commit']);
	    cb(null);
	}, getConfig: function(node, cb) {
	    modelLog.push(['getConfig', node]);
	    var config = { title: 'A channel', accessModel: 'open', publishModel: 'subscribers' };
	    if (/\/geoloc\/previous$/.test(node))
		config.accessModel = 'whitelist';
	    if (/\/geoloc\/current$/.test(node))
		config.accessModel = 'authorize';
	    if (/channel$/.test(node))
		config.publishModel = 'publishers';
	    cb(null, config);
	}, getAffiliation: function(node, user, cb) {
	    modelLog.push(['getAffiliation', node, user]);
	    var affiliation = 'none', m;
	    if ((m = user.match(/^xmpp:(.+?)@affiliation.test/)))
		affiliation = m[1];
	    cb(null, affiliation);
	}, getSubscription: function(node, user, cb) {
	    modelLog.push(['getSubscription', node, user]);
	    var subscription = 'subscribed';
	    cb(null, subscription);
	}, getSubscribers: function(node, cb) {
	    modelLog.push(['getSubscribers', node]);
	    cb(null, [{ user: 'xmpp:subscriber@example.com', subscription: 'subscribed' }]);
	}, setAffiliation: function(node, user, affiliation, cb) {
	    modelLog.push(['setAffiliation', node, user, affiliation]);
	    cb(null);
	}, setSubscription: function(node, user, subscription, cb) {
	    modelLog.push(['setSubscription', node, user, subscription]);
	    cb(null);
	}, getOwners: function(node, cb) {
	    modelLog.push(['getOwners', node]);
	    var owners = [], m;
	    if ((m = node.match(/^\/user\/(.+?)/)))
		owners.push('xmpp:' + m[1]);
	    cb(null, owners);
	}, writeItem: function(publisher, node, id, item, cb) {
	    modelLog.push(['writeItem', publisher, node, id, item]);
	    cb(null);
	} });
    }
};
controller.setModel(mockModel);


vows.describe('request').addBatch({

    'create-nodes': {
	'should work for owner': {
	    topic: function() {
		controller.request({ feature: 'create-nodes',
				     operation: 'create',
				     from: 'xmpp:simon@buddycloud.com',
				     node: '/user/simon@buddycloud.com/channel',
				     callback: this.callback
				   });
	    },
	    'without error': function(err) {
		assert.ifError(err);
	    }
	},
	'should not work for non-owner': {
	    topic: function() {
		controller.request({ feature: 'create-nodes',
				     operation: 'create',
				     from: 'xmpp:eve@buddycloud.com',
				     node: '/user/simon@buddycloud.com/channel',
				     callback: this.callback
				   });
	    },
	    'forbidden': function(err, a) {
		assert.equal(err && err.condition, 'forbidden');
	    }
	}
    },

    'publish': {
	'when publishing': {
	    topic: function() {
		var that = this;
		this.notified = [];
		controller.hookFrontend('xmpp', {
		    notify: function(jid, node, items) {
			that.notified.push(jid);
		    }
		});
		var entryEl =
		    new ltx.Element('entry', { xmlns: 'http://jabber.org/protocol/pubsub' }).
		    c('published').t('2010-02-09T22:58:00+0100').up().
                    c('author').
                    c('name').t('astro@spaceboyz.net').up().
                    c('jid', { xmlns: 'http://buddycloud.com/atom-elements-0' }).
		    t('astro@spaceboyz.net').up().up().
		    c('content', { type: 'text' }).t('Hello Channel!').up().
                    c('geoloc', { xmlns: 'http://jabber.org/protocol/geoloc' }).
                    c('locality').t('Dresden');

		controller.request({ feature: 'publish',
				     operation: 'publish',
				     from: 'xmpp:astro@spaceboyz.net',
				     node: '/user/astro@spaceboyz.net/channel',
				     items: { first: entryEl },
				     callback: this.callback
				   });
	    },
	    'should have notified': function() {
		assert.ok(this.notified.indexOf('subscriber@example.com') >= 0,
			  'Not notified subscriber@example.com');
	    },
	    'should have written the item': function() {
		assertModelLog(['writeItem',
				'xmpp:astro@spaceboyz.net', '/user/astro@spaceboyz.net/channel',
				'first', undefined]);
	    }
	},
	'for a member to a read-only node': {
	    topic: function() {
		controller.request({ feature: 'publish',
				     operation: 'publish',
				     from: 'xmpp:member@example.com',
				     node: '/user/astro@spaceboyz.net/geoloc/current',
				     items: { first: new ltx.Element('entry', { xmlns: 'http://jabber.org/protocol/pubsub' }) },
				     callback: this.callback
				   });
	    },
	    'forbidden': function(err, a) {
		assert.equal(err && err.condition, 'forbidden');
	    }
	},
	'for a member to an open node': {
	    topic: function() {
		controller.request({ feature: 'publish',
				     operation: 'publish',
				     from: 'xmpp:member@affiliation.test',
				     node: '/user/astro@spaceboyz.net/channel',
				     items: { first: new ltx.Element('entry', { xmlns: 'http://jabber.org/protocol/pubsub' }) },
				     callback: this.callback
				   });
	    },
	    'success': function(err, a) {
		assert.isNull(err);
	    }
	}
    },

    'subscribe': {
	'for a hidden channel': {
	    topic: function() {
		controller.request({ feature: 'subscribe',
				     operation: 'subscribe',
				     from: 'xmpp:eve@example.gov',
				     node: '/user/astro@spaceboyz.net/geoloc/previous',
				     callback: this.callback
				   });
	    },
	    'forbidden': function(err, a) {
		assert.equal(err && err.condition, 'forbidden');
	    }
	},
	'for an authorization-only channel': {
	    topic: function() {
		controller.request({ feature: 'subscribe',
				     operation: 'subscribe',
				     from: 'xmpp:eve@example.gov',
				     node: '/user/astro@spaceboyz.net/geoloc/current',
				     callback: this.callback
				   });
	    },
	    'forbidden': function(err, subscription) {
		assert.isNull(err);
		assert.equal(subscription, 'pending');
	    }
	}
    }

}).run();
