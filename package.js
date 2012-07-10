#!/usr/bin/env node
require('colors')
var fs = require('fs')
var path = require('path')
var tarballify = require('tarballify')
var version = require('./lib/version')
var name = require('./lib/name')

console.log("creating new tarball …".green)
var tarball = tarballify("./lib/main.js", {
    dirname:__dirname,
    cache:false,
})
    .on('warn',  function(w){console.warn( "WARN".yellow,w)})
    .on('error', function(e){console.error("ERR ".red   ,e)})
    .on('skip',  function(s){console.log( "skip".bold.blue,s.name.cyan,s.dirname)})
    .on('wait', function(){console.log("waiting for tarball to finish …".green)})
//     .on('append', function(f,e){console.log("append",f.props.size,"\t",e.name, "\t",f.path)})
    .on('close', function(){console.log("done.".bold.green)})
//     .on('syntaxError', console.error.bind(console))
tarball.pipe(fs.createWriteStream(path.join(__dirname, name+"-"+version+".tar.gz")))
;[
    // fix 'modName is not defined'
    "node_modules/ltx/lib/sax_expat.js",
    "node_modules/ltx/lib/sax_ltx.js",
    "node_modules/ltx/lib/sax_saxjs.js",
    // server files
    "config.js.example",
    "package.json",
    "postgres.sql",
    "LICENSE",
    "README.md"
].forEach(function(file){tarball.append(file)})
console.log("(fixed 'modName is not defined').")
console.log("('file is not defined' in jsconfig can be ignored).")

console.log("setup ready …".green)
tarball.end()
