process.on 'uncaughtException', (err) ->
    console.error "uncaughtException: #{err.stack || err.message || err.toString()}"

if process.argv.length < 3
    console.error "Usage: #{process.argv[0]} #{process.argv[1]} <config.js>"
    process.exit 1

process.chdir __dirname

config = require(process.argv[2])

xmppConn = new (require('./xmpp/connection').Connection)(config.xmpp)
xmppConn.iqHandler = require('./xmpp/pubsub_server').handler;
console.log 'xmppConn', xmppConn
