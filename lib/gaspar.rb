require 'thread'
require "gaspar/version"
require "rufus/scheduler"
require 'colorize'
require 'active_support/core_ext/array/extract_options'

class Gaspar
  VERSION = "0.0.1"

  attr_reader :drift, :scheduler

  class << self
    attr_reader :singleton

    def schedule(redis, options = {}, &block)
      if Object.const_defined? :Rails
        return unless options[:permit_test_mode] if Rails.env.test?
      end

      options[:worker] ||= :sidekiq if Object.const_defined? :Sidekiq
      options[:worker] ||= :resque  if Object.const_defined? :Resque

      @singleton ||= new(redis, options, &block)
      self
    end

    def start!
      raise "Gaspar#schedule has not been called, or did not succeed" if @singleton.nil?
      @singleton.send(:start!) if @singleton
    end

    def destruct!
      return unless @singleton
      @singleton.send(:shutdown!)
      @singleton = nil
    end

    def log(logger, message)
      logger.debug "[%s] %s" % ["GASPAR".yellow, message] if logger
    end
  end

  def every(timing, *args, &block)
    options = args.extract_options!

    # In order to make sure that jobs are executed at the same time regardless of who runs them
    # we quantitize the start time to the next-nearest time slice. This more closely emulates
    # cron-style behavior.
    if timing.is_a? String
      seconds = Rufus.parse_duration_string(timing)
    else
      seconds = timing.to_i
    end
    now = Time.now.to_i - drift
    start_at = Time.at( now + (seconds - (now % seconds)) )

    options = options.merge(:first_at => start_at)
    options[:period] = seconds

    schedule :every, timing, args, options, &block
  end

  def cron(timing, *args, &block)
    options = args.extract_options!
    next_fire = Rufus::CronLine.new(timing).next_time

    options[:period] = next_fire.to_i - Time.now.to_i
    schedule :cron, timing, args, options, &block
  end

  private

  def lock
    @lock.synchronize { yield }
  end

  def schedule(method, timing, args = [], options = {}, &block)
    if block_given?
      options[:name] ||= args.first
    else
      klass, worker_args = *args
      options[:name] ||= "%s(%s)" % [klass, args.join(", ")]
      case @options[:worker]
      when :resque
        block = Proc.new { Resque.enqueue klass.constantize, *worker_args }
      when :sidekiq
        block = Proc.new { klass.constantize.perform_async *worker_args }
      end
    end


    name = options.delete :name
    if name.nil?
      if Object.const_defined? :Sourcify
        name = Digest::SHA1.hexdigest(block.to_source)
      else
        raise "No :name specified and sourcify is not available. Specify a name, or add sourcify to your bundle."
      end
    end
    key = "cron:%s-%s" % [timing, name]
    period = options.delete :period
    expiry = period - 5
    expiry = 1 if expiry < 1

    scheduler.send method, timing, options do
      # If we can acquire a lock...
      if @redis.setnx key, Process.pid
        log "#{Process.pid} running #{name}"
        # ...set the lock to expire, which makes sure that staggered workers with out-of-sync clocks don't
        lock { @running_jobs += 1 }
        @redis.expire key, expiry
        # ...and then run the job
        block.call
        lock { @running_jobs -= 1 }
      end
    end
  end

  def log(message)
    self.class.log @logger, message
  end

  def initialize(redis, options = {}, &block)
    @logger       = options.delete :logger
    @redis        = redis
    @options      = options
    @block        = block
    @lock = Mutex.new
    lock { @running_jobs = 0 }

    @options[:namespace] ||= "gaspar"
  end

  def start!
    return log "Running under a controlling TTY. Refusing to start. Try starting from a daemonized process." if STDOUT.tty? or STDERR.tty?
    return if @started

    @started = true
    sync_watches
    @scheduler = Rufus::Scheduler.start_new
    @scheduler.every("1h") { sync_watches }
    instance_eval &@block
    @block = nil

    at_exit do
      force_shutdown_at = Time.now.to_i + 15
      sleep(0.1) while lock { @running_jobs } > 0 and Time.now.to_i < force_shutdown_at
    end
  end

  def shutdown!
    @scheduler.stop if @scheduler
  end

  # Abuse Redis key TTLs to synchronize our watches
  def sync_watches
    if @redis.setnx "#{@options[:namespace]}:timesync", Time.now.to_i
      @redis.expire "#{@options[:namespace]}:timesync", 3.2e8.to_i  # Set to expire in ~100 years
    end
    epoch  = @redis.get("#{@options[:namespace]}:timesync").to_i
    ttl    = @redis.ttl "#{@options[:namespace]}:timesync"
    offset = (3.2e8 - ttl)
    @drift = Time.now.to_i - (epoch + offset)
    log "Resynced - Drift is #{@drift}"
  end
end