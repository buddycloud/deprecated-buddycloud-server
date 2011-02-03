var vows = require('vows'),
assert = require('assert'),
controller = require('./../controller');

var mockModel = {
    transaction: function(cb) {
	cb(null, { commit: function(cb) {
	    cb(null);
	}, rollback: function(cb) {
	    cb(null);
	}, createNode: function(node, cb) {
	    cb(null);
	}, getConfig: function(node, cb) {
	    cb(null, { title: 'A channel', accessModel: 'open', publishModel: 'subscribers' });
	}, getAffiliation: function(node, user, cb) {
	    cb(null, 'none');
	}, getSubscription: function(node, user, cb) {
	    cb(null, 'none');
	}, setAffiliation: function(node, user, affiliation, cb) {
	    cb(null);
	}, setSubscription: function(node, user, subscription, cb) {
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
		assert.equal('forbidden', err.condition);
	    }
	}
    }

}).run();
