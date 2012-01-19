path = require 'path'
{ run, compileScript, readFile, writeFile, notify } = require 'muffin'

task 'build', 'compile coffeescript → javascript', (options) ->
    run
        options:options
        files:[
            "./src/**/*.coffee"
            "package.json"
        ]
        map:
            'src/(.+).coffee': (m) ->
                compileScript m[0], path.join("lib" ,"#{m[1]}.js"), options

            'package.json': (m) ->
                readFile(m[0]).then (package) ->
                    json = JSON.parse(package)
                    data = "module.exports=\"#{json.version}\""
                    writeFile("lib/version.js", data).then ->
                        notify m[0], "Extracted version: #{json.version}"
