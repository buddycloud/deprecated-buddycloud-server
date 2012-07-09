#!/usr/bin/env node
var fs = require('fs')
var path = require('path')
var tarballify = require('tarballify')
var version = require('./lib/version')
var name = require('./lib/name')

console.log("creating new tarball …")
var tarball = tarballify("./lib/main.js", {
    dirname:__dirname,
})
    .register(".node", function (body, file) {
        console.log("skip binary file:", file)
        return "skip binary"
    })
    .on('error', console.error.bind(console))
    .on('wait', function(){console.log("waiting for tarball to finish …")})
    .on('append', function(f,e){console.log("append",f.props.size,"\t",e.name, "\t",f.path)})
    .on('close', function(){console.log("done.")})
//     .on('syntaxError', console.error.bind(console))
tarball.pipe(fs.createWriteStream(path.join(__dirname, name+"-"+version+".tar.gz")))
;[
    "config.js.example",
    "package.json",
    "postgres.sql",
    "LICENSE",
    "README.md"
].forEach(function(file){tarball.append(file)})

console.log("setup ready …")
tarball.end()
