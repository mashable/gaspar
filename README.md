# Gaspar
<img src="http://cdn.wikimg.net/strategywiki/images/0/04/Chrono_Trigger_Sprites_Gaspar.png" align="right" style="margin: 0 0 20px 20px" />

Gaspar is a recurring job ("cron") manager for Ruby daemons. It's primarily intended to be used with Rails + Sidekiq/Resque and friends.

Gaspar runs in-process, meaning there is no additional daemon to configure or maintain. Just define your jobs and they'll get fired by *something*,
whether that's your Rails processes, Sidekiq workers, or whatnot. Of course, you can always run it in a separate daemon if you wanted, too.

By default, Gaspar does not run if you are running under Rails and `Rails.env.test?`. Pass `:permit_test_mode => true` to `Gaspar.schedule` if you want Gaspar to run in test mode.

## Installation

Add this line to your application's Gemfile:

    gem 'gaspar'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install gaspar

## Usage

Usage is straightforward. Jobs are defined in a DSL. At a minimum, you need to pass a Redis instance to Gaspar, which is used for synchronizing job locks. The redis instance should be threadsafe; if you haven't turned it off explicitly, thread safety should already be present.

    Gaspar.configure(:logger => Rails.logger) do
      every "5s", "Ping" do
        Rails.logger.debug "ping"
      end
    end

Job definitions take one of several formats:

    every [time], [job name] do
      # Code to run
    end

If you have Resque or Sidekiq installed, you can pass a worker class name as string or symbol (plus any args), and it'll be automatically enqueued when the job fires:

    every [time], :DoStuffWorker, 1, 2, 3
    # If you are using Resque, this will fire `Resque.enqueue(DoStuffWorker, 1, 2, 3)`
    # If you are using Sidekiq, this will fire `DoStuffWorker.perform_async(1, 2, 3)`

Jobs also accept cron formats:

    cron "15,30 * * * *" do
      # Run stuff at 15 and 30 past the hour
    end

Jobs are each run in their own individual thread, but you should keep your jobs as lightweight as possible, so best practices will generally mean firing off background workers. Jobs should never exceed 15 seconds runtime, as on process exit, Gaspar will delay for up to 15 seconds to allow currently-running jobs to terminate before they are abandoned. Additionally, jobs should be threadsafe.

    Gaspar.configure(:logger => Rails.logger) do
      every "10m",         :UpdateStuffWorker
      cron  "0 * * * * ",  :DailyUpdateWorker, "with", :some_options => true
      every("1h")          { HourlyUpdateWorker.perform_async }
    end

Once you have Gaspar configured, you'll need to choose when to start it, and you'll pass a Redis connection for Gaspar to use. This is done separately from the configuration with the expectation that you won't want to run Gaspar for everything that boots your app, and you'll need to take care to close Gaspar (using `Gaspar#retire`) pre-forking, and to start it post-forking (using `Gaspar#start!`)

    Gaspar.start!(Redis.new)

Since Gaspar uses a Redis connection, you should initialize it after your daemon forks. For example, to use it with Unicorn:

    before_fork do |server, worker|
      Gaspar.retire
    end

    after_fork do |server, worker|
      Gaspar.start! Redis.new
    end

Or with Passenger:

    PhusionPassenger.on_event(:starting_worker_process) do |forked|
      if forked
        Gaspar.start! Redis.new
      end
    end

Finally, Gaspar will refuse to initialize if the process has a controlling TTY. This prevents it from running for, say, rake tasks and the like.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
