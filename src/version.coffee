fs = require('fs')

exports.version = JSON.parse(fs.readFileSync("#{__dirname}/../package.json")).version
