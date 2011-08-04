# channel-server

Social network users who are concerned about privacy and censorship
want to run their own decentralized instances, yielding full control
over own data. channel-server is a building block for a bright future:
it exposes your data to the network, featuring access control and
real-time update notification.

The primary network protocol is
[buddycloud channels](http://buddycloud.org/).

channel-server is distributed under the Apache License 2.0. See the
`LICENSE` file.

## Installation

At this early stage you should be prepared to upgrade this software in
the future.

Instructions are located at https://buddycloud.org/wiki/Install


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

    Request                    subscribed
    ------>Frontend---->Router------------>.Database.
    <------|      |      |                 |  own & |
           |      |      |not subscribed   |synchro-|
      proxy|      |      |                 |  nized |
    <------|      |<-----/                 |  data  |
           |______|                        |________|

### Frontends

#### XEP-0060 Publish-Subscribe w/ buddycloud conventions

Top priority

#### OStatus

Future

### Backends

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