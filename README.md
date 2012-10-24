# Gaspar
<img src="http://cdn.wikimg.net/strategywiki/images/0/04/Chrono_Trigger_Sprites_Gaspar.png" align="right" />

Gaspar is a recurring job ("cron") manager for Ruby daemons. It's primarily intended to be used with Rails and friends.

Gaspar runs in-process, meaning there is no additional daemon to configure or maintain. Just define your jobs and they'll get fired by *something*,
whether that's your Rails processes, Sidekiq workers, or whatnot.

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

    Gaspar.schedule(Redis.new, :logger => Rails.logger) do
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

Jobs are each run in their own individual thread, but you should keep your jobs as lightweight as possible, so best practices will generally mean firing off background workers.

    Gaspar.schedule(Redis.new, :logger => Rails.logger) do
      every "10m",         :UpdateStuffWorker
      every "1h",          :HourlyUpdateWorker
      cron  "0 * * * * ",  :DailyUpdateWorker
    end

If you want Gaspar to only run in, say, your Sidekiq workers (and not your Rails instances or rake tasks), just scope it appropriately:

  if Sidekiq.server?
    Gaspar.schedule(...) do
      # ...
    end
  end

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
