fs = require 'fs'
path = require 'path'
{ run, compileScript, readFile, writeFile, exec, notify } = require 'muffin'

# In Node.js 0.8.x, existsSync moved from path to fs.
existsSync = fs.existsSync or path.existsSync

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
                writeNameAndVersion = (name, version) ->
                    data = "module.exports=\"#{version}\"\n"
                    writeFile("lib/version.js", data).then ->
                        notify m[0], "Extracted version: #{version}"
                    data = "module.exports=\"#{name}\"\n"
                    writeFile("lib/name.js", data).then ->
                    notify m[0], "Extracted name: #{name}"

                readFile(m[0]).then (item) ->
                    { name, version } = JSON.parse(item)
                    if existsSync('.git')
                        exec('git describe --tags')[1].then (out) ->
                            # Remove leading "v" and trailing \n
                            version = out[0].slice(1, -1)
                            writeNameAndVersion name, version
                    else
                        writeNameAndVersion name, version
