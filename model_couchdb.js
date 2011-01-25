var ltx = require('ltx');
var errors = require('./errors');
var cradle = require('cradle');
cradle.setup({host: '127.0.0.1',
	      port: 5984,
              cache: false, raw: false});
var db = new(cradle.Connection)().database('channel-server');

/**
 * API entry point
 */
exports.transaction = function(cb) {
    new Transaction(cb);
};

/**
 * Transaction primitives
 *
 * Takes care of Optimistic Concurrency Control with CouchDB.
 *
 * Also converts errors to suitable format.
 */
var MAX_RETRIES = 10;

function Transaction(cb) {
    this.transactionCb = cb;
    /* all documents this transaction affects, which will be
     * atomically written upon commit()
     */
    this.saveDocs = {};
    cb(null, this);
}

/**
 * Perform only HEAD request to get the CouchDB document revision in
 * order to overwrite it later.
 */
Transaction.prototype.preload = function(id, cb) {
    db.head(id, function(err, headers) {
	var doc;
	if (err && err.error === 'not_found') {
	    doc = { _id: id };
	} else if (err) {
	    cb(err);
	    return;
	} else {
	    doc = { _id: id,
		    _rev: headers['etag'].slice(1, -1)
		  };
	}
	this.saveDocs[id] = doc;
	cb(null, doc);
    });
};

Transaction.prototype.load = function(id, cb) {
    if (this.saveDocs.hasOwnProperty(id)) {
	/* Shortcut if already cached */
	cb(null, this.saveDocs[id]);
	return;
    }

    db.get(id, function(err, res) {
	if (err && err.error === 'not_found')
	    cb.call(this, null, null);
	else if (err)
	    cb.call(this, new errors.InternalServerError(err.error));
	else {
	    var doc = res.toJSON();
	    this.saveDocs[doc._id] = doc;
	    cb.call(this, null, doc);
	}
    });
};

/**
 * Not asynchronous because we just keep docs to be written around
 * until the (atomic) commit.
 */
Transaction.prototype.save = function(doc) {
    this.saveDocs[doc._id] = doc;
};

/**
 * `delete' is a JavaScript keyword.
 */
Transaction.prototype.remove = function(doc) {
    doc._deleted = true;
    this.save(doc);
};

Transaction.prototype.commit = function(cb) {
    var that = this;

    /* Assemble db.save() parameter */
    var docs = [];
    for(var id in this.saveDocs) {
	if (this.saveDocs.hasOwnProperty(id))
	    docs.push(this.saveDocs[id]);
    }
    this.saveDocs = {};  /* Not needed anymore */

    db.save(docs, function(err) {
	if (err && err.error === 'conflict' && that.retries < MAX_RETRIES) {
	    /* Optimistic Concurrency Control retry */
	    that.retries++;
	    console.warn('CouchDB transaction retry ' + that.retries);
	    that.transactionCb(null, that);
	} else if (err)
	    cb(new errors.InternalServerError(err.error));
	else
	    cb(null);
    });
};

Transaction.prototype.rollback = function(cb) {
    /* Nothing to be done for optimistic concurrency control */
    cb(null);
};

Transaction.prototype.view = function(name, options, cb) {
    db.view(name, options, function(err, res) {
	if (err) {
	    cb(err);
	    return;
	}

	var results = [];
	res.toJSON().rows().forEach(function(row) {
	    results.push.apply(results, row.value);
	});
	cb(null, results);
    });
};

/**
 * TODO: abstract view retrieval for values handling & error wrapping.
 */

/**
 * Data model helpers
 */

function nodeKey(node) {
    return encodeURIComponent(node);
}
function itemKey(node, item) {
    return encodeURIComponent(node) + '&' + encodeURIComponent(item);
}


/**
 * Initialize views
 *
 * Attention: these need the CouchDB setting reduce_limit=false.
 */
