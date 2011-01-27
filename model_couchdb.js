var ltx = require('ltx');
var errors = require('./errors');
var cradle = require('cradle');
var db;

exports.start = function(config) {
    cradle.setup({ host: config.host,
		   port: config.port,
		   cache: false,
		   raw: false
		 });
    db = new(cradle.Connection)().database(config.database);
};

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
    var that = this;
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
	that.saveDocs[id] = doc;
	cb.call(that, null, doc);
    });
};

Transaction.prototype.load = function(id, cb) {
    if (this.saveDocs.hasOwnProperty(id)) {
	/* Shortcut if already cached */
	cb.call(this, null, this.saveDocs[id]);
	return;
    }

    var that = this;
    db.get(id, function(err, res) {
	if (err && err.error === 'not_found')
	    cb.call(that, null, null);
	else if (err)
	    cb.call(that, new errors.InternalServerError(err.error));
	else {
	    var doc = res.toJSON();
	    that.saveDocs[doc._id] = doc;
	    cb.call(that, null, doc);
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
	var rows = res.toJSON().rows;
	if (rows)
	    rows.forEach(function(row) {
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

function assertNodeName(node) {
    if (/^[a-zA-Z0-9\-\/@\.]+$/.test(node))
	return true;
    else
	throw new errors.BadRequest('Invalid node name');
}
function nodeKey(node) {
    assertNodeName(node);
    return encodeURIComponent(node);
}
function itemKey(node, item) {
    assertNodeName(node);
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
	      /*
	       * per user
	       */
	      affiliations: {
		  map: function(doc) {
		      if (doc._id.indexOf('&') < 0) {
			  /* is node */
			  var node = doc._id;

			  if (doc.affiliations) {
			      for(var user in doc.affiliations)
				  emit(user, doc.affiliations[user]);
			  }
		      }
		  },
		  reduce: function(keys, values, rereduce) {
		      if (rereduce)
			  values = Array.prototype.concat.apply([], values);
		      return values;
		  }
	      },
	      subscriptions: {
		  map: function(doc) {
		      if (doc._id.indexOf('&') < 0) {
			  /* is node */
			  var node = doc._id;

			  if (doc.subscriptions) {
			      for(var user in doc.subscriptions)
				  emit(user, { node: node,
					       subscription: doc.subscriptions[user]
					     });
			  }
		      }
		  },
		  reduce: function(keys, values, rereduce) {
		      if (rereduce)
			  values = Array.prototype.concat.apply([], values);
		      return values;
		  }
	      },
	      /*
	       * used for getAllSubscribers(), thus no per-node
	       * affiliations checking is done.
	       */
	      subscribers: {
		  map: function(doc) {
		      if (doc._id.indexOf('&') < 0) {
			  /* is node */
			  var node = doc._id;

			  if (doc.subscriptions) {
			      for(var user in doc.subscriptions)
				  emit(node, user);
			  }
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
	cb(null);
    });
};

/*
 * Subscription management
 */

Transaction.prototype.getSubscription = function(node, user, cb) {
     this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	var subscription = doc.subscriptions &&
		       doc.subscriptions[user];
	cb(null, subscription);
     });
};

/**
 * The subscription types are used as string, while
 * 'none'/''/null/undefined means delete.
 */
Transaction.prototype.setSubscription = function(node, user, subscription, cb) {
     this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	if (!doc.hasOwnProperty('subscriptions'))
	    doc.subscriptions = {};
	if (subscription && subscription !== 'none')
	    doc.subscriptions[user] = subscription;
	else
	    delete doc.subscriptions[user];

	this.save(doc);
	cb(null);
    });
};

/**
 * cb(err, [{ user: user, subscription: subscription }])
 */
Transaction.prototype.getSubscribers = function(node, cb) {
    this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	var subscribers = [];
	if (doc.subscribers) {
	    for(var user in doc.subscribers)
		subscribers.push({ user: user,
				   subscription: doc.subscribers[user]
				 });
	}

	cb(null, subscribers);
    });
};

/**
 * cb(err, [{ node: '...', subscription: '...' }])
 */
Transaction.prototype.getSubscriptions = function(user, cb) {
    this.view('channel-server/subscriptions', { group: true,
						key: user }, cb);
};

/**
 * cb(err, [user])
 */
Transaction.prototype.getAllSubscribers = function(cb) {
    this.view('channel-server/subscribers', { group: false }, cb);
};

/**
 * Affiliation management
 */

Transaction.prototype.getAffiliation = function(node, user, cb) {
     this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	var affiliation = doc.affiliations &&
		       doc.affiliations[user];
	cb(null, affiliation);
     });
};

/**
 * The affiliation types are used as string, while
 * 'none'/''/null/undefined means delete.
 */
Transaction.prototype.setAffiliation = function(node, user, affiliation, cb) {
     this.load(nodeKey(node), function(err, doc) {
	if (err) {
	    cb(err);
	    return;
	}
	if (!doc) {
	    cb(new errors.NotFound('No such node'));
	    return;
	}

	if (!doc.hasOwnProperty('affiliations'))
	    doc.affiliations = {};
	if (affiliation && affiliation !== 'none')
	    doc.affiliations[user] = affiliation;
	else
	    delete doc.affiliations[user];

	this.save(doc);
	cb(null);
    });
};

/**
 * cb(err, [{ node: node, affiliation: affiliation }]
 */
Transaction.prototype.getAffiliations = function(user, cb) {
    this.view('channel-server/affiliations', { group: true,
					       key: user }, cb);
};

/**
 * cb(err, [{ user: user, affiliation: affiliation }]
 */
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
	if (doc.affiliations) {
	    for(var user in doc.affiliations)
		affiliations.push({ user: user,
				    affiliation: doc.affiliations[user]
				  });
	}
	cb(null, affiliations);
    }));
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

/**
 * Config management
 */

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
