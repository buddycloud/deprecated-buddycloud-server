process.on 'uncaughtException', (err) ->
    console.error "uncaughtException: #{err.stack || err.message || err.toString()}"

if process.argv.length < 3
    console.error "Usage: #{process.argv[0]} #{process.argv[1]} <config.js>"
    process.exit 1

process.chdir __dirname