db.save('_design/channel-server',
	{ views: {
	      nodeItems: {
		  map: function(doc) {
		      var delim = doc._id.indexOf('&');
		      if (delim > 0) {
			  var node = doc._id.substr(0, delim);
			  var itemId = doc._id.substr(delim + 1);
			  emit(node, { id: itemId,
				       date: doc.date
				     });
		      }
		  },
		  reduce: function(keys, values, rereduce) {
		      if (rereduce)
			  values = Array.prototype.concat.apply([], values);
		      return values.sort(function(a, b) {
			  if (a.date < b.date)
			      return -1;
			  else if (a.date > b.date)
			      return 1;
			  else
			      return 0;
		      });
		  }
	      },
	      affiliations: {
		  map: function(doc) {
		      if (doc._id.indexOf('&') < 0) {
			  /* is node */
			  var node = doc._id;

			  if (doc.publishers)
			      doc.publishers.forEach(function(publisher) {
				  var r = {};
				  r[node] = 'publisher';
				  emit(publisher, r);
			      });
			  if (doc.owners)
			      doc.owners.forEach(function(owner) {
				  var r = {};
				  r[node] = 'owner';
				  emit(owner, r);
			      });
			  if (doc.subscribers)
			      doc.subscribers.forEach(function(subscriber) {
				  var r = {};
				  r[node] = 'member';
				  emit(subscriber, r);
			      });
		      }
		  },
		  reduce: function(keys, values, rereduce) {
		      var r = {};
		      values.forEach(function(v) {
			  for(var node in v) {
			      var role = v[node];
			      if (role === 'owner')
				  r[node] = 'owner';
			      else if (role === 'publisher' &&
				       r[node] !== 'owner')
			          r[node] = 'publisher';
			      else if (role === 'member' &&
				       r[node] !== 'owner' &&
				       r[node] !== 'publisher')
			          r[node] = 'member';
			  }
		      });
		      return r;
		  }
	      },
	      subscriptions: {
		  map: function(doc) {
		      if (doc._id.indexOf('&') < 0) {
			  /* is node */
			  var node = doc._id;

			  if (doc.subscribers)
			      doc.subscribers.forEach(function(subscriber) {
				  emit(subscriber, node);
			      });
		      }
		  },
		  reduce: function(keys, values, rereduce) {
		      if (rereduce)
			  values = Array.prototype.concat.apply([], values);
		      return values;
		  }
	      },
	      subscribers: {
		  map: function(doc) {
		      if (doc._id.indexOf('&') < 0) {
			  /* is node */
			  var node = doc._id;

			  if (doc.subscribers)
			      doc.subscribers.forEach(function(subscriber) {
				  emit(node, subscriber);
			      });
		      }
		  },
		  reduce: function(keys, values, rereduce) {
		      if (rereduce)
			  values = Array.prototype.concat.apply([], values);
		      var result = [], seen = {};
		      values.forEach(function(value) {
			  if (!seen.hasOwnProperty(value)) {
			      seen[value] = true;
			      result.push(value);
			  }
		      });
		      return result;
		  }
	      }
	  } });

/**
 * Actual data model
 */

Transaction.prototype.createNode = function(node, cb) {
    /* TODO: filter node for chars */
    this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (doc) {
	    cb(new errors.Conflict('Node already exists'));
	    return;
	}

	this.save({ _id: nodeKey(node) });
    });
};

Transaction.prototype.subscribeNode = function(subscriber, node, cb) {
    this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	if (!doc.hasOwnProperty('subscribers'))
	    doc.subscribers = [];
	if (doc.subscribers.indexOf(subscriber) < 0)
	    doc.subscribers.push(subscriber);
	this.save(doc);
	cb(null);
    });
};

Transaction.prototype.unsubscribeNode = function(subscriber, node, cb) {
    this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	if (doc.hasOwnProperty('subscribers') &&
	    doc.subscribers.indexOf(subscriber) >= 0) {

	    doc.subscribers = doc.subscribers.filter(function(user) {
		return user !== subscriber;
	    });
	    this.save(doc);
	    cb(null);
	} else {
	    cb(new errors.NotFound('Not subscribed'));
	}
    });
};

Transaction.prototype.getSubscribers = function(node, cb) {
    this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}

	cb(null, doc.subscribers || []);
    });
};

