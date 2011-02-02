# channel-server

Social network users who are concerned about privacy and censorship
want to run their own decentralized instances, yielding full control
over own data. channel-server is a building block for a bright future:
it exposes your data to the network, featuring access control and
real-time update notification.

The primary network protocol is
[Buddycloud Channels](http://open.buddycloud.com/).

channel-server is distributed under the Apache License 2.0. See the
`LICENSE` file.


## Installation

At this early stage you should be prepared to upgrade this software in
the future.


### Requirements

You will need [Node](http://nodejs.org/) and its package manager
[npm](http://npmjs.org/). Then install development packages for
installing the required libraries:

    apt-get install -t testing libicu-dev libexpat-dev  # on Ubuntu/Debian
    
Next, depending on your preference, you may choose to just
`npm install channel-server` or install further dependencies
manually and run channel-server from the repository:
    
    npm install node-xmpp step node-uuid node-stringprep
    npm install cradle  # for CouchDB
    npm install pg      # for PostgreSQL


### Configuration

Edit `config.js`. It's not just JSON but full JavaScript, meaning you
can use unquoted object keys and even code.

The `xmpp` section sets up a component connection. For ejabberd the
listener configuration should look like this:

    {5233, ejabberd_service, [{hosts, ["channels.example.com"], [{password, "secret"}]}]}


#### CouchDB configuration

* Head to the administration interface at http://localhost:5984/_utils/
* Change the `reduce_limit` to `false`
* Create your database

#### PostgreSQL configuration

The [pg](https://github.com/brianc/node-postgres) library uses TCP
connections, no Unix domain sockets with user account
credentials. Hence, use `createuser -P` and grant the new user
privileges on your database.

Next, install the database schema:

    psql channel-server
    \i postgres.sql


### Start

Simply do:

    node main.js


## Hacking

The most important concept with Node is asynchronous event
handlers. We try to flatten the code flow by using the
[Step](http://github.com/creationix/step) library. Pay attention to
always call a callback in success as well as error cases. Lost control
flows may result in hanging requests and unfinished database
transactions.

### Design

Network applications are proxies. In general, they provide a
well-defined interface to databases with additional access control,
data sanitization, and in this case, notification hooks.

Additionally, the MVC pattern influenced this application much:

* View: network frontend such as `xmpp_pubsub.js`
* Controller: core logic in `controller.js`
* Model: database-specific backends with transaction support

### Backends

#### CouchDB

Implementing new features is easy with CouchDB as developers may
change their database schema as they please. Unless you're able to
optimize the hell out of it, don't use in production.

#### PostgreSQL

Sporting real transactions and a normalized database schema, this SQL
backend is expected to yield high performance.


## TODO

* `grep TODO *.js`
* [Result Set Management](http://xmpp.org/extensions/xep-0059.html)
* Outcast affiliation
* Subscription notification messages
* More configurability (channel presets)
* Topic channels
* More backends (MySQL? SQLite?)
* Further frontends: Web, oStatus
