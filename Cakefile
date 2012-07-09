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
                readFile(m[0]).then (item) ->
                    json = JSON.parse(item)
                    data = "module.exports=\"#{json.version}\"\n"
                    writeFile("lib/version.js", data).then ->
                        notify m[0], "Extracted version: #{json.version}"
                    data = "module.exports=\"#{json.name}\"\n"
                    writeFile("lib/name.js", data).then ->
                        notify m[0], "Extracted name: #{json.name}"