Transaction.prototype.getSubscriptions = function(subscriber, cb) {
    this.view('channel-server/subscriptions', { group: true,
						key: subscriber }, cb);
};

Transaction.prototype.getAllSubscribers = function(cb) {
    this.view('channel-server/subscribers', { group: false }, cb);
};

Transaction.prototype.getAffiliation = function(user, node, cb) {
    this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	if (doc.hasOwnProperty('owners') &&
	    doc.owners.indexOf(user) >= 0) {
	    cb(null, 'owner');
	    return;
	}
	if (doc.hasOwnProperty('publishers') &&
	    doc.publishers.indexOf(user) >= 0) {
	    cb(null, 'publisher');
	    return;
	}
	if (doc.hasOwnProperty('subscribers') &&
	    doc.subscribers.indexOf(user) >= 0) {
	    cb(null, 'member');
	    return;
	}
	cb(null, 'none');
    });
};

Transaction.prototype.getAffiliations = function(user, cb) {
    this.view('channel-server/affiliations', { group: true,
					       key: user }, cb);
};

Transaction.prototype.getAffiliated = function(node, cb) {
    this.load(nodeKey(node, function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	var affiliations = [];
	if (doc.hasOwnProperty('owners'))
	    doc.owners.forEach(function(owner) {
		affiliations.push({ user: owner,
				    affiliation: 'owner' });
	    });
	if (doc.hasOwnProperty('publishers'))
	    doc.publishers.forEach(function(publisher) {
		affiliations.push({ user: publisher,
				    affiliation: 'publisher' });
	    });
	if (doc.hasOwnProperty('subscribers'))
	    doc.subscribers.forEach(function(subscriber) {
		affiliations.push({ user: subscriber,
				    affiliation: 'member' });
	    });
	cb(null, affiliations);
    }));
};

Transaction.prototype.addOwner = function(owner, node, cb) {
    this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(new Error(err.error));
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	if (!doc.hasOwnProperty('owners'))
	    doc.owners = [];
	if (doc.owners.indexOf(owner) < 0)
	    doc.owners.push(owner);
	this.save(doc);
	cb(null);
    });
};

/**
 * An item is always the children array of the <item node='...'> element
 */
Transaction.prototype.writeItem = function(publisher, node, id, item, cb) {
    /* TODO: check for node */
    this.preload(itemKey(node, id), function(err, doc) {
	if (err) {
	    cb(new errors.InternalServerError(err.error));
	    return;
	}

	doc.xml = item.join('').toString();
	doc.date = new Date().toISOString();
	this.save(doc);
	cb(null);
    });
};

Transaction.prototype.deleteItem = function(node, itemId, cb) {
    this.load(itemKey(node, itemId), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node or item'));
	    return;
	}

	this.remove(doc);
	cb(null);
    });
};

/**
 * sorted by time
 */
Transaction.prototype.getItemIds = function(node, cb) {
    this.view('channel-server/nodeItems', { group: true,
					    key: node }, function(err, values) {
        if (err) {
	    cb(err);
	    return;
	}

	var ids = values.map(function(value) {
	    return value.id;
	});
	cb(null, ids);
    });
};

Transaction.prototype.getItem = function(node, id, cb) {
    this.load(itemKey(node, id), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node or item'));
	    return;
	}

	var item;
	try {
	    item = ltx.parse(res.toJSON().xml).children;
	} catch (e) {
	    console.error('Parsing ' + JSON.stringify({node:node,id:id}) + ': ' + e.stack);
	    item = [];
	}
	cb(null, item);
    });
};

Transaction.prototype.getConfig = function(node, cb) {
    this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	var config = { title: doc.title,
		       accessModel: doc.accessModel,
		       publishModel: doc.publishModel
		     };
	cb(null, config);
    });
};

Transaction.prototype.setConfig = function(node, config, cb) {
    this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	if (config.title)
	    doc.title = config.title;
	if (config.accessModel)
	    doc.accessModel = config.accessModel;
	if (config.publishModel)
	    doc.publishModel = config.publishModel;
	db.save(doc);
	cb(null);
    });
};
