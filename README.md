# channel-server

Social network users who are concerned about privacy and censorship
want to run their own decentralized instances, yielding full control
over own data. channel-server is a building block for a bright future:
it exposes your data to the network, featuring access control and
real-time update notification.


## Installation

At this early stage you should be prepared to upgrade this software in
the future.


### Requirements

You will need [Node](http://nodejs.org/) and its package manager
[npm](http://npmjs.org/). Then install development packages for
installing the required libraries:

    apt-get install libicu-dev libexpat-dev  # on Ubuntu/Debian
    npm install node-xmpp step cradle node-uuid


### Configuration

Edit `config.js`. It's not just JSON but full JavaScript, meaning you
can use unquoted object keys and even code.

The `xmpp` section sets up a component connection. For ejabberd the
listener configuration should look like this:

    {5233, ejabberd_service, [{hosts, ["channels.example.com"], [{password, "secret"}]}]}


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

Yet to be written.


## TODO

* `grep TODO *.js`
* [Result Set Management](http://xmpp.org/extensions/xep-0059.html)
* More configurability
* Topic channels
* More backends (PostgreSQL)
* Discoverability
* Further frontends: Web, oStatus
