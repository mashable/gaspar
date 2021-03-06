require 'thread'
require "gaspar/version"
require "rufus/scheduler"
require 'colorize'
require 'active_support/core_ext/array/extract_options'
require 'active_support/inflector'
require 'active_support/concern'
require 'active_support/callbacks'

class Gaspar
  attr_reader :drift, :scheduler
  include ActiveSupport::Callbacks
  define_callbacks :scheduled

  class << self
    attr_reader :singleton

    # Public: Configure Gaspar
    #
    # options - an options hash
    def configure(options = {}, &block)
      @singleton ||= new(options, &block)
      self
    end

    # Public: Get whether Gaspar has been configured yet or not
    #
    # Returns: [Boolean]
    def configured?
      !@singleton.nil?
    end

    # Public: Stop processing jobs and destroy the singleton. Returns Gaspar to an unconfigured state.
    def destruct!
      retire
      @singleton = nil
    end

    # Public: Execute the configuration and start processing jobs.
    #
    # redis - The redis instance to use for synchronization
    def start!(redis)
      raise "Gaspar#configure has not been called, or did not succeed" if @singleton.nil?
      @singleton.send(:start!, redis) if @singleton
    end

    def retire
      return unless @singleton
      @singleton.send(:shutdown!)
    end

    def log(logger, message)
      logger.debug "[%s] %s" % ["Gaspar".yellow, message] if logger
    end

    def started?
      @singleton.started?
    end
  end

  def can_run_if(&block)
    @can_run_if = block
  end

  def before_each(&block)
    self.class.set_callback :scheduled, :before, &block
  end

  def after_each(&block)
    self.class.set_callback :scheduled, :after, &block
  end

  def around_each(&block)
    self.class.set_callback :scheduled, :around, &block
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
    cron = Rufus::CronLine.new(timing)
    next_fire = cron.next_time
    next_next_fire = cron.next_time(next_fire + 0.001)

    options[:period] = next_next_fire.to_i - next_fire.to_i
    schedule :cron, timing, args, options, &block
  end

  def started?
    @started
  end

  private

  def lua?
    @can_use_lua
  end

  def lock
    @lock.synchronize { yield }
  end

  def can_run?
    return false if STDOUT.tty? or STDERR.tty?
    return false if @can_run_if and @can_run_if.call == false
    return false if Object.const_defined? :Rails and Rails.env.test? and !@options[:permit_test_mode]
    return true
  end

  def schedule(method, timing, args = [], options = {}, &block)
    if block_given?
      options[:name] ||= args.first
    else
      klass, worker_args = *args
      options[:name] ||= "%s(%s)" % [klass, args.join(", ")]
      klass = klass.to_s
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
    key = "#{@options[:namespace]}:%s-%s" % [timing, name]
    period = options.delete :period
    expiry = period - 5
    expiry = 1 if expiry < 1

    scheduler.send method, timing, options do
      # If we can acquire a lock...
      begin
        acquire_lock(key, expiry) do
          log "#{Process.pid} running #{name}"
          # ...set the lock to expire, which makes sure that staggered workers with out-of-sync clocks don't
          lock { @running_jobs += 1 }
          # ...and then run the job
          run_callbacks(:scheduled, &block)
          lock { @running_jobs -= 1 }
        end
      rescue Redis::BaseError
        # pass
      end
    end
  end

  def log(message)
    self.class.log @logger, message
  end

  def initialize(options = {}, &block)
    @logger       = options[:logger]
    @options      = options
    @block        = block
    @lock = Mutex.new
    lock { @running_jobs = 0 }

    @options[:namespace] ||= "gaspar"
    @options[:worker]    ||= :sidekiq if Object.const_defined? :Sidekiq
    @options[:worker]    ||= :resque  if Object.const_defined? :Resque
  end

  def start!(redis)
    return log "Running under a controlling TTY. Refusing to start. Try starting from a daemonized process." unless can_run?

    @redis = redis
    @can_use_lua = @redis.info.keys.grep(/_lua/).any?

    return if @started

    sync_watches
    @scheduler = Rufus::Scheduler::PlainScheduler.new
    @scheduler.every("1h") { sync_watches }
    instance_eval &@block
    return unless can_run?

    @started = true
    @scheduler.start

    at_exit do
      @scheduler.stop if @scheduler
      force_shutdown_at = Time.now.to_i + 15
      sleep(0.1) while lock { @running_jobs } > 0 and Time.now.to_i < force_shutdown_at
    end
  end

  def shutdown!
    @scheduler.stop if @scheduler && @started
    @started = false
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

  def acquire_lock(name, expiry, &block)
    value = "#{Process.pid}-#{Time.now.utc.to_i}"
    if lua?
      lua_lock(name, expiry, value, &block)
    else
      legacy_lock(name, expiry, value, &block)
    end
  end

  def lua_lock(key, expiry, value, &block)
    block.call if @redis.evalsha(register_redis_lock_scripts, keys: [key], argv: [expiry.to_i, value]) == 1
  end

  def legacy_lock(key, expiry, value, &block)
    if @redis.setnx key, value
      @redis.expire key, expiry.to_i
      block.call
    end
  end

  def register_redis_lock_scripts
    @lock_func_sha ||= begin
      lock_func = <<-EOF
        if redis.call('ttl', KEYS[1]) == -1 then
          redis.call('del', KEYS[1])
        end
        return redis.call('setnx', KEYS[1], ARGV[2]) == 1 and redis.call('expire', KEYS[1], ARGV[1]) and 1 or 0
      EOF
      @redis.script(:load, lock_func)
      Digest::SHA1.hexdigest(lock_func)
    end
  end
end
