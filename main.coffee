run_sequence = require 'run-sequence'
require("coffee-script/register")

# utilities
path = require('path')
fs = require('fs')
_ = require('lodash')

argv = require('minimist')(process.argv.slice(2))

# gulp plugins
ngClassify = require 'gulp-ng-classify'
gif = require 'gulp-if'
sourcemaps = require 'gulp-sourcemaps'
coffee = require 'gulp-coffee'
gutil = require 'gulp-util'
annotate = require 'gulp-ng-annotate'
concat = require 'gulp-concat'
cached = require 'gulp-cached'
karma = require 'gulp-karma'
remember = require 'gulp-remember'
uglify = require 'gulp-uglify'
jade = require 'gulp-jade'
rename = require 'gulp-rename'
bower = require 'gulp-bower-deps'
templateCache = require './gulp-angular-templatecache'
lr = require 'gulp-livereload'
cssmin = require 'gulp-minify-css'
less = require 'gulp-less'
fixtures2js = require 'gulp-fixtures2js'
gulp_help = require 'gulp-help'

# dependencies for webserver
connect = require('connect')

module.exports =  (gulp) ->
    # standard gulp is not cs friendly (cgulp is). you need to register coffeescript first to be able to load cs files
    gulp = gulp_help gulp, afterPrintCallback: (tasks) ->
        console.log(gutil.colors.underline("Options:"))
        console.log(gutil.colors.cyan("  --coverage") + " Runs the test with coverage reports")
        console.log(gutil.colors.cyan("  --notests") + "  Skip running the tests")
        console.log("")

    # in prod mode, we uglify. in dev mode, we create sourcemaps
    # that should be the only difference, to minimize risk on difference between prod and dev builds
    prod = "prod" in argv._
    dev = "dev" in argv._
    coverage = argv.coverage
    notests = argv.notests

    # Load in the build config files
    config = require("./defaultconfig.coffee")
    buildConfig = require(path.join(process.cwd(), "guanlecoja", "config.coffee"))
    _.merge(config, buildConfig)

    # _.merge does not play well with lists, we just take the overridden version
    if buildConfig.karma?.files?
        config.karma.files = buildConfig.karma.files
    if buildConfig.buildtasks?
        config.buildtasks = buildConfig.buildtasks

    bower = bower(config.bower)
    bower.installtask(gulp)

    # first thing, we remove the build dir
    # we do it synchronously to simplify things
    require('rimraf').sync(config.dir.build)

    if coverage
        require('rimraf').sync(config.dir.coverage)

    if notests
        config.testtasks = ["notests"]

    catch_errors = (s) ->
        s.on "error", (e) ->
            error = gutil.colors.bold.red
            if e.fileName?
                gutil.log(error("#{e.plugin}:#{e.name}: #{e.fileName} +#{e.lineNumber}"))
            else
                gutil.log(error("#{e.plugin}:#{e.name}"))
            gutil.log(error(e.message))
            gutil.beep()
            s.end()
            s.emit("end")
            if not dev
                throw e
            return null
        s

    # if coverage, we need to put vendors and templates apart
    if coverage
        config.vendors_apart = true
        config.templates_apart = true

    script_sources = config.files.app.concat(config.files.scripts)

    unless config.vendors_apart
        # libs first, then app, then the rest
        script_sources = bower.deps.concat(script_sources)

    unless config.templates_apart
        script_sources = script_sources.concat(config.files.templates)


    # main scripts task.
    # if coffee_coverage, we only pre-process ngclassify, and karma will do the rest
    # in other cases, we have a more complex setup, if order to enable joining all
    # the sources (vendors, scripts, and templates)
    gulp.task 'scripts', false, ->
        if coverage and config.coffee_coverage
            return gulp.src script_sources
                .pipe(catch_errors(ngClassify(config.ngclassify(config))))
                .pipe gulp.dest path.join(config.dir.coverage, "src")

        gulp.src script_sources
            .pipe gif(dev or config.sourcemaps, sourcemaps.init())
            .pipe cached('scripts')
            # coffee build
            .pipe(catch_errors(gif("*.coffee", ngClassify(config.ngclassify(config)))))
            .pipe(catch_errors(gif("*.coffee", coffee())))
            # jade build
            .pipe(catch_errors(gif("*.jade", jade())))
            .pipe gif "*.html", rename (p) ->
                if config.name? and config.name isnt 'app'
                    p.dirname = path.join(config.name, "views")
                else
                    p.dirname = "views"
                p.basename = p.basename.replace(".tpl","")
                null
            .pipe remember('scripts')
            .pipe(gif("*.html", templateCache({module:config.name})))
            .pipe concat("scripts.js")
            # now everything is in js, do angular annotation, and minification
            .pipe gif(prod, annotate())
            .pipe gif(prod, uglify())
            .pipe gif(dev or config.sourcemaps, sourcemaps.write("."))
            .pipe gulp.dest config.dir.build
            .pipe gif(dev, lr())

    # concat vendors apart
    gulp.task 'vendors', false, ->
        unless config.vendors_apart and bower.deps.length > 0
            return
        gulp.src bower.deps
            .pipe gif(dev or config.sourcemaps, sourcemaps.init())
            .pipe concat("vendors.js")
            # now everything is in js, do angular annotation, and minification
            .pipe gif(prod, uglify())
            .pipe gif(dev or config.sourcemaps, sourcemaps.write("."))
            .pipe gulp.dest config.dir.build
            .pipe gif(dev, lr())

    # build and concat templates apart
    gulp.task 'templates', false, ->
        unless config.templates_apart
            return
        gulp.src config.files.templates
            # jade build
            .pipe(catch_errors(gif("*.jade", jade())))
            .pipe gif "*.html", rename (p) ->
                if config.name? and config.name isnt 'app'
                    p.dirname = path.join(config.name, "views")
                else
                    p.dirname = "views"
                p.basename = p.basename.replace(".tpl","")
                null
            .pipe(gif("*.html", templateCache({module:config.name})))
            .pipe concat("templates.js")
            .pipe gulp.dest config.dir.build

    # the tests files produce another file
    gulp.task 'tests', false, ->
        src = bower.testdeps.concat(config.files.tests)
        gulp.src src
            .pipe cached('tests')
            .pipe gif(dev, sourcemaps.init())
            # coffee build
            .pipe(catch_errors(gif("*.coffee", ngClassify(config.ngclassify))))
            .pipe(catch_errors(gif("*.coffee", coffee())))
            .pipe remember('tests')
            .pipe concat("tests.js")
            .pipe gif(dev, sourcemaps.write("."))
            .pipe gulp.dest config.dir.build


    # a customizable task that generates fixtures from external tool
    gulp.task 'generatedfixtures', false, config.generatedfixtures

    # a task to compile json fixtures into constants that sits on window.FIXTURES
    gulp.task 'fixtures', false, ->
        gulp.src config.files.fixtures, base: process.cwd()
            # fixtures
            .pipe rename dirname:""
            .pipe fixtures2js "fixtures.js",
                postProcessors:
                    "**/*.json": "json"
            .pipe gulp.dest config.dir.build

    # a task to compile less files
    gulp.task 'styles', false, ->
        gulp.src config.files.less
            .pipe cached('styles')
            .pipe catch_errors(less())
            .pipe remember('styles')
            .pipe concat("styles.css")
            .pipe gif(prod, cssmin())
            .pipe gulp.dest config.dir.build
            .pipe gif(dev, lr())

    # just copy fonts and imgs to the output dir
    gulp.task 'fonts', false, ->
        gulp.src config.files.fonts
            .pipe rename dirname:""
            .pipe gulp.dest path.join(config.dir.build, "fonts")

    gulp.task 'imgs', false, ->
        gulp.src config.files.images
            .pipe rename dirname:""
            .pipe gulp.dest path.join(config.dir.build, "img")

    # index.jade build
    gulp.task 'index', false, ->
        gulp.src config.files.index
            .pipe catch_errors(jade())
            .pipe gulp.dest config.dir.build

    # Run server.
    gulp.task 'server', false, ['index'], (next) ->
        if config.devserver?
            connect()
            .use(connect.static(config.dir.build))
            .listen(config.devserver.port, next)
        else
            next()

    gulp.task "watch", false, ->
        # karma own watch mode is used. no need to restart karma
        gulp.watch(script_sources, ["scripts"])
        gulp.watch(config.files.templates, ["templates"])
        gulp.watch(config.files.tests, ["tests"])
        gulp.watch(config.files.less, ["styles"])
        gulp.watch(config.files.index, ["index"])
        null

    # karma configuration, we build a lot of the config file automatically
    gulp.task "karma", false, ->
        karmaconf =
            basePath: config.dir.build
            action: if dev then 'watch' else 'run'

        _.merge(karmaconf, config.karma)

        if config.vendors_apart
            karmaconf.files = ["vendors.js"].concat(config.karma.files)

        if config.templates_apart
            karmaconf.files = karmaconf.files.concat(["templates.js"])
        if coverage
            karmaconf.reporters.push("coverage")
            karmaconf.preprocessors = {
                '**/scripts.js': ['sourcemap', 'coverage']
                '**/tests.js': ['sourcemap']
                '**/*.coffee': ['coverage']
            }
            for r in karmaconf.coverageReporter.reporters
                if r.dir == "coverage"
                    r.dir = config.dir.coverage
            karmaconf.basePath = "."
            scripts_index = karmaconf.files.indexOf("scripts.js")
            karmaconf.files = karmaconf.files.map (p) -> path.join(config.dir.build, p)

            if config.coffee_coverage
                # insert the pre-classified files inside the karma config file list
                # (after vendors.js)
                classified = script_sources.map (p) ->
                    path.join("coverage", p)
                karmaconf.files.splice.apply(karmaconf.files, [scripts_index, 1].concat(classified))

        gulp.src karmaconf.files
            .pipe karma(karmaconf)

    gulp.task "notests", false, ->
        null

    defaultHelp = "Build and test the code once, without minification"
    if argv.help or argv.h
        # we replace default task when help is requested
        gulp.task "default", defaultHelp, ['help'], ->
    else
        gulp.task "default", defaultHelp, (callback) ->
            run_sequence config.preparetasks, config.buildtasks, config.testtasks,
                callback
    devHelp = "Run needed tasks for development:
        build,
        tests,
        watch and rebuild. This task only ends when you hit CTRL-C!"
    if config.devserver
        devHelp += "\nAlso runs the dev server"

    gulp.task "dev", devHelp, ['default', 'watch', "server"]
    # prod is a fake task, which enables minification
    gulp.task "prod", "Run production build (minified)", ['default']
